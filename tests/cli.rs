//! Integration tests for the zrush binary: protocol I/O per
//! docs/internal/contracts/cli-protocol.md.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use zrush::wire;

fn zrush() -> Command {
    Command::new(env!("CARGO_BIN_EXE_zrush"))
}

// ---- zrush plan ----

/// Run `zrush plan` with the given trailing args and stdin bytes.
fn run_plan(extra: &[&str], stdin: &[u8]) -> (i32, Vec<u8>) {
    let mut child = zrush()
        .arg("plan")
        .args(extra)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn zrush plan");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(stdin)
        .expect("write stdin");
    let out = child.wait_with_output().expect("wait");
    (out.status.code().expect("exit code"), out.stdout)
}

/// The full required flag set (cli-protocol.md "起動"); tests override
/// individual values as needed.
fn plan_args<'a>(
    producer: &'a str,
    query: &'a str,
    mode: &'a str,
    rows: &'a str,
    width: &'a str,
    trailing_space: &'a str,
) -> Vec<&'a str> {
    vec![
        "--producer",
        producer,
        "--query",
        query,
        "--mode",
        mode,
        "--smart-case",
        "true",
        "--rows",
        rows,
        "--width",
        width,
        "--trailing-space",
        trailing_space,
    ]
}

const REC_SEP: u8 = 0;
const FIELD_SEP: u8 = 2;
const TAG_SEP: u8 = 1;

/// A batch header record: tag `b` plus the given shared tag/value pairs
/// (cli-protocol.md "バッチヘッダレコード").
fn header(fields: &[(&str, &str)]) -> Vec<u8> {
    let mut r = b"b".to_vec();
    for (tag, val) in fields {
        r.push(FIELD_SEP);
        r.extend_from_slice(tag.as_bytes());
        r.push(TAG_SEP);
        r.extend_from_slice(val.as_bytes());
    }
    r.push(REC_SEP);
    r
}

/// A candidate record with arbitrary tag/value pairs; the first pair's
/// tag must be `w` to form a valid candidate (cli-protocol.md).
fn field_record(fields: &[(&str, &str)]) -> Vec<u8> {
    let mut r = Vec::new();
    for (i, (tag, val)) in fields.iter().enumerate() {
        if i > 0 {
            r.push(FIELD_SEP);
        }
        r.extend_from_slice(tag.as_bytes());
        r.push(TAG_SEP);
        r.extend_from_slice(val.as_bytes());
    }
    r.push(REC_SEP);
    r
}

/// A plain candidate record: `w` only.
fn word(w: &str) -> Vec<u8> {
    field_record(&[("w", w)])
}

fn parse_wire(out: &[u8]) -> wire::Plan {
    wire::parse(out).expect("valid plan")
}

fn has_highlight(
    plan: &wire::Plan,
    role: wire::Role,
    pos: usize,
    start: usize,
    len: usize,
) -> bool {
    plan.highlights
        .iter()
        .any(|h| (h.role, h.pos, h.start, h.len) == (role, pos, start, len))
}

#[test]
fn plan_rejects_negative_width_with_exit_2() {
    let (code, _) = run_plan(&plan_args("compsys", "a", "typo", "10", "-1", "true"), b"");
    assert_eq!(code, 2);
}

#[test]
fn removed_match_subcommand_now_exits_2() {
    // `zrush match` does not exist; it's just an unknown subcommand.
    let out = zrush()
        .args(["match", "--query", "a"])
        .stderr(Stdio::null())
        .output()
        .expect("run");
    assert_eq!(out.status.code(), Some(2));
}

