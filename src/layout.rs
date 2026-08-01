//! Grid layout, highlight, and navigation engine for `zrush plan`.
//!
//! Semantics: docs/internal/contracts/cli-protocol.md "stdout(描画プラン)",
//! specifically "表示行の中身" (grouping/grid), "オフセット規律"
//! (char-count vs display-width split), "ハイライト", and "ナビ". This
//! module owns grouping, the column-major grid, cell truncation/padding,
//! and every offset computed against the listing text; it does not know
//! about matching -- match spans (char offsets over a candidate's
//! match-text, from matching::QueryMatcher::spans) are supplied by the
//! caller and only get clipped/repositioned here.
//!
//! Mixing char counts and display widths is a recurring source of offset
//! bugs, which is why the contract spells out the split explicitly:
//! highlight/cell-range `start`/`len` are always char counts over the
//! lossy-UTF-8 reading of the listing text, while cell padding/truncation
//! is always display width (unicode-width). The two are computed from the
//! same lossy decoding pass (`lossy_chars`) so they can never drift apart
//! here.

use std::borrow::Cow;
use std::ops::Range;

use unicode_width::UnicodeWidthChar;

use crate::record::{Batch, Candidate};

/// Column cap and gutter width: Rust-internal constants, not part of the
/// protocol (cli-protocol.md "列数").
const MAX_COLS: usize = 8;
const GUTTER: usize = 2;

/// Highlight role (cli-protocol.md "ハイライト"). `heading` entries carry
/// `pos == 0`; `match` entries carry the position they belong to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Role {
    Match,
    Heading,
}

impl Role {
    /// The stdout wire token (cli-protocol.md "role ∈ match | heading").
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Match => "match",
            Role::Heading => "heading",
        }
    }
}

/// One "role pos start len" stdout entry. `start`/`len` are char offsets
/// over the full listing text (rows joined by `\n`, no leading newline).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Highlight {
    pub role: Role,
    pub pos: usize,
    pub start: usize,
    pub len: usize,
}

/// One "next prev left right" stdout entry, absolute position numbers
/// (0 = unselected). cli-protocol.md "ナビ".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct Nav {
    pub next: usize,
    pub prev: usize,
    pub left: usize,
    pub right: usize,
}

/// The rendered plan: display rows plus, for each of the `P` selectable
/// positions (1-indexed; `positions[p - 1]` etc.), its source candidate,
/// cell range, and navigation entry.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Plan {
    /// L display rows (no trailing/embedded newline per row).
    pub rows: Vec<Vec<u8>>,
    /// H highlight entries.
    pub highlights: Vec<Highlight>,
    /// P entries: (start, len) char range of the position's real (post-
    /// truncation, pre-padding) cell text within the listing text.
    pub cell_ranges: Vec<(usize, usize)>,
    /// P entries: navigation targets.
    pub nav: Vec<Nav>,
    /// P entries: index into the `candidates` slice passed to `build`,
    /// for plan.rs's insertion-text lookup.
    pub positions: Vec<usize>,
}

