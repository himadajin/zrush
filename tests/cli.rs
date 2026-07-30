//! Integration tests for the zrush binary: protocol I/O per
//! docs/internal/contracts/cli-protocol.md.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

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
    query: &'a str,
    mode: &'a str,
    rows: &'a str,
    width: &'a str,
    trailing_space: &'a str,
) -> Vec<&'a str> {
    vec![
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

/// Parsed `zrush plan` stdout: fixed-position fields plus the four
/// repeated blocks. Asserts the `4 + L + H + 3P` field-count invariant
/// (cli-protocol.md "stdout(描画プラン)") while parsing.
struct Plan {
    common_prefix: Vec<u8>,
    rows: Vec<Vec<u8>>,
    highlights: Vec<String>,
    cells: Vec<String>,
    nav: Vec<String>,
    inserts: Vec<Vec<u8>>,
}

fn parse_plan(out: &[u8]) -> Plan {
    assert_eq!(out.last(), Some(&0u8), "output must be NUL-terminated");
    let f: Vec<Vec<u8>> = out[..out.len() - 1]
        .split(|&b| b == 0)
        .map(<[u8]>::to_vec)
        .collect();
    assert!(
        f.len() >= 3,
        "must have at least common-prefix, L, P: {f:?}"
    );
    let l: usize = std::str::from_utf8(&f[1])
        .unwrap()
        .parse()
        .expect("L is a decimal integer");
    let p: usize = std::str::from_utf8(&f[2])
        .unwrap()
        .parse()
        .expect("P is a decimal integer");
    let mut i = 3;
    let rows = f[i..i + l].to_vec();
    i += l;
    let h: usize = std::str::from_utf8(&f[i])
        .unwrap()
        .parse()
        .expect("H is a decimal integer");
    i += 1;
    let highlights: Vec<String> = f[i..i + h]
        .iter()
        .map(|b| String::from_utf8(b.clone()).unwrap())
        .collect();
    i += h;
    let cells: Vec<String> = f[i..i + p]
        .iter()
        .map(|b| String::from_utf8(b.clone()).unwrap())
        .collect();
    i += p;
    let nav: Vec<String> = f[i..i + p]
        .iter()
        .map(|b| String::from_utf8(b.clone()).unwrap())
        .collect();
    i += p;
    let inserts = f[i..i + p].to_vec();
    i += p;
    assert_eq!(i, f.len(), "field count must equal 4 + L + H + 3P");
    Plan {
        common_prefix: f[0].clone(),
        rows,
        highlights,
        cells,
        nav,
        inserts,
    }
}

#[test]
fn plan_rejects_unknown_or_missing_args_with_exit_2() {
    let (code, _) = run_plan(&["--bogus", "x"], b"");
    assert_eq!(code, 2);
    let (code, _) = run_plan(&["--query", "a"], b""); // missing the rest
    assert_eq!(code, 2);
}

#[test]
fn plan_rejects_invalid_enum_and_bool_values_with_exit_2() {
    let (code, _) = run_plan(&plan_args("a", "fuzzy", "10", "40", "true"), b""); // bad --mode
    assert_eq!(code, 2);
    let (code, _) = run_plan(&plan_args("a", "typo", "10", "40", "yes"), b""); // bad --trailing-space
    assert_eq!(code, 2);
}

#[test]
fn plan_rejects_non_numeric_rows_or_width_with_exit_2() {
    let (code, _) = run_plan(&plan_args("a", "typo", "abc", "40", "true"), b"");
    assert_eq!(code, 2);
    let (code, _) = run_plan(&plan_args("a", "typo", "10", "-1", "true"), b"");
    assert_eq!(code, 2);
}

#[test]
fn plan_rejects_non_terminated_stream_with_exit_3() {
    let args = plan_args("a", "typo", "10", "40", "true");
    let mut stdin = header(&[]);
    stdin.extend(word("git"));
    stdin.pop(); // drop the final NUL: framing violation
    let (code, _) = run_plan(&args, &stdin);
    assert_eq!(code, 3);
}

#[test]
fn removed_match_subcommand_now_exits_2() {
    // `zrush match` (v1) no longer exists; it's just an unknown subcommand.
    let out = zrush()
        .args(["match", "--query", "a"])
        .stderr(Stdio::null())
        .output()
        .expect("run");
    assert_eq!(out.status.code(), Some(2));
}

#[test]
fn plan_empty_stdin_is_the_four_field_zero_match_form() {
    let (code, out) = run_plan(&plan_args("abc", "typo", "10", "40", "true"), b"");
    assert_eq!(code, 0);
    assert_eq!(out, b"\x000\x000\x000\x00");
}

#[test]
fn plan_zero_matches_is_the_four_field_form() {
    let mut stdin = header(&[]);
    stdin.extend(word("alpha"));
    stdin.extend(word("beta"));
    let (code, out) = run_plan(&plan_args("zzz", "typo", "10", "40", "true"), &stdin);
    assert_eq!(code, 0);
    assert_eq!(out, b"\x000\x000\x000\x00");
}

#[test]
fn plan_end_to_end_grouped_payload() {
    let mut stdin = header(&[("J", "cmds"), ("X", "Commands")]);
    stdin.extend(word("git"));
    stdin.extend(word("grep"));
    // width=9: gmaxw=max(3,4)=4 -> cols=floor(11/6)=1 (single column),
    // and "Commands" (8 chars) still fits the width budget untruncated.
    let (code, out) = run_plan(&plan_args("g", "prefix", "10", "9", "true"), &stdin);
    assert_eq!(code, 0);
    let p = parse_plan(&out);
    assert_eq!(p.common_prefix, b"g");
    assert_eq!(
        p.rows,
        vec![b"Commands".to_vec(), b"git ".to_vec(), b"grep".to_vec()]
    );
    assert_eq!(p.inserts, vec![b"git ".to_vec(), b"grep ".to_vec()]);
    // Offsets run over the whole listing text ("Commands\ngit \ngrep"):
    // heading spans [0,8); row 2 starts at char 9; row 3 at char 14.
    assert_eq!(p.cells, vec!["9 3", "14 4"]);
    assert!(p.highlights.iter().any(|h| h == "heading 0 0 8"));
    assert!(p.highlights.iter().any(|h| h == "match 1 9 1"));
    assert!(p.highlights.iter().any(|h| h == "match 2 14 1"));
    assert_eq!(p.nav, vec!["2 0 1 2", "2 1 1 2"]);
}

#[test]
fn plan_match_text_uses_m_tag_over_w() {
    let mut stdin = header(&[]);
    stdin.extend(field_record(&[
        ("w", "space\\ name.txt"),
        ("m", "space name.txt"),
    ]));
    let (code, out) = run_plan(&plan_args("space", "prefix", "10", "40", "false"), &stdin);
    assert_eq!(code, 0);
    let p = parse_plan(&out);
    assert_eq!(p.rows, vec![b"space name.txt".to_vec()]);
    // Insertion text still uses the quoted `w`, not `m`.
    assert_eq!(p.inserts, vec![b"space\\ name.txt".to_vec()]);
}

#[test]
fn plan_d_tag_is_displayed_instead_of_match_text() {
    let mut stdin = header(&[]);
    stdin.extend(field_record(&[("w", "raw"), ("d", "Pretty Display")]));
    let (code, out) = run_plan(&plan_args("", "typo", "10", "40", "false"), &stdin);
    assert_eq!(code, 0);
    let p = parse_plan(&out);
    assert_eq!(p.rows, vec![b"Pretty Display".to_vec()]);
    assert_eq!(p.inserts, vec![b"raw".to_vec()]);
}

#[test]
fn plan_cjk_cell_alignment_pads_by_width_offsets_by_chars() {
    let mut stdin = header(&[]);
    stdin.extend(word("日本語")); // 3 chars, display width 6
    stdin.extend(word("ab"));
    // width=8: gmaxw=max(6,2)=6 -> cols=floor(10/8)=1 (single column).
    let (code, out) = run_plan(&plan_args("", "typo", "10", "8", "false"), &stdin);
    assert_eq!(code, 0);
    let p = parse_plan(&out);
    assert_eq!(
        p.rows,
        vec!["日本語".as_bytes().to_vec(), b"ab    ".to_vec()]
    );
    // Cell range length is char count (3, 2), not display width (6, 2).
    assert_eq!(p.cells, vec!["0 3", "4 2"]);
}

#[test]
fn plan_dir_synthesis_uses_real_filesystem_stat() {
    let dir = std::env::temp_dir().join(format!("zrush-cli-it-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("child")).expect("mkdir");
    let rd = format!("{}/", dir.display());
    let mut stdin = header(&[("f", "1"), ("rd", &rd)]);
    stdin.extend(word("child"));
    let (code, out) = run_plan(&plan_args("", "typo", "10", "40", "true"), &stdin);
    assert_eq!(code, 0);
    let p = parse_plan(&out);
    // `/` synthesized (real directory), which also suppresses the
    // trailing space despite --trailing-space true.
    assert_eq!(p.inserts, vec![b"child/".to_vec()]);
    std::fs::remove_dir_all(&dir).expect("cleanup");
}

#[test]
fn plan_trailing_space_toggle() {
    let mut stdin = header(&[]);
    stdin.extend(word("git"));
    let (code, on) = run_plan(&plan_args("", "typo", "10", "40", "true"), &stdin);
    assert_eq!(code, 0);
    let (code, off) = run_plan(&plan_args("", "typo", "10", "40", "false"), &stdin);
    assert_eq!(code, 0);
    assert_eq!(parse_plan(&on).inserts, vec![b"git ".to_vec()]);
    assert_eq!(parse_plan(&off).inserts, vec![b"git".to_vec()]);
}

#[test]
fn plan_ranking_tiers_and_common_prefix() {
    let mut stdin = header(&[]);
    for w in ["mydocs", "docs", "dot-config", "doc", "xxx"] {
        stdin.extend(word(w));
    }
    // width=10 == the widest match: gmaxw=10, cols=floor(12/12)=1,
    // forcing a single column so rows appear in rank order top-to-bottom.
    let (code, out) = run_plan(&plan_args("doc", "typo", "10", "10", "false"), &stdin);
    assert_eq!(code, 0);
    let p = parse_plan(&out);
    // prefix-exact(doc) > prefix(docs) > substring(mydocs) > edit(dot-config); xxx excluded.
    assert_eq!(p.common_prefix, b"doc");
    let pad = |w: &str| format!("{w:<10}").into_bytes();
    assert_eq!(
        p.rows,
        vec![pad("doc"), pad("docs"), pad("mydocs"), pad("dot-config")]
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
    let (code, out) = run_plan(&plan_args("gti", "typo", "10", "8", "false"), &stdin);
    assert_eq!(code, 0);
    let p = parse_plan(&out);
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
    let (code, out) = run_plan(&plan_args("ar", "substring", "10", "40", "false"), &stdin);
    assert_eq!(code, 0);
    let p = parse_plan(&out);
    assert_eq!(p.rows, vec![b"cargo".to_vec()]);
    assert!(p.highlights.iter().any(|h| h == "match 1 1 2"));
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
typeset -g  ZRUSH_PROTOCOL_VERSION='2'
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
        Some("[display]\nmax-lines = 5\n[keybind]\nselect-next = \"ctrl-n\"\n"),
    );
    let (code, out) = run_config(&dir);
    assert_eq!(code, 0);
    assert!(out.contains("ZRUSH_CFG_MAX_LINES='5'"), "{out}");
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
