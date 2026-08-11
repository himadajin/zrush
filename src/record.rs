//! Candidate-payload record parser and the parsed form the worker retains.
//!
//! Format and semantics: docs/internal/contracts/cli-protocol.md
//! ("`zrush worker`" -> 「`store` の `candidate_payload`」, source of truth).
//! NUL-terminated records; fields within a record are `\2`-joined
//! `<tag>\1<value>` pairs. Batch header records (first field tag `b`) carry
//! shared fields that apply to every candidate record up to the next header;
//! candidate records (first field tag `w`) carry per-candidate `w`/`m`/`d`/`n`.
//!
//! [`parse`] takes ownership of one payload and returns a [`Stored`] that
//! keeps those bytes: a `store` request parses once, and each later `plan`
//! reads [`Batch`] / [`Candidate`] views borrowing from the retained buffer.
//! plan.rs is the consumer.

const REC_SEP: u8 = 0; // \0: terminates a record
const FIELD_SEP: u8 = 2; // \2: joins fields within a record
const TAG_SEP: u8 = 1; // \1: separates a field's tag from its value

/// Byte range into a [`Stored`] buffer. Empty stands for "absent", matching
/// the contract's equivalence of an absent field and an empty value.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct ByteSpan {
    start: usize,
    end: usize,
}

impl ByteSpan {
    fn is_empty(self) -> bool {
        self.start == self.end
    }
}

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

/// A batch header's shared fields as ranges into the owning [`Stored`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct BatchSpans {
    p_vis: ByteSpan,
    p_hidden: ByteSpan,
    s_vis: ByteSpan,
    s_hidden: ByteSpan,
    i_vis: ByteSpan,
    i_hidden: ByteSpan,
    ip: ByteSpan,
    f: ByteSpan,
    rd: ByteSpan,
    x: ByteSpan,
    j: ByteSpan,
}

/// A candidate record's fields as ranges into the owning [`Stored`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CandidateSpans {
    w: ByteSpan,
    m: Option<ByteSpan>,
    d: Option<ByteSpan>,
    n: Option<ByteSpan>,
    batch: usize,
}

/// One parsed candidate payload, owning the bytes its views borrow: batch
/// headers and candidates in stream order.
#[derive(Debug)]
pub(crate) struct Stored {
    bytes: Vec<u8>,
    batches: Vec<BatchSpans>,
    candidates: Vec<CandidateSpans>,
}

impl Stored {
    fn slice(&self, span: ByteSpan) -> &[u8] {
        &self.bytes[span.start..span.end]
    }

    /// Batch headers in stream order; a [`Candidate`]'s `batch` indexes this.
    pub(crate) fn batches(&self) -> Vec<Batch<'_>> {
        self.batches
            .iter()
            .map(|spans| Batch {
                p_vis: self.slice(spans.p_vis),
                p_hidden: self.slice(spans.p_hidden),
                s_vis: self.slice(spans.s_vis),
                s_hidden: self.slice(spans.s_hidden),
                i_vis: self.slice(spans.i_vis),
                i_hidden: self.slice(spans.i_hidden),
                ip: self.slice(spans.ip),
                f: self.slice(spans.f),
                rd: self.slice(spans.rd),
                x: self.slice(spans.x),
                j: self.slice(spans.j),
            })
            .collect()
    }

    pub(crate) fn candidate_count(&self) -> usize {
        self.candidates.len()
    }

    pub(crate) fn candidate(&self, index: usize) -> Candidate<'_> {
        let spans = self.candidates[index];
        Candidate {
            w: self.slice(spans.w),
            m: spans.m.map(|span| self.slice(span)),
            d: spans.d.map(|span| self.slice(span)),
            n: spans.n.map(|span| self.slice(span)),
            batch: spans.batch,
        }
    }

    pub(crate) fn candidates(&self) -> impl ExactSizeIterator<Item = Candidate<'_>> {
        (0..self.candidate_count()).map(|index| self.candidate(index))
    }
}

/// The only parse error: a non-empty stream whose last byte is not NUL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FramingError;

