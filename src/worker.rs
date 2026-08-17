//! Persistent worker session: `store`, `history-snapshot`, `history-append`
//! and `plan` requests, the `input` / `flush` notifications, and the
//! `plan-ready` / `capture-required` events their quiet periods produce.

use std::ffi::OsStr;
use std::fmt;
use std::fs::File;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;
use std::time::{Duration, Instant};

use crate::framing::{self, Decoder};
use crate::history::HistoryIndex;
use crate::matching::Mode;
use crate::plan::{self, Producer};
use crate::record;
use crate::wire::{BUILD_STAMP, parse_canonical_u64};

const READ_BUFFER_SIZE: usize = 8192;
const FIRST_APPLICATION_FD: RawFd = 3;

/// Upper bound of a notification's `delay_ms`
/// (config-schema.md `[display].delay-ms`).
const DELAY_MS_MAX: u64 = 10_000;

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

/// One outcome of waiting on the session's byte stream.
pub(crate) enum Chunk {
    /// Bytes read into the caller's buffer.
    Data(usize),
    /// The deadline passed before any byte arrived.
    Expired,
    Eof,
}

/// The session's byte stream together with the monotonic clock that measures
/// quiet periods (cli-protocol.md 「入力通知と worker event」).
///
/// The event loop reads time and bytes through this one seam, so tests drive
/// it with a deterministic clock and the matching/ranking/layout side stays
/// free of both.
pub(crate) trait Source {
    fn now(&self) -> Instant;

    /// Wait for bytes, giving up at `deadline` (waits indefinitely without one).
    fn read_until(
        &mut self,
        deadline: Option<Instant>,
        buffer: &mut [u8],
    ) -> std::io::Result<Chunk>;
}

/// The session stream of a real worker: stdin, waited on so a quiet period can
/// expire while no message is arriving.
///
/// The wait is `select(2)` rather than `poll(2)`: on macOS a reader parked in
/// an open-ended `poll` on a FIFO never sees the writer that is blocked inside
/// a single `write(2)` larger than the FIFO buffer -- 8192 bytes arrive, 8193
/// hang -- and a `store` carrying a command-position capture is tens of
/// kilobytes. An open-ended `kqueue` wait loses the same wakeup; `select` and a
/// blocking `read` do not, and a `poll` with a timeout recovers because each
/// call arms again. Only stdin is ever watched, so the descriptor is always
/// inside `FD_SETSIZE`.
pub(crate) struct StdinSource;

impl Source for StdinSource {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn read_until(
        &mut self,
        deadline: Option<Instant>,
        buffer: &mut [u8],
    ) -> std::io::Result<Chunk> {
        loop {
            let mut timeout = match deadline {
                None => None,
                Some(deadline) => {
                    match wait_timeout(deadline.saturating_duration_since(self.now())) {
                        Some(timeout) => Some(timeout),
                        None => return Ok(Chunk::Expired),
                    }
                }
            };

            // select is called with one owned descriptor set and one owned
            // timeout, both left to the kernel to update.
            let ready = unsafe {
                let mut watched = std::mem::zeroed::<libc::fd_set>();
                libc::FD_SET(libc::STDIN_FILENO, &mut watched);
                libc::select(
                    libc::STDIN_FILENO + 1,
                    &mut watched,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    timeout.as_mut().map_or(std::ptr::null_mut(), |timeout| {
                        timeout as *mut libc::timeval
                    }),
                )
            };
            if ready < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if ready == 0 {
                return Ok(Chunk::Expired);
            }

            // read is called with a pointer and length from `buffer` itself.
            let read =
                unsafe { libc::read(libc::STDIN_FILENO, buffer.as_mut_ptr().cast(), buffer.len()) };
            if read < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            return Ok(match read {
                0 => Chunk::Eof,
                read => Chunk::Data(read as usize),
            });
        }
    }
}

