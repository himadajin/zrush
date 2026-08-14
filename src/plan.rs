//! Orchestration for worker plan requests (cli-protocol.md "`zrush worker`").
//!
//! Pipeline: hidden-file exclusion -> matching::QueryMatcher
//! (score every remaining candidate + common-prefix over the *untruncated*
//! prefix-tier matches)
//! -> ranking::rank (suppress approximate tiers when a literal exists,
//! then use the producer's ordering and absolute layout capacity: rows*8
//! for compsys, rows for history)
//! -> matching::QueryMatcher::spans (only for the ranked subset) ->
//! layout::build (the producer's grid direction/column cap plus shared
//! grouping/highlights/nav, further truncated to the real per-group row
//! budget) -> insert::build per displayed position
//! (this is where `-f` directory-synthesis stat happens, and only for
//! positions layout actually kept) -> wire::serialize.
//!
//! `compute` reads a candidate source (record::Candidates: a slot's parsed
//! payload, or a window over the history index) and takes an injected
//! `is_dir` predicate, so it stays free of I/O and is directly testable. It
//! cannot fail: the payload was validated when the request that carried it
//! was parsed, and session I/O belongs to worker.rs.

use crate::matching::{Mode, QueryMatcher, Tier};
use crate::record::Candidates;
use crate::span::CharSpan;
use crate::{insert, layout, ranking, record, wire};

/// Snapshot of a plan request's scalar fields; producer selects result
/// ordering and layout geometry.
pub(crate) struct Params {
    pub producer: Producer,
    pub query: Vec<u8>,
    pub mode: Mode,
    pub smart_case: bool,
    pub rows: usize,
    pub width: usize,
    pub trailing_space: bool,
}

/// Producer profile policy selected by the request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Producer {
    Compsys,
    History,
}

impl Producer {
    fn order(self) -> ranking::Order {
        match self {
            Producer::Compsys => ranking::Order::Quality,
            Producer::History => ranking::Order::Stdin,
        }
    }

    fn layout_style(self) -> layout::Style {
        match self {
            Producer::Compsys => layout::Style::Grid,
            Producer::History => layout::Style::History,
        }
    }
}

/// Run the full pipeline over a candidate source and return the serialized
/// render plan.
pub(crate) fn compute(
    params: &Params,
    source: &dyn Candidates,
    is_dir: &dyn Fn(&[u8]) -> bool,
) -> Vec<u8> {
    let batches = source.batches();

    let mut qm = QueryMatcher::new(&params.query, params.mode, params.smart_case);
    let mut matched: Vec<(usize, crate::matching::TierHit)> = Vec::new();
    // Prefix-tier match-texts, pre-truncation: common-prefix must reflect
    // every match, not just the ones the grid ends up displaying
    // (cli-protocol.md "common-prefix の意味論").
    let mut prefix_texts: Vec<&[u8]> = Vec::new();
    // cli-protocol.md "隠し候補の除外": excluded before tier classification, so
    // hidden files reach neither the listing nor common-prefix.
    let hidden_opt_in = params.query.first() == Some(&b'.');
    for idx in 0..source.candidate_count() {
        let cand = source.candidate(idx);
        let text = cand.match_text();
        if !hidden_opt_in && text.starts_with(b".") && batches[cand.batch].f == b"1" {
            continue;
        }
        if let Some(hit) = qm.classify(text) {
            if hit.tier() == Tier::Prefix {
                prefix_texts.push(text);
            }
            matched.push((idx, hit));
        }
    }
    let common_prefix = crate::matching::common_prefix(prefix_texts.into_iter());

    // behavior.md "表示": cap ranking at the selected layout's absolute
    // capacity. layout::build applies the real, per-group row budget on
    // top of this coarse cap.
    let style = params.producer.layout_style();
    let cap = params.rows.saturating_mul(style.max_cols());
    let ranked = ranking::rank(&matched, cap, params.producer.order());
    let candidates: Vec<record::Candidate<'_>> = ranked
        .iter()
        .map(|&(idx, _)| source.candidate(idx))
        .collect();
    // spans() is a second pass by design (matching.rs docs): only run it
    // on the ranked subset that actually reaches layout, and derive it
    // from the hit that candidate was already classified by.
    let spans: Vec<Vec<CharSpan>> = candidates
        .iter()
        .zip(&ranked)
        .map(|(c, &(_, hit))| qm.spans(c.match_text(), hit))
        .collect();

    // Producer-specific display preprocessing belongs here, before layout
    // applies grouping, geometry, offsets, and navigation. Build sources for
    // every ranked candidate because group widths are based on full group
    // membership, even when the row budget later drops some positions.
    let sources = compose_cell_sources(&candidates);

    let built = layout::build(
        &candidates,
        &batches,
        &sources,
        &spans,
        params.rows,
        params.width,
        style,
    );

    // Insertion text, and thus the `-f` stat, is built only for the
    // positions layout actually kept -- never the full ranked/matched set.
    let insert_texts: Vec<Vec<u8>> = built
        .positions
        .iter()
        .map(|&i| {
            let cand = &candidates[i];
            let batch = &batches[cand.batch];
            insert::build(batch, cand, params.trailing_space, is_dir)
        })
        .collect();

    wire::serialize(common_prefix, &built, &insert_texts)
}