/// Parse one complete candidate payload per cli-protocol.md, taking
/// ownership of it. Mapping a `FramingError` to the worker response, and
/// retaining the result per slot, belong to worker.rs.
pub(crate) fn parse(bytes: Vec<u8>) -> Result<Stored, FramingError> {
    // NUL-terminated records: a non-empty stream must end with NUL, and
    // stripping it yields exactly the record list.
    let body_len = match bytes.last() {
        None => 0,
        Some(&REC_SEP) => bytes.len() - 1,
        Some(_) => return Err(FramingError),
    };

    let mut batches: Vec<BatchSpans> = Vec::new();
    let mut candidates: Vec<CandidateSpans> = Vec::new();
    // None until the first header is seen; candidate records before that
    // point are skipped (cli-protocol.md "スキップ規律").
    let mut current_batch: Option<usize> = None;

    for (at, record) in split_spans(&bytes[..body_len], REC_SEP, 0) {
        let mut fields =
            split_spans(record, FIELD_SEP, at).map(|(at, field)| split_field(field, at));
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
    Ok(Stored {
        bytes,
        batches,
        candidates,
    })
}

/// Split `input` on `separator`, pairing every piece with its own offset in
/// the payload buffer; `base` is `input`'s offset there.
fn split_spans(input: &[u8], separator: u8, base: usize) -> impl Iterator<Item = (usize, &[u8])> {
    let mut at = base;
    input
        .split(move |&byte| byte == separator)
        .map(move |piece| {
            let start = at;
            at += piece.len() + 1; // the separator the split consumed
            (start, piece)
        })
}

/// Split a `<tag>\1<value>` field at offset `at`. A field without the
/// separator cannot occur under the contract (framing-byte exclusion is the
/// sender's guarantee); read it as an empty-value tag rather than panicking.
fn split_field(field: &[u8], at: usize) -> (&[u8], ByteSpan) {
    let end = at + field.len();
    match field.iter().position(|&b| b == TAG_SEP) {
        Some(i) => (
            &field[..i],
            ByteSpan {
                start: at + i + 1,
                end,
            },
        ),
        None => (field, ByteSpan { start: end, end }),
    }
}

/// Fold a header record's remaining fields into a `BatchSpans`: unknown tags
/// ignored, duplicate tags first-wins, empty value == absent.
fn parse_batch_fields<'a>(fields: impl Iterator<Item = (&'a [u8], ByteSpan)>) -> BatchSpans {
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
    // An absent tag and an empty value both read as the empty span.
    BatchSpans {
        p_vis: p_vis.unwrap_or_default(),
        p_hidden: p_hidden.unwrap_or_default(),
        s_vis: s_vis.unwrap_or_default(),
        s_hidden: s_hidden.unwrap_or_default(),
        i_vis: i_vis.unwrap_or_default(),
        i_hidden: i_hidden.unwrap_or_default(),
        ip: ip.unwrap_or_default(),
        f: f.unwrap_or_default(),
        rd: rd.unwrap_or_default(),
        x: x.unwrap_or_default(),
        j: j.unwrap_or_default(),
    }
}