#[test]
fn plan_dir_synthesis_uses_real_filesystem_stat() {
    let dir = std::env::temp_dir().join(format!("zrush-cli-it-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("child")).expect("mkdir");
    let rd = format!("{}/", dir.display());
    let mut stdin = header(&[("f", "1"), ("rd", &rd)]);
    stdin.extend(word("child"));
    let (code, out) = run_plan(
        &plan_args("compsys", "", "typo", "10", "40", "true"),
        &stdin,
    );
    assert_eq!(code, 0);
    let p = parse_wire(&out);
    // `/` synthesized (real directory), which also suppresses the
    // trailing space despite --trailing-space true.
    assert_eq!(p.inserts, vec![b"child/".to_vec()]);
    std::fs::remove_dir_all(&dir).expect("cleanup");
}

#[test]
fn plan_trailing_space_true_appends_space() {
    let mut stdin = header(&[]);
    stdin.extend(word("git"));
    let (code, on) = run_plan(
        &plan_args("compsys", "", "typo", "10", "40", "true"),
        &stdin,
    );
    assert_eq!(code, 0);
    assert_eq!(parse_wire(&on).inserts, vec![b"git ".to_vec()]);
}

#[test]
fn plan_ranking_tiers_and_common_prefix() {
    let mut stdin = header(&[]);
    for w in ["mydocs", "docs", "dot-config", "doc", "xxx"] {
        stdin.extend(word(w));
    }
    // width=10 == the widest match: gmaxw=10, cols=floor(12/12)=1,
    // forcing a single column so rows appear in rank order top-to-bottom.
    let (code, out) = run_plan(
        &plan_args("compsys", "doc", "typo", "10", "10", "false"),
        &stdin,
    );
    assert_eq!(code, 0);
    let p = parse_wire(&out);
    // prefix-exact(doc) > prefix(docs) > substring(mydocs) > edit(dot-config); xxx excluded.
    assert_eq!(p.common_prefix, b"doc");
    let pad = |w: &str| format!("{w:<10}").into_bytes();
    assert_eq!(
        p.rows,
        vec![pad("doc"), pad("docs"), pad("mydocs"), pad("dot-config")]
    );
}

#[test]
fn plan_history_producer_keeps_stdin_order() {
    // cli-protocol.md "マッチング・ランキングの意味論": --producer history
    // keeps the payload's (newest-first) order whatever the match
    // quality, while --producer compsys ranks the same payload by tier.
    let mut stdin = header(&[]);
    for w in ["echo xfoo", "unrelated", "foo"] {
        stdin.extend(word(w));
    }
    // Even at width=40, history is a single column with position 1 at the
    // bottom. Logical insertion order remains newest-first.
    let (code, out) = run_plan(
        &plan_args("history", "foo", "typo", "10", "40", "false"),
        &stdin,
    );
    assert_eq!(code, 0);
    // "unrelated" matches no tier and is dropped; the rest keep their order.
    let plan = parse_wire(&out);
    assert_eq!(
        plan.rows,
        vec![b"foo      ".to_vec(), b"echo xfoo".to_vec()]
    );
    assert_eq!(plan.inserts, vec![b"echo xfoo".to_vec(), b"foo".to_vec()]);

    let (code, out) = run_plan(
        &plan_args("compsys", "foo", "typo", "10", "9", "false"),
        &stdin,
    );
    assert_eq!(code, 0);
    assert_eq!(
        parse_wire(&out).inserts,
        vec![b"foo".to_vec(), b"echo xfoo".to_vec()]
    );
}

#[test]
fn plan_typo_transposition_gti() {
    let mut stdin = header(&[]);
    for w in ["git", "grep", "git-lfs"] {
        stdin.extend(word(w));
    }
    // width=8: gmaxw=max(3,7)=7 (over the 2 matches) -> cols=floor(10/9)=1,
    // forcing a single column so each match gets its own row.
    let (code, out) = run_plan(
        &plan_args("compsys", "gti", "typo", "10", "8", "false"),
        &stdin,
    );
    assert_eq!(code, 0);
    let p = parse_wire(&out);
    // No prefix-tier match under "gti" -> empty common prefix.
    assert_eq!(p.common_prefix, b"");
    assert_eq!(p.rows.len(), 2); // "git" and "git-lfs" via the edit tier; "grep" excluded
}

#[test]
fn plan_match_highlight_offset_is_non_trivial_for_a_mid_string_match() {
    // Regression: layout.rs once misread matching::spans()'s (start, end)
    // tuples as (start, len). A start==0 span can't distinguish the two
    // readings; "ar" is a substring of "cargo" at char index 1 (a-r), so
    // matching::spans() emits (1, 3) -- start != 0, len != 1 -- giving a
    // highlight of "match 1 1 2" (len 2), not "match 1 1 3" (the old bug's
    // misreading of end=3 as a length, extending the highlight to "arg").
    let mut stdin = header(&[]);
    stdin.extend(word("cargo"));
    let (code, out) = run_plan(
        &plan_args("compsys", "ar", "substring", "10", "40", "false"),
        &stdin,
    );
    assert_eq!(code, 0);
    let p = parse_wire(&out);
    assert_eq!(p.rows, vec![b"cargo".to_vec()]);
    assert!(has_highlight(&p, wire::Role::Match, 1, 1, 2));
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

/// Create an isolated XDG_CONFIG_HOME; write config.toml when given.
fn xdg_dir(test: &str, config: Option<&str>) -> TempXdg {
    let dir = std::env::temp_dir().join(format!("zrush-it-{}-{test}", std::process::id()));
    let sub = dir.join("zrush");
    std::fs::create_dir_all(&sub).expect("mkdir");
    match config {
        Some(c) => std::fs::write(sub.join("config.toml"), c).expect("write config"),
        None => {
            let _ = std::fs::remove_file(sub.join("config.toml"));
        }
    }
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
fn config_without_file_prints_contract_default_output() {
    let dir = xdg_dir("defaults", None);
    let (code, out) = run_config(&dir);
    assert_eq!(code, 0);
    let expected = "\
typeset -g  ZRUSH_PROTOCOL_VERSION='4'
typeset -g  ZRUSH_CFG_MAX_LINES='10'
typeset -g  ZRUSH_CFG_DELAY_MS='30'
typeset -g  ZRUSH_CFG_MIN_INPUT='0'
typeset -g  ZRUSH_CFG_MODE='typo'
typeset -g  ZRUSH_CFG_SMART_CASE='true'
typeset -g  ZRUSH_CFG_TAB='menu'
typeset -g  ZRUSH_CFG_TRAILING_SPACE='true'
typeset -g  ZRUSH_CFG_HL_SELECTED='standout'
typeset -g  ZRUSH_CFG_HL_MATCH='underline'
typeset -g  ZRUSH_CFG_HL_HEADING='bold'
typeset -g  ZRUSH_CFG_HISTORY_LIMIT='5000'
typeset -ga ZRUSH_CFG_KEYBINDS=(
  'select-next'  'key:down'
  'select-next'  'seq:^N'
  'select-prev'  'key:up'
  'select-prev'  'seq:^P'
  'select-left'  'key:left'
  'select-left'  'seq:^B'
  'select-right' 'key:right'
  'select-right' 'seq:^F'
  'confirm'      'seq:^M'
  'dismiss'      'seq:^G'
)
typeset -ga ZRUSH_CFG_WARNINGS=()
";
    assert_eq!(out, expected);
}

#[test]
fn config_applies_file_values() {
    let dir = xdg_dir(
        "values",
        Some(
            "[display]\nmax-lines = 5\n[history]\nlimit = 1234\n[keybind]\nselect-next = \"ctrl-n\"\n",
        ),
    );
    let (code, out) = run_config(&dir);
    assert_eq!(code, 0);
    assert!(out.contains("ZRUSH_CFG_MAX_LINES='5'"), "{out}");
    assert!(out.contains("ZRUSH_CFG_HISTORY_LIMIT='1234'"), "{out}");
    assert!(out.contains("'select-next'  'seq:^N'"), "{out}");
    assert!(out.contains("ZRUSH_CFG_WARNINGS=()"), "{out}");
}

#[test]
fn config_invalid_values_fall_back_with_escaped_warnings() {
    let dir = xdg_dir(
        "invalid",
        Some("[matching]\nmode = \"ty'po\"\n[display]\nmax-lines = 0\n"),
    );
    let (code, out) = run_config(&dir);
    assert_eq!(code, 0, "config problems never fail the command");
    assert!(out.contains("ZRUSH_CFG_MODE='typo'"), "{out}");
    assert!(out.contains("ZRUSH_CFG_MAX_LINES='10'"), "{out}");
    // single-quote discipline: embedded ' arrives as '\''
    assert!(out.contains("ty'\\''po"), "{out}");
    assert!(out.contains("ZRUSH_CFG_WARNINGS=(\n"), "{out}");
}

#[test]
fn config_syntax_error_uses_all_defaults() {
    let dir = xdg_dir("syntax", Some("[display\nmax-lines = 5\n"));
    let (code, out) = run_config(&dir);
    assert_eq!(code, 0);
    assert!(out.contains("ZRUSH_CFG_MAX_LINES='10'"), "{out}");
    assert!(out.contains("TOML syntax error"), "{out}");
}

#[test]
fn config_keybind_duplicate_after_normalization() {
    // dismiss = ctrl-m collides with confirm's default (enter = seq:^M).
    let dir = xdg_dir("dup", Some("[keybind]\ndismiss = \"ctrl-m\"\n"));
    let (code, out) = run_config(&dir);
    assert_eq!(code, 0);
    assert!(out.contains("'confirm'      'seq:^M'"), "{out}");
    assert!(out.contains("'dismiss'      'seq:^G'"), "{out}");
    assert!(out.contains("same key after normalization"), "{out}");
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

#[test]
fn help_flag_exits_0() {
    // Human-facing affordance (cli-protocol.md "終了コード"): zsh never
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