/// Build the render plan for a ranked candidate list.
///
/// `candidates` must already be in rank order (matching.rs + ranking.rs);
/// this module does not re-sort. `spans[i]` are `matching::QueryMatcher::
/// spans()`'s (start, end) 0-based end-exclusive char ranges (NOT
/// (start, len)) over `candidates[i].match_text()`, aligned by index; a
/// missing or empty entry means no match decoration for that candidate.
/// `row_budget`/`width` are `--rows`/`--width` (cli-protocol.md
/// "起動"), assumed >= 1 by the caller but handled gracefully at 0 too.
pub(crate) fn build(
    candidates: &[Candidate<'_>],
    batches: &[Batch<'_>],
    spans: &[Vec<(usize, usize)>],
    row_budget: usize,
    width: usize,
) -> Plan {
    // --- Group candidates by key, in first-occurrence order (contract:
    // "グループの割り当ては候補の初出現順による"). A group's own row
    // order is the incoming (rank) order restricted to its members.
    struct Group<'a> {
        key: &'a [u8],
        heading: &'a [u8], // meaningless when key.is_empty()
        members: Vec<usize>,
    }
    // Ordered groups plus a key -> index lookup, kept in sync: the Vec
    // preserves first-occurrence display order, the map turns "does this
    // key already have a group" from an O(groups) scan into O(1)
    // (audit: linear scan measured 67ms at 30k all-unique-key candidates).
    let mut groups: Vec<Group<'_>> = Vec::new();
    let mut group_index: std::collections::HashMap<&[u8], usize> = std::collections::HashMap::new();
    for (idx, cand) in candidates.iter().enumerate() {
        let batch = &batches[cand.batch];
        let key = group_key(batch);
        if let Some(&gi) = group_index.get(key) {
            groups[gi].members.push(idx);
        } else {
            let heading = if key.is_empty() {
                &b""[..]
            } else {
                heading_text(batch)
            };
            group_index.insert(key, groups.len());
            groups.push(Group {
                key,
                heading,
                members: vec![idx],
            });
        }
    }

    // Per-candidate cell source text (contract "セルの表示テキストの決定
    // 規則": `d` if present, else match-text), newline-normalized. Built
    // for every candidate up front because gmaxw is defined over a
    // group's *full* membership, not just what ends up displayed.
    let sources: Vec<Cow<'_, [u8]>> = candidates
        .iter()
        .map(|c| normalize_newlines(c.d.unwrap_or(c.match_text())))
        .collect();

    let mut rows: Vec<Vec<u8>> = Vec::new();
    let mut row_lens: Vec<usize> = Vec::new(); // char length per row, parallel to `rows`
    struct HeadingMark {
        row: usize,
        len: usize,
    }
    struct CellMark {
        row: usize,
        in_row_start: usize,
        content_chars: usize,
        candidate: usize,
        pos: usize,
    }
    let mut heading_marks: Vec<HeadingMark> = Vec::new();
    let mut cell_marks: Vec<CellMark> = Vec::new();
    // Per-position group bounds, filled as groups are placed; used by
    // the nav pass below (left/right are group-clamped).
    let mut pos_group_start: Vec<usize> = Vec::new();
    let mut pos_group_end: Vec<usize> = Vec::new();
    let mut pos_group_grows: Vec<usize> = Vec::new();
    let mut positions: Vec<usize> = Vec::new();

    let mut remaining = row_budget;
    for (group_idx, group) in groups.iter().enumerate() {
        if remaining == 0 {
            break; // budget exhausted: this and every later group is dropped
        }
        let wants_heading = !group.key.is_empty();
        let required = if wants_heading { 2 } else { 1 };
        let show_heading = if remaining >= required {
            wants_heading
        } else if group_idx == 0 && wants_heading && remaining >= 1 {
            // Contract exception: only the *first* group may show its
            // candidates without a heading when the budget can't fit both.
            false
        } else {
            break; // can't fit this group (heading or not): drop it and stop
        };
        let candidate_budget = if show_heading {
            remaining - 1
        } else {
            remaining
        };

        // gmaxw = max(1, min(width, max member display width)) over the
        // group's *full* membership (cli-protocol.md "セル幅").
        let max_member_width = group
            .members
            .iter()
            .map(|&i| display_width(&sources[i]))
            .max()
            .unwrap_or(1);
        let gmaxw = group_gmaxw(width, max_member_width);
        let (cols, grows, gcount) = grid_dims(gmaxw, width, group.members.len(), candidate_budget);

        if show_heading {
            let heading = normalize_newlines(group.heading);
            // Same truncation rule as cells (cli-protocol.md "見出し
            // テキストが width を超える場合"): max original-byte prefix
            // whose lossy display width fits `width`.
            let (content, _w, chars) = truncate_to_width(&heading, width);
            let row = rows.len();
            rows.push(content.to_vec());
            row_lens.push(chars);
            heading_marks.push(HeadingMark { row, len: chars });
        }

        let start_pos = positions.len() + 1;
        let members_shown = &group.members[..gcount];
        // Position numbers are assigned by rank within the group (1..=
        // gcount), independent of which (row, col) grid cell a position
        // ends up rendered in -- `members_shown[p_local - 1]` (used below
        // to resolve each cell's candidate) already *is* that mapping, so
        // `positions` is exactly `members_shown`, built once here rather
        // than by pushing inside the render loop below. That loop visits
        // cells in (row, col) scan order, e.g. p_local = 1, 1+grows,
        // 1+2*grows, ..., 2, 2+grows, ... whenever grows > 1 and cols > 1
        // -- not in increasing position order -- so a push there would
        // (and did) desync `positions` from `cell_ranges`/`nav`, which
        // are always written or read by position index.
        positions.extend_from_slice(members_shown);
        for r in 1..=grows {
            let mut row_bytes: Vec<u8> = Vec::new();
            let mut in_row = 0usize;
            for c in 1..=cols {
                let p_local = (c - 1) * grows + r;
                if p_local > gcount {
                    break; // column-major fill: later columns are empty too
                }
                if c > 1 {
                    row_bytes.extend_from_slice(b"  ");
                    in_row += GUTTER;
                }
                let cell_start = in_row;
                let cand_idx = members_shown[p_local - 1];
                let (content, cwidth, cchars) = truncate_to_width(&sources[cand_idx], gmaxw);
                row_bytes.extend_from_slice(content);
                let pad = gmaxw - cwidth;
                row_bytes.resize(row_bytes.len() + pad, b' ');
                in_row += cchars + pad;
                let pos = start_pos + p_local - 1;
                cell_marks.push(CellMark {
                    row: rows.len(),
                    in_row_start: cell_start,
                    content_chars: cchars,
                    candidate: cand_idx,
                    pos,
                });
            }
            row_lens.push(in_row);
            rows.push(row_bytes);
        }
        let end_pos = positions.len();
        for _ in start_pos..=end_pos {
            pos_group_start.push(start_pos);
            pos_group_end.push(end_pos);
            pos_group_grows.push(grows);
        }

        remaining -= grows + usize::from(show_heading);
    }

    // --- Second pass: char offsets are only knowable once every row's
    // char length is final (contract: offsets run over the *whole*
    // concatenated listing text, not per row).
    let mut row_start: Vec<usize> = Vec::with_capacity(rows.len());
    let mut acc = 0usize;
    for &len in &row_lens {
        row_start.push(acc);
        acc += len + 1; // +1 for the `\n` joining this row to the next
    }

    let mut highlights: Vec<Highlight> = Vec::new();
    for h in &heading_marks {
        if h.len > 0 {
            highlights.push(Highlight {
                role: Role::Heading,
                pos: 0,
                start: row_start[h.row],
                len: h.len,
            });
        }
    }
    let mut cell_ranges = vec![(0usize, 0usize); positions.len()];
    for cm in &cell_marks {
        let start = row_start[cm.row] + cm.in_row_start;
        cell_ranges[cm.pos - 1] = (start, cm.content_chars);
        // Match decoration only on cells showing match-text verbatim
        // (contract: "display-text 表示セルには発行されない").
        if candidates[cm.candidate].d.is_none()
            && let Some(cand_spans) = spans.get(cm.candidate)
        {
            // matching.rs `spans()`: (start, end), 0-based end-exclusive
            // char range -- NOT (start, len). Clip both ends to the
            // truncated cell's char count.
            for &(s, e) in cand_spans {
                let cs = s.min(cm.content_chars);
                let ce = e.min(cm.content_chars);
                if ce > cs {
                    highlights.push(Highlight {
                        role: Role::Match,
                        pos: cm.pos,
                        start: start + cs,
                        len: ce - cs,
                    });
                }
            }
        }
    }

    let p = positions.len();
    let mut nav = Vec::with_capacity(p);
    for pos in 1..=p {
        let next = if pos == p { pos } else { pos + 1 };
        let prev = if pos == 1 { 0 } else { pos - 1 };
        let grows = pos_group_grows[pos - 1];
        let left = pos_group_start[pos - 1].max(pos.saturating_sub(grows));
        let right = pos_group_end[pos - 1].min(pos + grows);
        nav.push(Nav {
            next,
            prev,
            left,
            right,
        });
    }

    Plan {
        rows,
        highlights,
        cell_ranges,
        nav,
        positions,
    }
}

/// Group key resolution (cli-protocol.md "グループ分割"): `J` takes
/// priority over `X`; `J == "-default-"` (compsys's default group name)
/// reads as no key. Empty key means "no group / no heading".
fn group_key<'a>(batch: &Batch<'a>) -> &'a [u8] {
    if !batch.j.is_empty() {
        if batch.j == b"-default-" {
            b""
        } else {
            batch.j
        }
    } else {
        batch.x
    }
}

