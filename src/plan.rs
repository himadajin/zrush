//! Orchestration for `zrush plan` (cli-protocol.md "`zrush plan`",
//! source of truth for the whole pipeline and the stdout wire format).
//!
//! Pipeline: record::parse -> matching::QueryMatcher (score every parsed
//! candidate + common-prefix over the *untruncated* prefix-tier matches)
//! -> ranking::rank (truncate to the grid's absolute capacity, rows*8)
//! -> matching::QueryMatcher::spans (only for the ranked subset) ->
//! layout::build (grouping/grid/highlights/nav, further truncated to the
//! real per-group row budget) -> insert::build per displayed position
//! (this is where `-f` directory-synthesis stat happens, and only for
//! positions layout actually kept) -> flat NUL-terminated serialization.
//!
//! `run` takes the whole stdin buffer already read and an injected
//! `is_dir` predicate, so it stays free of I/O and is directly testable.
//! The only error this pipeline itself can produce is a stdin framing
//! violation (record.rs); reading stdin and writing stdout are main.rs's
//! job and fail (if at all) with the CLI's own exit-1 I/O path.

use std::io::Write;

use crate::matching::{Mode, QueryMatcher, Tier};
use crate::{insert, layout, ranking, record};

/// Snapshot of the `--query`/`--mode`/`--smart-case`/`--rows`/`--width`/
/// `--trailing-space` arguments (cli-protocol.md "起動").
pub(crate) struct Params {
    pub query: Vec<u8>,
    pub mode: Mode,
    pub smart_case: bool,
    pub rows: usize,
    pub width: usize,
    pub trailing_space: bool,
}

/// The only error `run` itself can produce (cli-protocol.md exit code 3).
/// I/O failures are main.rs's concern, not this pure pipeline's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Error {
    Framing,
}

/// Run the full v2 pipeline and return the serialized render plan.
pub(crate) fn run(
    params: &Params,
    stdin: &[u8],
    is_dir: &dyn Fn(&[u8]) -> bool,
) -> Result<Vec<u8>, Error> {
    let parsed = record::parse(stdin).map_err(|_| Error::Framing)?;

    let mut qm = QueryMatcher::new(&params.query, params.mode, params.smart_case);
    let mut scored: Vec<(usize, crate::matching::MatchScore)> = Vec::new();
    // Prefix-tier match-texts, pre-truncation: common-prefix must reflect
    // every match, not just the ones the grid ends up displaying
    // (cli-protocol.md "common-prefix の意味論").
    let mut prefix_texts: Vec<&[u8]> = Vec::new();
    for (idx, cand) in parsed.candidates.iter().enumerate() {
        let text = cand.match_text();
        if let Some(ms) = qm.score(text) {
            if ms.tier == Tier::Prefix {
                prefix_texts.push(text);
            }
            scored.push((idx, ms));
        }
    }
    let common_prefix = crate::matching::common_prefix(prefix_texts.into_iter());

    // behavior.md "表示": rank the top rows*8 candidates -- the grid's
    // absolute max capacity (8 columns cap, cli-protocol.md "列数").
    // layout::build applies the real, per-group row budget on top of
    // this coarse cap.
    let cap = params.rows.saturating_mul(8);
    let order = ranking::rank(&scored, cap);
    let candidates: Vec<record::Candidate<'_>> =
        order.iter().map(|&i| parsed.candidates[i]).collect();
    // spans() is a second pass by design (matching.rs docs): only run it
    // on the ranked subset that actually reaches layout.
    let spans: Vec<Vec<(usize, usize)>> = candidates
        .iter()
        .map(|c| qm.spans(c.match_text()))
        .collect();

    let built = layout::build(
        &candidates,
        &parsed.batches,
        &spans,
        params.rows,
        params.width,
    );

    // Insertion text, and thus the `-f` stat, is built only for the
    // positions layout actually kept -- never the full ranked/matched set.
    let insert_texts: Vec<Vec<u8>> = built
        .positions
        .iter()
        .map(|&i| {
            let cand = &candidates[i];
            let batch = &parsed.batches[cand.batch];
            insert::build(batch, cand, params.trailing_space, is_dir)
        })
        .collect();

    Ok(serialize(common_prefix, &built, &insert_texts))
}