/// Fold a candidate record's remaining fields (after `w`) into `m`/`d`/`n`:
/// unknown tags (including a duplicate `w`) ignored, duplicate `m`/`d`/`n`
/// first-wins, empty value == absent.
fn parse_candidate_fields<'a>(
    w: ByteSpan,
    fields: impl Iterator<Item = (&'a [u8], ByteSpan)>,
    batch: usize,
) -> CandidateSpans {
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
    CandidateSpans {
        w,
        m: m_raw.filter(|span| !span.is_empty()),
        d: d_raw.filter(|span| !span.is_empty()),
        n: n_raw.filter(|span| !span.is_empty()),
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
            let Ok(parsed) = parse(input) else { return Ok(()) };
            let batches = parsed.batches().len();
            for cand in parsed.candidates() {
                prop_assert!(!cand.w.is_empty(), "candidate with empty w: {cand:?}");
                prop_assert!(
                    cand.batch < batches,
                    "candidate batch index out of range: {cand:?}"
                );
            }
        }
    }

    /// Tag order of `BatchSpans` / [`Batch`], for indexing a generated
    /// header's shared values against the parsed views.
    const SHARED_TAGS: [&[u8]; 11] = [
        b"P", b"p", b"S", b"s", b"i", b"I", b"ip", b"f", b"rd", b"X", b"J",
    ];

    #[derive(Debug)]
    struct GeneratedCandidate {
        w: Vec<u8>,
        m: Option<Vec<u8>>,
        d: Option<Vec<u8>>,
        n: Option<Vec<u8>>,
    }

    #[derive(Debug)]
    struct GeneratedBatch {
        shared: Vec<Option<Vec<u8>>>,
        candidates: Vec<GeneratedCandidate>,
    }

    /// A value a conforming sender can emit: non-empty and free of the
    /// three framing bytes.
    fn generated_value() -> impl Strategy<Value = Vec<u8>> {
        prop::collection::vec(3u8..=u8::MAX, 1..=8)
    }

    fn generated_batches() -> impl Strategy<Value = Vec<GeneratedBatch>> {
        let candidate = (
            generated_value(),
            prop::option::of(generated_value()),
            prop::option::of(generated_value()),
            prop::option::of(generated_value()),
        )
            .prop_map(|(w, m, d, n)| GeneratedCandidate { w, m, d, n });
        let batch = (
            prop::collection::vec(prop::option::of(generated_value()), SHARED_TAGS.len()),
            prop::collection::vec(candidate, 0..=4),
        )
            .prop_map(|(shared, candidates)| GeneratedBatch { shared, candidates });
        prop::collection::vec(batch, 0..=3)
    }

    fn generated_payload(batches: &[GeneratedBatch]) -> Vec<u8> {
        let mut out = Vec::new();
        for batch in batches {
            out.extend_from_slice(b"b");
            out.push(TAG_SEP);
            for (tag, value) in SHARED_TAGS.iter().zip(&batch.shared) {
                if let Some(value) = value {
                    push_field(&mut out, tag, value);
                }
            }
            out.push(REC_SEP);
            for candidate in &batch.candidates {
                out.extend_from_slice(b"w");
                out.push(TAG_SEP);
                out.extend_from_slice(&candidate.w);
                for (tag, value) in [
                    (b"m".as_slice(), &candidate.m),
                    (b"d".as_slice(), &candidate.d),
                    (b"n".as_slice(), &candidate.n),
                ] {
                    if let Some(value) = value {
                        push_field(&mut out, tag, value);
                    }
                }
                out.push(REC_SEP);
            }
        }
        out
    }

    fn push_field(out: &mut Vec<u8>, tag: &[u8], value: &[u8]) {
        out.push(FIELD_SEP);
        out.extend_from_slice(tag);
        out.push(TAG_SEP);
        out.extend_from_slice(value);
    }

    // Every view is a range into the retained buffer, so a span that drifts
    // still yields *some* byte string. Only comparing against the values the
    // payload was built from ties a span to the field it claims to be.
    proptest! {
        #[test]
        fn spans_recover_the_values_the_payload_was_built_from(
            batches in generated_batches(),
        ) {
            let parsed = parse(generated_payload(&batches)).unwrap();
            let views = parsed.batches();
            prop_assert_eq!(views.len(), batches.len());

            let mut index = 0;
            for (batch_index, (spec, view)) in batches.iter().zip(&views).enumerate() {
                let shared: [&[u8]; SHARED_TAGS.len()] = [
                    view.p_vis, view.p_hidden, view.s_vis, view.s_hidden,
                    view.i_vis, view.i_hidden, view.ip, view.f,
                    view.rd, view.x, view.j,
                ];
                for ((tag, expected), actual) in SHARED_TAGS.iter().zip(&spec.shared).zip(shared) {
                    let expected: &[u8] = expected.as_deref().unwrap_or(b"");
                    prop_assert_eq!(actual, expected, "batch {} tag {:?}", batch_index, tag);
                }

                for expected in &spec.candidates {
                    let candidate = parsed.candidate(index);
                    prop_assert_eq!(candidate.w, &expected.w[..]);
                    prop_assert_eq!(candidate.m, expected.m.as_deref());
                    prop_assert_eq!(candidate.d, expected.d.as_deref());
                    prop_assert_eq!(candidate.n, expected.n.as_deref());
                    prop_assert_eq!(candidate.batch, batch_index);
                    index += 1;
                }
            }
            prop_assert_eq!(parsed.candidate_count(), index);
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
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.batches().len(), 1);
        assert_eq!(parsed.batches()[0].j, b"cmds");
        assert_eq!(parsed.candidate_count(), 2);
        assert_eq!(parsed.candidate(0).w, b"git");
        assert_eq!(parsed.candidate(0).batch, 0);
        assert_eq!(parsed.candidate(1).w, b"grep");
        assert_eq!(parsed.candidate(1).batch, 0);
    }

    #[test]
    fn match_text_prefers_m_falls_back_to_w() {
        let header = record(&[field("b", "")]);
        let with_m = record(&[field("w", "space\\ name.txt"), field("m", "space name.txt")]);
        let without_m = record(&[field("w", "plain.txt")]);
        let refs: [&[u8]; 3] = [&header, &with_m, &without_m];
        let input = payload(&refs);
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.candidate(0).m, Some(&b"space name.txt"[..]));
        assert_eq!(parsed.candidate(0).match_text(), b"space name.txt");
        assert_eq!(parsed.candidate(1).m, None);
        assert_eq!(parsed.candidate(1).match_text(), b"plain.txt");
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
        let parsed = parse(input).unwrap();
        let b = parsed.batches()[0];
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
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.batches().len(), 1);
        assert_eq!(parsed.batches()[0], Batch::default());
    }

    #[test]
    fn multiple_batches_with_differing_shared_fields() {
        let h1 = record(&[field("b", ""), field("J", "g1"), field("X", "Group 1")]);
        let c1 = record(&[field("w", "a")]);
        let h2 = record(&[field("b", ""), field("J", "g2"), field("X", "Group 2")]);
        let c2 = record(&[field("w", "b")]);
        let refs: [&[u8]; 4] = [&h1, &c1, &h2, &c2];
        let input = payload(&refs);
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.batches().len(), 2);
        assert_eq!(parsed.batches()[0].j, b"g1");
        assert_eq!(parsed.batches()[0].x, b"Group 1");
        assert_eq!(parsed.batches()[1].j, b"g2");
        assert_eq!(parsed.batches()[1].x, b"Group 2");
        assert_eq!(parsed.candidate(0).batch, 0);
        assert_eq!(parsed.candidate(1).batch, 1);
    }

    #[test]
    fn candidate_before_any_header_is_skipped() {
        let stray = record(&[field("w", "too-early")]);
        let header = record(&[field("b", "")]);
        let ok = record(&[field("w", "on-time")]);
        let refs: [&[u8]; 3] = [&stray, &header, &ok];
        let input = payload(&refs);
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.candidate_count(), 1);
        assert_eq!(parsed.candidate(0).w, b"on-time");
    }

    #[test]
    fn worker_pid_record_is_skipped() {
        let header = record(&[field("b", "")]);
        let pid = record(&[field("pid", "12345")]);
        let ok = record(&[field("w", "cand")]);
        let refs: [&[u8]; 3] = [&header, &pid, &ok];
        let input = payload(&refs);
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.batches().len(), 1);
        assert_eq!(parsed.candidate_count(), 1);
    }

    #[test]
    fn record_without_w_first_is_skipped() {
        let header = record(&[field("b", "")]);
        // `m` before `w` in field order: first field's tag isn't `w`.
        let bad = record(&[field("m", "text"), field("w", "word")]);
        let ok = record(&[field("w", "good")]);
        let refs: [&[u8]; 3] = [&header, &bad, &ok];
        let input = payload(&refs);
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.candidate_count(), 1);
        assert_eq!(parsed.candidate(0).w, b"good");
    }

    #[test]
    fn empty_w_record_is_skipped() {
        let header = record(&[field("b", "")]);
        let empty_w = record(&[field("w", "")]);
        let ok = record(&[field("w", "ok")]);
        let refs: [&[u8]; 3] = [&header, &empty_w, &ok];
        let input = payload(&refs);
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.candidate_count(), 1);
        assert_eq!(parsed.candidate(0).w, b"ok");
    }

    #[test]
    fn d_field_captured() {
        let header = record(&[field("b", "")]);
        let c = record(&[field("w", "word"), field("d", "display text")]);
        let refs: [&[u8]; 2] = [&header, &c];
        let input = payload(&refs);
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.candidate(0).d, Some(&b"display text"[..]));
    }

    #[test]
    fn history_number_field_is_captured() {
        let header = record(&[field("b", "")]);
        let c = record(&[field("w", "echo hi"), field("n", "12345")]);
        let refs: [&[u8]; 2] = [&header, &c];
        let input = payload(&refs);
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.candidate(0).n, Some(&b"12345"[..]));
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
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.candidate(0).m, None);
        assert_eq!(parsed.candidate(0).d, None);
        assert_eq!(parsed.candidate(0).n, None);
        assert_eq!(parsed.candidate(0).match_text(), b"word");
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
        let parsed = parse(input).unwrap();
        assert_eq!(parsed.batches()[0].j, b"first");
        assert_eq!(parsed.candidate(0).m, Some(&b"m1"[..]));
        assert_eq!(parsed.candidate(0).n, Some(&b"10"[..]));
    }

    #[test]
    fn empty_payload_is_zero_batches_and_candidates() {
        let parsed = parse(Vec::new()).unwrap();
        assert_eq!(parsed.batches().len(), 0);
        assert_eq!(parsed.candidate_count(), 0);
    }

    #[test]
    fn non_terminated_payload_is_framing_error() {
        let header = record(&[field("b", "")]);
        let mut input = header;
        // No trailing NUL appended (unlike `payload`).
        assert_eq!(parse(input.clone()).err(), Some(FramingError));
        // Sanity: same bytes plus a NUL do parse.
        input.push(0);
        assert!(parse(input).is_ok());
    }
}
