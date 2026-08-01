//! Orchestration for `zrush plan` (cli-protocol.md "`zrush plan`",
//! source of truth for the whole pipeline and the stdout wire format).
//!
//! Pipeline: record::parse -> matching::QueryMatcher (score every parsed
//! candidate + common-prefix over the *untruncated* prefix-tier matches)
//! -> ranking::rank (the pipeline's only producer-dependent stage;
//! truncates to the grid's absolute capacity, rows*8)
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

/// Snapshot of the `zrush plan` arguments (cli-protocol.md "起動");
/// `--producer` arrives as the result ordering it selects (ranking.rs).
pub(crate) struct Params {
    pub order: ranking::Order,
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

/// Run the full pipeline and return the serialized render plan.
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
    let ranked = ranking::rank(&scored, cap, params.order);
    let candidates: Vec<record::Candidate<'_>> =
        ranked.iter().map(|&i| parsed.candidates[i]).collect();
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
    use crate::wire;
    use proptest::prelude::*;

    #[derive(Debug)]
    struct GeneratedCandidate {
        w: Vec<u8>,
        m: Option<Vec<u8>>,
        d: Option<Vec<u8>>,
    }

    #[derive(Debug)]
    struct GeneratedCapture {
        shared: Vec<Option<Vec<u8>>>,
        file: bool,
        candidates: Vec<GeneratedCandidate>,
    }

    impl GeneratedCapture {
        fn payload(&self) -> Vec<u8> {
            const SHARED_TAGS: [&[u8]; 10] =
                [b"P", b"p", b"S", b"s", b"i", b"I", b"ip", b"rd", b"X", b"J"];

            let mut out = b"b\x01".to_vec();
            for (tag, value) in SHARED_TAGS.iter().zip(&self.shared) {
                if let Some(value) = value {
                    push_capture_field(&mut out, tag, value);
                }
            }
            if self.file {
                push_capture_field(&mut out, b"f", b"1");
            }
            out.push(0);

            for candidate in &self.candidates {
                out.extend_from_slice(b"w\x01");
                out.extend_from_slice(&candidate.w);
                if let Some(m) = candidate.m.as_ref().filter(|m| *m != &candidate.w) {
                    push_capture_field(&mut out, b"m", m);
                }
                if let Some(d) = &candidate.d {
                    push_capture_field(&mut out, b"d", d);
                }
                out.push(0);
            }
            out
        }
    }

    fn push_capture_field(out: &mut Vec<u8>, tag: &[u8], value: &[u8]) {
        out.push(2);
        out.extend_from_slice(tag);
        out.push(1);
        out.extend_from_slice(value);
    }

    fn capture_value(max_len: usize) -> impl Strategy<Value = Vec<u8>> {
        prop::collection::vec(3u8..=u8::MAX, 1..=max_len)
    }

    fn generated_candidate() -> impl Strategy<Value = GeneratedCandidate> {
        (
            capture_value(16),
            prop::option::of(capture_value(16)),
            prop::option::of(capture_value(16)),
        )
            .prop_map(|(w, m, d)| GeneratedCandidate { w, m, d })
    }

    fn generated_capture() -> impl Strategy<Value = GeneratedCapture> {
        (
            prop::collection::vec(prop::option::of(capture_value(8)), 10..=10),
            any::<bool>(),
            prop::collection::vec(generated_candidate(), 0..=16),
        )
            .prop_map(|(shared, file, candidates)| GeneratedCapture {
                shared,
                file,
                candidates,
            })
    }

    fn generated_mode() -> impl Strategy<Value = Mode> {
        prop_oneof![Just(Mode::Prefix), Just(Mode::Substring), Just(Mode::Typo),]
    }

    proptest! {
        #[test]
        fn serialized_pipeline_output_satisfies_wire_shape(
            capture in generated_capture(),
            query in prop::collection::vec(1u8..=u8::MAX, 0..=16),
            mode in generated_mode(),
            smart_case in any::<bool>(),
            rows in 1usize..=8,
            width in 1usize..=64,
            trailing_space in any::<bool>(),
        ) {
            let params = Params {
                order: ranking::Order::Quality,
                query,
                mode,
                smart_case,
                rows,
                width,
                trailing_space,
            };
            let stdin = capture.payload();
            let output = run(&params, &stdin, &no_dir).expect("generated payload is framed");
            let parsed = wire::parse(&output);
            prop_assert!(
                parsed.is_ok(),
                "reference parser rejected output {output:?}: {parsed:?}"
            );
        }
    }

