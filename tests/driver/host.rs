//! Host zsh under a real pty, with the expect/drain and log-synchronization
//! primitives the zle-integration tests are written against.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime};

use tempfile::TempDir;

use crate::fixtures;
use crate::pty::Pty;

pub mod keys {
    pub const UP: &str = "\x1b[A";
    pub const DOWN: &str = "\x1b[B";
    pub const RIGHT: &str = "\x1b[C";
    pub const LEFT: &str = "\x1b[D";
    pub const ENTER: &str = "\r";
    pub const DUMP_BUFFER: &str = "\x18b";
    pub const DUMP_RH: &str = "\x18h";
    pub const CURSOR_LEFT_THREE: &str = "\x18v";
}

/// Poll slice for every read of the pty; the enclosing deadlines are what
/// bound a wait, not this interval.
const POLL: Duration = Duration::from_millis(50);
/// Cadence at which log-watching loops re-read the log, draining in between.
const LOG_POLL: Duration = Duration::from_millis(150);
const DUMP_DEADLINE: Duration = Duration::from_secs(8);
/// Set to print per-host startup timings; see tmp/issue-76-rust-driver.
const TIMING_ENV: &str = "ZRUSH_DRIVER_TIMING";

pub struct Host {
    tmp: Option<TempDir>,
    log: PathBuf,
    pty: Pty,
    child: Child,
    /// Observation window (#63): everything the host has emitted since the
    /// last input we sent it. Only sending input opens a new window, so output
    /// an intervening drain consumed is still visible to a later expect.
    window: Vec<u8>,
    spawned_at: SystemTime,
    boot: Duration,
}

impl Host {
    pub fn boot() -> Self {
        let tmp = TempDir::new().expect("create work dir");
        let home = tmp.path().join("home");
        let work = tmp.path().join("work");
        let zdot = work.join("zdot");
        let xdg = work.join("xdg");
        let log = work.join("host.log");
        fs::create_dir_all(&home).expect("create home");
        fs::create_dir_all(&zdot).expect("create zdotdir");
        fs::create_dir_all(xdg.join("zrush")).expect("create config dir");
        fixtures::build(&home);

        let repo = Path::new(env!("CARGO_MANIFEST_DIR"));
        let rc = repo.join("tests/zsh/rc/minimal.zshrc");
        fs::write(zdot.join(".zshrc"), format!("source {}\n", rc.display())).expect("write .zshrc");

        let bin = env!("CARGO_BIN_EXE_zrush");
        let mut command = Command::new("zsh");
        // The allowlist below is what env_clear leaves the host with. Keeping
        // $EDITOR/$VISUAL out of it is load-bearing: zsh links the vi keymap to
        // main when either contains "vi", and every control key these tests
        // send is an emacs-keymap binding.
        command.arg("-d").arg("-i").current_dir(&home).env_clear();
        command.env("PATH", std::env::var_os("PATH").unwrap_or_default());
        if let Some(tmpdir) = std::env::var_os("TMPDIR") {
            command.env("TMPDIR", tmpdir);
        }
        command
            .env("TERM", "vt100")
            .env("LC_ALL", utf8_locale())
            .env("HOME", &home)
            .env("ZDOTDIR", &zdot)
            .env("XDG_CONFIG_HOME", &xdg)
            .env("ZRUSH_TEST_TMP", &work)
            .env("ZRUSH_LOG", &log)
            .env("ZRUSH_BIN", bin)
            .env("ZRUSH_REAL_BIN", bin)
            // Test seam: 5000 ms matches this harness's other bounded waits.
            .env("ZRUSH_HISTORY_DEADLINE_MS", "5000");

        let started = Instant::now();
        let spawned_at = SystemTime::now();
        let (pty, child) = Pty::spawn(&mut command).expect("spawn host zsh on a pty");
        let mut host = Self {
            tmp: Some(tmp),
            log,
            pty,
            child,
            window: Vec::new(),
            spawned_at,
            boot: Duration::ZERO,
        };
        if !host.expect("MARK-RC-DONE", Duration::from_secs(20)) {
            panic!("host startup unconfirmed: {}", host.window_tail());
        }
        host.sync_prompt(Duration::from_secs(5));
        host.boot = started.elapsed();
        host
    }

