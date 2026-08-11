//! Host zsh under a real pty, with the expect/drain and log-synchronization
//! primitives the zle-integration tests are written against.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime};

use tempfile::TempDir;

use crate::fake::Fake;
use crate::fixtures;
use crate::pty::{Chunk, Pty};

pub mod keys {
    pub const UP: &str = "\x1b[A";
    pub const DOWN: &str = "\x1b[B";
    pub const RIGHT: &str = "\x1b[C";
    pub const LEFT: &str = "\x1b[D";
    pub const ENTER: &str = "\r";
    pub const TAB: &str = "\t";
    pub const DISMISS: &str = "\x07";
    pub const SEND_BREAK: &str = "\x03";
    /// `kill-whole-line`: discards the current line without executing it, and
    /// without [`Host::clear_line`]'s drain for the cases that must not pause.
    pub const KILL_WHOLE_LINE: &str = "\x15";
    /// `ctrl-p`: a default select-prev key, and the one a `[keybind]` variant
    /// can drop from the action's list.
    pub const CTRL_P: &str = "\x10";
    /// `quoted-insert` then LF: a literal newline in BUFFER, without the line
    /// being accepted.
    pub const QUOTED_NEWLINE: &str = "\x16\n";
    pub const DUMP_BUFFER: &str = "\x18b";
    pub const DUMP_POSTDISPLAY: &str = "\x18p";
    pub const DUMP_RH: &str = "\x18h";
    /// The whole `region_highlight` array, third-party entries included.
    pub const DUMP_ALL_RH: &str = "\x18a";
    pub const DUMP_WORKER: &str = "\x18w";
    /// Empty-word-cache validity: `fpmatch=<0|1> age=<seconds|-1>`.
    pub const DUMP_CACHE: &str = "\x18c";
    /// Age the empty-word cache entry past its fixed TTL.
    pub const AGE_CACHE: &str = "\x18n";
    /// Listing kind, selection and position count (history rc only).
    pub const DUMP_KIND: &str = "\x18k";
    /// History-index latch and fingerprint baseline (history rc only).
    pub const DUMP_HIST: &str = "\x18i";
    /// The `$history` event number of the newest fixture line (history rc only).
    pub const DUMP_EVENT: &str = "\x18e";
    /// Debounce-timer and in-flight-collection fd state (history rc only).
    pub const DUMP_FDS: &str = "\x18t";
    /// `CURSOR` position, for the cases that need a delegated widget to have
    /// moved the cursor rather than merely left BUFFER alone (history rc only).
    pub const DUMP_CURSOR: &str = "\x18z";
    /// `backward-char`: a cursor movement zrush never binds, i.e. an external
    /// CURSOR-only change (history rc only).
    pub const BACKWARD_CHAR: &str = "\x18l";
    /// `up-line-or-history` bound raw: native history movement that bypasses
    /// zrush, i.e. the way into `HISTNO != HISTCMD` (history rc only).
    pub const RAW_HISTORY_UP: &str = "\x18u";
    pub const CURSOR_LEFT_THREE: &str = "\x18v";
    /// `_zrush_worker_shutdown` from a widget: an explicit healthy teardown.
    pub const WORKER_TEARDOWN: &str = "\x18q";
    /// Record the host's fd 0/1/2 targets and emit both stream sentinels.
    pub const STDIO_PROBE: &str = "\x18f";
    /// Synthesize the timer/ack/drain descriptors and run their shared
    /// teardown, without depending on timing or kernel backpressure.
    pub const CLOSE_AUX_FDS: &str = "\x18j";
    /// Arm a production-generated drain handler from a widget; the readiness
    /// dispatch it provokes only happens back in the real ZLE event loop.
    pub const GENERATED_CALLBACK: &str = "\x18g";
}

