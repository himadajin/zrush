//! Persistent worker session for `store` and `plan` requests.

use std::ffi::OsStr;
use std::fmt;
use std::fs::File;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;

use crate::framing::{self, Decoder};
use crate::matching::Mode;
use crate::plan::{self, Producer};
use crate::record;
use crate::wire::{BUILD_STAMP, parse_canonical_u64};

const READ_BUFFER_SIZE: usize = 8192;
const FIRST_APPLICATION_FD: RawFd = 3;

pub(crate) fn start_watchdog(control_fd: RawFd) -> std::io::Result<()> {
    let control = acquire_control_fd(control_fd)?;
    set_close_on_exec(control.as_raw_fd())?;
    set_close_on_exec(libc::STDOUT_FILENO)?;

    std::thread::Builder::new()
        .name("zrush-control-watchdog".into())
        .spawn(move || watch_control(control))?;
    Ok(())
}

fn acquire_control_fd(raw_fd: RawFd) -> std::io::Result<OwnedFd> {
    if raw_fd < FIRST_APPLICATION_FD {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "--control-fd must be greater than 2",
        ));
    }

    let status = fcntl_get(raw_fd, libc::F_GETFL)?;
    if status & libc::O_ACCMODE == libc::O_WRONLY {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "--control-fd must be readable",
        ));
    }

    // No threads exist yet, so the successful fcntl validation above and this
    // ownership transfer cannot race with a close or descriptor replacement.
    Ok(unsafe { OwnedFd::from_raw_fd(raw_fd) })
}

fn set_close_on_exec(raw_fd: RawFd) -> std::io::Result<()> {
    let flags = fcntl_get(raw_fd, libc::F_GETFD)?;
    fcntl_set(raw_fd, libc::F_SETFD, flags | libc::FD_CLOEXEC)
}