/// Flatten the plan into the stdout wire format (cli-protocol.md
/// "stdout(描画プラン)"): NUL-terminated fields, fixed order, total count
/// `4 + L + H + 3P`. A plan with `L == P == H == 0` (nothing matched)
/// naturally serializes to exactly the "0 マッチ" 4-field form.
fn serialize(common_prefix: &[u8], plan: &layout::Plan, insert_texts: &[Vec<u8>]) -> Vec<u8> {
    let mut out = Vec::new();
    push_bytes(&mut out, common_prefix);
    let _ = write!(out, "{}", plan.rows.len());
    out.push(0);
    let _ = write!(out, "{}", plan.positions.len());
    out.push(0);
    for row in &plan.rows {
        push_bytes(&mut out, row);
    }
    let _ = write!(out, "{}", plan.highlights.len());
    out.push(0);
    for h in &plan.highlights {
        let _ = write!(out, "{} {} {} {}", h.role.as_str(), h.pos, h.start, h.len);
        out.push(0);
    }
    for &(start, len) in &plan.cell_ranges {
        let _ = write!(out, "{start} {len}");
        out.push(0);
    }
    for n in &plan.nav {
        let _ = write!(out, "{} {} {} {}", n.next, n.prev, n.left, n.right);
        out.push(0);
    }
    for text in insert_texts {
        push_bytes(&mut out, text);
    }
    out
}