/// Poll slice for every read of the pty; the enclosing deadlines are what
/// bound a wait, not this interval.
const POLL: Duration = Duration::from_millis(50);
/// Cadence at which log-watching loops re-read the log, draining in between.
const LOG_POLL: Duration = Duration::from_millis(150);
const DUMP_DEADLINE: Duration = Duration::from_secs(8);
/// Set to make `Host::drop` print each host's boot/worker-ready timings.
const TIMING_ENV: &str = "ZRUSH_DRIVER_TIMING";

/// Shell line that widens the worker shutdown budget, for the cases that
/// assert a *completed* handoff. The production default is 100 ms, and its
/// expiry/quarantine branch is asserted independently by
/// `tests/zsh/transport.zsh`; without this seam scheduler variance alone could
/// turn a healthy shutdown into that branch.
pub const SHUTDOWN_SEAM: &str = "_ZRUSH_WORKER_SHUTDOWN_MS=5000";

/// Default `ZRUSH_HISTORY_DEADLINE_MS` for every host: 5000 ms matches this
/// harness's other bounded waits, so a loaded machine cannot turn a healthy
/// synchronous history exchange into the deadline branch. The production
/// default is 100 ms (docs/internal/specs/behavior.md 「履歴メニュー」).
const HISTORY_DEADLINE_SEAM: u32 = 5000;

pub struct Host {
    tmp: Option<TempDir>,
    log: PathBuf,
    xdg: PathBuf,
    pty: Pty,
    child: Child,
    /// Observation window (#63): everything the host has emitted since the
    /// last input we sent it. Only sending input opens a new window, so output
    /// an intervening drain consumed is still visible to a later expect.
    window: Vec<u8>,
    /// First `^Xf` fd signature this host reported; every later probe is
    /// compared against it rather than against another host's.
    stdio_baseline: Option<String>,
    fake: Option<Fake>,
    spawned_at: SystemTime,
    boot: Duration,
}

/// Host rc file, loaded through the host's own `$ZDOTDIR`.
#[derive(Clone, Copy, Default)]
enum HostRc {
    #[default]
    Minimal,
    /// Fixture history in memory (isolated HISTFILE, `SAVEHIST=0`) plus the
    /// history-menu dump widgets.
    History,
    /// [`HostRc::History`]'s isolation with the small, deliberately ordered
    /// fixture set the `[history].limit` scan window is read against.
    HistoryLimit,
    /// [`HostRc::History`]'s isolation with a fixture history large enough to
    /// cross the payload byte ceiling partway through the scan.
    HistoryBudget,
    /// [`HostRc::History`]'s isolation with a fixture history small enough to
    /// show whole, plus the history file a bulk load (`fc -R`) reads.
    HistorySync,
}

impl HostRc {
    fn file(self) -> &'static str {
        match self {
            HostRc::Minimal => "tests/zsh/rc/minimal.zshrc",
            HostRc::History => "tests/zsh/rc/history.zshrc",
            HostRc::HistoryLimit => "tests/zsh/rc/history-limit.zshrc",
            HostRc::HistoryBudget => "tests/zsh/rc/history-budget.zshrc",
            HostRc::HistorySync => "tests/zsh/rc/history-sync.zshrc",
        }
    }
}

/// What a scenario varies about its host. Every field defaults to the plain
/// [`Host::boot`] shape, so each constructor names only what it changes.
#[derive(Default)]
pub struct BootOptions<'a> {
    rc: HostRc,
    /// Shell lines sourced *before* the rc file reaches `zrush init zsh`, for
    /// a coexistence double that must sit below zrush in the wrapper chain.
    pre_rc: &'a str,
    /// Shell lines sourced *after* the rc file, for a double that must sit
    /// above it. They run after the rc's own `MARK-RC-DONE`, which boot's
    /// following prompt sync still covers.
    post_rc: &'a str,
    extra_fixtures: Option<fn(&Path)>,
    fake: bool,
    config: Option<&'a str>,
    /// This host's `ZRUSH_HISTORY_DEADLINE_MS`; `None` keeps the harness-wide
    /// [`HISTORY_DEADLINE_SEAM`]. The seam exists so the *structure* of the
    /// deadline branch is testable (a value no exchange can meet); the
    /// production magnitude belongs to `tests/zsh/driver-latency.zsh`, which
    /// deliberately has no seam.
    history_deadline_ms: Option<u32>,
}