    /// Params with the `--producer compsys` ordering (quality-ranked).
    fn params(query: &str, mode: Mode, rows: usize, width: usize, trailing_space: bool) -> Params {
        Params {
            order: ranking::Order::Quality,
            query: query.as_bytes().to_vec(),
            mode,
            smart_case: true,
            rows,
            width,
            trailing_space,
        }
    }

    /// Params with the `--producer history` ordering (stdin order kept).
    fn history_params(query: &str, mode: Mode, rows: usize, width: usize) -> Params {
        Params {
            order: ranking::Order::Stdin,
            ..params(query, mode, rows, width, false)
        }
    }

    fn no_dir(_: &[u8]) -> bool {
        false
    }

    fn parse_wire(out: &[u8]) -> wire::Plan {
        wire::parse(out).expect("valid plan")
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

    fn raw_word(w: &[u8]) -> Vec<u8> {
        let mut r = b"w".to_vec();
        r.push(1);
        r.extend_from_slice(w);
        r.push(0);
        r
    }

    fn word(w: &str) -> Vec<u8> {
        raw_word(w.as_bytes())
    }

    fn has_match(plan: &wire::Plan, pos: usize, start: usize, len: usize) -> bool {
        plan.highlights
            .iter()
            .any(|h| (h.role, h.pos, h.start, h.len) == (wire::Role::Match, pos, start, len))
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
        let p = parse_wire(&out);
        assert_eq!(p.common_prefix, b"g");
        // heading + "git" padded to gmaxw=4 + "grep" (already width 4).
        assert_eq!(
            p.rows,
            vec![b"Commands".to_vec(), b"git ".to_vec(), b"grep".to_vec()]
        );
        assert_eq!(p.cells.len(), 2);
        assert_eq!(p.navigation.len(), 2);
        assert_eq!(p.inserts, vec![b"git ".to_vec(), b"grep ".to_vec()]);
        // Offsets run over the whole listing text ("Commands\ngit \ngrep"):
        // heading spans [0,8); row 2 starts at char 9 (8 + 1 newline);
        // row 3 starts at char 14 (9 + 4 + 1 newline).
        assert_eq!(p.cells[0], (9, 3)); // "git" real text, 3 chars
        assert_eq!(p.cells[1], (14, 4)); // "grep", 4 chars
        assert!(
            p.highlights
                .iter()
                .any(|h| { (h.role, h.pos, h.start, h.len) == (wire::Role::Heading, 0, 0, 8) })
        );
        // query "g" is a 1-char prefix match: span [0,1) on each match-text.
        assert!(
            p.highlights
                .iter()
                .any(|h| { (h.role, h.pos, h.start, h.len) == (wire::Role::Match, 1, 9, 1) })
        );
        assert!(
            p.highlights
                .iter()
                .any(|h| { (h.role, h.pos, h.start, h.len) == (wire::Role::Match, 2, 14, 1) })
        );
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
        let p = parse_wire(&out);
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
        let p = parse_wire(&out);
        assert_eq!(p.rows, vec![b"Pretty Display".to_vec()]);
        assert_eq!(p.inserts, vec![b"raw".to_vec()]);
    }

    #[test]
    fn cjk_cell_alignment_width_padding_char_offsets() {
        let mut stdin = header(&[]);
        stdin.extend(word("日本語")); // 3 chars, width 6
        stdin.extend(word("ab"));
        let out = run(&params("", Mode::Typo, 10, 8, false), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        // single column (gmaxw=6, width=8 -> cols=floor(10/8)=1)
        assert_eq!(
            p.rows,
            vec!["日本語".as_bytes().to_vec(), b"ab    ".to_vec()]
        );
        assert_eq!(p.cells[0], (0, 3));
        assert_eq!(p.cells[1], (4, 2));
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
        let p = parse_wire(&out);
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
        assert_eq!(parse_wire(&on).inserts, vec![b"git ".to_vec()]);
        assert_eq!(parse_wire(&off).inserts, vec![b"git".to_vec()]);
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
    fn ranking_tiers_and_common_prefix() {
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
        let p = parse_wire(&out);
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
        let p = parse_wire(&out);
        assert_eq!(p.rows, vec![b"cargo".to_vec()]);
        assert!(
            p.highlights
                .iter()
                .any(|h| { (h.role, h.pos, h.start, h.len) == (wire::Role::Match, 1, 1, 2) })
        );
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
        let p = parse_wire(&out);
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
        let p = parse_wire(&out);
        assert_eq!(
            *calls.borrow(),
            p.cells.len(),
            "one stat per displayed position"
        );
        assert_eq!(*calls.borrow(), 1);
    }

    #[test]
    fn control_bytes_are_normalized_for_display_but_raw_in_insertion_text() {
        // cli-protocol.md "制御バイト→スペース正規化": every C0 byte and
        // DEL becomes one space in the *display* text, and display width,
        // padding, truncation and cell/highlight offsets are all measured
        // on that normalized text; insertion text keeps the raw bytes.
        // One payload, two widths, so the untruncated and truncated
        // readings are pinned against the same candidates.
        const ESC_DEL_TAB: &[u8] = b"ab\x1bcd\x7fef\tgh"; // 11 bytes -> "ab cd ef gh"
        const LF: &[u8] = b"zz\ncd"; // 5 bytes -> "zz cd"
        let mut stdin = header(&[]);
        stdin.extend(raw_word(ESC_DEL_TAB));
        stdin.extend(raw_word(LF));

        // width 40: nothing truncated. gmaxw is 11 -- the *normalized*
        // width of the first candidate (raw, its 3 control bytes would
        // have width 0 and give 8), which is what pads "zz cd" out to 11.
        let out = run(
            &params("cd", Mode::Substring, 10, 40, false),
            &stdin,
            &no_dir,
        )
        .unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.rows, vec![b"ab cd ef gh  zz cd      ".to_vec()]);
        assert_eq!(p.cells, vec![(0, 11), (13, 5)]);
        // Spans are computed on the raw match-text; the 1-byte-for-1-byte
        // normalization keeps them aligned with the displayed cell.
        assert!(has_match(&p, 1, 3, 2));
        assert!(has_match(&p, 2, 16, 2));
        assert_eq!(p.inserts, vec![ESC_DEL_TAB.to_vec(), LF.to_vec()]);

        // width 5: truncation counts the normalized text, so the retained
        // prefix is 5 chars ("ab cd"), not the 7 a control-byte-as-width-0
        // reading would keep.
        let out = run(
            &params("cd", Mode::Substring, 10, 5, false),
            &stdin,
            &no_dir,
        )
        .unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.rows, vec![b"ab cd".to_vec(), b"zz cd".to_vec()]);
        assert_eq!(p.cells, vec![(0, 5), (6, 5)]);
        assert!(has_match(&p, 1, 3, 2));
        assert!(has_match(&p, 2, 9, 2));
        assert_eq!(p.inserts, vec![ESC_DEL_TAB.to_vec(), LF.to_vec()]);
    }

    #[test]
    fn history_order_keeps_stdin_order_regardless_of_match_quality() {
        // cli-protocol.md "--producer history": the payload is newest
        // first and that order survives verbatim, so position 1 is the
        // newest *matching* history line even though the older candidate
        // is the better (prefix-tier) match.
        let mut stdin = header(&[]);
        for w in ["echo xfoo", "unrelated", "foo"] {
            stdin.extend(word(w));
        }
        // width 9 == the widest candidate, forcing a single column so the
        // rows read top-to-bottom in position order.
        let out = run(&history_params("foo", Mode::Typo, 10, 9), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        // "unrelated" matches no tier and is the only candidate dropped.
        assert_eq!(p.rows, vec![b"echo xfoo".to_vec(), b"foo      ".to_vec()]);
        assert_eq!(p.inserts, vec![b"echo xfoo".to_vec(), b"foo".to_vec()]);

        // Same payload under the compsys ordering ranks by quality
        // instead, so the two orderings really are distinguishable here.
        let out = run(&params("foo", Mode::Typo, 10, 9, false), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.inserts, vec![b"foo".to_vec(), b"echo xfoo".to_vec()]);
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
        let p = parse_wire(&out);
        assert_eq!(p.inserts, vec![b"child ".to_vec()]); // no '/'; trailing space kept
    }
}
