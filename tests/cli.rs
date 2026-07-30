//! Integration tests for the zrush binary: protocol I/O per
//! docs/internal/contracts/cli-protocol.md.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn zrush() -> Command {
    Command::new(env!("CARGO_BIN_EXE_zrush"))
}

/// Run `zrush match` with the given trailing args and stdin bytes.
fn run_match(extra: &[&str], stdin: &[u8]) -> (i32, Vec<u8>) {
    let mut child = zrush()
        .arg("match")
        .args(extra)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn zrush match");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(stdin)
        .expect("write stdin");
    let out = child.wait_with_output().expect("wait");
    (out.status.code().expect("exit code"), out.stdout)
}

fn typo_args<'a>(query: &'a str, max_lines: &'a str) -> Vec<&'a str> {
    vec![
        "--query",
        query,
        "--mode",
        "typo",
        "--smart-case",
        "true",
        "--max-lines",
        max_lines,
    ]
}

/// Build a candidate stream: 1-based indices, empty display-text.
fn candidates(texts: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::new();
    for (i, t) in texts.iter().enumerate() {
        out.extend_from_slice((i + 1).to_string().as_bytes());
        out.push(0);
        out.extend_from_slice(t);
        out.push(0);
        out.push(0); // empty display-text
    }
    out
}

fn fields(out: &[u8]) -> Vec<Vec<u8>> {
    assert_eq!(out.last(), Some(&0u8), "output must be NUL-terminated");
    out[..out.len() - 1]
        .split(|&b| b == 0)
        .map(<[u8]>::to_vec)
        .collect()
}

/// Ranked (index, match-spans) pairs from match output.
type RankedPairs = Vec<(Vec<u8>, Vec<u8>)>;

/// Parse match output into (common-prefix, [(index, match-spans)]).
fn parse_out(out: &[u8]) -> (Vec<u8>, RankedPairs) {
    let f = fields(out);
    assert!(
        f.len() % 2 == 1,
        "output must be 1 + 2n fields, got {}",
        f.len()
    );
    let pairs = f[1..]
        .chunks_exact(2)
        .map(|c| (c[0].clone(), c[1].clone()))
        .collect();
    (f[0].clone(), pairs)
}

/// Rank-ordered indices only (span fields dropped).
fn ranked(out: &[u8]) -> Vec<Vec<u8>> {
    parse_out(out).1.into_iter().map(|p| p.0).collect()
}

// ---- zrush match ----

#[test]
fn match_ranks_tiers_and_reports_common_prefix() {
    let stdin = candidates(&[b"mydocs", b"docs", b"dot-config", b"doc", b"xxx"]);
    let (code, out) = run_match(&typo_args("doc", "10"), &stdin);
    assert_eq!(code, 0);
    // prefix-exact(4) > prefix(2) > substring(1) > edit(3: doc~dot); "xxx" excluded.
    // LCP spans prefix-tier matches only: {docs, doc} -> "doc".
    let (lcp, pairs) = parse_out(&out);
    assert_eq!(lcp, b"doc");
    let idx: Vec<&[u8]> = pairs.iter().map(|p| p.0.as_slice()).collect();
    assert_eq!(idx, [&b"4"[..], b"2", b"1", b"3"]);
    // spans: 4=doc (prefix, whole), 2=docs (prefix), 1=mydocs (substring
    // at 2..5), 3=dot-config (edit: aligned prefix 0..3)
    let spans: Vec<&[u8]> = pairs.iter().map(|p| p.1.as_slice()).collect();
    assert_eq!(spans, [&b"0-3"[..], b"0-3", b"2-5", b"0-3"]);
}

#[test]
fn match_typo_transposition_gti() {
    let stdin = candidates(&[b"git", b"grep", b"git-lfs"]);
    let (code, out) = run_match(&typo_args("gti", "10"), &stdin);
    assert_eq!(code, 0);
    // git and git-lfs match via the edit tier, grep does not.
    // No prefix-tier match -> empty common prefix.
    let (lcp, pairs) = parse_out(&out);
    assert_eq!(lcp, b"");
    let idx: Vec<&[u8]> = pairs.iter().map(|p| p.0.as_slice()).collect();
    assert_eq!(idx, [&b"1"[..], b"3"]);
    // edit-tier spans cover the aligned (corrected-query) prefix
    let spans: Vec<&[u8]> = pairs.iter().map(|p| p.1.as_slice()).collect();
    assert_eq!(spans, [&b"0-3"[..], b"0-3"]);
}

#[test]
fn match_fuzzy_spans_are_merged_ranges() {
    // "dcf" on "dot-config" is a scattered subsequence (fuzzy tier):
    // d(0), c(4), f(7) -> three single-char ranges.
    let stdin = candidates(&[b"dot-config"]);
    let (code, out) = run_match(&typo_args("dcf", "10"), &stdin);
    assert_eq!(code, 0);
    let (_, pairs) = parse_out(&out);
    assert_eq!(pairs.len(), 1);
    assert_eq!(pairs[0].1, b"0-1,4-5,7-8");
}

