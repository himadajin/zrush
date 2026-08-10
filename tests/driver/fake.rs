//! The controllable `zrush` launcher (`tests/driver/bin/fake_worker.rs`) as the
//! tests see it: a control file that selects the next request's failure mode,
//! and the append-only state file the fake writes instead of anything the tests
//! could read off its stdout.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Bytes of filler the [`Mode::Drain`] session writes on stdin EOF, matching
/// `DRAIN_TAIL_BYTES` in the binary; the `tail` state line carries the count.
pub const DRAIN_TAIL_BYTES: usize = 8 * 1024 * 1024;

/// What the fake does with the *next* request it reads. The control file is
/// re-read per request, so a mode set while a session is live still applies.
#[derive(Clone, Copy, Debug)]
pub enum Mode {
    /// Delegate every invocation to the real binary (`execv`); no fake session.
    Proxy,
    /// Answer the handshake with `incompatible`, then fall back to `Proxy`.
    Mismatch,
    /// Park the request until the mode changes, leaving it pending.
    Hold,
    /// Exit without a terminal response.
    Die,
    /// Reply with an in-band `error` and keep serving.
    Error,
    /// Like `Error`, plus a raw non-protocol tail on stdin EOF.
    Drain,
}

impl Mode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Proxy => "proxy",
            Self::Mismatch => "mismatch",
            Self::Hold => "hold",
            Self::Die => "die",
            Self::Error => "error",
            Self::Drain => "drain",
        }
    }
}

pub struct Fake {
    control: PathBuf,
    state: PathBuf,
    count: PathBuf,
}

impl Fake {
    /// Point the host's `$ZRUSH_BIN` at the fake and give it a control/state
    /// file pair under this host's own work directory.
    pub(crate) fn install(work: &Path, command: &mut Command) -> Self {
        let control = work.join("fake-control");
        let state = work.join("fake-state");
        let count = work.join("fake-state.count");
        atomic_write(&control, Mode::Proxy.as_str());
        command
            .env("ZRUSH_BIN", env!("CARGO_BIN_EXE_zrush-fake-worker"))
            .env("ZRUSH_FAKE_CONTROL", &control)
            .env("ZRUSH_FAKE_STATE", &state);
        Self {
            control,
            state,
            count,
        }
    }

    pub fn set_mode(&self, mode: Mode) {
        atomic_write(&self.control, mode.as_str());
    }

    /// State lines containing `needle` (`grep -cF` semantics). Needles for a
    /// line that continues past the session number end with a space, so
    /// `die 1 ` cannot match `die 10 `.
    pub fn count(&self, needle: &str) -> usize {
        self.lines()
            .iter()
            .filter(|line| line.contains(needle))
            .count()
    }

    /// State lines equal to `line`. The boundary the trailing-space convention
    /// gives the other needles has to come from the line end for the records
    /// whose last field *is* the session number (`mismatch`, `eof`, `exit`).
    pub fn count_line(&self, line: &str) -> usize {
        self.lines().iter().filter(|have| *have == line).count()
    }

    /// The freshest state line containing `needle`.
    pub fn last(&self, needle: &str) -> Option<String> {
        self.lines().into_iter().rfind(|line| line.contains(needle))
    }

    /// Sessions the fake has ever started, from its persistent counter file.
    /// Tests baseline against this and assert on `current + N`, which is what
    /// keeps the accounting valid for one host among many running in parallel.
    pub fn sessions(&self) -> usize {
        fs::read_to_string(&self.count)
            .ok()
            .and_then(|text| text.trim().parse().ok())
            .unwrap_or(0)
    }

    /// Sessions that actually reached the worker path (`^start `); a `proxy`
    /// invocation execs the real binary before writing anything.
    pub fn starts(&self) -> usize {
        self.lines()
            .iter()
            .filter(|line| line.starts_with("start "))
            .count()
    }

    /// How many `request <session> <request_id>` lines carry exactly this id,
    /// across every session -- one means it was never replayed.
    pub fn requests_for(&self, request_id: &str) -> usize {
        self.lines()
            .iter()
            .filter(|line| {
                let fields: Vec<&str> = line.split(' ').collect();
                fields.len() == 3
                    && fields[0] == "request"
                    && !fields[1].is_empty()
                    && fields[1].bytes().all(|b| b.is_ascii_digit())
                    && fields[2] == request_id
            })
            .count()
    }

    fn lines(&self) -> Vec<String> {
        match fs::read_to_string(&self.state) {
            Ok(text) => text.lines().map(str::to_string).collect(),
            Err(_) => Vec::new(),
        }
    }
}

/// Every reader of `path` (the fake's `hold`-loop poller, and its one-shot
/// mode checks) must see a complete mode, so write a sibling temp file and
/// `rename` it in.
fn atomic_write(path: &Path, contents: &str) {
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    fs::write(&tmp, contents).expect("write fake control temp file");
    fs::rename(&tmp, path).expect("rename fake control temp file");
}
