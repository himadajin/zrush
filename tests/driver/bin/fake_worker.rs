//! Test-only `zrush` launcher with controllable persistent-worker failures.
//!
//! Every invocation delegates to the real binary named by `$ZRUSH_REAL_BIN`
//! unless it is `worker --control-fd N` and the control file selects a mode
//! other than `proxy`. In that case this process becomes the worker and speaks
//! docs/internal/contracts/cli-protocol.md 「セッションフレーミングと握手」
//! faithfully enough to reach the failure the mode asks for.
//!
//! The tests never read this process's stdout. They observe the append-only
//! state file (`$ZRUSH_FAKE_STATE`) and the session counter beside it, so every
//! line written here is part of the harness contract (`tests/driver/fake.rs`).

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::str;
use std::thread;
use std::time::Duration;

/// Filler written on stdin EOF in `drain` mode. Deliberately not a protocol
/// frame, and well above the largest default pipe capacity in the supported
/// macOS/Linux matrix (including Linux systems with 64 KiB pages), so the write
/// cannot finish unless the parent actively drains stdout.
const DRAIN_TAIL_BYTES: usize = 8 * 1024 * 1024;
/// Re-read cadence of the control file while `hold` is in effect.
const HOLD_POLL: Duration = Duration::from_millis(10);
/// Exit status for a launcher-contract violation (bad argv, bad handshake).
const FAKE_ERROR_STATUS: i32 = 18;
/// Exit status of the `die` mode: gone with no terminal response.
const DIE_STATUS: i32 = 19;
/// Exit status when the parent stopped reading the response stream.
const WRITE_FAILED_STATUS: i32 = 1;

fn main() {
    let real = env::var_os("ZRUSH_REAL_BIN").expect("ZRUSH_REAL_BIN is set by the harness");
    let fake = Fake::from_env();
    let args: Vec<OsString> = env::args_os().skip(1).collect();

    if args.is_empty() || args[0] != *"worker" || fake.mode() == "proxy" {
        exec_real(&real, &args);
    }
    if args.len() != 3 || args[1] != *"--control-fd" {
        fake.fail("bad worker argv");
    }
    let control = args[2]
        .to_str()
        .and_then(|text| text.parse::<i32>().ok())
        .unwrap_or_else(|| fake.fail("bad control fd"));
    if control <= 2 {
        fake.fail("bad control fd");
    }
    worker(&fake, control);
}

fn exec_real(real: &OsStr, args: &[OsString]) -> ! {
    let error = Command::new(real).args(args).exec();
    panic!("exec {}: {error}", Path::new(real).display());
}

/// The control/state/counter file trio, re-read per request so a test can
/// change the mode while a session is live.
struct Fake {
    control: PathBuf,
    state: PathBuf,
    count: PathBuf,
}

impl Fake {
    fn from_env() -> Self {
        let control = PathBuf::from(
            env::var_os("ZRUSH_FAKE_CONTROL").expect("ZRUSH_FAKE_CONTROL is set by the harness"),
        );
        let state = PathBuf::from(
            env::var_os("ZRUSH_FAKE_STATE").expect("ZRUSH_FAKE_STATE is set by the harness"),
        );
        let mut count = state.clone();
        count.set_extension("count");
        Self {
            control,
            state,
            count,
        }
    }

    fn mode(&self) -> String {
        match fs::read_to_string(&self.control) {
            Ok(text) => text.trim().to_string(),
            Err(_) => "proxy".to_string(),
        }
    }

    fn note(&self, line: &str) {
        let mut out = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.state)
            .unwrap_or_else(|e| panic!("open {}: {e}", self.state.display()));
        writeln!(out, "{line}")
            .unwrap_or_else(|e| panic!("append to {}: {e}", self.state.display()));
    }

    /// Session numbers are persistent across sessions and across processes:
    /// the tests baseline against the current value and assert on `current + N`.
    fn next_session(&self) -> u64 {
        let previous = match fs::read_to_string(&self.count) {
            Ok(text) => text
                .trim()
                .parse::<u64>()
                .unwrap_or_else(|e| panic!("session counter is not a number: {text:?} ({e})")),
            Err(_) => 0,
        };
        let value = previous + 1;
        fs::write(&self.count, value.to_string())
            .unwrap_or_else(|e| panic!("write {}: {e}", self.count.display()));
        value
    }

    fn fail(&self, reason: &str) -> ! {
        self.note(&format!("fake-error {reason}"));
        std::process::exit(FAKE_ERROR_STATUS);
    }
}

