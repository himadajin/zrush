use std::ffi::OsString;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const BUILD_STAMP: &[u8] = env!("ZRUSH_BUILD_STAMP").as_bytes();

use zrush::wire;

const VECTOR_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/vectors");

/// The `input_generation` a `store` vector's session notifies and binds to.
const BINDING: &[u8] = b"1";

/// Render a byte string in the corpus text format (tests/vectors/README.md).
/// A line break is layout, never data, so the writer is free to start a new
/// line after every `\0` and `\2`.
fn encode_text(bytes: &[u8]) -> String {
    let mut out = String::new();
    for &byte in bytes {
        match byte {
            0 => out.push_str("\\0\n"),
            1 => out.push_str("\\1"),
            2 => out.push_str("\\2\n"),
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            b'\t' => out.push_str("\\t"),
            b'\\' => out.push_str("\\\\"),
            0x20..=0x7e => out.push(byte as char),
            _ => out.push_str(&format!("\\x{byte:02x}")),
        }
    }
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn decode_text(text: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let mut rest = text.as_bytes();
    while let Some((&byte, tail)) = rest.split_first() {
        rest = tail;
        let offset = text.len() - rest.len();
        match byte {
            b'\n' => {}
            b'\\' => {
                let (&escape, tail) = rest
                    .split_first()
                    .ok_or_else(|| "trailing backslash".to_string())?;
                rest = tail;
                out.push(match escape {
                    b'0' => 0,
                    b'1' => 1,
                    b'2' => 2,
                    b'n' => b'\n',
                    b'r' => b'\r',
                    b't' => b'\t',
                    b'\\' => b'\\',
                    b'x' => {
                        let digits = rest
                            .get(..2)
                            .ok_or_else(|| format!("truncated \\x escape at offset {offset}"))?;
                        rest = &rest[2..];
                        let digits = std::str::from_utf8(digits)
                            .map_err(|_| format!("bad \\x escape at offset {offset}"))?;
                        u8::from_str_radix(digits, 16)
                            .map_err(|_| format!("bad \\x escape \\x{digits} at offset {offset}"))?
                    }
                    _ => {
                        return Err(format!(
                            "unknown escape \\{} at offset {offset}",
                            escape.escape_ascii()
                        ));
                    }
                });
            }
            0x20..=0x7e => out.push(byte),
            _ => {
                return Err(format!(
                    "raw byte 0x{byte:02x} outside the escape alphabet at offset {offset}"
                ));
            }
        }
    }
    Ok(out)
}

/// Single-line rendering for failure messages. Layout newlines are the only
/// literal newlines `encode_text` emits, so dropping them collapses the
/// escaped form onto one line without touching the escapes themselves.
fn dump(bytes: &[u8]) -> String {
    encode_text(bytes).replace('\n', "")
}

fn read_vector_file(path: &Path) -> Vec<u8> {
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("{}: read: {error}", path.display()));
    decode_text(&text).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}

fn vector_args(path: &Path) -> Vec<OsString> {
    let bytes = read_vector_file(&path.join("args"));
    if bytes.is_empty() {
        return Vec::new();
    }
    assert_eq!(
        bytes.last(),
        Some(&0),
        "{}: args is not NUL-terminated",
        path.display()
    );
    bytes[..bytes.len() - 1]
        .split(|&byte| byte == 0)
        .map(|value| std::os::unix::ffi::OsStringExt::from_vec(value.to_vec()))
        .collect()
}

/// A flag's value in a vector's `args`, or the empty string when absent.
fn flag_value(args: &[OsString], flag: &str) -> OsString {
    args.windows(2)
        .find(|pair| pair[0] == flag)
        .map(|pair| pair[1].clone())
        .unwrap_or_default()
}

/// The write request a vector's payload is carried by (`--source`), defaulting
/// to `store` so a vector that says nothing exercises the completion path.
fn vector_source(path: &Path) -> OsString {
    let source = flag_value(&vector_args(path), "--source");
    if source.is_empty() {
        OsString::from("store")
    } else {
        source
    }
}

fn vector_dirs(kind: &str) -> Vec<PathBuf> {
    let root = Path::new(VECTOR_ROOT).join(kind);
    let mut paths: Vec<_> = std::fs::read_dir(root)
        .expect("read vector directory")
        .map(|entry| entry.expect("read vector entry").path())
        .filter(|path| path.is_dir())
        .collect();
    paths.sort();
    // An empty corpus would let every check below pass without running
    // anything -- a silently vacuous suite is worse than a failing one.
    assert!(!paths.is_empty(), "no vectors found under {kind}/");
    paths
}