/// Heading text resolution (cli-protocol.md "見出しテキスト"): the
/// opposite priority from `group_key` -- `X` first, falling back to `J`.
/// Only meaningful when the group's key (from the same batch) is
/// non-empty; callers must not call this for an empty-key group.
fn heading_text<'a>(batch: &Batch<'a>) -> &'a [u8] {
    if !batch.x.is_empty() {
        batch.x
    } else {
        batch.j
    }
}

/// `gmaxw` per the contract's "max(1, min(width, ...))" formula, given
/// the (already width-unbounded) max member display width.
fn group_gmaxw(width: usize, max_member_width: usize) -> usize {
    max_member_width.min(width).max(1)
}

/// Grid dimensions for one group (cli-protocol.md "列数"/"行数"):
/// `cols = clamp(floor((width+2)/(gmaxw+2)), 1, 8)`,
/// `grows = ceil(members/cols)` clamped to the row budget,
/// `gcount = min(cols*grows, members)`,
/// then `cols` is recompressed to `ceil(gcount/grows)` so a shrunken
/// `grows` never leaves trailing empty columns.
///
/// Preconditions (upheld by `build`'s budget bookkeeping, not re-checked
/// here): `members >= 1` and `budget >= 1` -- a zero budget must never
/// reach this function (it means the group is dropped before grid math).
fn grid_dims(gmaxw: usize, width: usize, members: usize, budget: usize) -> (usize, usize, usize) {
    // Saturating: `width`/`gmaxw` come from caller-controlled CLI args
    // and candidate byte lengths respectively, so `+2` must not wrap at
    // usize::MAX (a wrap would corrupt the column count silently instead
    // of just saturating to a large-but-sane value).
    let cols = (width.saturating_add(2) / gmaxw.saturating_add(2)).clamp(1, MAX_COLS);
    let grows = members.div_ceil(cols).min(budget);
    let gcount = cols.saturating_mul(grows).min(members);
    let cols = gcount.div_ceil(grows);
    (cols, grows, gcount)
}

/// Replace `\n` with a space (cli-protocol.md: newline -> space, applied
/// to both candidate cell text and heading text). Zero-copy when there is
/// nothing to replace.
fn normalize_newlines(bytes: &[u8]) -> Cow<'_, [u8]> {
    if bytes.contains(&b'\n') {
        Cow::Owned(
            bytes
                .iter()
                .map(|&b| if b == b'\n' { b' ' } else { b })
                .collect(),
        )
    } else {
        Cow::Borrowed(bytes)
    }
}

/// Lossy-UTF-8 reading of `bytes` as `(char, source byte range)` pairs,
/// reproducing `String::from_utf8_lossy`'s maximal-subpart substitution
/// exactly (each invalid maximal subsequence becomes one `U+FFFD`) so
/// that byte offsets derived from it are valid `String::from_utf8_lossy`
/// char-boundary cuts. matching.rs's span offsets are indices into this
/// same standard lossy decoding, so no extra alignment is needed here.
///
/// O(n) overall: `str::from_utf8` is called once per maximal valid/
/// invalid run (not once per character -- a naive per-char
/// `from_utf8(rest)` call re-validates the whole remainder every step,
/// which is O(n^2) on long inputs; audit measurement: 383ms at 200KB).
/// Once a run validates, its chars are popped off the front of the
/// already-known-good `&str` in O(1) each via `chars().next()`.
fn lossy_chars(bytes: &[u8]) -> LossyChars<'_> {
    LossyChars {
        rest: bytes,
        rest_offset: 0,
        valid: "",
        valid_offset: 0,
    }
}