fn fcntl_get(raw_fd: RawFd, command: libc::c_int) -> std::io::Result<libc::c_int> {
    loop {
        // fcntl is called with a command that takes no third argument.
        let result = unsafe { libc::fcntl(raw_fd, command) };
        if result >= 0 {
            return Ok(result);
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn fcntl_set(raw_fd: RawFd, command: libc::c_int, value: libc::c_int) -> std::io::Result<()> {
    loop {
        // fcntl is called with the integer argument required by F_SETFD.
        let result = unsafe { libc::fcntl(raw_fd, command, value) };
        if result >= 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn watch_control(control: OwnedFd) -> ! {
    let mut control = File::from(control);
    let mut byte = [0_u8; 1];
    loop {
        match control.read(&mut byte) {
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Ok(_) | Err(_) => immediate_failure_exit(),
        }
    }
}

fn immediate_failure_exit() -> ! {
    // This deliberately bypasses destructors and stdio flushing from the
    // watchdog thread; no Rust references cross the process exit.
    unsafe { libc::_exit(1) }
}

#[derive(Debug)]
pub(crate) enum Error {
    Framing(framing::Error),
    Protocol,
    Io(std::io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Framing(error) => write!(f, "framing failure: {error}"),
            Self::Protocol => f.write_str("protocol violation"),
            Self::Io(error) => write!(f, "I/O failure: {error}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Framing(error) => Some(error),
            Self::Io(error) => Some(error),
            Self::Protocol => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum End {
    Eof,
    Incompatible,
}

enum Handshake {
    Awaiting,
    Ready,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum MessageResult {
    Continue,
    Incompatible,
}

enum Request {
    Store {
        slot: Slot,
        generation: i64,
        payload: Vec<u8>,
    },
    Plan {
        generation: i64,
        cwd: Vec<u8>,
        params: plan::Params,
    },
    Invalid,
}

/// The slots zsh addresses; the worker never interprets what they mean.
#[derive(Clone, Copy)]
enum Slot {
    Live,
    Cache,
}

const SLOT_COUNT: usize = 2;

/// At most one parsed candidate generation per slot, for the lifetime of
/// this session (cli-protocol.md 「要求と応答」).
#[derive(Default)]
struct CandidateStore {
    slots: [Option<(i64, record::Stored)>; SLOT_COUNT],
}

impl CandidateStore {
    /// Replace this slot's generation, leaving every other slot untouched.
    fn insert(&mut self, slot: Slot, generation: i64, stored: record::Stored) {
        self.slots[slot as usize] = Some((generation, stored));
    }

    /// Look a generation up across every slot.
    fn find(&self, generation: i64) -> Option<&record::Stored> {
        self.slots
            .iter()
            .flatten()
            .find(|(stored_generation, _)| *stored_generation == generation)
            .map(|(_, stored)| stored)
    }
}

pub(crate) fn run<R: Read, W: Write>(mut input: R, mut output: W) -> Result<End, Error> {
    let mut decoder = Decoder::new();
    let mut handshake = Handshake::Awaiting;
    let mut store = CandidateStore::default();
    let mut buffer = [0; READ_BUFFER_SIZE];

    loop {
        let read = input.read(&mut buffer).map_err(Error::Io)?;
        if read == 0 {
            decoder.finish().map_err(Error::Framing)?;
            return Ok(End::Eof);
        }

        match decoder.feed(&buffer[..read]) {
            Ok(messages) => {
                for message in messages {
                    if process_message(&message, &mut handshake, &mut store, &mut output)?
                        == MessageResult::Incompatible
                    {
                        discard_requests(&mut input);
                        return Ok(End::Incompatible);
                    }
                }
            }
            Err(feed_error) => {
                for message in feed_error.completed {
                    if process_message(&message, &mut handshake, &mut store, &mut output)?
                        == MessageResult::Incompatible
                    {
                        discard_requests(&mut input);
                        return Ok(End::Incompatible);
                    }
                }
                return Err(Error::Framing(feed_error.error));
            }
        }
    }
}

/// The post-`incompatible` discard state of cli-protocol.md
/// 「セッションフレーミングと握手」.
fn discard_requests<R: Read>(input: &mut R) {
    std::io::copy(input, &mut std::io::sink()).ok();
}

fn process_message<W: Write>(
    message: &[u8],
    handshake: &mut Handshake,
    store: &mut CandidateStore,
    output: &mut W,
) -> Result<MessageResult, Error> {
    let fields = decode_fields(message)?;
    match handshake {
        Handshake::Awaiting => process_hello(&fields, handshake, output),
        Handshake::Ready => {
            process_request(fields, store, output)?;
            Ok(MessageResult::Continue)
        }
    }
}

fn process_hello<W: Write>(
    fields: &[Vec<u8>],
    handshake: &mut Handshake,
    output: &mut W,
) -> Result<MessageResult, Error> {
    if fields.len() != 2 || fields[0] != b"hello" || !is_build_stamp(&fields[1]) {
        return Err(Error::Protocol);
    }

    if fields[1] != BUILD_STAMP.as_bytes() {
        write_message(output, &[b"incompatible", BUILD_STAMP.as_bytes()])?;
        return Ok(MessageResult::Incompatible);
    }

    write_message(output, &[b"ready", BUILD_STAMP.as_bytes()])?;
    *handshake = Handshake::Ready;
    Ok(MessageResult::Continue)
}

fn process_request<W: Write>(
    fields: Vec<Vec<u8>>,
    store: &mut CandidateStore,
    output: &mut W,
) -> Result<(), Error> {
    let request_id = fields
        .get(1)
        .filter(|value| parse_identifier(value).is_some())
        .ok_or(Error::Protocol)?
        .clone();

    match parse_request(fields) {
        Request::Invalid => write_message(output, &[b"error", &request_id, b"invalid-request"]),
        Request::Store {
            slot,
            generation,
            payload,
        } => match record::parse(payload) {
            Ok(stored) => {
                store.insert(slot, generation, stored);
                write_message(output, &[b"ok", &request_id, b""])
            }
            Err(record::FramingError) => {
                write_message(output, &[b"error", &request_id, b"invalid-payload"])
            }
        },
        Request::Plan {
            generation,
            cwd,
            params,
        } => match store.find(generation) {
            Some(stored) => {
                let is_dir = |path: &[u8]| is_dir_from(&cwd, path);
                let body = plan::compute(&params, stored, &is_dir);
                write_message(output, &[b"ok", &request_id, &body])
            }
            None => write_message(output, &[b"error", &request_id, b"unknown-generation"]),
        },
    }
}

fn parse_request(fields: Vec<Vec<u8>>) -> Request {
    match fields.first().map(Vec::as_slice) {
        Some(b"store") => parse_store(fields),
        Some(b"plan") => parse_plan(fields),
        _ => Request::Invalid,
    }
}

fn parse_store(fields: Vec<Vec<u8>>) -> Request {
    let Ok([_kind, _id, slot, generation, payload]) = <[Vec<u8>; 5]>::try_from(fields) else {
        return Request::Invalid;
    };
    let Some(slot) = parse_slot(&slot) else {
        return Request::Invalid;
    };
    let Some(generation) = parse_identifier(&generation) else {
        return Request::Invalid;
    };
    Request::Store {
        slot,
        generation,
        payload,
    }
}

fn parse_plan(fields: Vec<Vec<u8>>) -> Request {
    let Ok(
        [
            _kind,
            _id,
            generation,
            cwd,
            producer,
            query,
            mode,
            smart_case,
            rows,
            width,
            trailing_space,
        ],
    ) = <[Vec<u8>; 11]>::try_from(fields)
    else {
        return Request::Invalid;
    };

    let Some(generation) = parse_identifier(&generation) else {
        return Request::Invalid;
    };
    let Some(producer) = parse_producer(&producer) else {
        return Request::Invalid;
    };
    let Some(mode) = Mode::parse(std::str::from_utf8(&mode).unwrap_or("")) else {
        return Request::Invalid;
    };
    let Some(smart_case) = parse_bool(&smart_case) else {
        return Request::Invalid;
    };
    let Some(rows) = parse_positive_usize(&rows) else {
        return Request::Invalid;
    };
    let Some(width) = parse_positive_usize(&width) else {
        return Request::Invalid;
    };
    let Some(trailing_space) = parse_bool(&trailing_space) else {
        return Request::Invalid;
    };

    Request::Plan {
        generation,
        cwd,
        params: plan::Params {
            producer,
            query,
            mode,
            smart_case,
            rows,
            width,
            trailing_space,
        },
    }
}

fn parse_slot(value: &[u8]) -> Option<Slot> {
    match value {
        b"live" => Some(Slot::Live),
        b"cache" => Some(Slot::Cache),
        _ => None,
    }
}

fn parse_producer(value: &[u8]) -> Option<Producer> {
    match value {
        b"compsys" => Some(Producer::Compsys),
        b"history" => Some(Producer::History),
        _ => None,
    }
}

fn parse_bool(value: &[u8]) -> Option<bool> {
    match value {
        b"true" => Some(true),
        b"false" => Some(false),
        _ => None,
    }
}

/// `request_id` and `candidate_generation` share one grammar: canonical
/// ASCII decimal in `1..=i64::MAX`.
fn parse_identifier(value: &[u8]) -> Option<i64> {
    let parsed = parse_canonical_u64(value)?;
    i64::try_from(parsed).ok().filter(|id| *id > 0)
}

fn parse_positive_usize(value: &[u8]) -> Option<usize> {
    let parsed = parse_canonical_u64(value)?;
    usize::try_from(parsed).ok().filter(|number| *number > 0)
}

fn is_build_stamp(value: &[u8]) -> bool {
    !value.is_empty()
        && value
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
}

fn decode_fields(message: &[u8]) -> Result<Vec<Vec<u8>>, Error> {
    let mut decoder = Decoder::new();
    let fields = decoder
        .feed(message)
        .map_err(|feed_error| Error::Framing(feed_error.error))?;
    decoder.finish().map_err(Error::Framing)?;
    Ok(fields)
}

fn write_message<W: Write>(output: &mut W, fields: &[&[u8]]) -> Result<(), Error> {
    let payload: Vec<u8> = fields
        .iter()
        .flat_map(|field| framing::encode(field))
        .collect();
    output
        .write_all(&framing::encode(&payload))
        .map_err(Error::Io)?;
    output.flush().map_err(Error::Io)
}

fn is_dir_from(cwd: &[u8], path: &[u8]) -> bool {
    let path = Path::new(OsStr::from_bytes(path));
    let resolved = if path.is_absolute() {
        path.to_path_buf()
    } else {
        Path::new(OsStr::from_bytes(cwd)).join(path)
    };
    std::fs::metadata(resolved)
        .map(|metadata| metadata.is_dir())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn message(fields: &[&[u8]]) -> Vec<u8> {
        let inner: Vec<u8> = fields
            .iter()
            .flat_map(|field| framing::encode(field))
            .collect();
        framing::encode(&inner)
    }

    fn messages(bytes: &[u8]) -> Vec<Vec<Vec<u8>>> {
        let mut outer = Decoder::new();
        let frames = outer.feed(bytes).unwrap();
        outer.finish().unwrap();
        frames
            .iter()
            .map(|frame| decode_fields(frame).unwrap())
            .collect()
    }

    struct FailingReader;

    impl Read for FailingReader {
        fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
            Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "read failed",
            ))
        }
    }

    struct FailingWriter;

    impl Write for FailingWriter {
        fn write(&mut self, _buffer: &[u8]) -> std::io::Result<usize> {
            Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "write failed",
            ))
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// One batch header plus one candidate record.
    fn payload(word: &[u8]) -> Vec<u8> {
        [b"b\x01\0w\x01", word, b"\0"].concat()
    }

    fn store_request<'a>(
        id: &'a [u8],
        slot: &'a [u8],
        generation: &'a [u8],
        payload: &'a [u8],
    ) -> Vec<&'a [u8]> {
        vec![b"store", id, slot, generation, payload]
    }

    fn plan_request<'a>(id: &'a [u8], generation: &'a [u8]) -> Vec<&'a [u8]> {
        vec![
            b"plan", id, generation, b"/", b"compsys", b"", b"typo", b"true", b"10", b"40", b"true",
        ]
    }

    /// Field 3 of a terminal response: an `ok` body or an error `code`.
    fn body(response: &[Vec<u8>]) -> &[u8] {
        &response[2]
    }

    fn session(requests: &[Vec<u8>]) -> Vec<Vec<Vec<u8>>> {
        let mut input = message(&[b"hello", BUILD_STAMP.as_bytes()]);
        for fields in requests {
            input.extend_from_slice(fields);
        }
        let mut output = Vec::new();
        assert_eq!(run(Cursor::new(input), &mut output).unwrap(), End::Eof);
        let decoded = messages(&output);
        assert_eq!(
            decoded[0],
            [b"ready".to_vec(), BUILD_STAMP.as_bytes().to_vec()]
        );
        decoded
    }

    #[test]
    fn handshake_and_multiple_requests_share_one_session() {
        let decoded = session(&[
            message(&store_request(b"1", b"live", b"5", b"")),
            message(&plan_request(b"2", b"5")),
            message(&plan_request(b"3", b"5")),
        ]);

        assert_eq!(decoded[1], [b"ok".to_vec(), b"1".to_vec(), Vec::new()]);
        assert_eq!(&decoded[2][..2], [b"ok".as_slice(), b"2".as_slice()]);
        assert_eq!(&decoded[3][..2], [b"ok".as_slice(), b"3".as_slice()]);
        assert_eq!(body(&decoded[2]), b"\0\x30\0\x30\0\x30\0");
    }

    #[test]
    fn one_store_serves_every_later_plan() {
        let payload = payload(b"git");
        let decoded = session(&[
            message(&store_request(b"1", b"live", b"5", &payload)),
            message(&plan_request(b"2", b"5")),
            message(&plan_request(b"3", b"5")),
        ]);

        assert!(
            body(&decoded[2]).windows(3).any(|bytes| bytes == b"git"),
            "plan does not list the stored candidate: {:?}",
            body(&decoded[2])
        );
        assert_eq!(body(&decoded[2]), body(&decoded[3]));
    }

    #[test]
    fn a_new_generation_replaces_only_its_own_slot() {
        let cached = payload(b"git");
        let live = payload(b"grep");
        let recached = payload(b"gzip");
        let decoded = session(&[
            message(&store_request(b"1", b"cache", b"5", &cached)),
            message(&store_request(b"2", b"live", b"6", &live)),
            message(&store_request(b"3", b"cache", b"7", &recached)),
            message(&plan_request(b"4", b"7")),
            message(&plan_request(b"5", b"6")),
            message(&plan_request(b"6", b"5")),
        ]);

        assert!(body(&decoded[4]).windows(4).any(|b| b == b"gzip"));
        assert!(body(&decoded[5]).windows(4).any(|b| b == b"grep"));
        assert_eq!(
            decoded[6],
            [
                b"error".to_vec(),
                b"6".to_vec(),
                b"unknown-generation".to_vec()
            ]
        );
    }

    #[test]
    fn a_plan_for_a_generation_no_slot_holds_is_a_terminal_error() {
        let decoded = session(&[message(&plan_request(b"1", b"9"))]);

        assert_eq!(
            decoded[1],
            [
                b"error".to_vec(),
                b"1".to_vec(),
                b"unknown-generation".to_vec()
            ]
        );
    }

    #[test]
    fn a_store_that_fails_framing_leaves_every_slot_unchanged() {
        let live = payload(b"git");
        let cached = payload(b"grep");
        let decoded = session(&[
            message(&store_request(b"1", b"live", b"5", &live)),
            message(&store_request(b"2", b"cache", b"6", &cached)),
            message(&store_request(b"3", b"live", b"7", b"unterminated")),
            message(&plan_request(b"4", b"5")),
            message(&plan_request(b"5", b"6")),
            message(&plan_request(b"6", b"7")),
        ]);

        assert_eq!(
            decoded[3],
            [
                b"error".to_vec(),
                b"3".to_vec(),
                b"invalid-payload".to_vec()
            ]
        );
        // Neither the slot the failed store addressed nor the other one moved.
        assert!(body(&decoded[4]).windows(3).any(|b| b == b"git"));
        assert!(body(&decoded[5]).windows(4).any(|b| b == b"grep"));
        assert_eq!(
            decoded[6],
            [
                b"error".to_vec(),
                b"6".to_vec(),
                b"unknown-generation".to_vec()
            ]
        );
    }

    #[test]
    fn a_new_session_starts_with_an_empty_store() {
        let stored = payload(b"git");
        session(&[message(&store_request(b"1", b"live", b"5", &stored))]);

        let decoded = session(&[message(&plan_request(b"2", b"5"))]);

        assert_eq!(
            decoded[1],
            [
                b"error".to_vec(),
                b"2".to_vec(),
                b"unknown-generation".to_vec()
            ]
        );
    }

    #[test]
    fn mismatch_replies_once_and_discards_the_rest_of_stdin() {
        let input = [
            message(&[b"hello", b"deadbeef"]),
            message(&plan_request(b"1", b"5")),
            b"1:x!".to_vec(),
        ]
        .concat();
        let mut output = Vec::new();
        assert_eq!(
            run(Cursor::new(input), &mut output).unwrap(),
            End::Incompatible
        );
        assert_eq!(
            messages(&output),
            [vec![
                b"incompatible".to_vec(),
                BUILD_STAMP.as_bytes().to_vec()
            ]]
        );
    }

    #[test]
    fn correlatable_shape_and_payload_errors_are_in_band() {
        let decoded = session(&[
            message(&[b"other", b"7"]),
            message(&store_request(b"8", b"live", b"5", b"unterminated")),
            message(&store_request(b"9", b"elsewhere", b"5", b"")),
            message(&store_request(b"10", b"live", b"05", b"")),
            message(&plan_request(b"11", b"0")),
        ]);

        assert_eq!(
            decoded[1..],
            [
                vec![
                    b"error".to_vec(),
                    b"7".to_vec(),
                    b"invalid-request".to_vec()
                ],
                vec![
                    b"error".to_vec(),
                    b"8".to_vec(),
                    b"invalid-payload".to_vec()
                ],
                vec![
                    b"error".to_vec(),
                    b"9".to_vec(),
                    b"invalid-request".to_vec()
                ],
                vec![
                    b"error".to_vec(),
                    b"10".to_vec(),
                    b"invalid-request".to_vec()
                ],
                vec![
                    b"error".to_vec(),
                    b"11".to_vec(),
                    b"invalid-request".to_vec()
                ],
            ]
        );
    }

    /// cli-protocol.md 「要求と応答」: a `store` whose scalars *and* payload
    /// are both invalid answers with the error detected first.
    #[test]
    fn store_scalar_validation_precedes_payload_framing() {
        let decoded = session(&[message(&store_request(
            b"1",
            b"elsewhere",
            b"5",
            b"unterminated",
        ))]);

        assert_eq!(
            decoded[1],
            [
                b"error".to_vec(),
                b"1".to_vec(),
                b"invalid-request".to_vec()
            ]
        );
    }

    #[test]
    fn missing_or_noncanonical_request_id_is_fatal() {
        for fields in [
            vec![b"plan".as_slice()],
            vec![b"plan".as_slice(), b"01".as_slice()],
            vec![b"plan".as_slice(), b"9223372036854775808".as_slice()],
        ] {
            let input = [
                message(&[b"hello", BUILD_STAMP.as_bytes()]),
                message(&fields),
            ]
            .concat();
            let mut output = Vec::new();
            assert!(matches!(
                run(Cursor::new(input), &mut output),
                Err(Error::Protocol)
            ));
            assert_eq!(messages(&output).len(), 1);
        }
    }

    #[test]
    fn completed_prefix_is_written_before_later_outer_corruption() {
        let input = [
            message(&[b"hello", BUILD_STAMP.as_bytes()]),
            message(&store_request(b"1", b"live", b"5", b"")),
            b"1:x!".to_vec(),
        ]
        .concat();
        let mut output = Vec::new();
        let Err(Error::Framing(error)) = run(Cursor::new(input), &mut output) else {
            panic!("expected a framing error");
        };
        assert_eq!(error, framing::Error::InvalidTrailingComma);
        assert_eq!(messages(&output).len(), 2);
    }

    #[test]
    fn nested_framing_corruption_is_fatal() {
        let malformed_nested = framing::encode(b"4:plan,1:1");
        let input = [
            message(&[b"hello", BUILD_STAMP.as_bytes()]),
            malformed_nested,
        ]
        .concat();
        let mut output = Vec::new();
        let Err(Error::Framing(error)) = run(Cursor::new(input), &mut output) else {
            panic!("expected a framing error");
        };
        assert_eq!(error, framing::Error::TruncatedFrame);
        assert_eq!(messages(&output).len(), 1);
    }

    #[test]
    fn stream_io_failures_carry_their_source() {
        let Err(Error::Io(error)) = run(FailingReader, &mut Vec::new()) else {
            panic!("expected an I/O error");
        };
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);

        let Err(Error::Io(error)) = run(
            Cursor::new(message(&[b"hello", BUILD_STAMP.as_bytes()])),
            FailingWriter,
        ) else {
            panic!("expected an I/O error");
        };
        assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
    }

    #[test]
    fn scalar_parsers_require_canonical_positive_ascii() {
        assert_eq!(parse_identifier(b"1"), Some(1));
        assert_eq!(parse_identifier(b"9223372036854775807"), Some(i64::MAX));
        for value in [
            b"".as_slice(),
            b"0",
            b"01",
            b"+1",
            b"-1",
            b" 1",
            b"9223372036854775808",
        ] {
            assert_eq!(parse_identifier(value), None, "{value:?}");
        }
        for value in [b"1".as_slice(), b"42", usize::MAX.to_string().as_bytes()] {
            assert!(parse_positive_usize(value).is_some(), "{value:?}");
        }
        for value in [b"".as_slice(), b"0", b"01", b"+1", b"-1", b" 1"] {
            assert_eq!(parse_positive_usize(value), None, "{value:?}");
        }
    }

    #[test]
    fn relative_stat_paths_are_resolved_against_request_cwd() {
        let root = std::env::temp_dir().join(format!("zrush-worker-test-{}", std::process::id()));
        let child = root.join("child");
        std::fs::create_dir_all(&child).unwrap();
        assert!(is_dir_from(root.as_os_str().as_bytes(), b"child"));
        assert!(is_dir_from(b"/unrelated", child.as_os_str().as_bytes()));
        assert!(!is_dir_from(root.as_os_str().as_bytes(), b"~/child"));
        std::fs::remove_dir_all(root).unwrap();
    }
}