impl Host {
    pub fn boot() -> Self {
        Self::boot_with(BootOptions::default())
    }

    /// Like [`Host::boot`], but symlinks the shared 7001-file overflow tree
    /// (built once per process, cached under `target/`) into `fx/overflow`
    /// under the host's home.
    pub fn boot_with_overflow() -> Self {
        Self::boot_with(BootOptions {
            extra_fixtures: Some(fixtures::link_overflow),
            ..BootOptions::default()
        })
    }

    /// Like [`Host::boot`], but with `$ZRUSH_BIN` pointing at the failure-
    /// injection launcher (`$ZRUSH_REAL_BIN` still being the real binary).
    /// It starts in [`crate::fake::Mode::Proxy`], so the host behaves exactly
    /// as under the real binary until a test sets another mode.
    pub fn boot_fake() -> Self {
        Self::boot_with(BootOptions {
            fake: true,
            ..BootOptions::default()
        })
    }

    /// Like [`Host::boot`], but under `tests/zsh/rc/history.zshrc`.
    pub fn boot_history() -> Self {
        Self::boot_with(BootOptions {
            rc: HostRc::History,
            ..BootOptions::default()
        })
    }

    /// [`Host::boot_history`] with [`Host::boot_fake`]'s launcher, for the
    /// history cases that inject a worker failure.
    pub fn boot_history_fake() -> Self {
        Self::boot_with(BootOptions {
            rc: HostRc::History,
            fake: true,
            ..BootOptions::default()
        })
    }

    /// [`Host::boot_history`] with `config` already at
    /// `$XDG_CONFIG_HOME/zrush/config.toml` when the shell sources zrush, so
    /// the variant is in force from the first keystroke instead of racing the
    /// per-prompt config reload.
    pub fn boot_history_with_config(config: &str) -> Self {
        Self::boot_with(BootOptions {
            rc: HostRc::History,
            config: Some(config),
            ..BootOptions::default()
        })
    }

    /// [`Host::boot_history_with_config`] under
    /// `tests/zsh/rc/history-limit.zshrc`, whose fixture history is what a
    /// `[history].limit` scan window is read against.
    pub fn boot_history_limit_with_config(config: &str) -> Self {
        Self::boot_with(BootOptions {
            rc: HostRc::HistoryLimit,
            config: Some(config),
            ..BootOptions::default()
        })
    }

    /// [`Host::boot_history`] under `tests/zsh/rc/history-budget.zshrc`, whose
    /// fixture history outgrows the payload byte ceiling.
    pub fn boot_history_budget() -> Self {
        Self::boot_with(BootOptions {
            rc: HostRc::HistoryBudget,
            ..BootOptions::default()
        })
    }

    /// [`Host::boot_history`] under `tests/zsh/rc/history-sync.zshrc`, whose
    /// fixture history is small enough to read whole out of one menu and whose
    /// sandbox holds the history file a bulk load reads.
    pub fn boot_history_sync() -> Self {
        Self::boot_with(BootOptions {
            rc: HostRc::HistorySync,
            ..BootOptions::default()
        })
    }

    /// [`Host::boot_history`] with its own `ZRUSH_HISTORY_DEADLINE_MS`, for the
    /// cases that need the synchronous history exchange to run out of time.
    pub fn boot_history_with_deadline_ms(ms: u32) -> Self {
        Self::boot_with(BootOptions {
            rc: HostRc::History,
            history_deadline_ms: Some(ms),
            ..BootOptions::default()
        })
    }