fn push_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(bytes);
    out.push(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(query: &str, mode: Mode, rows: usize, width: usize, trailing_space: bool) -> Params {
        Params {
            query: query.as_bytes().to_vec(),
            mode,
            smart_case: true,
            rows,
            width,
            trailing_space,
        }
    }

    fn no_dir(_: &[u8]) -> bool {
        false
    }

    /// Split a `run()` result into its fixed-position and repeated-block
    /// fields, verifying the `4 + L + H + 3P` field-count invariant.
    struct Parsed {
        common_prefix: Vec<u8>,
        rows: Vec<Vec<u8>>,
        highlights: Vec<Vec<u8>>,
        cells: Vec<Vec<u8>>,
        nav: Vec<Vec<u8>>,
        inserts: Vec<Vec<u8>>,
    }

    fn parse_out(out: &[u8]) -> Parsed {
        assert_eq!(out.last(), Some(&0u8), "output must be NUL-terminated");
        let f: Vec<Vec<u8>> = out[..out.len() - 1]
            .split(|&b| b == 0)
            .map(<[u8]>::to_vec)
            .collect();
        let l: usize = std::str::from_utf8(&f[1]).unwrap().parse().unwrap();
        let p: usize = std::str::from_utf8(&f[2]).unwrap().parse().unwrap();
        let mut i = 3;
        let rows = f[i..i + l].to_vec();
        i += l;
        let h: usize = std::str::from_utf8(&f[i]).unwrap().parse().unwrap();
        i += 1;
        let highlights = f[i..i + h].to_vec();
        i += h;
        let cells = f[i..i + p].to_vec();
        i += p;
        let nav = f[i..i + p].to_vec();
        i += p;
        let inserts = f[i..i + p].to_vec();
        i += p;
        assert_eq!(i, f.len(), "field count must be exactly 4 + L + H + 3P");
        Parsed {
            common_prefix: f[0].clone(),
            rows,
            highlights,
            cells,
            nav,
            inserts,
        }
    }

    fn header(fields: &[(&str, &str)]) -> Vec<u8> {
        let mut r = b"b".to_vec();
        for (tag, val) in fields {
            r.push(2);
            r.extend_from_slice(tag.as_bytes());
            r.push(1);
            r.extend_from_slice(val.as_bytes());
        }
        r.push(0);
        r
    }

    fn word(w: &str) -> Vec<u8> {
        let mut r = b"w".to_vec();
        r.push(1);
        r.extend_from_slice(w.as_bytes());
        r.push(0);
        r
    }

    #[test]
    fn empty_stdin_is_the_four_field_zero_match_form() {
        let out = run(&params("abc", Mode::Typo, 10, 40, true), b"", &no_dir).unwrap();
        assert_eq!(out, b"\x000\x000\x000\x00");
    }

    #[test]
    fn framing_error_is_reported() {
        // no trailing NUL: framing violation (record.rs).
        let err = run(&params("a", Mode::Typo, 10, 40, true), b"b", &no_dir).unwrap_err();
        assert_eq!(err, Error::Framing);
    }

    #[test]
    fn end_to_end_grouped_payload() {
        let mut stdin = Vec::new();
        stdin.extend(header(&[("J", "cmds"), ("X", "Commands")]));
        stdin.extend(word("git"));
        stdin.extend(word("grep"));

        // width=9: gmaxw=max(3,4)=4 -> cols=floor(11/6)=1 (single column),
        // and the width budget still fits "Commands" (8 chars) untruncated.
        let out = run(&params("g", Mode::Prefix, 10, 9, true), &stdin, &no_dir).unwrap();
        let p = parse_out(&out);
        assert_eq!(p.common_prefix, b"g");
        // heading + "git" padded to gmaxw=4 + "grep" (already width 4).
        assert_eq!(
            p.rows,
            vec![b"Commands".to_vec(), b"git ".to_vec(), b"grep".to_vec()]
        );
        assert_eq!(p.cells.len(), 2);
        assert_eq!(p.nav.len(), 2);
        assert_eq!(p.inserts, vec![b"git ".to_vec(), b"grep ".to_vec()]);
        // Offsets run over the whole listing text ("Commands\ngit \ngrep"):
        // heading spans [0,8); row 2 starts at char 9 (8 + 1 newline);
        // row 3 starts at char 14 (9 + 4 + 1 newline).
        assert_eq!(p.cells[0], b"9 3".to_vec()); // "git" real text, 3 chars
        assert_eq!(p.cells[1], b"14 4".to_vec()); // "grep", 4 chars
        let hl: Vec<&str> = p
            .highlights
            .iter()
            .map(|h| std::str::from_utf8(h).unwrap())
            .collect();
        assert!(hl.contains(&"heading 0 0 8"));
        // query "g" is a 1-char prefix match: span [0,1) on each match-text.
        assert!(hl.contains(&"match 1 9 1"));
        assert!(hl.contains(&"match 2 14 1"));
    }

    #[test]
    fn match_text_prefers_m_tag() {
        let mut stdin = header(&[]);
        // w is the quoted form; m is the unquoted raw text zrush must
        // match/display against.
        let mut rec = b"w".to_vec();
        rec.push(1);
        rec.extend_from_slice(b"space\\ name.txt");
        rec.push(2);
        rec.extend_from_slice(b"m");
        rec.push(1);
        rec.extend_from_slice(b"space name.txt");
        rec.push(0);
        stdin.extend(rec);

        let out = run(
            &params("space", Mode::Prefix, 10, 40, false),
            &stdin,
            &no_dir,
        )
        .unwrap();
        let p = parse_out(&out);
        assert_eq!(p.rows, vec![b"space name.txt".to_vec()]);
        assert_eq!(p.inserts, vec![b"space\\ name.txt".to_vec()]);
    }

    #[test]
    fn d_tag_is_displayed_instead_of_match_text() {
        let mut stdin = header(&[]);
        let mut rec = b"w".to_vec();
        rec.push(1);
        rec.extend_from_slice(b"raw");
        rec.push(2);
        rec.extend_from_slice(b"d");
        rec.push(1);
        rec.extend_from_slice(b"Pretty Display");
        rec.push(0);
        stdin.extend(rec);

        let out = run(&params("", Mode::Typo, 10, 40, false), &stdin, &no_dir).unwrap();
        let p = parse_out(&out);
        assert_eq!(p.rows, vec![b"Pretty Display".to_vec()]);
        assert_eq!(p.inserts, vec![b"raw".to_vec()]);
    }

    #[test]
    fn cjk_cell_alignment_width_padding_char_offsets() {
        let mut stdin = header(&[]);
        stdin.extend(word("日本語")); // 3 chars, width 6
        stdin.extend(word("ab"));
        let out = run(&params("", Mode::Typo, 10, 8, false), &stdin, &no_dir).unwrap();
        let p = parse_out(&out);
        // single column (gmaxw=6, width=8 -> cols=floor(10/8)=1)
        assert_eq!(
            p.rows,
            vec!["日本語".as_bytes().to_vec(), b"ab    ".to_vec()]
        );
        assert_eq!(std::str::from_utf8(&p.cells[0]).unwrap(), "0 3");
        assert_eq!(std::str::from_utf8(&p.cells[1]).unwrap(), "4 2");
    }

    #[test]
    fn dir_synthesis_uses_real_filesystem_stat() {
        let dir = std::env::temp_dir().join(format!("zrush-plan-it-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("child")).unwrap();
        let rd = format!("{}/", dir.display());

        let mut stdin = header(&[("f", "1"), ("rd", &rd)]);
        stdin.extend(word("child"));

        let real_is_dir = |path: &[u8]| {
            use std::os::unix::ffi::OsStrExt;
            std::fs::metadata(std::ffi::OsStr::from_bytes(path))
                .map(|m| m.is_dir())
                .unwrap_or(false)
        };
        let out = run(&params("", Mode::Typo, 10, 40, true), &stdin, &real_is_dir).unwrap();
        let p = parse_out(&out);
        assert_eq!(p.inserts, vec![b"child/".to_vec()]); // no trailing space: nospace on `/`

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn trailing_space_toggle() {
        let stdin = {
            let mut s = header(&[]);
            s.extend(word("git"));
            s
        };
        let on = run(&params("", Mode::Typo, 10, 40, true), &stdin, &no_dir).unwrap();
        let off = run(&params("", Mode::Typo, 10, 40, false), &stdin, &no_dir).unwrap();
        assert_eq!(parse_out(&on).inserts, vec![b"git ".to_vec()]);
        assert_eq!(parse_out(&off).inserts, vec![b"git".to_vec()]);
    }

    #[test]
    fn zero_matches_after_filtering_is_still_the_four_field_form() {
        let stdin = {
            let mut s = header(&[]);
            s.extend(word("alpha"));
            s.extend(word("beta"));
            s
        };
        let out = run(&params("zzz", Mode::Typo, 10, 40, true), &stdin, &no_dir).unwrap();
        assert_eq!(out, b"\x000\x000\x000\x00");
    }

    #[test]
    fn ranking_tiers_and_common_prefix_v2() {
        let stdin = {
            let mut s = header(&[]);
            for w in ["mydocs", "docs", "dot-config", "doc", "xxx"] {
                s.extend(word(w));
            }
            s
        };
        // width=10 == the widest match ("dot-config"): gmaxw=10,
        // cols=floor(12/12)=1, forcing a single column so rows appear
        // in rank order top-to-bottom (each padded to width 10).
        let out = run(&params("doc", Mode::Typo, 10, 10, false), &stdin, &no_dir).unwrap();
        let p = parse_out(&out);
        assert_eq!(p.common_prefix, b"doc");
        // prefix-exact(doc) > prefix(docs) > substring(mydocs) > edit(dot-config); xxx excluded.
        let pad = |w: &str| format!("{w:<10}").into_bytes();
        assert_eq!(
            p.rows,
            vec![pad("doc"), pad("docs"), pad("mydocs"), pad("dot-config")]
        );
    }

    #[test]
    fn match_highlight_offset_is_non_trivial_for_a_mid_string_match() {
        // Regression: a start==0 span can't distinguish a correct
        // (start, end) reading from a buggy (start, start+len) one.
        // "ar" is a substring of "cargo" at char index 1 (a-r), so
        // matching::spans() emits (1, 3) -- start != 0, len != 1.
        let stdin = {
            let mut s = header(&[]);
            s.extend(word("cargo"));
            s
        };
        let out = run(
            &params("ar", Mode::Substring, 10, 40, false),
            &stdin,
            &no_dir,
        )
        .unwrap();
        let p = parse_out(&out);
        assert_eq!(p.rows, vec![b"cargo".to_vec()]);
        let m = p
            .highlights
            .iter()
            .find(|h| std::str::from_utf8(h).unwrap().starts_with("match "))
            .unwrap();
        assert_eq!(std::str::from_utf8(m).unwrap(), "match 1 1 2");
    }

    #[test]
    fn common_prefix_includes_matches_dropped_by_the_rows_times_8_cap() {
        // rows=1 -> cap = rows*8 = 8. 8 "aaaN" candidates plus a 9th
        // ("ab") all match query "a"'s prefix tier, but only the first 8
        // (stdin order; all tied) survive ranking's cap -- "ab" never
        // reaches layout. common-prefix must still reflect it
        // (cli-protocol.md: computed over the *untruncated* prefix-tier
        // matches), so the LCP collapses to "a", not "aaa".
        let stdin = {
            let mut s = header(&[]);
            for n in 1..=8 {
                s.extend(word(&format!("aaa{n}")));
            }
            s.extend(word("ab"));
            s
        };
        let out = run(&params("a", Mode::Typo, 1, 40, false), &stdin, &no_dir).unwrap();
        let p = parse_out(&out);
        assert_eq!(p.common_prefix, b"a");
        // Sanity: "ab" really was dropped by the cap, not merely unranked.
        assert!(p.rows.iter().all(|r| r != b"ab"));
    }

    #[test]
    fn stat_runs_only_for_displayed_f_eq_1_positions() {
        // 10 candidates, all f=1, but a narrow grid (rows=1, width=3)
        // only displays 1 of them. `is_dir` must be called exactly once
        // -- not once per matched, ranked, or rows*8-capped candidate --
        // since the `-f` stat is budgeted by what the grid actually shows.
        let stdin = {
            let mut s = header(&[("f", "1"), ("rd", "./")]);
            for i in 0..10 {
                s.extend(word(&format!("d{i}")));
            }
            s
        };
        let calls = std::cell::RefCell::new(0usize);
        let counting_is_dir = |_: &[u8]| {
            *calls.borrow_mut() += 1;
            false
        };
        let out = run(
            &params("", Mode::Typo, 1, 3, false),
            &stdin,
            &counting_is_dir,
        )
        .unwrap();
        let p = parse_out(&out);
        assert_eq!(
            *calls.borrow(),
            p.cells.len(),
            "one stat per displayed position"
        );
        assert_eq!(*calls.borrow(), 1);
    }

    #[test]
    fn newline_in_candidate_is_normalized_for_display_but_raw_in_insertion_text() {
        // cli-protocol.md: newline -> space is a *display* normalization
        // only; insertion text returns the original bytes untouched.
        let mut stdin = header(&[]);
        stdin.extend(word("foo\nbar"));
        let out = run(&params("", Mode::Typo, 10, 40, false), &stdin, &no_dir).unwrap();
        let p = parse_out(&out);
        assert_eq!(p.rows, vec![b"foo bar".to_vec()]);
        assert_eq!(p.inserts, vec![b"foo\nbar".to_vec()]);
    }

    #[test]
    fn dir_synthesis_is_skipped_when_real_stat_fails() {
        // A real fs::metadata-backed is_dir on a path that doesn't exist
        // must behave exactly like the fake-false case: no `/` synthesis.
        let mut stdin = header(&[("f", "1"), ("rd", "/nonexistent-zrush-test-path-xyz/")]);
        stdin.extend(word("child"));
        let real_is_dir = |path: &[u8]| {
            use std::os::unix::ffi::OsStrExt;
            std::fs::metadata(std::ffi::OsStr::from_bytes(path))
                .map(|m| m.is_dir())
                .unwrap_or(false)
        };
        let out = run(&params("", Mode::Typo, 10, 40, true), &stdin, &real_is_dir).unwrap();
        let p = parse_out(&out);
        assert_eq!(p.inserts, vec![b"child ".to_vec()]); // no '/'; trailing space kept
    }
}
