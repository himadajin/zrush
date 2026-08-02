use std::ffi::OsString;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use zrush::wire;

const VECTOR_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/vectors");

fn vector_args(path: &Path) -> Vec<OsString> {
    let mut bytes = std::fs::read(path.join("args")).expect("read vector args");
    if bytes.is_empty() {
        return Vec::new();
    }
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    bytes
        .split(|&byte| byte == b'\n')
        .map(|line| std::os::unix::ffi::OsStringExt::from_vec(line.to_vec()))
        .collect()
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
    let value = |flag: &str| {
        args.windows(2)
            .find(|w| w[0] == flag)
            .map(|w| w[1].clone())
            .unwrap_or_default()
    };
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
    let payload = std::fs::read(path.join("payload.bin")).expect("payload");
    let cwd = std::env::current_dir().expect("cwd");
    let request = msg(&[
        b"plan",
        b"1",
        cwd.as_os_str().as_bytes(),
        value("--producer").as_bytes(),
        value("--query").as_bytes(),
        value("--mode").as_bytes(),
        value("--smart-case").as_bytes(),
        value("--rows").as_bytes(),
        value("--width").as_bytes(),
        value("--trailing-space").as_bytes(),
        &payload,
    ]);
    let mut child = Command::new(env!("CARGO_BIN_EXE_zrush"))
        .arg("worker")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|error| panic!("{}: spawn zrush: {error}", path.display()));
    let write_result = child
        .stdin
        .take()
        .expect("vector child stdin")
        .write_all(&[msg(&[b"hello", b"6"]), request].concat());
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

fn dump(bytes: &[u8]) -> String {
    let mut out = String::new();
    for &byte in bytes {
        match byte {
            0 => out.push_str("\\0"),
            1 => out.push_str("\\1"),
            2 => out.push_str("\\2"),
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            b'\t' => out.push_str("\\t"),
            b'\\' => out.push_str("\\\\"),
            0x20..=0x7e => out.push(byte as char),
            _ => out.push_str(&format!("\\x{byte:02x}")),
        }
    }
    out
}

fn first_difference(expected: &[u8], actual: &[u8]) -> String {
    let expected_fields: Vec<_> = expected[..expected.len() - 1]
        .split(|&byte| byte == 0)
        .collect();
    let actual_fields: Vec<_> = actual[..actual.len() - 1]
        .split(|&byte| byte == 0)
        .collect();
    if expected_fields.len() != actual_fields.len() {
        return format!(
            "field count differs (expected {}, actual {}); expected: {}; actual: {}",
            expected_fields.len(),
            actual_fields.len(),
            dump(expected),
            dump(actual)
        );
    }

    let field = expected_fields
        .iter()
        .zip(&actual_fields)
        .position(|(left, right)| left != right)
        .expect("different byte strings have a different field");
    let byte = expected_fields[field]
        .iter()
        .zip(actual_fields[field])
        .position(|(left, right)| left != right)
        .unwrap_or(expected_fields[field].len().min(actual_fields[field].len()));
    let start = field.saturating_sub(2);
    let end = (field + 3).min(expected_fields.len());
    let context = |fields: &[&[u8]]| {
        fields[start..end]
            .iter()
            .enumerate()
            .map(|(offset, value)| format!("{}: {}", start + offset + 1, dump(value)))
            .collect::<Vec<_>>()
            .join(" | ")
    };
    format!(
        "first difference at field {} (byte {byte} within field); expected context: {}; actual context: {}",
        field + 1,
        context(&expected_fields),
        context(&actual_fields)
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
        let expected_path = path.join("expected.bin");
        let expected = if update {
            None
        } else {
            let expected = std::fs::read(&expected_path)
                .unwrap_or_else(|error| panic!("{name}: read expected.bin: {error}"));
            if let Err(error) = wire::parse(&expected) {
                failures.push(format!(
                    "{name}: expected.bin is not a valid plan: {error}; bytes: {}",
                    dump(&expected)
                ));
                continue;
            }
            Some(expected)
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

        if update {
            let changed = match std::fs::read(&expected_path) {
                Ok(current) => current != output.stdout,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                Err(error) => panic!("{name}: read expected.bin before update: {error}"),
            };
            if changed {
                std::fs::write(&expected_path, &output.stdout)
                    .unwrap_or_else(|error| panic!("{name}: update expected.bin: {error}"));
                updated.push(format!("{name}/expected.bin"));
            }
        } else if output.stdout != expected.as_deref().expect("golden was loaded") {
            failures.push(format!(
                "{name}: golden output mismatch; {}",
                first_difference(expected.as_deref().unwrap(), &output.stdout)
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
        let plan = match std::fs::read(path.join("plan.bin")) {
            Ok(bytes) => bytes,
            Err(error) => {
                failures.push(format!("{name}: read plan.bin: {error}"));
                continue;
            }
        };
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
        let expected = if name.ends_with("nonterminated-stdin") {
            b"invalid-payload"
        } else {
            b"invalid-request"
        };
        let valid = output.status.code() == Some(0)
            && frames.len() == 2
            && decode_fields_strict(&frames[0]) == vec![b"ready".to_vec(), b"6".to_vec()]
            && decode_fields_strict(&frames[1])
                == vec![b"error".to_vec(), b"1".to_vec(), expected.to_vec()];
        if !valid {
            failures.push(format!(
                "{name}: expected ready + one terminal in-band error; got exit {:?}, stdout: {}, stderr: {}",
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
