//! Persistent worker session for plan requests.

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

enum Request<'a> {
    Valid {
        request_id: &'a [u8],
        cwd: &'a [u8],
        params: plan::Params,
        payload: &'a [u8],
    },
    Invalid {
        request_id: &'a [u8],
    },
}

pub(crate) fn run<R: Read, W: Write>(mut input: R, mut output: W) -> Result<End, Error> {
    let mut decoder = Decoder::new();
    let mut handshake = Handshake::Awaiting;
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
                    if process_message(&message, &mut handshake, &mut output)?
                        == MessageResult::Incompatible
                    {
                        discard_requests(&mut input);
                        return Ok(End::Incompatible);
                    }
                }
            }
            Err(feed_error) => {
                for message in feed_error.completed {
                    if process_message(&message, &mut handshake, &mut output)?
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
    output: &mut W,
) -> Result<MessageResult, Error> {
    let fields = decode_fields(message)?;
    match handshake {
        Handshake::Awaiting => process_hello(&fields, handshake, output),
        Handshake::Ready => {
            process_request(&fields, output)?;
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

fn process_request<W: Write>(fields: &[Vec<u8>], output: &mut W) -> Result<(), Error> {
    let request_id = fields
        .get(1)
        .filter(|value| parse_request_id(value).is_some())
        .ok_or(Error::Protocol)?;

    match parse_request(fields, request_id) {
        Request::Invalid { request_id } => {
            write_message(output, &[b"error", request_id, b"invalid-request"])
        }
        Request::Valid {
            request_id,
            cwd,
            params,
            payload,
        } => {
            let is_dir = |path: &[u8]| is_dir_from(cwd, path);
            match plan::run(&params, payload, &is_dir) {
                Ok(render_plan) => write_message(output, &[b"ok", request_id, &render_plan]),
                Err(record::FramingError) => {
                    write_message(output, &[b"error", request_id, b"invalid-payload"])
                }
            }
        }
    }
}

fn parse_request<'a>(fields: &'a [Vec<u8>], request_id: &'a [u8]) -> Request<'a> {
    let [
        cmd,
        _id,
        cwd,
        producer,
        query,
        mode,
        smart_case,
        rows,
        width,
        trailing_space,
        payload,
    ] = fields
    else {
        return Request::Invalid { request_id };
    };
    if cmd != b"plan" {
        return Request::Invalid { request_id };
    }

    let Some(producer) = parse_producer(producer) else {
        return Request::Invalid { request_id };
    };
    let Some(mode) = Mode::parse(std::str::from_utf8(mode).unwrap_or("")) else {
        return Request::Invalid { request_id };
    };
    let Some(smart_case) = parse_bool(smart_case) else {
        return Request::Invalid { request_id };
    };
    let Some(rows) = parse_positive_usize(rows) else {
        return Request::Invalid { request_id };
    };
    let Some(width) = parse_positive_usize(width) else {
        return Request::Invalid { request_id };
    };
    let Some(trailing_space) = parse_bool(trailing_space) else {
        return Request::Invalid { request_id };
    };

    Request::Valid {
        request_id,
        cwd,
        params: plan::Params {
            producer,
            query: query.clone(),
            mode,
            smart_case,
            rows,
            width,
            trailing_space,
        },
        payload,
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

fn parse_request_id(value: &[u8]) -> Option<i64> {
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

    fn request<'a>(id: &'a [u8], cwd: &'a [u8], payload: &'a [u8]) -> Vec<&'a [u8]> {
        vec![
            b"plan", id, cwd, b"compsys", b"", b"typo", b"true", b"10", b"40", b"true", payload,
        ]
    }

    #[test]
    fn handshake_and_multiple_requests_share_one_session() {
        let hello = message(&[b"hello", BUILD_STAMP.as_bytes()]);
        let first = request(b"1", b"/", b"");
        let second = request(b"2", b"/", b"");
        let input = [hello, message(&first), message(&second)].concat();
        let mut output = Vec::new();

        assert_eq!(run(Cursor::new(input), &mut output).unwrap(), End::Eof);
        let decoded = messages(&output);
        assert_eq!(
            decoded[0],
            [b"ready".to_vec(), BUILD_STAMP.as_bytes().to_vec()]
        );
        assert_eq!(&decoded[1][..2], [b"ok".as_slice(), b"1".as_slice()]);
        assert_eq!(&decoded[2][..2], [b"ok".as_slice(), b"2".as_slice()]);
        assert_eq!(decoded[1][2], b"\0\x30\0\x30\0\x30\0");
    }

    #[test]
    fn mismatch_replies_once_and_discards_the_rest_of_stdin() {
        let input = [
            message(&[b"hello", b"deadbeef"]),
            message(&request(b"1", b"/", b"")),
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
        let hello = message(&[b"hello", BUILD_STAMP.as_bytes()]);
        let bad_shape = message(&[b"other", b"7"]);
        let bad_payload = message(&request(b"8", b"/", b"unterminated"));
        let mut output = Vec::new();

        run(
            Cursor::new([hello, bad_shape, bad_payload].concat()),
            &mut output,
        )
        .unwrap();
        assert_eq!(
            messages(&output),
            [
                vec![b"ready".to_vec(), BUILD_STAMP.as_bytes().to_vec()],
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
            message(&request(b"1", b"/", b"")),
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
        assert_eq!(parse_request_id(b"1"), Some(1));
        assert_eq!(parse_request_id(b"9223372036854775807"), Some(i64::MAX));
        for value in [
            b"".as_slice(),
            b"0",
            b"01",
            b"+1",
            b"-1",
            b" 1",
            b"9223372036854775808",
        ] {
            assert_eq!(parse_request_id(value), None, "{value:?}");
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