/// Every reader of `path` (the `hold`-loop poller, and the one-shot `proxy`,
/// `mismatch`, and `drain` mode checks) must see a complete mode, so write a
/// sibling temp file and `rename` it in.
fn atomic_write(path: &Path, contents: &str) {
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    fs::write(&tmp, contents).unwrap_or_else(|e| panic!("write {}: {e}", tmp.display()));
    fs::rename(&tmp, path)
        .unwrap_or_else(|e| panic!("rename {} -> {}: {e}", tmp.display(), path.display()));
}

fn worker(fake: &Fake, control_fd: i32) {
    // cli-protocol.md 「abort control と worker 終了」: stdout is the response
    // stream and descendants must not inherit it.
    set_cloexec(1);
    thread::spawn(move || watchdog(control_fd));

    let session = fake.next_session();
    fake.note(&format!("start {session}"));

    let mut input = io::stdin().lock();
    let hello = read_netstring(&mut input, fake)
        .map(|payload| fields(&payload, fake))
        .unwrap_or_default();
    let valid_stamp = |stamp: &[u8]| {
        !stamp.is_empty()
            && stamp
                .iter()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    };
    if hello.len() != 2 || hello[0] != b"hello" || !valid_stamp(&hello[1]) {
        fake.fail("bad hello");
    }

    if fake.mode() == "mismatch" {
        atomic_write(&fake.control, "proxy");
        write_message(&[b"incompatible", b"cafebabe"]);
        fake.note(&format!("mismatch {session}"));
        // cli-protocol.md 「セッションフレーミングと握手」: the post-`incompatible`
        // discard state.
        io::copy(&mut input, &mut io::sink()).ok();
        return;
    }
    write_message(&[b"ready", &hello[1]]);
    fake.note(&format!("ready {session}"));

    loop {
        let Some(payload) = read_netstring(&mut input, fake) else {
            fake.note(&format!("eof {session}"));
            if fake.mode() == "drain" {
                write_stdout(&vec![b'x'; DRAIN_TAIL_BYTES]);
                fake.note(&format!("tail {session} {DRAIN_TAIL_BYTES}"));
            }
            fake.note(&format!("exit {session}"));
            return;
        };
        let request = fields(&payload, fake);
        // The kind is folded onto the contract's two request kinds so a state
        // line always splits into four fields (`tests/driver/fake.rs`).
        let kind = match request.first().map(Vec::as_slice) {
            Some(b"store") => "store",
            Some(b"plan") => "plan",
            _ => "other",
        };
        let request_id = match request.get(1) {
            Some(field) => str::from_utf8(field)
                .unwrap_or_else(|e| panic!("request_id is not UTF-8: {field:?} ({e})"))
                .to_string(),
            None => "missing".to_string(),
        };
        fake.note(&format!("request {session} {kind} {request_id}"));

        let mut action = fake.mode();
        if action == "hold" {
            fake.note(&format!("hold {session} {request_id}"));
            while action == "hold" {
                thread::sleep(HOLD_POLL);
                action = fake.mode();
            }
        }
        if action == "die" {
            fake.note(&format!("die {session} {request_id}"));
            // SAFETY: an immediate process-wide exit with no unwinding, which
            // is the point: no terminal response ever reaches the parent.
            unsafe { libc::_exit(DIE_STATUS) };
        }
        if action == "error" || action == "drain" || action == "unknown-generation" {
            // A `store` always succeeds with the contract's empty body; the
            // mode decides only what the `plan` referencing it gets back.
            if kind == "store" {
                write_message(&[b"ok", request_id.as_bytes(), b""]);
            } else if action == "unknown-generation" {
                write_message(&[b"error", request_id.as_bytes(), b"unknown-generation"]);
            } else {
                write_message(&[b"error", request_id.as_bytes(), b"invalid-request"]);
            }
            fake.note(&format!("{action} {session} {request_id}"));
            continue;
        }
        fake.fail(&format!("unknown control {action}"));
    }
}

