//! stdin record parser for `zrush plan`.
//!
//! Format and semantics: docs/internal/contracts/cli-protocol.md
//! ("`zrush plan`" -> "stdin(レコードストリーム)", source of truth). NUL-terminated
//! records; fields within a record are `\2`-joined `<tag>\1<value>` pairs.
//! Batch header records (first field tag `b`) carry shared fields that
//! apply to every candidate record up to the next header; candidate
//! records (first field tag `w`) carry per-candidate `w`/`m`/`d`/`n`.
//!
//! Zero-copy: every value here borrows from the caller's stdin buffer.
//! plan.rs is the consumer.

const REC_SEP: u8 = 0; // \0: terminates a record
const FIELD_SEP: u8 = 2; // \2: joins fields within a record
const TAG_SEP: u8 = 1; // \1: separates a field's tag from its value

/// Shared fields from a batch header record, inherited by every candidate
/// up to the next header (cli-protocol.md "バッチヘッダレコード").
///
/// The sender only emits a shared field when it is non-empty, and per the
/// contract's general rule "absent field" and "empty value" are
/// equivalent -- so every field here reads as the empty slice when the
/// header omitted it (or, defensively, sent it empty). Field names mirror
/// their wire tags directly (cli-protocol.md "バッチヘッダレコード"); the
/// compadd option each visible/hidden prefix/suffix tag corresponds to is
/// a compsys 捕獲 profile convention (cli-protocol.md "compsys 捕獲
/// profile"), not a fact of this producer-independent record layer.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Batch<'a> {
    pub p_vis: &'a [u8],    // P
    pub p_hidden: &'a [u8], // p
    pub s_vis: &'a [u8],    // S
    pub s_hidden: &'a [u8], // s
    pub i_vis: &'a [u8],    // i
    pub i_hidden: &'a [u8], // I
    pub ip: &'a [u8],       // ip: IPREFIX
    pub f: &'a [u8],        // f: "1" if a file candidate
    pub rd: &'a [u8],       // rd: real directory (for `-f` "/" synthesis)
    pub x: &'a [u8],        // X: group heading text
    pub j: &'a [u8],        // J: group name
}

/// One candidate record, tagged with the index of its owning batch into
/// the `batches` vec returned alongside it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Candidate<'a> {
    /// Candidate body used to build the insertion text (cli-protocol.md
    /// `w`, "候補レコード"). Never empty -- the parser skips records that
    /// would produce one. Producer-profile-specific: see cli-protocol.md
    /// "compsys 捕獲 profile" / "history profile".
    pub w: &'a [u8],
    /// match-text (cli-protocol.md `m`), present only when it differs
    /// from `w`.
    pub m: Option<&'a [u8]>,
    /// Display text (cli-protocol.md `d`, "候補レコード").
    pub d: Option<&'a [u8]>,
    /// History event number (cli-protocol.md `n`), emitted only by the
    /// history profile as non-empty ASCII decimal digits.
    pub n: Option<&'a [u8]>,
    /// Index into the sibling `batches` vec.
    pub batch: usize,
}

impl<'a> Candidate<'a> {
    /// match-text: `m` if present, else `w` (cli-protocol.md "候補レコード").
    pub fn match_text(&self) -> &'a [u8] {
        self.m.unwrap_or(self.w)
    }
}

/// Parsed stdin payload: batch headers and candidates in stream order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Parsed<'a> {
    pub batches: Vec<Batch<'a>>,
    pub candidates: Vec<Candidate<'a>>,
}

/// The only parse error (cli-protocol.md exit code 3): a non-empty stream
/// whose last byte is not NUL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FramingError;

/// Parse the full stdin buffer per cli-protocol.md. Exit-code mapping for
/// `FramingError` is plan.rs's job, not this module's.
pub(crate) fn parse(input: &[u8]) -> Result<Parsed<'_>, FramingError> {
    // NUL-terminated records: a non-empty stream must end with NUL, and
    // stripping it yields exactly the record list.
    let body = match input.last() {
        None => return Ok(Parsed::default()),
        Some(&REC_SEP) => &input[..input.len() - 1],
        Some(_) => return Err(FramingError),
    };

    let mut batches: Vec<Batch<'_>> = Vec::new();
    let mut candidates: Vec<Candidate<'_>> = Vec::new();
    // None until the first header is seen; candidate records before that
    // point are skipped (cli-protocol.md "スキップ規律").
    let mut current_batch: Option<usize> = None;

    for record in body.split(|&b| b == REC_SEP) {
        let mut fields = record.split(|&b| b == FIELD_SEP).map(split_field);
        // Splitting even an empty slice yields one (empty) element, so a
        // record always has a first field.
        let (tag0, val0) = fields.next().expect("record has >= 1 field");
        match tag0 {
            b"b" => {
                batches.push(parse_batch_fields(fields));
                current_batch = Some(batches.len() - 1);
            }
            // Candidate record: first field must be a non-empty `w`.
            b"w" if !val0.is_empty() => {
                let Some(batch) = current_batch else {
                    continue; // no header seen yet: skip
                };
                candidates.push(parse_candidate_fields(val0, fields, batch));
            }
            // First tag neither `b` nor a non-empty `w` (empty `w`, a
            // stray worker `pid` record, or an unknown tag): skip.
            _ => {}
        }
    }
    Ok(Parsed {
        batches,
        candidates,
    })
}

