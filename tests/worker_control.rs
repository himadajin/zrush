use std::io::{Read, Write};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

const BUILD_STAMP: &[u8] = env!("ZRUSH_BUILD_STAMP").as_bytes();

fn netstring(payload: &[u8]) -> Vec<u8> {
    let mut out = payload.len().to_string().into_bytes();
    out.push(b':');
    out.extend_from_slice(payload);
    out.push(b',');
    out
}

fn message(fields: &[&[u8]]) -> Vec<u8> {
    netstring(
        &fields
            .iter()
            .flat_map(|field| netstring(field))
            .collect::<Vec<_>>(),
    )
}

fn zrush() -> Command {
    Command::new(env!("CARGO_BIN_EXE_zrush"))
}

fn spawn_worker() -> (Child, UnixStream) {
    let (control_read, control_write) = UnixStream::pair().expect("create control channel");
    let control_fd = control_read.as_raw_fd();
    let mut command = zrush();
    command
        .arg("worker")
        .arg("--control-fd")
        .arg(control_fd.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());

    // The socket starts CLOEXEC. Clear that flag only in this forked child so
    // concurrent test subprocesses cannot retain each other's control ends.
    unsafe {
        command.pre_exec(move || {
            if libc::fcntl(control_fd, libc::F_SETFD, 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }

    let child = command.spawn().expect("spawn worker");
    drop(control_read);
    (child, control_write)
}

fn complete_handshake(child: &mut Child) {
    let hello = message(&[b"hello", BUILD_STAMP]);
    child
        .stdin
        .as_mut()
        .expect("request stdin")
        .write_all(&hello)
        .expect("write hello");
    let expected = message(&[b"ready", BUILD_STAMP]);
    let mut ready = vec![0_u8; expected.len()];
    child
        .stdout
        .as_mut()
        .expect("response stdout")
        .read_exact(&mut ready)
        .expect("read ready");
    assert_eq!(ready, expected);
}

fn wait_bounded(child: &mut Child) -> ExitStatus {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = child.try_wait().expect("poll worker") {
            return status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("worker did not exit before timeout");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn abort_byte_exits_while_request_stdin_is_blocked() {
    let (mut child, mut control) = spawn_worker();
    complete_handshake(&mut child);

    control.write_all(&[0]).expect("send abort byte");

    assert_eq!(wait_bounded(&mut child).code(), Some(1));
}

#[test]
fn control_eof_exits_while_request_stdin_is_blocked() {
    let (mut child, control) = spawn_worker();
    complete_handshake(&mut child);

    drop(control);

    assert_eq!(wait_bounded(&mut child).code(), Some(1));
}

#[test]
fn normal_request_stdin_eof_exits_cleanly_without_joining_watchdog() {
    let (mut child, control) = spawn_worker();
    drop(child.stdin.take());

    assert_eq!(wait_bounded(&mut child).code(), Some(0));
    drop(control);
}

#[test]
fn invalid_control_fd_fails_before_request_processing() {
    let output = zrush()
        .args(["worker", "--control-fd", "2147483647"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run worker with invalid control fd");

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty(), "worker never emits ready");
    assert!(output.stderr.ends_with(b"\n"));
}

#[test]
fn write_only_control_fd_fails_before_request_processing() {
    let control = std::fs::OpenOptions::new()
        .write(true)
        .open("/dev/null")
        .expect("open write-only descriptor");
    let control_fd = control.as_raw_fd();
    let mut command = zrush();
    command
        .args(["worker", "--control-fd", &control_fd.to_string()])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    unsafe {
        command.pre_exec(move || {
            if libc::fcntl(control_fd, libc::F_SETFD, 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }

    let output = command.output().expect("run worker with write-only fd");

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty(), "worker never emits ready");
}

#[test]
fn missing_control_fd_is_a_usage_error() {
    let output = zrush()
        .arg("worker")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .expect("run worker without control fd");

    assert_eq!(output.status.code(), Some(2));
}

#[test]
fn standard_or_malformed_control_fd_is_a_usage_error() {
    for value in ["2", "-1", "+3", "not-a-fd"] {
        let output = zrush()
            .args(["worker", "--control-fd", value])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .expect("run worker with invalid control fd argument");

        assert_eq!(output.status.code(), Some(2), "value {value:?}");
    }
}