/// Blocking read of the control fd. Any byte, EOF, or non-`EINTR` error ends
/// the process immediately, even while the main thread is inside a request.
fn watchdog(control_fd: i32) -> ! {
    let mut byte = [0u8; 1];
    loop {
        // SAFETY: a one-byte read into an owned buffer on an inherited fd the
        // launcher validated as > 2.
        let n = unsafe { libc::read(control_fd, byte.as_mut_ptr().cast(), 1) };
        if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        // SAFETY: immediate process-wide exit from a non-main thread.
        unsafe { libc::_exit(1) };
    }
}

fn set_cloexec(fd: i32) {
    // SAFETY: fcntl on a live descriptor with a flag-setting command.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } == -1 {
        panic!("set FD_CLOEXEC on fd {fd}: {}", io::Error::last_os_error());
    }
}

// ---- netstring framing (cli-protocol.md 「セッションフレーミングと握手」) ----

/// One canonical netstring, or `None` at a clean message boundary EOF.
fn read_netstring<R: Read>(input: &mut R, fake: &Fake) -> Option<Vec<u8>> {
    let mut digits: Vec<u8> = Vec::new();
    loop {
        let Some(byte) = read_byte(input, fake) else {
            if digits.is_empty() {
                return None;
            }
            fake.fail("truncated length");
        };
        if byte == b':' {
            break;
        }
        if !byte.is_ascii_digit() {
            fake.fail("invalid length");
        }
        digits.push(byte);
    }
    if digits.is_empty() || (digits.len() > 1 && digits[0] == b'0') {
        fake.fail("noncanonical length");
    }
    let size: usize = str::from_utf8(&digits)
        .ok()
        .and_then(|text| text.parse().ok())
        .unwrap_or_else(|| fake.fail("invalid length"));
    let mut payload = vec![0u8; size];
    let mut filled = 0;
    while filled < size {
        match input.read(&mut payload[filled..]) {
            Ok(0) => fake.fail("truncated payload"),
            Ok(n) => filled += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => fake.fail(&format!("read error {e}")),
        }
    }
    if read_byte(input, fake) != Some(b',') {
        fake.fail("truncated payload");
    }
    Some(payload)
}

fn read_byte<R: Read>(input: &mut R, fake: &Fake) -> Option<u8> {
    let mut byte = [0u8; 1];
    loop {
        match input.read(&mut byte) {
            Ok(0) => return None,
            Ok(_) => return Some(byte[0]),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => fake.fail(&format!("read error {e}")),
        }
    }
}

/// The concatenated field netstrings of one message payload.
fn fields(payload: &[u8], fake: &Fake) -> Vec<Vec<u8>> {
    let mut rest = payload;
    let mut result = Vec::new();
    while !rest.is_empty() {
        let Some(field) = read_netstring(&mut rest, fake) else {
            fake.fail("missing field");
        };
        result.push(field);
    }
    result
}

fn netstring(payload: &[u8]) -> Vec<u8> {
    let mut out = payload.len().to_string().into_bytes();
    out.push(b':');
    out.extend_from_slice(payload);
    out.push(b',');
    out
}

fn write_message(items: &[&[u8]]) {
    let mut body = Vec::new();
    for item in items {
        body.extend_from_slice(&netstring(item));
    }
    write_stdout(&netstring(&body));
}

/// A response the parent is no longer reading ends the session, quietly. This
/// process's stderr is the host's `ZRUSH_LOG`, which the tests read as a shared
/// observation surface, so a panic message here would land in their evidence.
fn write_stdout(bytes: &[u8]) {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    if out.write_all(bytes).is_err() || out.flush().is_err() {
        std::process::exit(WRITE_FAILED_STATUS);
    }
}