/// Split a `<tag>\1<value>` field. A field without the separator cannot
/// occur under the contract (framing-byte exclusion is the sender's
/// guarantee); read it as an empty-value tag rather than panicking.
fn split_field(field: &[u8]) -> (&[u8], &[u8]) {
    match field.iter().position(|&b| b == TAG_SEP) {
        Some(i) => (&field[..i], &field[i + 1..]),
        None => (field, b""),
    }
}

/// Fold a header record's remaining fields into a `Batch`: unknown tags
/// ignored, duplicate tags first-wins, empty value == absent.
fn parse_batch_fields<'a>(fields: impl Iterator<Item = (&'a [u8], &'a [u8])>) -> Batch<'a> {
    let mut p_vis = None;
    let mut p_hidden = None;
    let mut s_vis = None;
    let mut s_hidden = None;
    let mut i_vis = None;
    let mut i_hidden = None;
    let mut ip = None;
    let mut f = None;
    let mut rd = None;
    let mut x = None;
    let mut j = None;
    for (tag, val) in fields {
        let slot = match tag {
            b"P" => &mut p_vis,
            b"p" => &mut p_hidden,
            b"S" => &mut s_vis,
            b"s" => &mut s_hidden,
            b"i" => &mut i_vis,
            b"I" => &mut i_hidden,
            b"ip" => &mut ip,
            b"f" => &mut f,
            b"rd" => &mut rd,
            b"X" => &mut x,
            b"J" => &mut j,
            _ => continue, // unknown tag: ignored
        };
        if slot.is_none() {
            *slot = Some(val); // first occurrence wins
        }
    }
    let present = |v: Option<&'a [u8]>| v.filter(|s| !s.is_empty()).unwrap_or(b"");
    Batch {
        p_vis: present(p_vis),
        p_hidden: present(p_hidden),
        s_vis: present(s_vis),
        s_hidden: present(s_hidden),
        i_vis: present(i_vis),
        i_hidden: present(i_hidden),
        ip: present(ip),
        f: present(f),
        rd: present(rd),
        x: present(x),
        j: present(j),
    }
}