struct LossyChars<'a> {
    /// Bytes not yet scanned for validity.
    rest: &'a [u8],
    /// Absolute offset (into the original input) of `rest`'s first byte.
    rest_offset: usize,
    /// A validated run not yet fully consumed; chars are popped from its
    /// front without re-validating.
    valid: &'a str,
    /// Absolute offset of `valid`'s first byte.
    valid_offset: usize,
}

impl Iterator for LossyChars<'_> {
    type Item = (char, Range<usize>);

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            if let Some(c) = self.valid.chars().next() {
                let len = c.len_utf8();
                let start = self.valid_offset;
                self.valid = &self.valid[len..];
                self.valid_offset += len;
                return Some((c, start..start + len));
            }
            if self.rest.is_empty() {
                return None;
            }
            // `valid` exhausted: scan `rest` once for the next maximal
            // valid run, or -- if it starts with invalid bytes -- consume
            // one maximal invalid subsequence as a single U+FFFD.
            match std::str::from_utf8(self.rest) {
                Ok(s) => {
                    self.valid = s;
                    self.valid_offset = self.rest_offset;
                    self.rest_offset += self.rest.len();
                    self.rest = &[];
                }
                Err(e) if e.valid_up_to() > 0 => {
                    let (good, bad) = self.rest.split_at(e.valid_up_to());
                    self.valid = std::str::from_utf8(good).unwrap();
                    self.valid_offset = self.rest_offset;
                    self.rest_offset += good.len();
                    self.rest = bad;
                }
                // Invalid subsequence right at the start: `error_len()`
                // bytes (or the whole remainder, if merely incomplete)
                // become one U+FFFD, matching from_utf8_lossy's
                // maximal-subpart rule.
                Err(e) => {
                    let bad_len = e.error_len().unwrap_or(self.rest.len());
                    let start = self.rest_offset;
                    self.rest = &self.rest[bad_len..];
                    self.rest_offset += bad_len;
                    return Some(('\u{FFFD}', start..start + bad_len));
                }
            }
        }
    }
}

/// Full lossy display width of `bytes` (no truncation). Control chars
/// (including a stray `\r`) have no assigned width and count as 0.
fn display_width(bytes: &[u8]) -> usize {
    lossy_chars(bytes)
        .map(|(c, _)| UnicodeWidthChar::width(c).unwrap_or(0))
        .sum()
}