/// Round a remaining quiet period up to select(2)'s microsecond timeout, so a
/// sub-microsecond remainder waits rather than spinning. `None` once nothing
/// remains.
fn wait_timeout(remaining: Duration) -> Option<libc::timeval> {
    /// Longest wait ever handed to select. A quiet period is at most ten
    /// seconds, so the clamp is unreachable; it exists so that no arithmetic
    /// here can produce a `tv_sec` that select is free to reject as `EINVAL`.
    const MAX_MICROS: u128 = i32::MAX as u128 * 1_000;

    if remaining.is_zero() {
        return None;
    }
    let micros = (remaining.as_micros()
        + u128::from(!remaining.subsec_nanos().is_multiple_of(1_000)))
    .min(MAX_MICROS);
    Some(libc::timeval {
        tv_sec: (micros / 1_000_000) as libc::time_t,
        tv_usec: (micros % 1_000_000) as libc::suseconds_t,
    })
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
        input_generation: i64,
        payload: Vec<u8>,
    },
    History {
        write: HistoryWrite,
        generation: i64,
        payload: Vec<u8>,
    },
    Plan {
        generation: i64,
        cwd: Vec<u8>,
        history_limit: usize,
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

/// The two writes of the history index (cli-protocol.md 「要求と応答」).
#[derive(Clone, Copy)]
enum HistoryWrite {
    Snapshot,
    Append,
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

/// The last `input` notification the session accepted, whole
/// (cli-protocol.md 「入力通知と worker event」).
///
/// `expiry` carries the pending/settled distinction: `Some` is the instant its
/// quiet period ends, `None` means it has already settled.
struct CurrentInput {
    generation: i64,
    /// The generation this input claims can serve it, or `0` for "none".
    candidate_generation: i64,
    cwd: Vec<u8>,
    params: plan::Params,
    expiry: Option<Instant>,
}

/// Everything one session retains: the candidate store's slots, the history
/// index -- which is not a slot, `store` never reaches it and the history
/// writes never reach a slot (cli-protocol.md 「要求と応答」) -- and the one
/// current input the quiet period is measured for.
#[derive(Default)]
struct Session {
    store: CandidateStore,
    history: HistoryIndex,
    input: Option<CurrentInput>,
}

impl Session {
    /// The instant stdin must stop waiting at, if an input is pending.
    fn deadline(&self) -> Option<Instant> {
        self.input.as_ref().and_then(|input| input.expiry)
    }

    /// Settle the current input once its quiet period has passed, whether or
    /// not a message arrived to notice it.
    fn settle_expired<W: Write>(&mut self, now: Instant, output: &mut W) -> Result<(), Error> {
        let Some(input) = &self.input else {
            return Ok(());
        };
        let Some(expiry) = input.expiry else {
            return Ok(());
        };
        if expiry > now {
            return Ok(());
        }
        let generation = input.candidate_generation;
        self.settle_against(generation, output)
    }

    /// Settle the current input against one candidate generation: the one the
    /// notification named when its quiet period expires, the one just stored
    /// when a `store` answers it.
    ///
    /// Emits exactly one event: `plan-ready` when that generation is held,
    /// `capture-required` otherwise.
    fn settle_against<W: Write>(&mut self, generation: i64, output: &mut W) -> Result<(), Error> {
        let Some(input) = self.input.as_mut() else {
            return Ok(());
        };
        input.expiry = None;
        let input = &*input;
        let resolved = match generation {
            0 => None,
            generation => self.store.find(generation),
        };
        let target = input.generation.to_string();
        match resolved {
            Some(stored) => {
                let is_dir = |path: &[u8]| is_dir_from(&input.cwd, path);
                let body = plan::compute(&input.params, stored, &is_dir);
                write_message(output, &[b"plan-ready", target.as_bytes(), &body])
            }
            None => write_message(output, &[b"capture-required", target.as_bytes()]),
        }
    }

    /// cli-protocol.md 「入力通知と worker event」: an accepted `input`
    /// replaces the current one whole and restarts the quiet period with its
    /// own `delay_ms`; `0` settles at acceptance.
    fn accept_input<W: Write>(
        &mut self,
        fields: Vec<Vec<u8>>,
        now: Instant,
        output: &mut W,
    ) -> Result<(), Error> {
        let Some(input) = parse_input(fields, now) else {
            return Err(Error::Protocol);
        };
        // Strictly monotonic within the session, and the current input is the
        // last one accepted.
        if self
            .input
            .as_ref()
            .is_some_and(|current| input.generation <= current.generation)
        {
            return Err(Error::Protocol);
        }

        let settles_now = input.expiry.is_none();
        let generation = input.candidate_generation;
        self.input = Some(input);
        if settles_now {
            self.settle_against(generation, output)?;
        }
        Ok(())
    }

    /// cli-protocol.md 「入力通知と worker event」: a `flush` cuts the quiet
    /// period short for a pending current input of the same generation, and is
    /// dropped when it would have no effect.
    fn accept_flush<W: Write>(
        &mut self,
        fields: Vec<Vec<u8>>,
        output: &mut W,
    ) -> Result<(), Error> {
        let Ok([_kind, generation]) = <[Vec<u8>; 2]>::try_from(fields) else {
            return Err(Error::Protocol);
        };
        let Some(generation) = parse_identifier(&generation) else {
            return Err(Error::Protocol);
        };
        match &self.input {
            Some(input) if input.expiry.is_some() && input.generation == generation => {
                let candidate_generation = input.candidate_generation;
                self.settle_against(candidate_generation, output)
            }
            _ => Ok(()),
        }
    }

    /// Whether a `store` answers the input the worker is still holding
    /// (cli-protocol.md 「入力通知と worker event」).
    fn binds_current_input(&self, input_generation: i64) -> bool {
        self.input
            .as_ref()
            .is_some_and(|input| input.generation == input_generation)
    }
}

/// The session event loop: stdin's wait carries the quiet period's expiry as
/// its deadline, so an event can be emitted with no message arriving
/// (cli-protocol.md 「起動と責務」).
pub(crate) fn run<S: Source, W: Write>(mut source: S, mut output: W) -> Result<End, Error> {
    let mut decoder = Decoder::new();
    let mut handshake = Handshake::Awaiting;
    let mut session = Session::default();
    let mut buffer = [0; READ_BUFFER_SIZE];

    loop {
        let chunk = source
            .read_until(session.deadline(), &mut buffer)
            .map_err(Error::Io)?;
        let read = match chunk {
            // A pending input at a frame-boundary EOF simply never settles.
            Chunk::Eof => {
                decoder.finish().map_err(Error::Framing)?;
                return Ok(End::Eof);
            }
            Chunk::Expired => {
                session.settle_expired(source.now(), &mut output)?;
                continue;
            }
            Chunk::Data(read) => read,
        };

        let (messages, failure) = match decoder.feed(&buffer[..read]) {
            Ok(messages) => (messages, None),
            // Messages completed before the corruption are delivered first, so
            // the split of one read never changes what is answered.
            Err(feed_error) => (feed_error.completed, Some(feed_error.error)),
        };
        for message in messages {
            let now = source.now();
            // An expiry that came due while earlier messages were handled is
            // reported before the next one, keeping events in the order the
            // session produced them.
            session.settle_expired(now, &mut output)?;
            if process_message(&message, now, &mut handshake, &mut session, &mut output)?
                == MessageResult::Incompatible
            {
                discard_requests(&mut source);
                return Ok(End::Incompatible);
            }
        }
        if let Some(error) = failure {
            return Err(Error::Framing(error));
        }
    }
}

/// The post-`incompatible` discard state of cli-protocol.md
/// 「セッションフレーミングと握手」.
fn discard_requests<S: Source>(source: &mut S) {
    let mut buffer = [0; READ_BUFFER_SIZE];
    while let Ok(Chunk::Data(_)) = source.read_until(None, &mut buffer) {}
}

fn process_message<W: Write>(
    message: &[u8],
    now: Instant,
    handshake: &mut Handshake,
    session: &mut Session,
    output: &mut W,
) -> Result<MessageResult, Error> {
    let fields = decode_fields(message)?;
    match handshake {
        Handshake::Awaiting => process_hello(&fields, handshake, output),
        Handshake::Ready => {
            // Notifications carry no `request_id`, so a malformed one has no
            // in-band answer and ends the session; every other kind is a
            // request, correlated by its `request_id`.
            match fields.first().map(Vec::as_slice) {
                Some(b"input") => session.accept_input(fields, now, output)?,
                Some(b"flush") => session.accept_flush(fields, output)?,
                _ => process_request(fields, session, output)?,
            }
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
    session: &mut Session,
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
            input_generation,
            payload,
        } => {
            // cli-protocol.md 「要求と応答」: the binding is checked before the
            // payload's framing, so a superseded input's candidate stream is
            // never parsed.
            if !session.binds_current_input(input_generation) {
                return write_message(output, &[b"error", &request_id, b"superseded"]);
            }
            match record::parse(payload) {
                Ok(stored) => {
                    session.store.insert(slot, generation, stored);
                    write_message(output, &[b"ok", &request_id, b""])?;
                    // An accepted `store` settles the input it answers, and the
                    // terminal `ok` precedes that event.
                    session.settle_against(generation, output)
                }
                Err(record::FramingError) => {
                    write_message(output, &[b"error", &request_id, b"invalid-payload"])
                }
            }
        }
        Request::History {
            write,
            generation,
            payload,
        } => match record::parse(payload) {
            Ok(stored) => {
                let accepted = match write {
                    HistoryWrite::Snapshot => session.history.install(generation, &stored),
                    HistoryWrite::Append => session.history.append(generation, &stored),
                };
                match accepted {
                    Ok(()) => write_message(output, &[b"ok", &request_id, b""]),
                    Err(_) => {
                        write_message(output, &[b"error", &request_id, b"unknown-generation"])
                    }
                }
            }
            Err(record::FramingError) => {
                write_message(output, &[b"error", &request_id, b"invalid-payload"])
            }
        },
        Request::Plan {
            generation,
            cwd,
            history_limit,
            params,
        } => {
            let is_dir = |path: &[u8]| is_dir_from(&cwd, path);
            // cli-protocol.md 「要求と応答」: one generation namespace spanning
            // both slots and the index. The index answers only for its
            // current stamp, and builds the query window per request because
            // the scan bound is the request's.
            let body = if let Some(stored) = session.store.find(generation) {
                Some(plan::compute(&params, stored, &is_dir))
            } else if session.history.holds(generation) {
                let window = session.history.window(history_limit);
                Some(plan::compute(&params, &window, &is_dir))
            } else {
                None
            };
            match body {
                Some(body) => write_message(output, &[b"ok", &request_id, &body]),
                None => write_message(output, &[b"error", &request_id, b"unknown-generation"]),
            }
        }
    }
}

fn parse_request(fields: Vec<Vec<u8>>) -> Request {
    match fields.first().map(Vec::as_slice) {
        Some(b"store") => parse_store(fields),
        Some(b"history-snapshot") => parse_history(fields, HistoryWrite::Snapshot),
        Some(b"history-append") => parse_history(fields, HistoryWrite::Append),
        Some(b"plan") => parse_plan(fields),
        _ => Request::Invalid,
    }
}

fn parse_store(fields: Vec<Vec<u8>>) -> Request {
    let Ok([_kind, _id, slot, generation, input_generation, payload]) =
        <[Vec<u8>; 6]>::try_from(fields)
    else {
        return Request::Invalid;
    };
    let Some(slot) = parse_slot(&slot) else {
        return Request::Invalid;
    };
    let Some(generation) = parse_identifier(&generation) else {
        return Request::Invalid;
    };
    let Some(input_generation) = parse_identifier(&input_generation) else {
        return Request::Invalid;
    };
    Request::Store {
        slot,
        generation,
        input_generation,
        payload,
    }
}

/// cli-protocol.md 「入力通知と worker event」: an `input` notification, whose
/// plan fields are always laid out as `producer = compsys`.
fn parse_input(fields: Vec<Vec<u8>>, now: Instant) -> Option<CurrentInput> {
    let [
        _kind,
        generation,
        candidate_generation,
        delay_ms,
        cwd,
        query,
        mode,
        smart_case,
        rows,
        width,
        trailing_space,
    ] = <[Vec<u8>; 11]>::try_from(fields).ok()?;

    let generation = parse_identifier(&generation)?;
    let candidate_generation = parse_reference(&candidate_generation)?;
    let delay = parse_delay(&delay_ms)?;
    let mode = Mode::parse(std::str::from_utf8(&mode).ok()?)?;
    let smart_case = parse_bool(&smart_case)?;
    let rows = parse_positive_usize(&rows)?;
    let width = parse_positive_usize(&width)?;
    let trailing_space = parse_bool(&trailing_space)?;

    Some(CurrentInput {
        generation,
        candidate_generation,
        cwd,
        params: plan::Params {
            producer: Producer::Compsys,
            query,
            mode,
            smart_case,
            rows,
            width,
            trailing_space,
            offset: 0,
        },
        expiry: (!delay.is_zero()).then(|| now + delay),
    })
}

fn parse_history(fields: Vec<Vec<u8>>, write: HistoryWrite) -> Request {
    let Ok([_kind, _id, generation, payload]) = <[Vec<u8>; 4]>::try_from(fields) else {
        return Request::Invalid;
    };
    let Some(generation) = parse_identifier(&generation) else {
        return Request::Invalid;
    };
    Request::History {
        write,
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
            history_limit,
            offset,
        ],
    ) = <[Vec<u8>; 13]>::try_from(fields)
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
    // Same grammar as an identifier, and mandatory whichever store the
    // generation resolves to (cli-protocol.md 「要求と応答」).
    let Some(history_limit) = parse_identifier(&history_limit) else {
        return Request::Invalid;
    };
    let Some(offset) = parse_nonneg_usize(&offset) else {
        return Request::Invalid;
    };

    Request::Plan {
        generation,
        cwd,
        history_limit: usize::try_from(history_limit).unwrap_or(usize::MAX),
        params: plan::Params {
            producer,
            query,
            mode,
            smart_case,
            rows,
            width,
            trailing_space,
            offset,
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

/// A notification's `candidate_generation`: an identifier, or the reserved `0`
/// meaning "no reusable candidates" (cli-protocol.md 「入力通知と worker event」).
fn parse_reference(value: &[u8]) -> Option<i64> {
    i64::try_from(parse_canonical_u64(value)?).ok()
}

/// A notification's `delay_ms`: canonical decimal milliseconds within the
/// configured range (config-schema.md `[display].delay-ms`).
fn parse_delay(value: &[u8]) -> Option<Duration> {
    let millis = parse_canonical_u64(value)?;
    (millis <= DELAY_MS_MAX).then(|| Duration::from_millis(millis))
}

fn parse_positive_usize(value: &[u8]) -> Option<usize> {
    let parsed = parse_canonical_u64(value)?;
    usize::try_from(parsed).ok().filter(|number| *number > 0)
}

fn parse_nonneg_usize(value: &[u8]) -> Option<usize> {
    usize::try_from(parse_canonical_u64(value)?).ok()
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
    use std::collections::VecDeque;

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

    /// One step of a scripted session.
    enum Step {
        /// Bytes arriving at the current virtual instant.
        Send(Vec<u8>),
        /// Virtual time passing with the stream silent.
        Wait(Duration),
    }

    fn wait(millis: u64) -> Step {
        Step::Wait(Duration::from_millis(millis))
    }

    /// A deterministic session stream: the clock moves only where the script
    /// says it does, so every quiet period expires at a known point.
    struct Script {
        now: Instant,
        steps: VecDeque<Step>,
    }

    impl Script {
        fn new(steps: Vec<Step>) -> Self {
            Self {
                now: Instant::now(),
                steps: steps.into(),
            }
        }
    }

    impl Source for Script {
        fn now(&self) -> Instant {
            self.now
        }

        fn read_until(
            &mut self,
            deadline: Option<Instant>,
            buffer: &mut [u8],
        ) -> std::io::Result<Chunk> {
            loop {
                if deadline.is_some_and(|deadline| deadline <= self.now) {
                    return Ok(Chunk::Expired);
                }
                match self.steps.pop_front() {
                    Some(Step::Send(bytes)) => {
                        assert!(
                            bytes.len() <= buffer.len(),
                            "scripted chunk exceeds the buffer"
                        );
                        buffer[..bytes.len()].copy_from_slice(&bytes);
                        return Ok(Chunk::Data(bytes.len()));
                    }
                    Some(Step::Wait(duration)) => {
                        let reached = self.now + duration;
                        match deadline {
                            Some(deadline) if deadline <= reached => {
                                let remaining = reached - deadline;
                                if !remaining.is_zero() {
                                    self.steps.push_front(Step::Wait(remaining));
                                }
                                self.now = deadline;
                                return Ok(Chunk::Expired);
                            }
                            _ => self.now = reached,
                        }
                    }
                    // The script has run out: EOF is readable right now, so it
                    // is delivered even with a quiet period still pending.
                    None => return Ok(Chunk::Eof),
                }
            }
        }
    }

    struct FailingSource;

    impl Source for FailingSource {
        fn now(&self) -> Instant {
            Instant::now()
        }

        fn read_until(
            &mut self,
            _deadline: Option<Instant>,
            _buffer: &mut [u8],
        ) -> std::io::Result<Chunk> {
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

    fn hello() -> Vec<u8> {
        message(&[b"hello", BUILD_STAMP.as_bytes()])
    }

    fn drive(steps: Vec<Step>) -> (Result<End, Error>, Vec<u8>) {
        let mut output = Vec::new();
        let result = run(Script::new(steps), &mut output);
        (result, output)
    }

    /// Every message a handshaken session emits before its EOF, in order.
    fn timed(steps: Vec<Step>) -> Vec<Vec<Vec<u8>>> {
        let mut script = vec![Step::Send(hello())];
        script.extend(steps);
        let (result, output) = drive(script);
        assert_eq!(result.unwrap(), End::Eof);
        let mut decoded = messages(&output);
        assert_eq!(
            decoded.remove(0),
            [b"ready".to_vec(), BUILD_STAMP.as_bytes().to_vec()]
        );
        decoded
    }

    fn session(requests: &[Vec<u8>]) -> Vec<Vec<Vec<u8>>> {
        timed(requests.iter().cloned().map(Step::Send).collect())
    }

    /// The terminal response correlated to one request. Exactly one exists:
    /// the contract's 「終端応答をちょうど 1 個」.
    fn reply(decoded: &[Vec<Vec<u8>>], id: &[u8]) -> Vec<Vec<u8>> {
        let mut found: Vec<Vec<Vec<u8>>> = decoded
            .iter()
            .filter(|message| {
                matches!(message.first().map(Vec::as_slice), Some(b"ok" | b"error"))
                    && message.get(1).is_some_and(|value| value == id)
            })
            .cloned()
            .collect();
        assert_eq!(
            found.len(),
            1,
            "expected one terminal response for {id:?}: {decoded:?}"
        );
        found.pop().unwrap()
    }

    fn ok(id: &[u8]) -> Vec<Vec<u8>> {
        vec![b"ok".to_vec(), id.to_vec(), Vec::new()]
    }

    fn error(id: &[u8], code: &[u8]) -> Vec<Vec<u8>> {
        vec![b"error".to_vec(), id.to_vec(), code.to_vec()]
    }

    /// The worker events of a session, in the order they were written.
    fn events(decoded: &[Vec<Vec<u8>>]) -> Vec<Vec<Vec<u8>>> {
        decoded
            .iter()
            .filter(|message| {
                matches!(
                    message.first().map(Vec::as_slice),
                    Some(b"plan-ready" | b"capture-required")
                )
            })
            .cloned()
            .collect()
    }

    fn capture_required(generation: &[u8]) -> Vec<Vec<u8>> {
        vec![b"capture-required".to_vec(), generation.to_vec()]
    }

    /// Field 3 of a terminal response: an `ok` body or an error `code`.
    fn body(response: &[Vec<u8>]) -> &[u8] {
        &response[2]
    }

    /// One batch header plus one candidate record.
    fn payload(word: &[u8]) -> Vec<u8> {
        [b"b\x01\0w\x01", word, b"\0"].concat()
    }

    fn store_request<'a>(
        id: &'a [u8],
        slot: &'a [u8],
        generation: &'a [u8],
        input_generation: &'a [u8],
        payload: &'a [u8],
    ) -> Vec<&'a [u8]> {
        vec![b"store", id, slot, generation, input_generation, payload]
    }

    fn input_notification<'a>(
        generation: &'a [u8],
        candidate_generation: &'a [u8],
        delay_ms: &'a [u8],
    ) -> Vec<&'a [u8]> {
        vec![
            b"input",
            generation,
            candidate_generation,
            delay_ms,
            b"/",
            b"",
            b"typo",
            b"true",
            b"10",
            b"40",
            b"true",
        ]
    }

    /// An input a following `store` can bind to: its quiet period outlasts
    /// every scripted step, so it stays pending until something settles it.
    fn pending_input(generation: &[u8]) -> Vec<u8> {
        message(&input_notification(generation, b"0", b"1000"))
    }

    fn plan_request<'a>(id: &'a [u8], generation: &'a [u8]) -> Vec<&'a [u8]> {
        vec![
            b"plan", id, generation, b"/", b"compsys", b"", b"typo", b"true", b"10", b"40",
            b"true", b"5000", b"0",
        ]
    }

    /// A `plan` reading the history index: the `history` producer and an
    /// explicit scan bound.
    fn history_plan_request<'a>(
        id: &'a [u8],
        generation: &'a [u8],
        history_limit: &'a [u8],
    ) -> Vec<&'a [u8]> {
        history_plan_request_at(id, generation, history_limit, b"0")
    }

    fn history_plan_request_at<'a>(
        id: &'a [u8],
        generation: &'a [u8],
        history_limit: &'a [u8],
        offset: &'a [u8],
    ) -> Vec<&'a [u8]> {
        vec![
            b"plan",
            id,
            generation,
            b"/",
            b"history",
            b"",
            b"typo",
            b"true",
            b"10",
            b"40",
            b"false",
            history_limit,
            offset,
        ]
    }

    /// A history-profile payload: one empty batch header, then `w`/`n`
    /// candidate records newest first.
    fn history_payload(entries: &[(&[u8], &[u8])]) -> Vec<u8> {
        let mut out = b"b\x01\0".to_vec();
        for (line, event) in entries {
            out.extend_from_slice(b"w\x01");
            out.extend_from_slice(line);
            out.extend_from_slice(b"\x02n\x01");
            out.extend_from_slice(event);
            out.push(0);
        }
        out
    }

    fn history_request<'a>(
        kind: &'a [u8],
        id: &'a [u8],
        generation: &'a [u8],
        payload: &'a [u8],
    ) -> Vec<&'a [u8]> {
        vec![kind, id, generation, payload]
    }

    #[test]
    fn handshake_and_multiple_requests_share_one_session() {
        let decoded = session(&[
            pending_input(b"1"),
            message(&store_request(b"1", b"live", b"5", b"1", b"")),
            message(&plan_request(b"2", b"5")),
            message(&plan_request(b"3", b"5")),
        ]);

        assert_eq!(reply(&decoded, b"1"), ok(b"1"));
        assert_eq!(&reply(&decoded, b"2")[..2], [b"ok".as_slice(), b"2"]);
        assert_eq!(&reply(&decoded, b"3")[..2], [b"ok".as_slice(), b"3"]);
        assert_eq!(body(&reply(&decoded, b"2")), b"\0\x30\0\x30\0\x30\0");
    }

    #[test]
    fn one_store_serves_every_later_plan() {
        let stored = payload(b"git");
        let decoded = session(&[
            pending_input(b"1"),
            message(&store_request(b"1", b"live", b"5", b"1", &stored)),
            message(&plan_request(b"2", b"5")),
            message(&plan_request(b"3", b"5")),
        ]);

        assert!(
            body(&reply(&decoded, b"2"))
                .windows(3)
                .any(|bytes| bytes == b"git"),
            "plan does not list the stored candidate: {:?}",
            body(&reply(&decoded, b"2"))
        );
        assert_eq!(body(&reply(&decoded, b"2")), body(&reply(&decoded, b"3")));
    }

    #[test]
    fn a_new_generation_replaces_only_its_own_slot() {
        let cached = payload(b"git");
        let live = payload(b"grep");
        let recached = payload(b"gzip");
        let decoded = session(&[
            pending_input(b"1"),
            message(&store_request(b"1", b"cache", b"5", b"1", &cached)),
            pending_input(b"2"),
            message(&store_request(b"2", b"live", b"6", b"2", &live)),
            pending_input(b"3"),
            message(&store_request(b"3", b"cache", b"7", b"3", &recached)),
            message(&plan_request(b"4", b"7")),
            message(&plan_request(b"5", b"6")),
            message(&plan_request(b"6", b"5")),
        ]);

        assert!(
            body(&reply(&decoded, b"4"))
                .windows(4)
                .any(|bytes| bytes == b"gzip")
        );
        assert!(
            body(&reply(&decoded, b"5"))
                .windows(4)
                .any(|bytes| bytes == b"grep")
        );
        assert_eq!(reply(&decoded, b"6"), error(b"6", b"unknown-generation"));
    }

    #[test]
    fn a_plan_for_a_generation_no_slot_holds_is_a_terminal_error() {
        let decoded = session(&[message(&plan_request(b"1", b"9"))]);

        assert_eq!(reply(&decoded, b"1"), error(b"1", b"unknown-generation"));
    }

    #[test]
    fn a_store_that_fails_framing_leaves_every_slot_unchanged() {
        let live = payload(b"git");
        let cached = payload(b"grep");
        let decoded = session(&[
            pending_input(b"1"),
            message(&store_request(b"1", b"live", b"5", b"1", &live)),
            pending_input(b"2"),
            message(&store_request(b"2", b"cache", b"6", b"2", &cached)),
            pending_input(b"3"),
            message(&store_request(b"3", b"live", b"7", b"3", b"unterminated")),
            message(&plan_request(b"4", b"5")),
            message(&plan_request(b"5", b"6")),
            message(&plan_request(b"6", b"7")),
        ]);

        assert_eq!(reply(&decoded, b"3"), error(b"3", b"invalid-payload"));
        // Neither the slot the failed store addressed nor the other one moved.
        assert!(
            body(&reply(&decoded, b"4"))
                .windows(3)
                .any(|bytes| bytes == b"git")
        );
        assert!(
            body(&reply(&decoded, b"5"))
                .windows(4)
                .any(|bytes| bytes == b"grep")
        );
        assert_eq!(reply(&decoded, b"6"), error(b"6", b"unknown-generation"));
        // A `store` that never reached a slot settles nothing either.
        assert_eq!(events(&decoded).len(), 2);
    }

    #[test]
    fn a_new_session_starts_with_an_empty_store() {
        let stored = payload(b"git");
        session(&[
            pending_input(b"1"),
            message(&store_request(b"1", b"live", b"5", b"1", &stored)),
        ]);

        let decoded = session(&[message(&plan_request(b"2", b"5"))]);

        assert_eq!(reply(&decoded, b"2"), error(b"2", b"unknown-generation"));
    }

    #[test]
    fn mismatch_replies_once_and_discards_the_rest_of_stdin() {
        let (result, output) = drive(vec![
            Step::Send(message(&[b"hello", b"deadbeef"])),
            Step::Send(message(&plan_request(b"1", b"5"))),
            Step::Send(b"1:x!".to_vec()),
        ]);

        assert_eq!(result.unwrap(), End::Incompatible);
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
            pending_input(b"1"),
            message(&store_request(b"8", b"live", b"5", b"1", b"unterminated")),
            message(&store_request(b"9", b"elsewhere", b"5", b"1", b"")),
            message(&store_request(b"10", b"live", b"05", b"1", b"")),
            message(&store_request(b"11", b"live", b"5", b"01", b"")),
            // The five-field `store` of the previous wire carries no binding.
            message(&[b"store", b"12", b"live", b"5", b""]),
            message(&plan_request(b"13", b"0")),
        ]);

        assert_eq!(reply(&decoded, b"7"), error(b"7", b"invalid-request"));
        assert_eq!(reply(&decoded, b"8"), error(b"8", b"invalid-payload"));
        assert_eq!(reply(&decoded, b"9"), error(b"9", b"invalid-request"));
        assert_eq!(reply(&decoded, b"10"), error(b"10", b"invalid-request"));
        assert_eq!(reply(&decoded, b"11"), error(b"11", b"invalid-request"));
        assert_eq!(reply(&decoded, b"12"), error(b"12", b"invalid-request"));
        assert_eq!(reply(&decoded, b"13"), error(b"13", b"invalid-request"));
    }

    /// cli-protocol.md 「要求と応答」: a `store` whose scalars *and* payload
    /// are both invalid answers with the error detected first.
    #[test]
    fn store_scalar_validation_precedes_payload_framing() {
        let decoded = session(&[
            pending_input(b"1"),
            message(&store_request(
                b"1",
                b"elsewhere",
                b"5",
                b"1",
                b"unterminated",
            )),
        ]);

        assert_eq!(reply(&decoded, b"1"), error(b"1", b"invalid-request"));
    }

    /// cli-protocol.md 「入力通知と worker event」: the binding is checked
    /// before the payload, so a superseded capture is never parsed.
    #[test]
    fn an_unbound_store_is_superseded_before_its_payload_is_read() {
        let decoded = session(&[
            // No current input at all.
            message(&store_request(b"1", b"live", b"5", b"1", b"unterminated")),
            pending_input(b"2"),
            // Bound to an input the worker no longer holds.
            message(&store_request(b"2", b"live", b"6", b"1", b"unterminated")),
            message(&plan_request(b"3", b"5")),
            message(&plan_request(b"4", b"6")),
        ]);

        assert_eq!(reply(&decoded, b"1"), error(b"1", b"superseded"));
        assert_eq!(reply(&decoded, b"2"), error(b"2", b"superseded"));
        // A superseded store stores nothing and settles nothing.
        assert_eq!(reply(&decoded, b"3"), error(b"3", b"unknown-generation"));
        assert_eq!(reply(&decoded, b"4"), error(b"4", b"unknown-generation"));
        assert!(events(&decoded).is_empty());
    }

    #[test]
    fn an_accepted_store_answers_ok_then_plan_ready() {
        let stored = payload(b"git");
        let decoded = session(&[
            pending_input(b"7"),
            message(&store_request(b"1", b"live", b"41", b"7", &stored)),
        ]);

        assert_eq!(decoded[0], ok(b"1"));
        assert_eq!(decoded[1][..2], [b"plan-ready".to_vec(), b"7".to_vec()]);
        assert!(decoded[1][2].windows(3).any(|bytes| bytes == b"git"));
        assert_eq!(decoded.len(), 2);
    }

    /// A second `store` bound to the same generation is answered like the
    /// first: the worker enforces the binding, not an event count.
    #[test]
    fn a_store_settles_the_current_input_whether_pending_or_settled() {
        let stored = payload(b"git");
        let decoded = timed(vec![
            Step::Send(message(&input_notification(b"7", b"0", b"30"))),
            wait(50),
            Step::Send(message(&store_request(b"1", b"live", b"41", b"7", &stored))),
            Step::Send(message(&store_request(b"2", b"live", b"42", b"7", &stored))),
        ]);

        assert_eq!(
            events(&decoded),
            [
                capture_required(b"7"),
                vec![b"plan-ready".to_vec(), b"7".to_vec(), decoded[2][2].clone()],
                vec![b"plan-ready".to_vec(), b"7".to_vec(), decoded[4][2].clone()],
            ]
        );
        assert_eq!(reply(&decoded, b"1"), ok(b"1"));
        assert_eq!(reply(&decoded, b"2"), ok(b"2"));
    }

    #[test]
    fn a_new_session_holds_no_current_input() {
        session(&[pending_input(b"7")]);

        let decoded = session(&[message(&store_request(b"1", b"live", b"41", b"7", b""))]);

        assert_eq!(reply(&decoded, b"1"), error(b"1", b"superseded"));
    }

    /// cli-protocol.md 「入力通知と worker event」: the quiet period is
    /// restarted by every accepted notification, and only the last one settles.
    #[test]
    fn notifications_coalesce_to_the_latest_generation() {
        let decoded = timed(vec![
            Step::Send(message(&input_notification(b"1", b"0", b"30"))),
            wait(20),
            Step::Send(message(&input_notification(b"2", b"0", b"30"))),
            wait(20),
            // Nothing has settled 40ms in: the second notification restarted
            // the period, and this response anchors the stream order.
            Step::Send(message(&plan_request(b"9", b"9"))),
            wait(20),
        ]);

        assert_eq!(
            decoded,
            [error(b"9", b"unknown-generation"), capture_required(b"2"),]
        );
    }

    #[test]
    fn a_zero_delay_notification_settles_at_acceptance() {
        let decoded = timed(vec![Step::Send(message(&input_notification(
            b"1", b"0", b"0",
        )))]);

        assert_eq!(decoded, [capture_required(b"1")]);
    }

    /// A settled input whose `candidate_generation` is held answers with the
    /// plan itself; an unheld one is a capture request, not a failure.
    #[test]
    fn settling_resolves_the_notified_candidate_generation() {
        let stored = payload(b"git");
        let decoded = session(&[
            pending_input(b"1"),
            message(&store_request(b"1", b"cache", b"41", b"1", &stored)),
            message(&input_notification(b"2", b"41", b"0")),
            message(&input_notification(b"3", b"999", b"0")),
        ]);

        let events = events(&decoded);
        assert_eq!(events[1][..2], [b"plan-ready".to_vec(), b"2".to_vec()]);
        assert!(events[1][2].windows(3).any(|bytes| bytes == b"git"));
        assert_eq!(events[2], capture_required(b"3"));
    }

    /// cli-protocol.md 「入力通知と worker event」: a notification's
    /// `candidate_generation` resolves against the two slots alone -- the
    /// history index answers `plan` requests only.
    #[test]
    fn a_notification_never_resolves_the_history_index() {
        let installed = history_payload(&[(b"ls", b"41")]);
        let decoded = session(&[
            message(&history_request(
                b"history-snapshot",
                b"1",
                b"5",
                &installed,
            )),
            message(&input_notification(b"1", b"5", b"0")),
            // The index really does hold that generation for a `plan`.
            message(&history_plan_request(b"2", b"5", b"5000")),
        ]);

        assert_eq!(events(&decoded), [capture_required(b"1")]);
        assert!(
            body(&reply(&decoded, b"2"))
                .windows(2)
                .any(|bytes| bytes == b"ls")
        );
    }

    #[test]
    fn a_flush_settles_only_a_pending_input_of_the_same_generation() {
        let decoded = timed(vec![
            // No current input.
            Step::Send(message(&[b"flush", b"1"])),
            Step::Send(message(&input_notification(b"5", b"0", b"1000"))),
            // A generation that is not the current one.
            Step::Send(message(&[b"flush", b"4"])),
            Step::Send(message(&[b"flush", b"6"])),
            Step::Send(message(&[b"flush", b"5"])),
            // Already settled.
            Step::Send(message(&[b"flush", b"5"])),
            // A dropped flush leaves the monotonic bound where it was.
            Step::Send(message(&input_notification(b"6", b"0", b"0"))),
        ]);

        assert_eq!(decoded, [capture_required(b"5"), capture_required(b"6")]);
    }

    #[test]
    fn a_quiet_period_expires_with_no_message_arriving() {
        let decoded = timed(vec![
            Step::Send(message(&input_notification(b"1", b"0", b"30"))),
            // The stream falls silent: only the deadline can settle this.
            wait(50),
        ]);

        assert_eq!(decoded, [capture_required(b"1")]);
    }

    #[test]
    fn a_pending_input_at_eof_emits_nothing() {
        assert!(timed(vec![Step::Send(pending_input(b"1"))]).is_empty());
    }

    #[test]
    fn input_generations_must_increase_strictly() {
        for second in [b"5".as_slice(), b"4"] {
            let (result, output) = drive(vec![
                Step::Send(hello()),
                Step::Send(message(&input_notification(b"5", b"0", b"1000"))),
                Step::Send(message(&input_notification(second, b"0", b"1000"))),
            ]);
            assert!(matches!(result, Err(Error::Protocol)), "{second:?}");
            assert_eq!(messages(&output).len(), 1);
        }

        let decoded = timed(vec![
            Step::Send(message(&input_notification(b"5", b"0", b"0"))),
            Step::Send(message(&input_notification(
                b"9223372036854775807",
                b"9223372036854775807",
                b"0",
            ))),
        ]);
        assert_eq!(
            decoded,
            [
                capture_required(b"5"),
                capture_required(b"9223372036854775807"),
            ]
        );
    }

    /// Notifications carry no `request_id`, so a malformed one has no in-band
    /// answer: it ends the session (cli-protocol.md 「入力通知と worker event」).
    #[test]
    fn malformed_notifications_end_the_session() {
        let mut malformed: Vec<Vec<Vec<u8>>> = Vec::new();
        for (generation, candidate_generation, delay) in [
            (b"0".as_slice(), b"0".as_slice(), b"30".as_slice()),
            (b"01", b"0", b"30"),
            (b"9223372036854775808", b"0", b"30"),
            (b" 1", b"0", b"30"),
            (b"1", b"01", b"30"),
            (b"1", b"-1", b"30"),
            (b"1", b"9223372036854775808", b"30"),
            (b"1", b"0", b"10001"),
            (b"1", b"0", b"030"),
            (b"1", b"0", b""),
            (b"1", b"0", b" 30"),
        ] {
            malformed.push(
                input_notification(generation, candidate_generation, delay)
                    .iter()
                    .map(|field| field.to_vec())
                    .collect(),
            );
        }
        // Shape and enumeration violations of the same notification.
        let mut short = input_notification(b"1", b"0", b"30");
        short.pop();
        malformed.push(short.iter().map(|field| field.to_vec()).collect());
        for (index, value) in [(6, b"fuzzy".as_slice()), (7, b"TRUE"), (8, b"0"), (9, b"0")] {
            let mut fields = input_notification(b"1", b"0", b"30");
            fields[index] = value;
            malformed.push(fields.iter().map(|field| field.to_vec()).collect());
        }
        // A `flush` is held to the same standard.
        for fields in [
            vec![b"flush".to_vec()],
            vec![b"flush".to_vec(), b"1".to_vec(), b"1".to_vec()],
            vec![b"flush".to_vec(), b"0".to_vec()],
            vec![b"flush".to_vec(), b"01".to_vec()],
        ] {
            malformed.push(fields);
        }

        for fields in malformed {
            let borrowed: Vec<&[u8]> = fields.iter().map(Vec::as_slice).collect();
            let (result, output) = drive(vec![Step::Send(hello()), Step::Send(message(&borrowed))]);
            assert!(matches!(result, Err(Error::Protocol)), "{fields:?}");
            assert_eq!(messages(&output).len(), 1, "{fields:?}");
        }
    }

    #[test]
    fn a_snapshot_serves_a_plan_that_references_its_generation() {
        let payload = history_payload(&[(b"echo hi", b"42"), (b"ls", b"41")]);
        let decoded = session(&[
            message(&history_request(b"history-snapshot", b"1", b"5", &payload)),
            message(&history_plan_request(b"2", b"5", b"5000")),
        ]);

        assert_eq!(reply(&decoded, b"1"), ok(b"1"));
        // The index is a single column drawn bottom-up, so the newest line is
        // the last display row, and each cell carries its event number.
        assert!(
            body(&reply(&decoded, b"2"))
                .windows(15)
                .any(|bytes| bytes == b"   42  echo hi\0"),
            "plan does not list the newest entry: {:?}",
            body(&reply(&decoded, b"2"))
        );
        assert!(
            body(&reply(&decoded, b"2"))
                .windows(2)
                .any(|bytes| bytes == b"41")
        );
    }

    /// cli-protocol.md 「要求と応答」: a `plan` sees exactly the history
    /// writes that preceded it in the byte stream, and the index answers only
    /// for its current stamp.
    #[test]
    fn pipelined_history_writes_are_visible_to_the_plan_behind_them() {
        let snapshot = history_payload(&[(b"ls", b"41")]);
        let appended = history_payload(&[(b"echo hi", b"42")]);
        let decoded = session(&[
            message(&history_request(b"history-snapshot", b"1", b"5", &snapshot)),
            message(&history_request(b"history-append", b"2", b"6", &appended)),
            message(&history_plan_request(b"3", b"6", b"5000")),
            message(&history_plan_request(b"4", b"5", b"5000")),
        ]);

        assert_eq!(reply(&decoded, b"1"), ok(b"1"));
        assert_eq!(reply(&decoded, b"2"), ok(b"2"));
        let listed = reply(&decoded, b"3");
        assert!(body(&listed).windows(7).any(|bytes| bytes == b"echo hi"));
        assert!(body(&listed).windows(2).any(|bytes| bytes == b"ls"));
        assert_eq!(reply(&decoded, b"4"), error(b"4", b"unknown-generation"));
    }

    #[test]
    fn every_history_request_receives_exactly_one_terminal_response() {
        let payload = history_payload(&[(b"ls", b"41")]);
        let decoded = session(&[
            message(&history_request(b"history-append", b"1", b"5", &payload)),
            message(&history_request(b"history-snapshot", b"2", b"5", &payload)),
            message(&history_request(b"history-snapshot", b"3", b"5", &payload)),
            message(&history_request(b"history-append", b"4", b"6", &payload)),
        ]);

        // An append cannot initialize the index.
        assert_eq!(reply(&decoded, b"1"), error(b"1", b"unknown-generation"));
        assert_eq!(reply(&decoded, b"2"), ok(b"2"));
        // Equal to the stamp the snapshot just wrote: not strictly greater.
        assert_eq!(reply(&decoded, b"3"), error(b"3", b"unknown-generation"));
        assert_eq!(reply(&decoded, b"4"), ok(b"4"));
    }

    #[test]
    fn a_history_write_that_fails_framing_changes_neither_the_index_nor_a_slot() {
        let stored = payload(b"git");
        let installed = history_payload(&[(b"ls", b"41")]);
        let decoded = session(&[
            pending_input(b"1"),
            message(&store_request(b"1", b"live", b"5", b"1", &stored)),
            message(&history_request(
                b"history-snapshot",
                b"2",
                b"6",
                &installed,
            )),
            message(&history_request(
                b"history-snapshot",
                b"3",
                b"7",
                b"unterminated",
            )),
            message(&history_request(
                b"history-append",
                b"4",
                b"8",
                b"unterminated",
            )),
            message(&history_plan_request(b"5", b"6", b"5000")),
            message(&history_plan_request(b"6", b"7", b"5000")),
            message(&plan_request(b"7", b"5")),
        ]);

        assert_eq!(reply(&decoded, b"3"), error(b"3", b"invalid-payload"));
        assert_eq!(reply(&decoded, b"4"), error(b"4", b"invalid-payload"));
        // The index kept both its content and the stamp of the last write it
        // accepted, and the slot is untouched.
        assert!(
            body(&reply(&decoded, b"5"))
                .windows(2)
                .any(|bytes| bytes == b"ls")
        );
        assert_eq!(reply(&decoded, b"6"), error(b"6", b"unknown-generation"));
        assert!(
            body(&reply(&decoded, b"7"))
                .windows(3)
                .any(|bytes| bytes == b"git")
        );
    }

    #[test]
    fn a_new_session_starts_with_an_uninitialized_index() {
        let installed = history_payload(&[(b"ls", b"41")]);
        session(&[message(&history_request(
            b"history-snapshot",
            b"1",
            b"5",
            &installed,
        ))]);

        let decoded = session(&[
            message(&history_plan_request(b"2", b"5", b"5000")),
            message(&history_request(b"history-append", b"3", b"6", &installed)),
        ]);

        assert_eq!(reply(&decoded, b"2"), error(b"2", b"unknown-generation"));
        assert_eq!(reply(&decoded, b"3"), error(b"3", b"unknown-generation"));
    }

    /// cli-protocol.md 「要求と応答」: `store` never reaches the index and the
    /// history writes never reach a slot.
    #[test]
    fn history_writes_and_slots_are_independent() {
        let live = payload(b"git");
        let cached = payload(b"grep");
        let installed = history_payload(&[(b"ls", b"41")]);
        let decoded = session(&[
            pending_input(b"1"),
            message(&store_request(b"1", b"live", b"5", b"1", &live)),
            pending_input(b"2"),
            message(&store_request(b"2", b"cache", b"6", b"2", &cached)),
            message(&history_request(
                b"history-snapshot",
                b"3",
                b"7",
                &installed,
            )),
            pending_input(b"3"),
            message(&store_request(b"4", b"live", b"8", b"3", &live)),
            message(&plan_request(b"5", b"6")),
            message(&history_plan_request(b"6", b"7", b"5000")),
            message(&history_plan_request(b"7", b"8", b"5000")),
            message(&plan_request(b"8", b"5")),
        ]);

        assert!(
            body(&reply(&decoded, b"5"))
                .windows(4)
                .any(|bytes| bytes == b"grep")
        );
        assert!(
            body(&reply(&decoded, b"6"))
                .windows(2)
                .any(|bytes| bytes == b"ls")
        );
        // Generation 8 belongs to the `live` slot, and generation 5 was
        // replaced there: neither resolves to the index.
        assert!(
            !body(&reply(&decoded, b"7"))
                .windows(2)
                .any(|bytes| bytes == b"ls")
        );
        assert_eq!(reply(&decoded, b"8"), error(b"8", b"unknown-generation"));
    }

    #[test]
    fn history_scalar_validation_precedes_payload_framing() {
        let payload = history_payload(&[(b"ls", b"41")]);
        let decoded = session(&[
            message(&history_request(b"history-snapshot", b"1", b"05", &payload)),
            message(&history_request(b"history-append", b"2", b"0", &payload)),
            message(&history_request(
                b"history-snapshot",
                b"3",
                b"05",
                b"unterminated",
            )),
            message(&[b"history-snapshot", b"4", b"5"]),
        ]);

        for id in [b"1".as_slice(), b"2", b"3", b"4"] {
            assert_eq!(reply(&decoded, id), error(id, b"invalid-request"));
        }
    }

    #[test]
    fn a_plan_without_a_canonical_history_limit_is_invalid() {
        let mut requests = Vec::new();
        for (id, limit) in [
            (b"1".as_slice(), b"".as_slice()),
            (b"2", b"0"),
            (b"3", b"05000"),
            (b"4", b" 5000"),
            (b"5", b"9223372036854775808"),
        ] {
            requests.push(message(&history_plan_request(id, b"9", limit)));
        }
        // The 11-field plan of the previous wire is not a request either.
        requests.push(message(&[
            b"plan", b"6", b"9", b"/", b"compsys", b"", b"typo", b"true", b"10", b"40", b"true",
        ]));
        let decoded = session(&requests);

        for id in [b"1".as_slice(), b"2", b"3", b"4", b"5", b"6"] {
            assert_eq!(reply(&decoded, id), error(id, b"invalid-request"));
        }
    }

    #[test]
    fn a_plan_without_a_canonical_offset_is_invalid() {
        let mut requests = Vec::new();
        for (id, offset) in [
            (b"1".as_slice(), b"".as_slice()),
            (b"2", b"00"),
            (b"3", b" 0"),
        ] {
            requests.push(message(&history_plan_request_at(id, b"9", b"5000", offset)));
        }
        // The 12-field plan of the previous wire is not a request either.
        requests.push(message(&[
            b"plan", b"4", b"9", b"/", b"compsys", b"", b"typo", b"true", b"10", b"40", b"true",
            b"5000",
        ]));
        let decoded = session(&requests);

        for id in [b"1".as_slice(), b"2", b"3", b"4"] {
            assert_eq!(reply(&decoded, id), error(id, b"invalid-request"));
        }
    }

    /// cli-protocol.md 「history profile」: the request's scan bound is
    /// clamped to the retention cap, and a slot-resolved `plan` ignores it.
    #[test]
    fn the_history_limit_bounds_the_scan_and_is_ignored_by_slots() {
        let installed = history_payload(&[(b"newest", b"3"), (b"older", b"2"), (b"oldest", b"1")]);
        let stored = payload(b"git");
        let decoded = session(&[
            message(&history_request(
                b"history-snapshot",
                b"1",
                b"5",
                &installed,
            )),
            pending_input(b"1"),
            message(&store_request(b"2", b"live", b"6", b"1", &stored)),
            message(&history_plan_request(b"3", b"5", b"1")),
            message(&history_plan_request(b"4", b"5", b"9223372036854775807")),
            message(&history_plan_request(b"5", b"6", b"1")),
        ]);

        let scanned_one = reply(&decoded, b"3");
        assert!(body(&scanned_one).windows(6).any(|b| b == b"newest"));
        assert!(!body(&scanned_one).windows(5).any(|b| b == b"older"));
        // A limit past the retention cap simply scans the whole index.
        let scanned_all = reply(&decoded, b"4");
        assert!(body(&scanned_all).windows(6).any(|b| b == b"oldest"));
        // The slot's payload is listed whole: `history_limit` addresses the
        // index alone.
        assert!(body(&reply(&decoded, b"5")).windows(3).any(|b| b == b"git"));
    }

    #[test]
    fn missing_or_noncanonical_request_id_is_fatal() {
        for fields in [
            vec![b"plan".as_slice()],
            vec![b"plan".as_slice(), b"01".as_slice()],
            vec![b"plan".as_slice(), b"9223372036854775808".as_slice()],
        ] {
            let (result, output) = drive(vec![Step::Send(hello()), Step::Send(message(&fields))]);
            assert!(matches!(result, Err(Error::Protocol)));
            assert_eq!(messages(&output).len(), 1);
        }
    }

    #[test]
    fn completed_prefix_is_written_before_later_outer_corruption() {
        let (result, output) = drive(vec![
            Step::Send(hello()),
            Step::Send(
                [
                    message(&store_request(b"1", b"live", b"5", b"1", b"")),
                    b"1:x!".to_vec(),
                ]
                .concat(),
            ),
        ]);

        let Err(Error::Framing(error)) = result else {
            panic!("expected a framing error");
        };
        assert_eq!(error, framing::Error::InvalidTrailingComma);
        assert_eq!(messages(&output).len(), 2);
    }

    #[test]
    fn nested_framing_corruption_is_fatal() {
        let (result, output) = drive(vec![
            Step::Send(hello()),
            Step::Send(framing::encode(b"4:plan,1:1")),
        ]);

        let Err(Error::Framing(error)) = result else {
            panic!("expected a framing error");
        };
        assert_eq!(error, framing::Error::TruncatedFrame);
        assert_eq!(messages(&output).len(), 1);
    }

    #[test]
    fn stream_io_failures_carry_their_source() {
        let Err(Error::Io(error)) = run(FailingSource, &mut Vec::new()) else {
            panic!("expected an I/O error");
        };
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);

        let Err(Error::Io(error)) = run(Script::new(vec![Step::Send(hello())]), FailingWriter)
        else {
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
        assert_eq!(parse_nonneg_usize(b"0"), Some(0));
        assert_eq!(parse_nonneg_usize(b"3"), Some(3));
        for value in [b"".as_slice(), b"00", b"01", b"+1", b"-1", b" 0"] {
            assert_eq!(parse_nonneg_usize(value), None, "{value:?}");
        }
        // The reserved `0` is a notification's alone.
        assert_eq!(parse_reference(b"0"), Some(0));
        assert_eq!(parse_reference(b"9223372036854775807"), Some(i64::MAX));
        for value in [b"".as_slice(), b"01", b"-1", b"9223372036854775808"] {
            assert_eq!(parse_reference(value), None, "{value:?}");
        }
        assert_eq!(parse_delay(b"0"), Some(Duration::ZERO));
        assert_eq!(parse_delay(b"10000"), Some(Duration::from_millis(10_000)));
        for value in [b"".as_slice(), b"01", b"10001", b" 1", b"-1"] {
            assert_eq!(parse_delay(value), None, "{value:?}");
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

    /// The byte strings of cli-protocol.md 「具体例」, decoded and re-emitted
    /// by this session verbatim.
    #[test]
    fn the_contract_examples_are_this_wire() {
        let input = b"64:5:input,1:7,1:0,2:30,4:/tmp,2:gi,4:typo,4:true,2:10,2:79,4:true,,";
        let capture_required = b"24:16:capture-required,1:7,,";
        let store = b"40:5:store,2:12,4:live,2:41,1:7,8:b\x01\0w\x01ls\0,,";
        let superseded = b"27:5:error,2:12,10:superseded,,";
        let plan_ready = b"28:10:plan-ready,1:7,7:\x000\x000\x000\x00,,";
        let flush = b"12:5:flush,1:7,,";

        let (result, output) = drive(vec![
            Step::Send(hello()),
            Step::Send(input.to_vec()),
            wait(30),
            Step::Send(store.to_vec()),
            // The input is settled by now, so this flush is dropped.
            Step::Send(flush.to_vec()),
            // A later input supersedes generation 7 and the same capture with
            // it.
            Step::Send(message(&input_notification(b"8", b"0", b"1000"))),
            Step::Send(store.to_vec()),
        ]);

        assert_eq!(result.unwrap(), End::Eof);
        assert_eq!(
            output,
            [
                message(&[b"ready", BUILD_STAMP.as_bytes()]),
                capture_required.to_vec(),
                message(&[b"ok", b"12", b""]),
                plan_ready.to_vec(),
                superseded.to_vec(),
            ]
            .concat()
        );
    }
}
