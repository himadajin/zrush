//! Process-boundary tests for the zrush binary per
//! docs/internal/contracts/cli-protocol.md.

use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

const BUILD_STAMP: &[u8] = env!("ZRUSH_BUILD_STAMP").as_bytes();

fn zrush() -> Command {
    Command::new(env!("CARGO_BIN_EXE_zrush"))
}

fn worker_command() -> (Command, UnixStream, UnixStream) {
    let (read, write) = UnixStream::pair().expect("create control channel");
    let control_fd = read.as_raw_fd();
    let mut command = zrush();
    command
        .arg("worker")
        .arg("--control-fd")
        .arg(control_fd.to_string());
    // UnixStream descriptors are CLOEXEC. Only the intended control read end
    // is made inheritable in the forked child, without exposing unrelated
    // parallel-test descriptors across exec.
    unsafe {
        command.pre_exec(move || {
            if libc::fcntl(control_fd, libc::F_SETFD, 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    (command, read, write)
}

// ---- zrush worker ----

fn ns(payload: &[u8]) -> Vec<u8> {
    let mut out = payload.len().to_string().into_bytes();
    out.push(b':');
    out.extend_from_slice(payload);
    out.push(b',');
    out
}
fn msg(fields: &[&[u8]]) -> Vec<u8> {
    ns(&field_stream(fields))
}
fn field_stream(fields: &[&[u8]]) -> Vec<u8> {
    let mut payload = Vec::new();
    for f in fields {
        payload.extend(ns(f));
    }
    payload
}
fn decode_frames(mut bytes: &[u8]) -> Vec<Vec<u8>> {
    let mut frames = Vec::new();
    while !bytes.is_empty() {
        let colon = bytes.iter().position(|&b| b == b':').expect("colon");
        let len: usize = std::str::from_utf8(&bytes[..colon])
            .unwrap()
            .parse()
            .unwrap();
        let start = colon + 1;
        let end = start + len;
        assert_eq!(bytes.get(end), Some(&b','));
        frames.push(bytes[start..end].to_vec());
        bytes = &bytes[end + 1..];
    }
    frames
}
fn fields(frame: &[u8]) -> Vec<Vec<u8>> {
    decode_frames(frame).into_iter().collect()
}

#[test]
fn worker_protocol_mismatch_replies_then_discards_until_stdin_eof() {
    let (mut command, control_read, _control_write) = worker_command();
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    drop(control_read);
    let mut input = msg(&[b"hello", b"deadbeef"]);
    input.extend_from_slice(b"1:x!not-a-frame");
    child.stdin.take().unwrap().write_all(&input).unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    let frames = decode_frames(&out.stdout);
    assert_eq!(frames.len(), 1, "one terminal response, nothing after it");
    assert_eq!(
        fields(&frames[0]),
        vec![b"incompatible".to_vec(), BUILD_STAMP.to_vec()]
    );
}

/// The line's content is outside the contract (cli-protocol.md), so only its
/// existence and single-line shape are pinned here.
#[test]
fn worker_session_fatal_failure_emits_one_diagnostic_line_on_stderr() {
    let (mut command, control_read, _control_write) = worker_command();
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    drop(control_read);
    let mut input = msg(&[b"hello", BUILD_STAMP]);
    input.extend_from_slice(b"1:x!");
    child.stdin.take().unwrap().write_all(&input).unwrap();

    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        out.stderr.last(),
        Some(&b'\n'),
        "diagnostic line is complete"
    );
    let line = &out.stderr[..out.stderr.len() - 1];
    assert!(!line.is_empty(), "diagnostic line is not empty");
    assert!(!line.contains(&b'\n'), "exactly one diagnostic line");
}

// ---- zrush config ----

/// Isolated XDG_CONFIG_HOME, removed on drop so runs don't litter TMPDIR.
struct TempXdg(PathBuf);

impl Drop for TempXdg {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

impl std::ops::Deref for TempXdg {
    type Target = PathBuf;
    fn deref(&self) -> &PathBuf {
        &self.0
    }
}

/// Create an isolated XDG_CONFIG_HOME containing config.toml.
fn xdg_dir(test: &str, config: &str) -> TempXdg {
    let dir = std::env::temp_dir().join(format!("zrush-it-{}-{test}", std::process::id()));
    let sub = dir.join("zrush");
    std::fs::create_dir_all(&sub).expect("mkdir");
    std::fs::write(sub.join("config.toml"), config).expect("write config");
    TempXdg(dir)
}

fn run_config(xdg: &PathBuf) -> (i32, String) {
    let out = zrush()
        .arg("config")
        .env("XDG_CONFIG_HOME", xdg)
        .stderr(Stdio::null())
        .output()
        .expect("run zrush config");
    (
        out.status.code().expect("exit code"),
        String::from_utf8(out.stdout).expect("config output is UTF-8"),
    )
}

#[test]
fn config_applies_file_values() {
    let dir = xdg_dir(
        "values",
        "[display]\nmax-lines = 5\n[history]\nlimit = 1234\n[keybind]\nselect-next = \"ctrl-n\"\n",
    );
    let (code, out) = run_config(&dir);
    assert_eq!(code, 0);
    assert!(out.contains("ZRUSH_CFG_MAX_LINES='5'"), "{out}");
    assert!(out.contains("ZRUSH_CFG_HISTORY_LIMIT='1234'"), "{out}");
    assert!(out.contains("'select-next'  'seq:^N'"), "{out}");
    assert!(out.contains("ZRUSH_CFG_WARNINGS=()"), "{out}");
}

#[test]
fn config_errors_exit_0() {
    for (name, config) in [
        ("invalid-value", "[display]\nmax-lines = 0\n"),
        ("syntax-error", "[display\nmax-lines = 5\n"),
    ] {
        let dir = xdg_dir(name, config);
        let (code, _) = run_config(&dir);
        assert_eq!(code, 0, "{name}");
    }
}

#[test]
fn config_rejects_arguments_with_exit_2() {
    let out = zrush()
        .args(["config", "--extra"])
        .stderr(Stdio::null())
        .output()
        .expect("run");
    assert_eq!(out.status.code(), Some(2));
}

// ---- zrush init ----

/// cli-protocol.md "`zrush init` stdout".
fn sq_bytes(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len() + 2);
    out.push(b'\'');
    for &b in s {
        if b == b'\'' {
            out.extend_from_slice(b"'\\''");
        } else {
            out.push(b);
        }
    }
    out.push(b'\'');
    out
}

#[test]
fn init_zsh_preludes_and_body_match_binary_and_source() {
    let bin = env!("CARGO_BIN_EXE_zrush");
    let out = zrush()
        .args(["init", "zsh"])
        .output()
        .expect("run zrush init zsh");
    assert_eq!(out.status.code(), Some(0));

    let mut expected = b"typeset -g ZRUSH_BIN=${ZRUSH_BIN:-".to_vec();
    expected.extend(sq_bytes(bin.as_bytes()));
    expected.extend_from_slice(b"}\n");
    expected.extend_from_slice(b"typeset -g _ZRUSH_EXPECTED_BUILD_STAMP='");
    expected.extend_from_slice(BUILD_STAMP);
    expected.extend_from_slice(b"'\n");
    let script =
        std::fs::read(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("zsh/zrush.zsh"))
            .expect("read zsh/zrush.zsh");
    expected.extend_from_slice(&script);
    assert_eq!(out.stdout, expected);
}

#[test]
fn init_zsh_output_parses_as_zsh() {
    let out = zrush()
        .args(["init", "zsh"])
        .output()
        .expect("run zrush init zsh");
    assert_eq!(out.status.code(), Some(0));

    let path = std::env::temp_dir().join(format!("zrush-init-it-{}.zsh", std::process::id()));
    std::fs::write(&path, &out.stdout).expect("write init output");
    let check = Command::new("zsh")
        .arg("-fn")
        .arg(&path)
        .output()
        .expect("run zsh -fn (zsh is a test prerequisite)");
    let _ = std::fs::remove_file(&path);
    assert!(
        check.status.success(),
        "zsh -fn rejected init output: {}",
        String::from_utf8_lossy(&check.stderr)
    );
}

#[test]
fn init_missing_or_unknown_shell_or_extra_args_exit_2() {
    let cases: [&[&str]; 3] = [&["init"], &["init", "bash"], &["init", "zsh", "extra"]];
    for args in cases {
        let out = zrush()
            .args(args)
            .stderr(Stdio::null())
            .output()
            .expect("run");
        assert_eq!(out.status.code(), Some(2), "{args:?}");
    }
}

#[test]
fn help_flag_exits_0() {
    // Human-facing affordance (cli-protocol.md "Exit Codes"): zsh never
    // invokes --help, but it must not read as a usage error.
    let out = zrush()
        .arg("--help")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .expect("run");
    assert_eq!(out.status.code(), Some(0));
}

#[test]
fn unknown_subcommand_exits_2() {
    let out = zrush()
        .arg("bogus")
        .stderr(Stdio::null())
        .output()
        .expect("run");
    assert_eq!(out.status.code(), Some(2));
    let out = zrush().stderr(Stdio::null()).output().expect("run");
    assert_eq!(out.status.code(), Some(2));
}