/// Compose the display source for every candidate before the layout phase.
///
/// The history profile's event-number field is display-only and uses one
/// shared width across all numbered candidates. `match_offset` is optional so
/// layout can distinguish match-text cells from `d` display-text cells
/// without inspecting producer-specific candidate fields.
pub(crate) fn compose_cell_sources(
    candidates: &[record::Candidate<'_>],
) -> Vec<layout::CellSource> {
    let number_width = candidates
        .iter()
        .filter_map(|candidate| candidate.n.map(<[u8]>::len))
        .max()
        .map(|width| width.max(5));

    candidates
        .iter()
        .map(|candidate| {
            let base =
                layout::normalize_control_bytes(candidate.d.unwrap_or(candidate.match_text()));
            let matchable = candidate.d.is_none();
            let Some(number) = candidate.n else {
                return layout::CellSource {
                    text: base.into_owned(),
                    number_range: None,
                    match_offset: matchable.then_some(0),
                };
            };

            let width = number_width.expect("a numbered candidate establishes number width");
            let padding = width - number.len();
            let mut text = Vec::with_capacity(width + 2 + base.len());
            text.resize(padding, b' ');
            text.extend_from_slice(number);
            text.extend_from_slice(b"  ");
            text.extend_from_slice(&base);

            layout::CellSource {
                text,
                number_range: Some(CharSpan::new(padding, padding + number.len())),
                match_offset: matchable.then_some(width + 2),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[derive(Debug)]
    struct GeneratedCandidate {
        w: Vec<u8>,
        m: Option<Vec<u8>>,
        d: Option<Vec<u8>>,
        n: Option<Vec<u8>>,
    }

    #[derive(Debug)]
    struct GeneratedCapture {
        shared: Vec<Option<Vec<u8>>>,
        file: bool,
        candidates: Vec<GeneratedCandidate>,
    }

    impl GeneratedCapture {
        fn payload(&self) -> Vec<u8> {
            const SHARED_TAGS: [&[u8]; 11] = [
                b"P", b"p", b"S", b"s", b"i", b"I", b"ip", b"es", b"rd", b"X", b"J",
            ];

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
                if let Some(n) = &candidate.n {
                    push_capture_field(&mut out, b"n", n);
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
            prop::option::of(prop::collection::vec(b'0'..=b'9', 1..=8)),
        )
            .prop_map(|(w, m, d, n)| GeneratedCandidate { w, m, d, n })
    }

    fn generated_capture() -> impl Strategy<Value = GeneratedCapture> {
        (
            prop::collection::vec(prop::option::of(capture_value(8)), 11..=11),
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
                producer: Producer::Compsys,
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

    /// A history-profile payload as history.rs receives it: one empty batch
    /// header, then `w` plus an optional `n`, newest first.
    fn generated_history_payload(entries: &[(Vec<u8>, Option<Vec<u8>>)]) -> Vec<u8> {
        let mut out = b"b\x01\0".to_vec();
        for (line, event) in entries {
            out.extend_from_slice(b"w\x01");
            out.extend_from_slice(line);
            if let Some(event) = event {
                push_capture_field(&mut out, b"n", event);
            }
            out.push(0);
        }
        out
    }

    proptest! {
        /// The same totality and wire-shape invariant over the other
        /// candidate source: an arbitrary index read through an arbitrary
        /// scan window.
        #[test]
        fn window_sourced_pipeline_output_satisfies_wire_shape(
            entries in prop::collection::vec(
                (
                    capture_value(16),
                    prop::option::of(prop::collection::vec(b'0'..=b'9', 1..=8)),
                ),
                0..=16,
            ),
            limit in 1usize..=20,
            query in prop::collection::vec(1u8..=u8::MAX, 0..=16),
            mode in generated_mode(),
            smart_case in any::<bool>(),
            rows in 1usize..=8,
            width in 1usize..=64,
        ) {
            let stored = record::parse(generated_history_payload(&entries))
                .expect("generated payload is framed");
            let mut index = crate::history::HistoryIndex::default();
            index.install(1, &stored).expect("a fresh index accepts a snapshot");

            let params = Params {
                producer: Producer::History,
                query,
                mode,
                smart_case,
                rows,
                width,
                trailing_space: false,
            };
            let output = compute(&params, &index.window(limit), &no_dir);
            let parsed = wire::parse(&output);
            prop_assert!(
                parsed.is_ok(),
                "reference parser rejected output {output:?}: {parsed:?}"
            );
        }
    }

    /// Params with the `compsys` producer profile.
    fn params(query: &str, mode: Mode, rows: usize, width: usize, trailing_space: bool) -> Params {
        Params {
            producer: Producer::Compsys,
            query: query.as_bytes().to_vec(),
            mode,
            smart_case: true,
            rows,
            width,
            trailing_space,
        }
    }

    /// Params with the `history` producer profile.
    fn history_params(query: &str, mode: Mode, rows: usize, width: usize) -> Params {
        Params {
            producer: Producer::History,
            ..params(query, mode, rows, width, false)
        }
    }

    fn no_dir(_: &[u8]) -> bool {
        false
    }

    /// The store-then-plan pair the worker performs, as one call: parse a
    /// payload and compute a plan from the result.
    fn run(
        params: &Params,
        payload: &[u8],
        is_dir: &dyn Fn(&[u8]) -> bool,
    ) -> Result<Vec<u8>, record::FramingError> {
        let stored = record::parse(payload.to_vec())?;
        Ok(compute(params, &stored, is_dir))
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

    fn history_word(w: &str, n: &str) -> Vec<u8> {
        let mut r = b"w\x01".to_vec();
        r.extend_from_slice(w.as_bytes());
        r.extend_from_slice(b"\x02n\x01");
        r.extend_from_slice(n.as_bytes());
        r.push(0);
        r
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

    /// cli-protocol.md "隠し候補の除外".
    #[test]
    fn hidden_file_candidates_are_excluded_until_the_query_opts_in() {
        let stdin = {
            let mut s = header(&[("f", "1")]);
            s.extend(word(".hidden"));
            s.extend(word("visible"));
            s
        };

        // Empty query: the dot candidate reaches neither the listing nor
        // common-prefix, which is computed over the survivors alone.
        let p = parse_wire(&run(&params("", Mode::Typo, 10, 40, false), &stdin, &no_dir).unwrap());
        assert_eq!(p.rows, vec![b"visible".to_vec()]);
        assert_eq!(p.common_prefix, b"visible");

        // A query matching it as a substring is not an opt-in.
        let out = run(&params("h", Mode::Typo, 10, 40, false), &stdin, &no_dir).unwrap();
        assert_eq!(out, b"\x000\x000\x000\x00");

        // A leading dot opts in; "visible" then matches no tier.
        let p =
            parse_wire(&run(&params(".h", Mode::Typo, 10, 40, false), &stdin, &no_dir).unwrap());
        assert_eq!(p.rows, vec![b".hidden".to_vec()]);
        assert_eq!(p.common_prefix, b".hidden");
    }

    /// The exclusion mirrors what `globdots` adds in the capture fork, so it is
    /// limited to file batches (cli-protocol.md "隠し候補の除外").
    #[test]
    fn hidden_exclusion_is_limited_to_file_batches() {
        let stdin = {
            let mut s = header(&[]);
            s.extend(word(".PHONY"));
            s
        };
        let p = parse_wire(&run(&params("", Mode::Typo, 10, 40, false), &stdin, &no_dir).unwrap());
        assert_eq!(p.rows, vec![b".PHONY".to_vec()]);
    }

    #[test]
    fn literal_matches_suppress_approximate_for_compsys_and_keep_common_prefix() {
        let stdin = {
            let mut s = header(&[]);
            for w in ["mydocs", "docs", "dot-config", "doc", "xxx"] {
                s.extend(word(w));
            }
            s
        };
        // width=10 leaves one column, so rows appear in rank order
        // top-to-bottom (each padded to the surviving gmaxw of 6).
        let out = run(&params("doc", Mode::Typo, 10, 10, false), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.common_prefix, b"doc");
        // The literal survivors retain their quality order; dot-config is
        // an Edit match and is explicitly suppressed rather than ranked
        // below them. xxx matches no tier.
        let pad = |w: &str| format!("{w:<6}").into_bytes();
        assert_eq!(p.rows, vec![pad("doc"), pad("docs"), pad("mydocs")]);
        assert_eq!(
            p.inserts,
            vec![b"doc".to_vec(), b"docs".to_vec(), b"mydocs".to_vec()]
        );
        assert!(!p.inserts.iter().any(|text| text == b"dot-config"));
    }

    #[test]
    fn approximate_only_typo_rescue_is_preserved_for_compsys() {
        let mut stdin = header(&[]);
        for w in ["git", "grep", "git-lfs"] {
            stdin.extend(word(w));
        }

        let out = run(&params("gti", Mode::Typo, 10, 8, false), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.common_prefix, b"");
        assert_eq!(p.inserts, vec![b"git".to_vec(), b"git-lfs".to_vec()]);
    }

    #[test]
    fn late_literal_suppresses_approximates_before_the_coarse_capacity_cap() {
        let mut stdin = header(&[]);
        // rows=1 gives compsys a coarse capacity of 8. These eight Edit
        // matches would fill it if ranking truncated before suppression.
        for n in 0..8 {
            stdin.extend(word(&format!("dot{n}")));
        }
        // The only literal match deliberately arrives beyond that capacity.
        stdin.extend(word("doc"));

        let out = run(&params("doc", Mode::Typo, 1, 10, false), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.common_prefix, b"doc");
        assert_eq!(p.inserts, vec![b"doc".to_vec()]);
    }

    #[test]
    fn substring_alone_suppresses_approximate_matches() {
        let mut stdin = header(&[]);
        // fop is Edit, far-out-object is Fuzzy, and echo foo is the only
        // literal match (Substring rather than Prefix).
        for w in ["fop", "far-out-object", "echo foo"] {
            stdin.extend(word(w));
        }

        let out = run(&params("foo", Mode::Typo, 10, 40, false), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.common_prefix, b"");
        assert_eq!(p.inserts, vec![b"echo foo".to_vec()]);
    }

    #[test]
    fn match_highlight_offset_is_non_trivial_for_a_mid_string_match() {
        // Regression: a start==0 span can't distinguish a correct
        // end-exclusive reading from a buggy (start, start+len) one, and
        // this is the end-to-end check of the one span -> wire `start len`
        // conversion (span.rs). "ar" is a substring of "cargo" at char
        // index 1 (a-r), so matching::spans() emits chars [1,3) --
        // start != 0, len != 1.
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
        // cli-protocol.md "producer = history": the payload is newest
        // first. Approximate candidates are suppressed when literals exist,
        // while the surviving literal candidates keep that payload order.
        let mut stdin = header(&[]);
        for w in ["fop", "echo xfoo", "far-out-object", "unrelated", "foo"] {
            stdin.extend(word(w));
        }
        // A wide terminal could fit both candidates in a completion-grid
        // row, but history remains one column and renders logical position
        // 1 at the bottom.
        let out = run(&history_params("foo", Mode::Typo, 10, 40), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        // fop is Edit and far-out-object is Fuzzy; both are explicitly
        // suppressed. unrelated matches no tier.
        assert_eq!(p.rows, vec![b"foo      ".to_vec(), b"echo xfoo".to_vec()]);
        assert_eq!(p.inserts, vec![b"echo xfoo".to_vec(), b"foo".to_vec()]);
        assert!(!p.inserts.iter().any(|text| text == b"fop"));
        assert!(!p.inserts.iter().any(|text| text == b"far-out-object"));

        // Same payload under the compsys ordering ranks by quality
        // instead, so the two orderings really are distinguishable here.
        let out = run(&params("foo", Mode::Typo, 10, 9, false), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.inserts, vec![b"foo".to_vec(), b"echo xfoo".to_vec()]);
    }

    #[test]
    fn history_approximate_only_matches_keep_stdin_order() {
        let mut stdin = header(&[]);
        // fop is Edit and far-out-object is Fuzzy. With no literal match,
        // both remain in the payload's newest-first order.
        stdin.extend(word("fop"));
        stdin.extend(word("far-out-object"));

        let out = run(&history_params("foo", Mode::Typo, 10, 40), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.common_prefix, b"");
        assert_eq!(p.inserts, vec![b"fop".to_vec(), b"far-out-object".to_vec()]);
    }

    #[test]
    fn history_capacity_is_one_candidate_per_row() {
        let mut stdin = header(&[]);
        for w in ["newest", "newer", "older", "oldest"] {
            stdin.extend(word(w));
        }

        let out = run(&history_params("", Mode::Typo, 2, 80), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.rows, vec![b"newer ".to_vec(), b"newest".to_vec()]);
        assert_eq!(p.inserts, vec![b"newest".to_vec(), b"newer".to_vec()]);
    }

    #[test]
    fn history_event_number_is_display_only_and_shifts_match_highlight() {
        let mut stdin = header(&[]);
        stdin.extend(history_word("echo foo", "42"));
        let out = run(&history_params("foo", Mode::Typo, 10, 40), &stdin, &no_dir).unwrap();
        let p = parse_wire(&out);
        assert_eq!(p.rows, vec![b"   42  echo foo".to_vec()]);
        assert_eq!(p.cells, vec![(0, 15)]);
        assert_eq!(p.inserts, vec![b"echo foo".to_vec()]);
        assert!(
            p.highlights.iter().any(|h| {
                (h.role, h.pos, h.start, h.len) == (wire::Role::HistoryNumber, 1, 3, 2)
            })
        );
        assert!(has_match(&p, 1, 12, 3));
    }

    /// Moving dedup, the scan window and record building into the worker
    /// changed no plan: one duplicate-free history payload, read once as a
    /// stored payload and once as an index window, serializes identically --
    /// same ordering, layout, event-number column and insertion text.
    #[test]
    fn a_history_window_and_a_stored_payload_serialize_the_same_plan() {
        let mut stdin = header(&[]);
        for (line, event) in [("echo foo", "105"), ("unrelated", "104"), ("foo", "99")] {
            stdin.extend(history_word(line, event));
        }
        let stored = record::parse(stdin).unwrap();
        let mut index = crate::history::HistoryIndex::default();
        index
            .install(1, &stored)
            .expect("a fresh index accepts a snapshot");
        let window = index.window(5000);

        for params in [
            history_params("foo", Mode::Typo, 10, 16),
            history_params("", Mode::Typo, 2, 16),
            history_params("zzz", Mode::Prefix, 10, 16),
            params("foo", Mode::Typo, 10, 16, true),
        ] {
            assert_eq!(
                compute(&params, &stored, &no_dir),
                compute(&params, &window, &no_dir),
                "query {:?} producer {:?}",
                params.query,
                params.producer
            );
        }
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