/// Truncate `bytes` to the maximal original-byte prefix whose lossy
/// display width fits `budget` (cli-protocol.md "切り詰め"). Returns
/// `(prefix, prefix's display width, prefix's char count)`; the returned
/// slice is always a subslice of `bytes` (no re-encoding).
fn truncate_to_width(bytes: &[u8], budget: usize) -> (&[u8], usize, usize) {
    let mut width = 0usize;
    let mut chars = 0usize;
    let mut cut = 0usize;
    for (c, range) in lossy_chars(bytes) {
        let w = UnicodeWidthChar::width(c).unwrap_or(0);
        if width + w > budget {
            break;
        }
        width += w;
        chars += 1;
        cut = range.end;
    }
    (&bytes[..cut], width, chars)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand<'a>(
        w: &'a [u8],
        m: Option<&'a [u8]>,
        d: Option<&'a [u8]>,
        batch: usize,
    ) -> Candidate<'a> {
        Candidate { w, m, d, batch }
    }

    fn batch(j: &'static [u8], x: &'static [u8]) -> Batch<'static> {
        Batch {
            j,
            x,
            ..Batch::default()
        }
    }

    // ---- pure formula tests (pin the contract's arithmetic directly) ----

    #[test]
    fn grid_dims_basic_formula() {
        // width=20, gmaxw=4: cols = floor(22/6) = 3.
        assert_eq!(grid_dims(4, 20, 9, 100), (3, 3, 9));
        // members < capacity: grows shrinks via ceil, cols recompresses
        // so no empty trailing columns (2 members, cap would be 3 cols).
        assert_eq!(grid_dims(4, 20, 2, 100), (2, 1, 2));
    }

    #[test]
    fn grid_dims_clamps_cols_to_eight() {
        // Tiny cells, huge width: floor((100+2)/(1+2)) = 34, clamped to 8.
        assert_eq!(grid_dims(1, 100, 64, 100), (8, 8, 64));
    }

    #[test]
    fn grid_dims_row_budget_clamps_grows_and_gcount() {
        // width=10, gmaxw=4: cols = floor(12/6) = 2 capacity, but only 1
        // row of budget: grows=1, gcount = min(2*1, 10) = 2, cols
        // recompresses to ceil(2/1)=2.
        assert_eq!(grid_dims(4, 10, 10, 1), (2, 1, 2));
    }

    #[test]
    fn grid_dims_single_wide_candidate_forces_single_column() {
        // gmaxw already clamped to width elsewhere; here gmaxw==width
        // directly forces cols=1 (floor((w+2)/(w+2))=1).
        assert_eq!(grid_dims(20, 20, 1, 100), (1, 1, 1));
    }

    #[test]
    fn grid_dims_does_not_overflow_at_usize_max() {
        // width/gmaxw at usize::MAX must saturate the `+2`, not wrap
        // around to a tiny (or panicking, in debug builds) value.
        let (cols, grows, gcount) = grid_dims(usize::MAX, usize::MAX, 5, 100);
        assert_eq!((cols, grows, gcount), (1, 5, 5));
    }

    fn spans_none(n: usize) -> Vec<Vec<(usize, usize)>> {
        vec![Vec::new(); n]
    }

    // ---- grouping ----

    #[test]
    fn default_default_group_name_has_no_key_or_heading() {
        let batches = [batch(b"-default-", b"")];
        let cands = [cand(b"git", None, None, 0), cand(b"grep", None, None, 0)];
        let plan = build(&cands, &batches, &spans_none(2), 10, 40);
        assert_eq!(plan.rows.len(), 1); // single row, no heading row
        assert!(plan.highlights.iter().all(|h| h.role != Role::Heading));
    }

    #[test]
    fn empty_group_key_candidates_form_one_headingless_bucket() {
        // batch0: no J/X (ungrouped); batch1: named group "cmds"/"Cmds";
        // interleaved in rank order to exercise first-occurrence bucketing.
        let batches = [batch(b"", b""), batch(b"cmds", b"Cmds")];
        let cands = [
            cand(b"a", None, None, 0), // ungrouped, establishes the bucket
            cand(b"b", None, None, 1), // group "cmds"
            cand(b"c", None, None, 0), // ungrouped again, joins first bucket
        ];
        let plan = build(&cands, &batches, &spans_none(3), 10, 40);
        // 1 headed group (2 rows: heading+1) + 1 headingless row = 3 rows.
        assert_eq!(plan.rows.len(), 3);
        let headings: Vec<_> = plan
            .highlights
            .iter()
            .filter(|h| h.role == Role::Heading)
            .collect();
        assert_eq!(headings.len(), 1);
    }

    #[test]
    fn heading_prefers_x_falls_back_to_j() {
        let batches = [batch(b"g1", b""), batch(b"", b"Heading Text")];
        let cands = [cand(b"a", None, None, 0), cand(b"b", None, None, 1)];
        let plan = build(&cands, &batches, &spans_none(2), 10, 40);
        // group 0: heading = J ("g1"); group 1: heading = X ("Heading Text").
        assert_eq!(plan.rows[0], b"g1");
        // rows: [heading g1, row a, heading "Heading Text", row b]
        assert_eq!(plan.rows[2], b"Heading Text");
    }

    #[test]
    fn heading_wider_than_width_is_truncated_on_a_wide_char_boundary() {
        // 7 CJK chars, display width 14 (2 per char); width budget 5
        // only fits 2 full chars (width 4) -- the 3rd would overflow to 6.
        let heading = "見出しテキスト";
        let batches = [batch(b"g", heading.as_bytes())];
        let cands = [cand(b"x", None, None, 0)];
        let plan = build(&cands, &batches, &spans_none(1), 10, 5);
        let want: String = heading.chars().take(2).collect();
        assert_eq!(plan.rows[0], want.as_bytes());
        let h = plan
            .highlights
            .iter()
            .find(|h| h.role == Role::Heading)
            .unwrap();
        // Offset is char count (2), not display width (4) -- same
        // char/width split as cell offsets.
        assert_eq!((h.start, h.len), (0, 2));
    }

    // ---- budget: heading omission and group drop ----

    #[test]
    fn first_group_omits_heading_when_budget_is_one() {
        let batches = [batch(b"g1", b"")];
        let cands = [cand(b"a", None, None, 0)];
        let plan = build(&cands, &batches, &spans_none(1), 1, 40);
        assert_eq!(plan.rows.len(), 1); // heading dropped, candidate kept
        assert_eq!(plan.rows[0], b"a");
        assert!(plan.highlights.iter().all(|h| h.role != Role::Heading));
    }

    #[test]
    fn later_group_is_dropped_wholesale_when_budget_insufficient() {
        let batches = [batch(b"g1", b""), batch(b"g2", b"")];
        let cands = [cand(b"a", None, None, 0), cand(b"b", None, None, 1)];
        // budget 2: group 1 takes heading(1)+row(1) = 2, leaving 0 for
        // group 2 (which would need 2 for its own heading).
        let plan = build(&cands, &batches, &spans_none(2), 2, 40);
        assert_eq!(plan.rows.len(), 2);
        assert_eq!(plan.positions, vec![0]);
    }

    #[test]
    fn row_budget_truncates_mid_group() {
        // One group, 5 members, only 2 rows of budget and a wide-enough
        // width to keep everything in a single column (grows-limited).
        let batches = [batch(b"", b"")];
        let cands: Vec<Candidate<'_>> = (0..5).map(|_| cand(b"x", None, None, 0)).collect();
        let plan = build(&cands, &batches, &spans_none(5), 2, 3);
        assert_eq!(plan.positions.len(), 2); // dropped the other 3
    }

    // ---- offsets: char count vs display width ----

    #[test]
    fn cjk_cell_padding_uses_width_offsets_use_chars() {
        // "日本語" = 3 chars, display width 6 (each CJK char is width 2).
        let batches = [batch(b"", b"")];
        let cands = [
            cand("日本語".as_bytes(), None, None, 0),
            cand(b"ab", None, None, 0),
        ];
        let plan = build(&cands, &batches, &spans_none(2), 10, 8);
        // Single column (gmaxw = max(6, 2) = 6; cols = floor(10/8) = 1),
        // two rows, no gutter.
        assert_eq!(plan.rows.len(), 2);
        // Row 0: "日本語" padded to width 6 -> no padding needed (already 6).
        assert_eq!(plan.rows[0], "日本語".as_bytes());
        // Row 1: "ab" padded to width 6 -> "ab" + 4 spaces.
        assert_eq!(plan.rows[1], b"ab    ");
        // Cell range length is CHAR count (3), not display width (6).
        assert_eq!(plan.cell_ranges[0], (0, 3));
        // Row 1 starts after "日本語" (3 chars) + 1 newline = char offset 4.
        assert_eq!(plan.cell_ranges[1], (4, 2));
    }

    #[test]
    fn heading_plus_multi_column_cjk_offsets() {
        // 4 single-char CJK candidates (width 2 each), width=6 -> gmaxw=2,
        // cols=floor(8/4)=2, grows=ceil(4/2)=2: a 2x2 grid with a heading,
        // combining both offset-tricky dimensions (heading row + CJK
        // char/width split) in one grid.
        let batches = [batch(b"g", b"Grp")];
        let cands = [
            cand("日".as_bytes(), None, None, 0),
            cand("本".as_bytes(), None, None, 0),
            cand("語".as_bytes(), None, None, 0),
            cand("字".as_bytes(), None, None, 0),
        ];
        let plan = build(&cands, &batches, &spans_none(4), 10, 6);
        // Column-major: col1=[日,本], col2=[語,字].
        assert_eq!(
            plan.rows,
            vec![
                "Grp".as_bytes().to_vec(),
                "日  語".as_bytes().to_vec(),
                "本  字".as_bytes().to_vec()
            ]
        );
        assert_eq!(plan.positions, vec![0, 1, 2, 3]); // 日,本,語,字 in rank order
        // char offsets: "Grp" (3 chars) + \n -> row2 at 4; row2 "日  語"
        // is 4 chars + \n -> row3 at 9.
        assert_eq!(
            plan.cell_ranges,
            vec![
                (4, 1),  // 日: row2, col1
                (9, 1),  // 本: row3, col1
                (7, 1),  // 語: row2, col2 (after "日  ")
                (12, 1), // 字: row3, col2 (after "本  ")
            ]
        );
    }

    #[test]
    fn duplicate_candidates_are_retained_not_deduplicated() {
        // cli-protocol.md "重複候補...除去せずそのまま送ってよい...Rust
        // も重複除去しない": two byte-identical candidates must still
        // occupy two distinct positions.
        let batches = [batch(b"", b"")];
        let cands = [cand(b"git", None, None, 0), cand(b"git", None, None, 0)];
        let plan = build(&cands, &batches, &spans_none(2), 10, 40);
        assert_eq!(plan.positions, vec![0, 1]);
        assert_eq!(plan.cell_ranges.len(), 2);
        assert_ne!(plan.cell_ranges[0], plan.cell_ranges[1]); // distinct cells, same text
    }

    #[test]
    fn invalid_utf8_does_not_panic_and_stays_byte_exact() {
        let batches = [batch(b"", b"")];
        let raw: &[u8] = b"ca\xFFt"; // \xFF is not valid UTF-8 continuation
        let cands = [cand(raw, None, None, 0)];
        let plan = build(&cands, &batches, &spans_none(1), 10, 40);
        // No truncation needed at width 40: the whole raw byte string
        // survives untouched (never re-encoded to U+FFFD bytes).
        assert_eq!(plan.rows[0], raw);
    }

    #[test]
    fn invalid_utf8_truncation_cuts_on_lossy_char_boundaries() {
        let batches = [batch(b"", b"")];
        // "a" + invalid byte (lossy: 1 char, width 1) + "bb": budget 2
        // should keep "a" and the replacement char (2 width), dropping "bb".
        let raw: &[u8] = b"a\xFFbb";
        let cands = [cand(raw, None, None, 0)];
        let plan = build(&cands, &batches, &spans_none(1), 10, 2);
        assert_eq!(plan.rows[0], b"a\xFF"); // original bytes, not U+FFFD bytes
    }

    #[test]
    fn invalid_utf8_multi_byte_incomplete_sequence_is_one_replacement_char() {
        let batches = [batch(b"", b"")];
        // \xF0\x9F\x98 is a truncated 4-byte sequence (3 of 4 bytes) at
        // the end of the buffer: from_utf8_lossy's maximal-subpart rule
        // collapses all 3 trailing bytes into a single U+FFFD, not three
        // separate ones (exercising the multi-byte error path, not just
        // the single stray-byte case above).
        let raw: &[u8] = b"ab\xF0\x9F\x98";
        let cands = [cand(raw, None, None, 0)];
        let plan = build(&cands, &batches, &spans_none(1), 10, 40); // no truncation
        assert_eq!(plan.rows[0], raw); // bytes preserved verbatim, never re-encoded
        // "a", "b", one replacement char for all 3 trailing bytes = 3
        // chars -- not 5 (if each trailing byte were its own U+FFFD).
        assert_eq!(plan.cell_ranges[0], (0, 3));
    }

    // ---- highlight span clipping ----

    #[test]
    fn match_span_is_clipped_to_truncated_cell() {
        let batches = [batch(b"", b"")];
        let cands = [cand(b"abcdef", None, None, 0)];
        // matching::spans() tuples are (start, end), 0-based
        // end-exclusive -- chars [1,5) = "bcde", reaching past the
        // truncation point (width budget 3).
        let spans = vec![vec![(1usize, 5usize)]];
        let plan = build(&cands, &batches, &spans, 10, 3);
        assert_eq!(plan.rows[0], b"abc");
        let m = plan
            .highlights
            .iter()
            .find(|h| h.role == Role::Match)
            .unwrap();
        // Clipped to the 3 retained chars: [1,3) = "bc".
        assert_eq!((m.start, m.len), (1, 2));
    }

    #[test]
    fn match_span_uses_end_exclusive_semantics_not_start_len() {
        // Regression: layout.rs once misread matching::spans()'s (start,
        // end) tuples as (start, len), which happened to be
        // indistinguishable whenever start == 0. "cargo" matched by "g"
        // (substring, found at char index 3) produces the real span
        // matching.rs::spans() would emit: (3, 4) = chars [3,4) = "g"
        // alone, i.e. len 1 -- not len 4 (mistaken as start=3,len=4) and
        // not len 2 (the bug actually observed: end misread as start+len
        // saturating past the candidate).
        let batches = [batch(b"", b"")];
        let cands = [cand(b"cargo", None, None, 0)];
        let spans = vec![vec![(3usize, 4usize)]];
        let plan = build(&cands, &batches, &spans, 10, 40); // no truncation
        assert_eq!(plan.rows[0], b"cargo");
        let m = plan
            .highlights
            .iter()
            .find(|h| h.role == Role::Match)
            .unwrap();
        assert_eq!((m.start, m.len), (3, 1));
    }

    #[test]
    fn display_text_cell_never_gets_match_highlight() {
        let batches = [batch(b"", b"")];
        let cands = [cand(b"raw", None, Some(b"shown"), 0)];
        // Non-zero start: a d-tag cell must suppress match decoration
        // regardless of what the (otherwise unused) span would resolve to.
        let spans = vec![vec![(1usize, 3usize)]];
        let plan = build(&cands, &batches, &spans, 10, 40);
        assert_eq!(plan.rows[0], b"shown");
        assert!(plan.highlights.iter().all(|h| h.role != Role::Match));
    }

    // ---- navigation ----

    #[test]
    fn single_candidate_nav_is_all_self_or_unselected() {
        let batches = [batch(b"", b"")];
        let cands = [cand(b"only", None, None, 0)];
        let plan = build(&cands, &batches, &spans_none(1), 10, 40);
        let n = plan.nav[0];
        assert_eq!(
            n,
            Nav {
                next: 1,
                prev: 0,
                left: 1,
                right: 1
            }
        );
    }

    #[test]
    fn single_column_group_left_right_clamp_to_group_ends() {
        // width forces cols=1 (gmaxw==width); 3 members -> a 1x3 column.
        let batches = [batch(b"", b"")];
        let cands: Vec<Candidate<'_>> = (0..3)
            .map(|_| cand(&b"xxxxxxxxxxxxxxxxxxxx"[..20], None, None, 0))
            .collect();
        let plan = build(&cands, &batches, &spans_none(3), 10, 20);
        assert_eq!(plan.positions.len(), 3);
        // grows == gcount == 3 here, so left/right land on the group's
        // extremes from any position (per the single formula; boundary
        // positions self-reference).
        assert_eq!(
            plan.nav[0],
            Nav {
                next: 2,
                prev: 0,
                left: 1,
                right: 3
            }
        );
        assert_eq!(
            plan.nav[1],
            Nav {
                next: 3,
                prev: 1,
                left: 1,
                right: 3
            }
        );
        assert_eq!(
            plan.nav[2],
            Nav {
                next: 3,
                prev: 2,
                left: 1,
                right: 3
            }
        );
    }

    #[test]
    fn ragged_last_column_nav_clamps_within_group() {
        // 5 narrow members, width forces cols=3 (gmaxw=1 -> cols=clamp
        // (floor(9/3),1,8)=3), so grows=ceil(5/3)=2, gcount=min(6,5)=5,
        // recompressed cols stays 3. Column-major layout:
        // col1: pos1,pos2 ; col2: pos3,pos4 ; col3: pos5 (ragged, no pos6).
        let batches = [batch(b"", b"")];
        let cands: Vec<Candidate<'_>> = (0..5).map(|_| cand(b"x", None, None, 0)).collect();
        let plan = build(&cands, &batches, &spans_none(5), 10, 7);
        assert_eq!(plan.positions.len(), 5);
        // pos5 is alone in its column (grows=2): left = max(1, 5-2) = 3.
        let n5 = plan.nav[4];
        assert_eq!(n5.left, 3);
        assert_eq!(n5.right, 5); // min(5, 5+2) clamped to group end
    }

    #[test]
    fn positions_map_back_to_source_candidates() {
        let batches = [batch(b"", b"")];
        let cands = [cand(b"a", None, None, 0), cand(b"b", None, None, 0)];
        let plan = build(&cands, &batches, &spans_none(2), 10, 40);
        assert_eq!(plan.positions, vec![0, 1]);
    }

    #[test]
    fn positions_follow_column_major_position_order_not_render_scan_order() {
        // Regression (external audit blocker): `positions` was once
        // pushed in the render loop's (row, col) *scan* order, which
        // only matches position order when grows == 1. 5 single-char
        // candidates a..e at rows=2, width=7 force gmaxw=1, cols=3,
        // grows=2, gcount=5 -- the exact grid the audit's black-box
        // repro used, where the scan order (a,c,e,b,d) diverges from
        // position order (a,b,c,d,e), so confirming a candidate inserted
        // its neighbor's text.
        let batches = [batch(b"", b"")];
        let cands: Vec<Candidate<'_>> = ["a", "b", "c", "d", "e"]
            .iter()
            .map(|w| cand(w.as_bytes(), None, None, 0))
            .collect();
        let plan = build(&cands, &batches, &spans_none(5), 2, 7);
        // Column-major placement: col1=[a,b], col2=[c,d], col3=[e] (ragged).
        assert_eq!(plan.rows, vec![b"a  c  e".to_vec(), b"b  d".to_vec()]);
        // positions[pos-1] must be the candidate at position `pos` in
        // rank order (a=0,b=1,c=2,d=3,e=4) -- NOT the render scan order
        // (a,c,e,b,d) the bug produced.
        assert_eq!(plan.positions, vec![0, 1, 2, 3, 4]);
        // Cross-validate every other position-indexed output against the
        // same grid by hand, per the audit's request to check them together.
        // char offsets: row0 "a  c  e" is 7 chars + \n -> row1 starts at 8.
        assert_eq!(
            plan.cell_ranges,
            vec![
                (0, 1),  // a: row0, col1
                (8, 1),  // b: row1, col1
                (3, 1),  // c: row0, col2 (after "a  ")
                (11, 1), // d: row1, col2 (after "b  ")
                (6, 1),  // e: row0, col3 (after "a  c  ")
            ]
        );
        // nav: next/prev walk positions 1..=5 sequentially; left/right
        // jump by grows=2 within the single group [1,5].
        assert_eq!(
            plan.nav[0],
            Nav {
                next: 2,
                prev: 0,
                left: 1,
                right: 3
            }
        ); // a
        assert_eq!(
            plan.nav[1],
            Nav {
                next: 3,
                prev: 1,
                left: 1,
                right: 4
            }
        ); // b
        assert_eq!(
            plan.nav[2],
            Nav {
                next: 4,
                prev: 2,
                left: 1,
                right: 5
            }
        ); // c
        assert_eq!(
            plan.nav[3],
            Nav {
                next: 5,
                prev: 3,
                left: 2,
                right: 5
            }
        ); // d
        assert_eq!(
            plan.nav[4],
            Nav {
                next: 5,
                prev: 4,
                left: 3,
                right: 5
            }
        ); // e
    }

    #[test]
    fn empty_candidates_yield_empty_plan() {
        let plan = build(&[], &[], &[], 10, 40);
        assert_eq!(plan, Plan::default());
    }

    // ---- external audit: contract boundary cases ----

    #[test]
    fn non_fitting_headed_group_stops_layout_even_if_a_later_group_would_fit() {
        // g1 (1 member) fits fully with its heading; g2 (1 member,
        // headed) then can't fit (budget left is 1, needs 2) and is a
        // *non-first* group, so the whole layout stops there -- even
        // though the headingless "" bucket that comes third (by
        // first-occurrence) would trivially fit in the 1 row left over.
        let batches = [batch(b"g1", b""), batch(b"g2", b""), batch(b"", b"")];
        let cands = [
            cand(b"a", None, None, 0), // group "g1": fits (heading + 1 row = 2)
            cand(b"b", None, None, 1), // group "g2": needs 2, only 1 left -> drop + stop
            cand(b"c", None, None, 2), // headingless bucket: would fit alone, never reached
        ];
        let plan = build(&cands, &batches, &spans_none(3), 3, 40);
        assert_eq!(plan.rows, vec![b"g1".to_vec(), b"a".to_vec()]);
        assert_eq!(plan.positions, vec![0]); // only "a"; "b" and "c" both absent
    }

    #[test]
    fn heading_text_is_fixed_by_the_groups_first_occurring_batch() {
        // Two batches share the group key "grp" but carry different `X`.
        // The heading must come from whichever batch's candidate
        // *first* established the group, not from a later member that
        // happens to join the same key with a different heading text.
        let batches = [
            batch(b"grp", b"First Heading"),
            batch(b"grp", b"Second Heading"),
        ];
        let cands = [cand(b"a", None, None, 0), cand(b"b", None, None, 1)];
        let plan = build(&cands, &batches, &spans_none(2), 10, 40);
        let headings: Vec<_> = plan
            .highlights
            .iter()
            .filter(|h| h.role == Role::Heading)
            .collect();
        assert_eq!(
            headings.len(),
            1,
            "both members share one group -> one heading"
        );
        assert_eq!(plan.rows[0], b"First Heading");
        assert!(plan.rows.iter().all(|r| r != b"Second Heading"));
    }

    #[test]
    fn default_group_name_has_no_group_even_with_a_non_empty_heading() {
        // J == "-default-" reads as no key regardless of X (X is not a
        // fallback here -- the -default- override short-circuits before
        // X is ever consulted). Contrast with `heading_prefers_x_falls_
        // back_to_j`, where an *empty* J does fall back to X.
        let batches = [batch(b"-default-", b"Some Heading")];
        let cands = [cand(b"a", None, None, 0)];
        let plan = build(&cands, &batches, &spans_none(1), 10, 40);
        assert_eq!(plan.rows, vec![b"a".to_vec()]); // no heading row
        assert!(plan.highlights.iter().all(|h| h.role != Role::Heading));
    }
}