    // ---- pty I/O ----

    pub fn send_keys(&mut self, keys: &str) {
        self.window.clear();
        self.pty
            .write_all(keys.as_bytes())
            .expect("write keys to host pty");
    }

    /// Read the pty for `how_long`. Every wait loop calls this: a host that is
    /// never read from can block in `tcsetattr TCSADRAIN`.
    pub fn drain(&mut self, how_long: Duration) {
        let deadline = Instant::now() + how_long;
        while Instant::now() < deadline {
            let chunk = self.pty.read_available(POLL);
            self.window.extend_from_slice(&chunk);
        }
    }

    pub fn expect(&mut self, text: &str, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            if self.window_has(text) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            let chunk = self.pty.read_available(POLL);
            self.window.extend_from_slice(&chunk);
        }
    }

    /// Match the raw bytes, then again with SGR sequences stripped (#64):
    /// highlighting can split text the caller expects to be contiguous.
    fn window_has(&self, text: &str) -> bool {
        contains(&self.window, text.as_bytes())
            || contains(&strip_sgr(&self.window), text.as_bytes())
    }

    fn window_tail(&self) -> String {
        let start = self.window.len().saturating_sub(300);
        String::from_utf8_lossy(&self.window[start..]).into_owned()
    }

    pub fn sync_prompt(&mut self, timeout: Duration) {
        self.expect("HP>", timeout);
        self.drain(Duration::from_millis(100));
    }

    pub fn press(&mut self, keys: &str) {
        self.send_keys(keys);
        self.drain(Duration::from_millis(300));
    }

    // ---- ZRUSH_LOG synchronization ----

    /// Number of log lines containing `needle` (grep -cF semantics).
    pub fn log_count(&self, needle: &str) -> usize {
        let Ok(bytes) = fs::read(&self.log) else {
            return 0;
        };
        bytes
            .split(|&b| b == b'\n')
            .filter(|line| contains(line, needle.as_bytes()))
            .count()
    }

    pub fn wait_log(&mut self, needle: &str, baseline: usize, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            self.drain(LOG_POLL);
            if self.log_count(needle) > baseline {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
        }
    }

    /// Assert that `needle` gains an occurrence after pressing `keys` in order.
    pub fn assert_log_grows(&mut self, needle: &str, keys: &[&str], label: &str) {
        let baseline = self.log_count(needle);
        for key in keys {
            self.press(key);
        }
        assert!(
            self.wait_log(needle, baseline, Duration::from_secs(3)),
            "{label}: no new {needle:?} line in the host log"
        );
    }

    /// Send keys and wait for the render plan they provoke to be applied.
    /// A new `plan: applied` line is the only reliable render signal: the pty
    /// byte stream is zle's own encoding, so listing text is not guaranteed to
    /// survive in it contiguously (#64).
    pub fn send_keys_wait_plan(&mut self, shape: PlanShape, keys: &str) {
        let base_all = self.log_count("plan: applied");
        let base_zero = self.log_count("plan: applied L=0 P=0");
        self.send_keys(keys);
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            self.drain(LOG_POLL);
            let all = self.log_count("plan: applied");
            let zero = self.log_count("plan: applied L=0 P=0");
            let reached = match shape {
                PlanShape::Zero => zero > base_zero,
                PlanShape::Nonempty => all - zero > base_all - base_zero,
            };
            if reached {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "no {shape:?} plan applied after sending {keys:?}"
            );
        }
    }

    // ---- test-only dump widgets (tests/zsh/rc/minimal.zshrc) ----

    /// Trigger a `^X*` dump widget and return the freshest matching log line's
    /// value. The key is re-pressed about once a second within the deadline: a
    /// keystroke landing while the host unwinds a pty-level interrupt can be
    /// swallowed without running its widget (#47), and dump widgets are pure
    /// observers so extra presses are harmless. Each press clears the
    /// observation window, so read window-dependent state before dumping.
    pub fn dump_get(&mut self, key: &str, tag: &str) -> Option<String> {
        let needle = format!("{tag}=");
        let baseline = self.log_count(&needle);
        let deadline = Instant::now() + DUMP_DEADLINE;
        while Instant::now() < deadline {
            self.send_keys(key);
            if self.wait_log(&needle, baseline, Duration::from_secs(1)) {
                let bytes = fs::read(&self.log).expect("read host log");
                let last = bytes
                    .split(|&b| b == b'\n')
                    .rfind(|line| contains(line, needle.as_bytes()))
                    .map(|line| String::from_utf8_lossy(line).into_owned())
                    .expect("matching log line");
                let value = last
                    .split_once(&needle)
                    .expect("log line carries the tag")
                    .1
                    .to_string();
                return Some(value);
            }
        }
        None
    }

    pub fn assert_buffer(&mut self, expected: &str, label: &str) {
        let dump = self
            .dump_get(keys::DUMP_BUFFER, "TESTBUF")
            .unwrap_or_else(|| panic!("{label}: BUFFER dump did not run"));
        assert_eq!(unquote(&dump), expected, "{label}");
    }

    /// zsh tags its own region_highlight entries with `memo=` only from 5.9 on.
    pub fn has_memo(&self) -> bool {
        zsh_version() >= (5, 9)
    }

    // ---- failure evidence and measurement ----

    fn log_tail(&self) -> String {
        let Ok(bytes) = fs::read(&self.log) else {
            return "<no log>".to_string();
        };
        let text = String::from_utf8_lossy(&bytes);
        let lines: Vec<&str> = text.lines().collect();
        lines[lines.len().saturating_sub(40)..].join("\n")
    }

    /// `boot_ms` is pty spawn to a ready prompt; `worker_ms` is pty spawn to
    /// the persistent worker's handshake, which the lazy worker only reaches
    /// once a test triggers its first collection.
    fn report_timing(&self) {
        let current = std::thread::current();
        let name = current.name().unwrap_or("?");
        let spawn_epoch = self
            .spawned_at
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or_default();
        let worker_ms = match self.log_epoch_of("worker: handshake ready") {
            Some(at) => format!("{:.1}", (at - spawn_epoch) * 1000.0),
            None => "-".to_string(),
        };
        eprintln!(
            "timing name={name} boot_ms={:.1} worker_ms={worker_ms}",
            self.boot.as_secs_f64() * 1000.0
        );
    }

    /// Epoch stamp of the first log line containing `needle`; `_zlog` prefixes
    /// every line with `[pid EPOCHREALTIME]`.
    fn log_epoch_of(&self, needle: &str) -> Option<f64> {
        let bytes = fs::read(&self.log).ok()?;
        let text = String::from_utf8_lossy(&bytes);
        let line = text.lines().find(|line| line.contains(needle))?;
        line.split_whitespace()
            .nth(1)?
            .trim_end_matches(']')
            .parse()
            .ok()
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if std::env::var_os(TIMING_ENV).is_some() {
            self.report_timing();
        }
        if std::thread::panicking()
            && let Some(tmp) = self.tmp.take()
        {
            let kept = tmp.keep();
            eprintln!("driver: work dir kept at {}", kept.display());
            eprintln!(
                "driver: tail of {}:\n{}",
                self.log.display(),
                self.log_tail()
            );
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum PlanShape {
    Zero,
    Nonempty,
}

// ---- byte helpers ----

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack.len() >= needle.len()
        && haystack.windows(needle.len()).any(|w| w == needle)
}

/// Drop each SGR sequence together with the NUL run that follows it (some
/// terminfo entries pad every SGR with NULs, #64). Unrelated literal NULs stay.
fn strip_sgr(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b && bytes.get(i + 1) == Some(&b'[') {
            let mut j = i + 2;
            while matches!(bytes.get(j), Some(b) if b.is_ascii_digit() || *b == b';') {
                j += 1;
            }
            if bytes.get(j) == Some(&b'm') {
                j += 1;
                while bytes.get(j) == Some(&0) {
                    j += 1;
                }
                i = j;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    out
}

/// Undo zsh's `${(qqqq)}` quoting, which the dump widgets apply before logging.
/// zsh emits `$'...'` carrying `\\`, `\'`, the named control escapes, and octal
/// `\NNN` (1 to 3 digits) for every other non-printable byte; printable
/// multibyte characters stay raw. Decoding builds a byte string and validates
/// it once, so a dumped value that is not UTF-8 -- or an escape form zsh is not
/// known to produce -- fails loudly instead of turning into plausible garbage.
fn unquote(text: &str) -> String {
    let body = text
        .strip_prefix("$'")
        .and_then(|rest| rest.strip_suffix('\''))
        .unwrap_or_else(|| panic!("not a ${{(qqqq)}}-quoted value: {text}"));
    let mut out: Vec<u8> = Vec::with_capacity(body.len());
    let mut bytes = body.as_bytes().iter().copied().peekable();
    while let Some(byte) = bytes.next() {
        if byte != b'\\' {
            out.push(byte);
            continue;
        }
        match bytes.next() {
            Some(b'\\') => out.push(b'\\'),
            Some(b'\'') => out.push(b'\''),
            Some(b'a') => out.push(0x07),
            Some(b'b') => out.push(0x08),
            Some(b'e') => out.push(0x1b),
            Some(b'f') => out.push(0x0c),
            Some(b'n') => out.push(b'\n'),
            Some(b'r') => out.push(b'\r'),
            Some(b't') => out.push(b'\t'),
            Some(b'v') => out.push(0x0b),
            Some(digit @ b'0'..=b'7') => {
                let mut value = u32::from(digit - b'0');
                for _ in 0..2 {
                    let Some(&next @ b'0'..=b'7') = bytes.peek() else {
                        break;
                    };
                    value = value * 8 + u32::from(next - b'0');
                    bytes.next();
                }
                out.push(
                    u8::try_from(value)
                        .unwrap_or_else(|_| panic!("octal escape out of range in {text}")),
                );
            }
            Some(other) => panic!("unhandled zsh escape \\{} in {text}", other as char),
            None => panic!("trailing backslash in {text}"),
        }
    }
    String::from_utf8(out).unwrap_or_else(|e| panic!("dumped value is not UTF-8: {text} ({e})"))
}

// ---- host environment probes ----

/// POSTDISPLAY printability checks want a real UTF-8 locale. Minimal Linux
/// images ship only C.UTF-8/C.utf8 while macOS ships en_US.UTF-8.
fn utf8_locale() -> &'static str {
    static LOCALE: OnceLock<&'static str> = OnceLock::new();
    LOCALE.get_or_init(|| {
        for candidate in ["en_US.UTF-8", "C.UTF-8", "C.utf8"] {
            let ok = Command::new("locale")
                .arg("charmap")
                .env("LC_ALL", candidate)
                .output()
                .map(|out| out.status.success())
                .unwrap_or(false);
            if ok {
                return candidate;
            }
        }
        "C"
    })
}

fn zsh_version() -> (u32, u32) {
    static VERSION: OnceLock<(u32, u32)> = OnceLock::new();
    *VERSION.get_or_init(|| {
        let out = Command::new("zsh")
            .args(["-f", "-c", "printf %s $ZSH_VERSION"])
            .output()
            .expect("probe zsh version");
        let text = String::from_utf8_lossy(&out.stdout);
        let mut parts = text.split('.');
        let major = parts.next().and_then(|p| p.parse().ok()).unwrap_or(0);
        let minor = parts.next().and_then(|p| p.parse().ok()).unwrap_or(0);
        (major, minor)
    })
}