    /// A host whose rc loads coexistence doubles around zrush: `pre` before it
    /// (so zrush records the double as a predecessor) and `post` after it (so
    /// the double wraps zrush's own registrations), the ordering
    /// docs/user/install.md documents for the real plugins.
    pub fn boot_with_doubles(pre: &'static str, post: &'static str) -> Self {
        Self::boot_with(BootOptions {
            pre_rc: pre,
            post_rc: post,
            ..BootOptions::default()
        })
    }

    /// [`Host::boot`] with an extra fixture tree.
    pub fn boot_with_fixtures(extra_fixtures: fn(&Path)) -> Self {
        Self::boot_with(BootOptions {
            extra_fixtures: Some(extra_fixtures),
            ..BootOptions::default()
        })
    }

    fn boot_with(options: BootOptions) -> Self {
        let BootOptions {
            rc,
            pre_rc,
            post_rc,
            extra_fixtures,
            fake,
            config,
            history_deadline_ms,
        } = options;
        let tmp = TempDir::new().expect("create work dir");
        let home = tmp.path().join("home");
        let work = tmp.path().join("work");
        let zdot = work.join("zdot");
        let xdg = work.join("xdg");
        let log = work.join("host.log");
        fs::create_dir_all(&home).expect("create home");
        fs::create_dir_all(&zdot).expect("create zdotdir");
        fs::create_dir_all(xdg.join("zrush")).expect("create config dir");
        if let Some(config) = config {
            fs::write(xdg.join("zrush/config.toml"), config).expect("write config.toml");
        }
        fixtures::build(&home);
        if let Some(extra_fixtures) = extra_fixtures {
            extra_fixtures(&home);
        }

        let rc = Path::new(env!("CARGO_MANIFEST_DIR")).join(rc.file());
        let zshrc = format!("{pre_rc}\nsource {}\n{post_rc}\n", rc.display());
        fs::write(zdot.join(".zshrc"), zshrc).expect("write .zshrc");

        let bin = env!("CARGO_BIN_EXE_zrush");
        let mut command = Command::new("zsh");
        // The allowlist below is what env_clear leaves the host with. Keeping
        // $EDITOR/$VISUAL out of it is load-bearing: zsh links the vi keymap to
        // main when either contains "vi", and every control key these tests
        // send is an emacs-keymap binding.
        command.arg("-d").arg("-i").current_dir(&home).env_clear();
        command.env("PATH", std::env::var_os("PATH").unwrap_or_default());
        command
            // The worker runtime directory and the automatic re-source's init
            // file are mktemp'd under $TMPDIR by the host itself, and its
            // zshexit cleanup never runs because Drop kills it. Pointing
            // $TMPDIR at this host's own work directory makes them go away
            // with it instead of accumulating in the system temp dir.
            .env("TMPDIR", &work)
            .env("TERM", "vt100")
            .env("LC_ALL", utf8_locale())
            .env("HOME", &home)
            .env("ZDOTDIR", &zdot)
            .env("XDG_CONFIG_HOME", &xdg)
            .env("ZRUSH_TEST_TMP", &work)
            .env("ZRUSH_LOG", &log)
            .env("ZRUSH_BIN", bin)
            .env("ZRUSH_REAL_BIN", bin)
            .env(
                "ZRUSH_HISTORY_DEADLINE_MS",
                history_deadline_ms
                    .unwrap_or(HISTORY_DEADLINE_SEAM)
                    .to_string(),
            );
        let fake = fake.then(|| Fake::install(&work, &mut command));

        let started = Instant::now();
        let spawned_at = SystemTime::now();
        let (pty, child) = Pty::spawn(&mut command).expect("spawn host zsh on a pty");
        let mut host = Self {
            tmp: Some(tmp),
            log,
            xdg,
            pty,
            child,
            window: Vec::new(),
            stdio_baseline: None,
            fake,
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

    /// Send a line of shell source for the host to execute (a definition, a
    /// `compdef`, a `:` no-op to force a config-mtime recheck, ...), followed
    /// by its terminating newline.
    pub fn send_line(&mut self, line: &str) {
        self.send_keys(&format!("{line}\n"));
    }

    /// `^U`: discard the current physical line without executing it.
    pub fn clear_line(&mut self) {
        self.send_keys(keys::KILL_WHOLE_LINE);
        self.drain(Duration::from_millis(200));
    }

    /// Read the pty until the host closes it -- the shell exited for real --
    /// or `timeout` expires, and report what it emitted on the way out.
    pub fn wait_for_exit(&mut self, timeout: Duration) -> Exit {
        let deadline = Instant::now() + timeout;
        let mut output = Vec::new();
        let mut reached_eof = false;
        while Instant::now() < deadline {
            match self.pty.read_chunk(POLL) {
                Chunk::Data(bytes) => {
                    self.window.extend_from_slice(&bytes);
                    output.extend_from_slice(&bytes);
                }
                Chunk::Idle => {}
                Chunk::Eof => {
                    reached_eof = true;
                    break;
                }
            }
        }
        Exit {
            reached_eof,
            output: String::from_utf8_lossy(&strip_sgr(&output)).into_owned(),
        }
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
    pub fn window_has(&self, text: &str) -> bool {
        contains(&self.window, text.as_bytes())
            || contains(&strip_sgr(&self.window), text.as_bytes())
    }

    /// Like [`Host::expect`], but for callers that (like the zsh driver's
    /// occasional `'*a*b*c*'` pattern) only need `needles` to appear in order,
    /// not contiguously: a zle redraw between two keystrokes' echoes can
    /// interleave escape sequences the caller does not care about.
    pub fn expect_in_order(&mut self, needles: &[&str], timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            if in_order(&self.window, needles) || in_order(&strip_sgr(&self.window), needles) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            let chunk = self.pty.read_available(POLL);
            self.window.extend_from_slice(&chunk);
        }
    }

    pub fn window_tail(&self) -> String {
        let start = self.window.len().saturating_sub(300);
        String::from_utf8_lossy(&self.window[start..]).into_owned()
    }

    pub fn sync_prompt(&mut self, timeout: Duration) -> bool {
        let ok = self.expect("HP>", timeout);
        self.drain(Duration::from_millis(100));
        ok
    }

    /// Send `keys::SEND_BREAK` and wait for the prompt it produces, re-sending
    /// about once a second until `deadline` elapses. zsh 5.9 defers a SIGINT
    /// that arrives while the host is inside a `zle -F` callback until the
    /// next input byte, then swallows that byte -- so a press landing in that
    /// window can vanish without ever reaching the line editor, and no single
    /// deadline is long enough to wait it out (#116). This mirrors the
    /// dump-widget re-press already used by [`Host::dump_get`] (#47).
    ///
    /// At a call site whose send-break targets an already-idle prompt
    /// (sb-1a, h26a) a re-press is unconditionally harmless: landing twice on
    /// a clean prompt is indistinguishable from landing once. At a call site
    /// whose following assertion depends on a premise that decays on its own
    /// -- an in-flight collection that finishes unprompted after ~0.5s
    /// (h26d), or a debounce timer that fires unprompted at `delay-ms`
    /// (h26c) -- a swallowed first press followed by a retry landing after
    /// that premise has already decayed makes the cleanup assertion pass
    /// vacuously instead of exercising send-break's own cleanup path. That is
    /// the same trade `dump_get` already makes for its own re-press (#47): a
    /// rare flake traded for a rarer vacuous pass, accepted because the
    /// alternative -- a single, unrepeated press -- is the flake this method
    /// exists to fix.
    ///
    /// Returns whether a prompt appeared within `deadline`.
    pub fn send_break_and_sync(&mut self, deadline: Duration) -> bool {
        let end = Instant::now() + deadline;
        loop {
            self.send_keys(keys::SEND_BREAK);
            if self.sync_prompt(Duration::from_secs(1)) {
                return true;
            }
            if Instant::now() >= end {
                return false;
            }
        }
    }

    /// Resize the host terminal. The host learns the new geometry through the
    /// SIGWINCH the kernel raises, and picks it up on its next render, which
    /// reads `COLUMNS` per request (docs/internal/contracts/cli-protocol.md
    /// 「起動」); provoke that render with a following keystroke.
    pub fn resize(&mut self, cols: u16, rows: u16) {
        self.pty.resize(cols, rows).expect("resize the host pty");
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

    /// The freshest log line containing `needle` (`grep -F | tail -1` semantics).
    pub fn last_log_line(&self, needle: &str) -> Option<String> {
        let bytes = fs::read(&self.log).ok()?;
        bytes
            .split(|&b| b == b'\n')
            .rfind(|line| contains(line, needle.as_bytes()))
            .map(|line| String::from_utf8_lossy(line).into_owned())
    }

    /// Complete lines currently in the log (`wc -l` semantics), for callers
    /// that need to count occurrences only in what a later step appends.
    pub fn log_lines(&self) -> usize {
        fs::read(&self.log)
            .map(|bytes| bytes.iter().filter(|&&b| b == b'\n').count())
            .unwrap_or(0)
    }

    /// Occurrences of `needle` among the log lines after the first `skip`.
    pub fn log_count_after(&self, skip: usize, needle: &str) -> usize {
        let Ok(bytes) = fs::read(&self.log) else {
            return 0;
        };
        bytes
            .split(|&b| b == b'\n')
            .skip(skip)
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
                let last = self.last_log_line(&needle).expect("matching log line");
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

    /// The `^Xb` BUFFER dump, unquoted.
    pub fn buffer(&mut self, label: &str) -> String {
        let dump = self
            .dump_get(keys::DUMP_BUFFER, "TESTBUF")
            .unwrap_or_else(|| panic!("{label}: BUFFER dump did not run"));
        unquote(&dump)
    }

    pub fn assert_buffer(&mut self, expected: &str, label: &str) {
        let buffer = self.buffer(label);
        assert_eq!(buffer, expected, "{label}");
    }

    /// The `^Xz` CURSOR dump, as an offset into BUFFER.
    pub fn cursor(&mut self, label: &str) -> usize {
        let dump = self
            .dump_get(keys::DUMP_CURSOR, "TESTCUR")
            .unwrap_or_else(|| panic!("{label}: CURSOR dump did not run"));
        dump.parse()
            .unwrap_or_else(|e| panic!("{label}: CURSOR dump {dump:?} is not a position ({e})"))
    }

    /// The `^Xk` listing dump: `kind=<...> sel=<n> listing=<0|1> npos=<n>`.
    pub fn listing_kind(&mut self, label: &str) -> String {
        self.dump_get(keys::DUMP_KIND, "TESTKIND")
            .unwrap_or_else(|| panic!("{label} listing-kind dump did not run"))
    }

    /// The `^Xt` collection dump: `timer=<fd> rfd=<fd> wfd=<fd> pty=<name>`.
    pub fn collection_fds(&mut self, label: &str) -> String {
        self.dump_get(keys::DUMP_FDS, "TESTFDS")
            .unwrap_or_else(|| panic!("{label} collection-fd dump did not run"))
    }

    /// The `^Xp` POSTDISPLAY dump, unquoted.
    pub fn postdisplay(&mut self, label: &str) -> String {
        let raw = self
            .dump_get(keys::DUMP_POSTDISPLAY, "TESTPOST")
            .unwrap_or_else(|| panic!("{label} POSTDISPLAY dump did not run"));
        unquote(&raw)
    }

    /// zsh tags its own region_highlight entries with `memo=` only from 5.9 on.
    pub fn has_memo(&self) -> bool {
        zsh_version() >= (5, 9)
    }

    /// The `^Xh` dump: zrush's own `region_highlight` entries, one per element.
    pub fn zrush_highlights(&mut self, label: &str) -> Vec<String> {
        self.highlight_entries(keys::DUMP_RH, "TESTRH", label)
    }

    /// The `^Xa` dump: every entry currently in `region_highlight`, zrush's own
    /// and any third party's.
    pub fn all_highlights(&mut self, label: &str) -> Vec<String> {
        self.highlight_entries(keys::DUMP_ALL_RH, "TESTALLRH", label)
    }

    fn highlight_entries(&mut self, key: &str, tag: &str, label: &str) -> Vec<String> {
        let dump = self
            .dump_get(key, tag)
            .unwrap_or_else(|| panic!("{label}: {tag} dump did not run"));
        dump.split(" | ")
            .filter(|entry| !entry.is_empty())
            .map(str::to_string)
            .collect()
    }

    /// The `^Xw` persistent-worker dump.
    pub fn worker_state(&mut self) -> String {
        self.dump_get(keys::DUMP_WORKER, "TESTWORKER")
            .expect("worker-state dump did not run")
    }

    /// The `^Xc` empty-word-cache dump.
    pub fn cache_state(&mut self) -> String {
        self.dump_get(keys::DUMP_CACHE, "TESTCACHE")
            .expect("cache-state dump did not run")
    }

    /// The `^Xi` history-index dump:
    /// `gen=<n> head=<n> count=<n> unacked=<n>`. `gen=0` is the single
    /// "index unusable" state -- an invalid latch and a dirty index are one
    /// thing -- so there is no separate dirty field to read
    /// (docs/internal/specs/behavior.md 「履歴メニュー」).
    pub fn history_state(&mut self) -> String {
        self.dump_get(keys::DUMP_HIST, "TESTHIST")
            .expect("history-index dump did not run")
    }

    /// Poll `^Xw` until the dump carries every one of `fields`, returning it;
    /// on timeout, the last dump seen.
    ///
    /// Worker-stop cleanup is asynchronous, and a session failure is logged
    /// before the lifecycle budget has necessarily reached response EOF -- so a
    /// following request must not treat that log line alone as evidence that
    /// replacement is allowed. This wait is that evidence.
    pub fn wait_worker_state(
        &mut self,
        timeout: Duration,
        fields: &[&str],
    ) -> Result<String, String> {
        let deadline = Instant::now() + timeout;
        let mut last = String::new();
        while Instant::now() < deadline {
            last = self.worker_state();
            if state_has(&last, fields) {
                return Ok(last);
            }
            self.drain(Duration::from_millis(100));
        }
        Err(last)
    }

    /// Record the fd 0/1/2 targets of a pristine shell, before anything has
    /// started a worker. Every later [`Host::assert_host_stdio`] compares
    /// against this, so call it right after boot on any host that uses them:
    /// a baseline seeded by the first assertion would have that assertion
    /// comparing a signature against itself.
    pub fn seed_stdio_baseline(&mut self) {
        let signature = self.probe_stdio("stdio baseline");
        self.stdio_baseline = Some(signature);
    }

    /// Compare the host's fd 0/1/2 targets against its pristine-shell baseline
    /// and confirm both output streams still reach its pty.
    pub fn assert_host_stdio(&mut self, label: &str) {
        let signature = self.probe_stdio(label);
        let expected = self
            .stdio_baseline
            .as_ref()
            .expect("seed_stdio_baseline() must run on the pristine host first");
        assert_eq!(&signature, expected, "{label}: fd targets changed");
        assert!(
            self.window_has("ZRUSH-STDOUT-SENTINEL") && self.window_has("ZRUSH-STDERR-SENTINEL"),
            "{label}: a stream sentinel never reached the pty: {}",
            self.window_tail()
        );
    }

    /// Run `^Xf` once and return the fd signature it reported. The observation
    /// window is left holding everything the probe emitted, sentinels included.
    fn probe_stdio(&mut self, label: &str) -> String {
        let baseline = self.log_count("TESTSTDIO=");
        self.send_keys(keys::STDIO_PROBE);
        assert!(
            self.wait_log("TESTSTDIO=", baseline, Duration::from_secs(5)),
            "{label}: stdio probe did not run"
        );
        self.drain(Duration::from_millis(200));
        let latest = self
            .last_log_line("TESTSTDIO=")
            .expect("stdio probe log line vanished after wait_log succeeded");
        latest
            .split_once("fds=")
            .unwrap_or_else(|| panic!("{label}: no fds= field in {latest:?}"))
            .1
            .to_string()
    }

    // ---- failure-injection launcher (tests/driver/fake.rs) ----

    pub fn fake(&self) -> &Fake {
        self.fake
            .as_ref()
            .expect("this host was not booted with Host::boot_fake()")
    }

    /// Wait for a fake state line containing `needle` to appear beyond
    /// `baseline`, draining the pty as every wait loop must.
    pub fn wait_fake(&mut self, needle: &str, baseline: usize, timeout: Duration) -> bool {
        self.wait_fake_with(baseline, timeout, |fake| fake.count(needle))
    }

    /// [`Host::wait_fake`] against a whole state line rather than a substring.
    pub fn wait_fake_line(&mut self, line: &str, baseline: usize, timeout: Duration) -> bool {
        self.wait_fake_with(baseline, timeout, |fake| fake.count_line(line))
    }

    fn wait_fake_with(
        &mut self,
        baseline: usize,
        timeout: Duration,
        count: impl Fn(&Fake) -> usize,
    ) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            self.drain(Duration::from_millis(100));
            if count(self.fake()) > baseline {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
        }
    }

    // ---- per-test config (tab: `[insert].tab` needs a non-default value) ----

    /// Config lives solely at `$XDG_CONFIG_HOME/zrush/config.toml`
    /// (docs/internal/specs/config-schema.md); write it directly rather than
    /// exercising `zrush config`'s own CLI, since that path is `tests/cli.rs`'s.
    pub fn write_config(&self, toml: &str) {
        fs::write(self.config_path(), toml).expect("write config.toml");
    }

    /// Drop back to defaults for the rest of a scenario whose later steps must
    /// not keep re-reporting the fixture config's warnings.
    pub fn remove_config(&self) {
        fs::remove_file(self.config_path()).expect("remove config.toml");
    }

    fn config_path(&self) -> PathBuf {
        self.xdg.join("zrush/config.toml")
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

/// What a host emitted between the input that ended it and its pty hanging up.
/// `output` has SGR sequences normalized away, since job-control notices are
/// asserted against as plain text.
pub struct Exit {
    pub reached_eof: bool,
    pub output: String,
}

// ---- `name=value` dump helpers ----

/// Whether `dump` carries every one of `fields` as a whole whitespace-delimited
/// token, so `reason=` does not match `reason=session-failure`.
pub fn state_has(dump: &str, fields: &[&str]) -> bool {
    fields
        .iter()
        .all(|field| dump.split_whitespace().any(|token| token == *field))
}

/// The value of a `name=value` token of a dump line.
pub fn dump_field<'a>(dump: &'a str, name: &str) -> &'a str {
    dump.split_whitespace()
        .filter_map(|token| token.split_once('='))
        .find(|(key, _)| *key == name)
        .map(|(_, value)| value)
        .unwrap_or_else(|| panic!("no {name}= field in {dump:?}"))
}

// ---- byte helpers ----

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack.len() >= needle.len()
        && haystack.windows(needle.len()).any(|w| w == needle)
}

/// Whether every one of `needles` occurs in `haystack`, each strictly after
/// the previous match ends.
fn in_order(haystack: &[u8], needles: &[&str]) -> bool {
    let mut pos = 0;
    for needle in needles {
        let bytes = needle.as_bytes();
        if bytes.is_empty() {
            return false;
        }
        match haystack
            .get(pos..)
            .and_then(|rest| rest.windows(bytes.len()).position(|w| w == bytes))
        {
            Some(offset) => pos += offset + bytes.len(),
            None => return false,
        }
    }
    true
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
pub(crate) fn unquote(text: &str) -> String {
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