fn run_vector_raw(path: &Path) -> std::process::Output {
    let args = vector_args(path);
    let value = |flag: &str| flag_value(&args, flag);
    fn ns(payload: &[u8]) -> Vec<u8> {
        let mut o = payload.len().to_string().into_bytes();
        o.push(b':');
        o.extend_from_slice(payload);
        o.push(b',');
        o
    }
    fn msg(fields: &[&[u8]]) -> Vec<u8> {
        let mut p = Vec::new();
        for f in fields {
            p.extend(ns(f));
        }
        ns(&p)
    }
    let payload = read_vector_file(&path.join("payload"));
    let append_path = path.join("append");
    let append = append_path.exists().then(|| read_vector_file(&append_path));
    let cwd = std::env::current_dir().expect("cwd");
    // One session carries the vector as the contract's requests: the payload
    // goes in with the write `--source` names (request_id 1, generation 1), an
    // `append` file follows it as a `history-append` (request_id 2, generation
    // 2), and the trailing `plan` reads back the last generation written.
    // A `store` is bound to the worker's current input, so a `store` vector
    // opens with an `input` notification (input_generation 1) whose quiet period
    // outlives the session: it is still pending when the `store` arrives, and
    // the `store` settles it into one `plan-ready`
    // (cli-protocol.md 「入力通知と worker event」).
    let source = vector_source(path);
    let mut requests = match source.as_bytes() {
        b"store" => [
            msg(&[
                b"input",
                BINDING,
                b"0",
                b"10000",
                cwd.as_os_str().as_bytes(),
                b"",
                b"typo",
                b"true",
                b"1",
                b"1",
                b"false",
            ]),
            msg(&[b"store", b"1", b"live", b"1", BINDING, &payload]),
        ]
        .concat(),
        b"history" => msg(&[b"history-snapshot", b"1", b"1", &payload]),
        b"history-append" => msg(&[b"history-append", b"1", b"1", &payload]),
        _ => panic!("{}: unknown --source {source:?}", path.display()),
    };
    let (generation, plan_id): (&[u8], &[u8]) = match &append {
        Some(append) => {
            requests.extend(msg(&[b"history-append", b"2", b"2", append]));
            (b"2", b"3")
        }
        None => (b"1", b"2"),
    };
    // `history_limit` is mandatory on every `plan`, so a vector that does not
    // exercise the scan window inherits the `[history].limit` default.
    let history_limit = match value("--history-limit") {
        limit if limit.is_empty() => OsString::from("5000"),
        limit => limit,
    };
    requests.extend(msg(&[
        b"plan",
        plan_id,
        generation,
        cwd.as_os_str().as_bytes(),
        value("--producer").as_bytes(),
        value("--query").as_bytes(),
        value("--mode").as_bytes(),
        value("--smart-case").as_bytes(),
        value("--rows").as_bytes(),
        value("--width").as_bytes(),
        value("--trailing-space").as_bytes(),
        history_limit.as_bytes(),
    ]));
    let (control_read, _control_write) = UnixStream::pair().expect("create control channel");
    let control_fd = control_read.as_raw_fd();
    let mut command = Command::new(env!("CARGO_BIN_EXE_zrush"));
    command
        .arg("worker")
        .arg("--control-fd")
        .arg(control_fd.to_string());
    unsafe {
        command.pre_exec(move || {
            if libc::fcntl(control_fd, libc::F_SETFD, 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|error| panic!("{}: spawn zrush: {error}", path.display()));
    drop(control_read);
    let write_result = child
        .stdin
        .take()
        .expect("vector child stdin")
        .write_all(&[msg(&[b"hello", BUILD_STAMP]), requests].concat());
    if let Err(error) = write_result {
        assert_eq!(
            error.kind(),
            std::io::ErrorKind::BrokenPipe,
            "{}: write payload: {error}",
            path.display()
        );
    }
    child
        .wait_with_output()
        .unwrap_or_else(|error| panic!("{}: wait for zrush: {error}", path.display()))
}

fn run_vector(path: &Path) -> std::process::Output {
    let mut output = run_vector_raw(path);
    // Strip the handshake response and unwrap the terminal ok payload.
    let frames = decode_strict(&output.stdout);
    if let Some(frame) = frames.last() {
        let fs = decode_fields_strict(frame);
        if fs.first().map(Vec::as_slice) == Some(b"ok") {
            output.stdout = fs.get(2).cloned().unwrap_or_default();
        }
    }
    output
}

fn decode_strict(mut bytes: &[u8]) -> Vec<Vec<u8>> {
    let mut frames = Vec::new();
    while !bytes.is_empty() {
        let colon = bytes
            .iter()
            .position(|&b| b == b':')
            .expect("missing colon");
        assert!(colon > 0 && (colon == 1 || bytes[0] != b'0'));
        assert!(bytes[..colon].iter().all(u8::is_ascii_digit));
        let len: usize = std::str::from_utf8(&bytes[..colon])
            .unwrap()
            .parse()
            .unwrap();
        let start = colon + 1;
        let end = start.checked_add(len).expect("length overflow");
        assert!(end < bytes.len() && bytes[end] == b',');
        frames.push(bytes[start..end].to_vec());
        bytes = &bytes[end + 1..];
    }
    frames
}

fn decode_fields_strict(frame: &[u8]) -> Vec<Vec<u8>> {
    decode_strict(frame)
}

/// Both sides are corpus text, one plan field per line, so the report names
/// the first differing line and then prints each form whole -- a vector is a
/// few hundred bytes, and the surrounding lines are the context that matters.
fn first_difference(expected: &str, actual: &str) -> String {
    let expected_lines: Vec<_> = expected.lines().collect();
    let actual_lines: Vec<_> = actual.lines().collect();
    let line = expected_lines
        .iter()
        .zip(&actual_lines)
        .position(|(left, right)| left != right)
        .unwrap_or(expected_lines.len().min(actual_lines.len()));
    let at = |lines: &[&str]| lines.get(line).map_or("<end of file>", |v| v).to_string();
    format!(
        "line {} differs (expected {} lines, actual {}); expected: {}; actual: {}\nexpected:\n{expected}actual:\n{actual}",
        line + 1,
        expected_lines.len(),
        actual_lines.len(),
        at(&expected_lines),
        at(&actual_lines),
    )
}

fn vector_name(path: &Path) -> String {
    path.strip_prefix(VECTOR_ROOT)
        .unwrap_or(path)
        .display()
        .to_string()
}

#[test]
fn plan_vectors_match_golden_outputs() {
    let update = std::env::var_os("UPDATE_GOLDEN").as_deref() == Some("1".as_ref());
    let mut failures = Vec::new();
    let mut updated = Vec::new();

    for path in vector_dirs("plan") {
        let name = vector_name(&path);
        let expected_path = path.join("expected");
        let expected = if update {
            None
        } else {
            let text = std::fs::read_to_string(&expected_path)
                .unwrap_or_else(|error| panic!("{name}: read expected: {error}"));
            let bytes = decode_text(&text).unwrap_or_else(|error| panic!("{name}: {error}"));
            if let Err(error) = wire::parse(&bytes) {
                failures.push(format!(
                    "{name}: expected is not a valid plan: {error}; bytes: {}",
                    dump(&bytes)
                ));
                continue;
            }
            Some(text)
        };

        let output = run_vector(&path);
        if output.status.code() != Some(0) {
            failures.push(format!(
                "{name}: expected exit 0, got {:?}; stderr: {}; actual stdout: {}",
                output.status.code(),
                dump(&output.stderr),
                dump(&output.stdout)
            ));
            continue;
        }
        if let Err(error) = wire::parse(&output.stdout) {
            failures.push(format!(
                "{name}: actual stdout is not a valid plan: {error}; bytes: {}",
                dump(&output.stdout)
            ));
            continue;
        }

        // Comparing in text space keeps a wrong encoder from ever producing a
        // false pass: it can only make the two forms differ.
        let actual = encode_text(&output.stdout);
        if update {
            let changed = match std::fs::read_to_string(&expected_path) {
                Ok(current) => current != actual,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                Err(error) => panic!("{name}: read expected before update: {error}"),
            };
            if changed {
                std::fs::write(&expected_path, &actual)
                    .unwrap_or_else(|error| panic!("{name}: update expected: {error}"));
                updated.push(format!("{name}/expected"));
            }
        } else if actual != *expected.as_deref().expect("golden was loaded") {
            failures.push(format!(
                "{name}: golden output mismatch; {}",
                first_difference(expected.as_deref().unwrap(), &actual)
            ));
        }
    }

    if !updated.is_empty() {
        failures.push(format!(
            "updated golden files (review these diffs, then rerun):\n{}",
            updated.join("\n")
        ));
    }

    assert!(
        failures.is_empty(),
        "vector failures:\n{}",
        failures.join("\n")
    );
}

#[test]
fn reject_plan_vectors_are_rejected() {
    let mut failures = Vec::new();

    for path in vector_dirs("reject-plan") {
        let name = vector_name(&path);
        let plan = read_vector_file(&path.join("plan"));
        if let Ok(parsed) = wire::parse(&plan) {
            failures.push(format!(
                "{name}: expected rejection, parsed as {parsed:?}; bytes: {}",
                dump(&plan)
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "vector failures:\n{}",
        failures.join("\n")
    );
}

#[test]
fn reject_vectors_match_expected_in_band_errors() {
    let mut failures = Vec::new();

    for path in vector_dirs("reject") {
        let name = vector_name(&path);
        let output = run_vector_raw(&path);
        let frames = decode_strict(&output.stdout);
        // A vector is rejected by exactly one of the session's two requests.
        // A bad payload fails the write (request_id 1) with `invalid-payload`,
        // and an append against the uninitialized index fails it with
        // `unknown-generation`; either way nothing is left for the `plan`
        // (request_id 2) to reference. Bad scalars write fine and fail the
        // `plan` itself.
        let write_reply: &[u8] = if name.ends_with("nonterminated-stdin") {
            b"invalid-payload"
        } else if vector_source(&path) == *"history-append" {
            b"unknown-generation"
        } else {
            b""
        };
        let plan_reply: &[u8] = if write_reply.is_empty() {
            b"invalid-request"
        } else {
            b"unknown-generation"
        };
        let store_frame = if write_reply.is_empty() {
            vec![b"ok".to_vec(), b"1".to_vec(), Vec::new()]
        } else {
            vec![b"error".to_vec(), b"1".to_vec(), write_reply.to_vec()]
        };
        // Only an accepted `store` settles the notification its session opened
        // with, so only then does a `plan-ready` sit between the two terminal
        // responses (cli-protocol.md 「入力通知と worker event」).
        let settles = write_reply.is_empty() && vector_source(&path) == *"store";
        let event_is_plan_ready = |frame: &[u8]| {
            let event = decode_fields_strict(frame);
            event.len() == 3 && event[0] == b"plan-ready" && event[1] == BINDING
        };
        let valid = output.status.code() == Some(0)
            && frames.len() == 3 + usize::from(settles)
            && decode_fields_strict(&frames[0]) == vec![b"ready".to_vec(), BUILD_STAMP.to_vec()]
            && decode_fields_strict(&frames[1]) == store_frame
            && (!settles || event_is_plan_ready(&frames[2]))
            && decode_fields_strict(frames.last().expect("a nonempty response stream"))
                == vec![b"error".to_vec(), b"2".to_vec(), plan_reply.to_vec()];
        if !valid {
            failures.push(format!(
                "{name}: expected ready + a terminal store reply + a terminal in-band plan error; got exit {:?}, stdout: {}, stderr: {}",
                output.status.code(),
                dump(&output.stdout),
                dump(&output.stderr)
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "vector failures:\n{}",
        failures.join("\n")
    );
}

/// Every corpus file must be spelled the way the writer spells it. Without
/// this a decoder bug could quietly map a vector onto some *other* byte
/// string -- a `reject-plan/` vector mangled into a different malformed plan
/// is still rejected, and the check would pass while fixing nothing.
#[test]
fn vector_files_are_canonical_text() {
    fn walk(dir: &Path, files: &mut Vec<PathBuf>) {
        for entry in std::fs::read_dir(dir).expect("read vector directory") {
            let path = entry.expect("read vector entry").path();
            if path.is_dir() {
                walk(&path, files);
            } else {
                files.push(path);
            }
        }
    }

    let mut files = Vec::new();
    walk(Path::new(VECTOR_ROOT), &mut files);
    files.sort();
    // `env` holds zsh parameter assignments read only by the zsh runner, and
    // README.md documents the corpus; neither is a wire byte string.
    files.retain(|path| {
        !matches!(
            path.file_name().and_then(|name| name.to_str()),
            Some("env" | "README.md")
        )
    });
    assert!(
        !files.is_empty(),
        "no corpus files found under tests/vectors"
    );

    let mut failures = Vec::new();
    for path in files {
        let name = vector_name(&path);
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) => {
                failures.push(format!("{name}: not readable as text: {error}"));
                continue;
            }
        };
        match decode_text(&text) {
            Ok(bytes) => {
                let canonical = encode_text(&bytes);
                if canonical != text {
                    failures.push(format!("{name}: not canonical; rewrite as:\n{canonical}"));
                }
            }
            Err(error) => failures.push(format!("{name}: {error}")),
        }
    }

    assert!(
        failures.is_empty(),
        "corpus files that are not canonical text:\n{}",
        failures.join("\n")
    );
}

proptest::proptest! {
    /// The canonicality check above pins `decode` only where `encode` is
    /// exact, so pin `encode` over the whole input space separately.
    #[test]
    fn corpus_text_round_trips_arbitrary_bytes(bytes: Vec<u8>) {
        proptest::prop_assert_eq!(decode_text(&encode_text(&bytes)).unwrap(), bytes);
    }
}