/// Fold a candidate record's remaining fields (after `w`) into `m`/`d`/`n`:
/// unknown tags (including a duplicate `w`) ignored, duplicate `m`/`d`/`n`
/// first-wins, empty value == absent.
fn parse_candidate_fields<'a>(
    w: &'a [u8],
    fields: impl Iterator<Item = (&'a [u8], &'a [u8])>,
    batch: usize,
) -> Candidate<'a> {
    let mut m_raw = None;
    let mut d_raw = None;
    let mut n_raw = None;
    for (tag, val) in fields {
        match tag {
            b"m" if m_raw.is_none() => m_raw = Some(val),
            b"d" if d_raw.is_none() => d_raw = Some(val),
            b"n" if n_raw.is_none() => n_raw = Some(val),
            _ => {} // unknown tag, or a later duplicate `w`/`m`/`d`/`n`
        }
    }
    Candidate {
        w,
        m: m_raw.filter(|v| !v.is_empty()),
        d: d_raw.filter(|v| !v.is_empty()),
        n: n_raw.filter(|v| !v.is_empty()),
        batch,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn parser_byte() -> impl Strategy<Value = u8> {
        prop_oneof![
            6 => prop::sample::select(vec![REC_SEP, TAG_SEP, FIELD_SEP]),
            6 => prop::sample::select(b"bwPpSsiIfrdXJmdn".to_vec()),
            1 => any::<u8>(),
        ]
    }

    fn arbitrary_parser_input() -> impl Strategy<Value = Vec<u8>> {
        let arbitrary = prop::collection::vec(any::<u8>(), 0..=256);
        let framing_heavy = prop::collection::vec(parser_byte(), 0..=256);
        let terminated = prop::collection::vec(parser_byte(), 0..256).prop_map(|mut bytes| {
            bytes.push(REC_SEP);
            bytes
        });
        prop_oneof![2 => arbitrary, 3 => framing_heavy, 5 => terminated]
    }

    // The signature already rules out any outcome but Ok / FramingError, so
    // asserting that alone would hold by typing. What is worth pinning over
    // arbitrary bytes is that no input panics, plus the two postconditions
    // plan.rs relies on when it indexes the result.
    proptest! {
        #[test]
        fn parse_is_total(input in arbitrary_parser_input()) {
            let Ok(parsed) = parse(&input) else { return Ok(()) };
            for cand in &parsed.candidates {
                prop_assert!(!cand.w.is_empty(), "candidate with empty w: {cand:?}");
                prop_assert!(
                    cand.batch < parsed.batches.len(),
                    "candidate batch index out of range: {cand:?}"
                );
            }
        }
    }

    /// Build a record from `\1`-joined tag/value pairs already `\2`-joined
    /// by the caller; this helper just appends the NUL terminator.
    fn payload(records: &[&[u8]]) -> Vec<u8> {
        let mut out = Vec::new();
        for r in records {
            out.extend_from_slice(r);
            out.push(0);
        }
        out
    }

    fn field(tag: &str, val: &str) -> Vec<u8> {
        let mut f = tag.as_bytes().to_vec();
        f.push(TAG_SEP);
        f.extend_from_slice(val.as_bytes());
        f
    }

    fn record(fields: &[Vec<u8>]) -> Vec<u8> {
        let mut out = Vec::new();
        for (i, f) in fields.iter().enumerate() {
            if i > 0 {
                out.push(FIELD_SEP);
            }
            out.extend_from_slice(f);
        }
        out
    }

    #[test]
    fn single_batch_multiple_candidates() {
        let header = record(&[field("b", ""), field("J", "cmds")]);
        let c1 = record(&[field("w", "git")]);
        let c2 = record(&[field("w", "grep")]);
        let refs: [&[u8]; 3] = [&header, &c1, &c2];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.batches.len(), 1);
        assert_eq!(parsed.batches[0].j, b"cmds");
        assert_eq!(parsed.candidates.len(), 2);
        assert_eq!(parsed.candidates[0].w, b"git");
        assert_eq!(parsed.candidates[0].batch, 0);
        assert_eq!(parsed.candidates[1].w, b"grep");
        assert_eq!(parsed.candidates[1].batch, 0);
    }

    #[test]
    fn match_text_prefers_m_falls_back_to_w() {
        let header = record(&[field("b", "")]);
        let with_m = record(&[field("w", "space\\ name.txt"), field("m", "space name.txt")]);
        let without_m = record(&[field("w", "plain.txt")]);
        let refs: [&[u8]; 3] = [&header, &with_m, &without_m];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.candidates[0].m, Some(&b"space name.txt"[..]));
        assert_eq!(parsed.candidates[0].match_text(), b"space name.txt");
        assert_eq!(parsed.candidates[1].m, None);
        assert_eq!(parsed.candidates[1].match_text(), b"plain.txt");
    }

    #[test]
    fn header_carries_every_shared_tag() {
        let header = record(&[
            field("b", ""),
            field("P", "p1"),
            field("p", "p2"),
            field("S", "s1"),
            field("s", "s2"),
            field("i", "i1"),
            field("I", "i2"),
            field("ip", "ipre"),
            field("f", "1"),
            field("rd", "/real"),
            field("X", "heading"),
            field("J", "group"),
        ]);
        let refs: [&[u8]; 1] = [&header];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        let b = &parsed.batches[0];
        assert_eq!(b.p_vis, b"p1");
        assert_eq!(b.p_hidden, b"p2");
        assert_eq!(b.s_vis, b"s1");
        assert_eq!(b.s_hidden, b"s2");
        assert_eq!(b.i_vis, b"i1");
        assert_eq!(b.i_hidden, b"i2");
        assert_eq!(b.ip, b"ipre");
        assert_eq!(b.f, b"1");
        assert_eq!(b.rd, b"/real");
        assert_eq!(b.x, b"heading");
        assert_eq!(b.j, b"group");
    }

    #[test]
    fn header_with_no_shared_tags() {
        let header = record(&[field("b", "")]);
        let refs: [&[u8]; 1] = [&header];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.batches.len(), 1);
        assert_eq!(parsed.batches[0], Batch::default());
    }

    #[test]
    fn multiple_batches_with_differing_shared_fields() {
        let h1 = record(&[field("b", ""), field("J", "g1"), field("X", "Group 1")]);
        let c1 = record(&[field("w", "a")]);
        let h2 = record(&[field("b", ""), field("J", "g2"), field("X", "Group 2")]);
        let c2 = record(&[field("w", "b")]);
        let refs: [&[u8]; 4] = [&h1, &c1, &h2, &c2];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.batches.len(), 2);
        assert_eq!(parsed.batches[0].j, b"g1");
        assert_eq!(parsed.batches[0].x, b"Group 1");
        assert_eq!(parsed.batches[1].j, b"g2");
        assert_eq!(parsed.batches[1].x, b"Group 2");
        assert_eq!(parsed.candidates[0].batch, 0);
        assert_eq!(parsed.candidates[1].batch, 1);
    }

    #[test]
    fn candidate_before_any_header_is_skipped() {
        let stray = record(&[field("w", "too-early")]);
        let header = record(&[field("b", "")]);
        let ok = record(&[field("w", "on-time")]);
        let refs: [&[u8]; 3] = [&stray, &header, &ok];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.candidates.len(), 1);
        assert_eq!(parsed.candidates[0].w, b"on-time");
    }

    #[test]
    fn worker_pid_record_is_skipped() {
        let header = record(&[field("b", "")]);
        let pid = record(&[field("pid", "12345")]);
        let ok = record(&[field("w", "cand")]);
        let refs: [&[u8]; 3] = [&header, &pid, &ok];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.batches.len(), 1);
        assert_eq!(parsed.candidates.len(), 1);
    }

    #[test]
    fn record_without_w_first_is_skipped() {
        let header = record(&[field("b", "")]);
        // `m` before `w` in field order: first field's tag isn't `w`.
        let bad = record(&[field("m", "text"), field("w", "word")]);
        let ok = record(&[field("w", "good")]);
        let refs: [&[u8]; 3] = [&header, &bad, &ok];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.candidates.len(), 1);
        assert_eq!(parsed.candidates[0].w, b"good");
    }

    #[test]
    fn empty_w_record_is_skipped() {
        let header = record(&[field("b", "")]);
        let empty_w = record(&[field("w", "")]);
        let ok = record(&[field("w", "ok")]);
        let refs: [&[u8]; 3] = [&header, &empty_w, &ok];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.candidates.len(), 1);
        assert_eq!(parsed.candidates[0].w, b"ok");
    }

    #[test]
    fn d_field_captured() {
        let header = record(&[field("b", "")]);
        let c = record(&[field("w", "word"), field("d", "display text")]);
        let refs: [&[u8]; 2] = [&header, &c];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.candidates[0].d, Some(&b"display text"[..]));
    }

    #[test]
    fn history_number_field_is_captured() {
        let header = record(&[field("b", "")]);
        let c = record(&[field("w", "echo hi"), field("n", "12345")]);
        let refs: [&[u8]; 2] = [&header, &c];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.candidates[0].n, Some(&b"12345"[..]));
    }

    #[test]
    fn empty_m_d_and_n_are_absent() {
        let header = record(&[field("b", "")]);
        let c = record(&[
            field("w", "word"),
            field("m", ""),
            field("d", ""),
            field("n", ""),
        ]);
        let refs: [&[u8]; 2] = [&header, &c];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.candidates[0].m, None);
        assert_eq!(parsed.candidates[0].d, None);
        assert_eq!(parsed.candidates[0].n, None);
        assert_eq!(parsed.candidates[0].match_text(), b"word");
    }

    #[test]
    fn duplicate_tag_first_wins() {
        let header = record(&[field("b", ""), field("J", "first"), field("J", "second")]);
        let c = record(&[
            field("w", "word"),
            field("m", "m1"),
            field("m", "m2"),
            field("n", "10"),
            field("n", "11"),
        ]);
        let refs: [&[u8]; 2] = [&header, &c];
        let input = payload(&refs);
        let parsed = parse(&input).unwrap();
        assert_eq!(parsed.batches[0].j, b"first");
        assert_eq!(parsed.candidates[0].m, Some(&b"m1"[..]));
        assert_eq!(parsed.candidates[0].n, Some(&b"10"[..]));
    }

    #[test]
    fn empty_payload_is_zero_batches_and_candidates() {
        let parsed = parse(&[]).unwrap();
        assert_eq!(parsed.batches.len(), 0);
        assert_eq!(parsed.candidates.len(), 0);
    }

    #[test]
    fn non_terminated_payload_is_framing_error() {
        let header = record(&[field("b", "")]);
        let mut input = header;
        // No trailing NUL appended (unlike `payload`).
        assert_eq!(parse(&input), Err(FramingError));
        // Sanity: same bytes plus a NUL do parse.
        input.push(0);
        assert!(parse(&input).is_ok());
    }
}