#[test]
fn match_edit_tier_ranks_close_corrections_first() {
    // All four are edit-tier matches for "gti"; git (transposition,
    // no unmatched suffix) must beat looser corrections regardless of
    // stdin order.
    let stdin = candidates(&[b"gtsort", b"gif2webp", b"git", b"glibtool"]);
    let (code, out) = run_match(&typo_args("gti", "10"), &stdin);
    assert_eq!(code, 0);
    let (lcp, _) = parse_out(&out);
    assert_eq!(lcp, b"", "edit-tier matches carry no common prefix");
    assert_eq!(ranked(&out), [&b"3"[..], b"1", b"4", b"2"]);
}

#[test]
fn match_common_prefix_spans_prefix_tier_only() {
    // Prefix tier {checkout, check-attr} -> LCP "check"; the substring
    // match sparse-checkout must not dilute it.
    let stdin = candidates(&[b"checkout", b"check-attr", b"sparse-checkout"]);
    let (code, out) = run_match(&typo_args("chec", "10"), &stdin);
    assert_eq!(code, 0);
    let (lcp, pairs) = parse_out(&out);
    assert_eq!(lcp, b"check");
    assert_eq!(pairs.len(), 3, "all three still match and rank");
}

#[test]
fn match_empty_query_keeps_stdin_order_with_empty_spans() {
    let stdin = candidates(&[b"bbb", b"aaa", b"ccc"]);
    let (code, out) = run_match(&typo_args("", "10"), &stdin);
    assert_eq!(code, 0);
    let (lcp, pairs) = parse_out(&out);
    assert_eq!(lcp, b"");
    for (i, (idx, spans)) in pairs.iter().enumerate() {
        assert_eq!(idx, (i + 1).to_string().as_bytes());
        assert_eq!(spans, b"", "empty query carries no position info");
    }
}

#[test]
fn match_zero_matches_emits_empty_common_prefix_only() {
    let stdin = candidates(&[b"alpha", b"beta"]);
    let (code, out) = run_match(&typo_args("qqqq", "10"), &stdin);
    assert_eq!(code, 0);
    assert_eq!(out, b"\0");
}

#[test]
fn match_empty_stdin_is_valid() {
    let (code, out) = run_match(&typo_args("abc", "10"), b"");
    assert_eq!(code, 0);
    assert_eq!(out, b"\0");
}

#[test]
fn match_truncates_to_max_lines_but_lcp_spans_all_matches() {
    let stdin = candidates(&[b"git-a", b"git-b", b"git-c"]);
    let (code, out) = run_match(&typo_args("git", "2"), &stdin);
    assert_eq!(code, 0);
    // Only 2 indices, but the LCP covers all three matches.
    let (lcp, _) = parse_out(&out);
    assert_eq!(lcp, b"git-");
    assert_eq!(ranked(&out), [&b"1"[..], b"2"]);
}

#[test]
fn match_non_utf8_candidate_is_not_dropped() {
    let stdin = candidates(&[b"caf\xe9.txt", b"other"]);
    let (code, out) = run_match(
        &[
            "--query",
            "caf",
            "--mode",
            "prefix",
            "--smart-case",
            "true",
            "--max-lines",
            "10",
        ],
        &stdin,
    );
    assert_eq!(code, 0);
    // Single match: LCP is its full match-text, raw bytes preserved.
    let (lcp, pairs) = parse_out(&out);
    assert_eq!(lcp, b"caf\xe9.txt");
    assert_eq!(pairs.len(), 1);
    assert_eq!(pairs[0].0, b"1");
    // span offsets are chars of the lossy reading: c,a,f -> 0-3
    assert_eq!(pairs[0].1, b"0-3");
}

#[test]
fn match_rejects_unknown_or_missing_args_with_exit_2() {
    let (code, _) = run_match(&["--bogus", "x"], b"");
    assert_eq!(code, 2);
    let (code, _) = run_match(&["--query", "a"], b""); // missing the rest
    assert_eq!(code, 2);
    let (code, _) = run_match(
        &[
            "--query",
            "a",
            "--mode",
            "fuzzy",
            "--smart-case",
            "true",
            "--max-lines",
            "10",
        ],
        b"",
    );
    assert_eq!(code, 2);
    let (code, _) = run_match(
        &[
            "--query",
            "a",
            "--mode",
            "typo",
            "--smart-case",
            "yes",
            "--max-lines",
            "10",
        ],
        b"",
    );
    assert_eq!(code, 2);
}

#[test]
fn match_rejects_malformed_streams_with_exit_3() {
    // field count not a multiple of 3
    let (code, _) = run_match(&typo_args("a", "10"), b"1\0git\0");
    assert_eq!(code, 3);
    // final field not NUL-terminated
    let (code, _) = run_match(&typo_args("a", "10"), b"1\0git\0trailing");
    assert_eq!(code, 3);
    // non-digit index
    let (code, _) = run_match(&typo_args("a", "10"), b"x1\0git\0\0");
    assert_eq!(code, 3);
    // empty index
    let (code, _) = run_match(&typo_args("a", "10"), b"\0git\0\0");
    assert_eq!(code, 3);
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
typeset -g  ZRUSH_PROTOCOL_VERSION='1'
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
