use std::ffi::OsString;
use std::io::Write;
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

fn run_vector(path: &Path) -> std::process::Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_zrush"))
        .arg("plan")
        .args(vector_args(path))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|error| panic!("{}: spawn zrush: {error}", path.display()));
    let payload = std::fs::read(path.join("payload.bin"))
        .unwrap_or_else(|error| panic!("{}: read payload.bin: {error}", path.display()));
    let write_result = child
        .stdin
        .take()
        .expect("vector child stdin")
        .write_all(&payload);
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
fn reject_vectors_match_expected_exit_codes() {
    let update = std::env::var_os("UPDATE_GOLDEN").as_deref() == Some("1".as_ref());
    let mut failures = Vec::new();
    let mut updated = Vec::new();

    for path in vector_dirs("reject") {
        let name = vector_name(&path);
        let exit_path = path.join("exit");
        let expected = if update {
            None
        } else {
            let expected_text = match std::fs::read_to_string(&exit_path) {
                Ok(text) => text,
                Err(error) => {
                    failures.push(format!("{name}: read exit: {error}"));
                    continue;
                }
            };
            let line = expected_text
                .strip_suffix('\n')
                .unwrap_or(expected_text.as_str());
            if line.is_empty()
                || line.contains('\n')
                || !line.bytes().all(|byte| byte.is_ascii_digit())
            {
                failures.push(format!(
                    "{name}: exit must be one decimal line containing 2 or 3, got {:?}",
                    expected_text
                ));
                continue;
            }
            let expected = match line.parse::<i32>() {
                Ok(value @ (2 | 3)) => value,
                Ok(value) => {
                    failures.push(format!("{name}: reject exit must be 2 or 3, got {value}"));
                    continue;
                }
                Err(error) => {
                    failures.push(format!("{name}: invalid exit file: {error}"));
                    continue;
                }
            };
            Some(expected)
        };
        let output = run_vector(&path);
        let actual = output.status.code();

        if update {
            let Some(actual @ (2 | 3)) = actual else {
                failures.push(format!(
                    "{name}: cannot update reject exit from {actual:?}; stdout: {}; stderr: {}",
                    dump(&output.stdout),
                    dump(&output.stderr)
                ));
                continue;
            };
            let rendered = format!("{actual}\n");
            let changed = match std::fs::read(&exit_path) {
                Ok(current) => current != rendered.as_bytes(),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                Err(error) => panic!("{name}: read exit before update: {error}"),
            };
            if changed {
                std::fs::write(&exit_path, rendered)
                    .unwrap_or_else(|error| panic!("{name}: update exit: {error}"));
                updated.push(format!("{name}/exit"));
            }
        } else if actual != expected {
            failures.push(format!(
                "{name}: expected exit {}, got {actual:?}; stdout: {}; stderr: {}",
                expected.expect("normal mode loaded exit"),
                dump(&output.stdout),
                dump(&output.stderr)
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
