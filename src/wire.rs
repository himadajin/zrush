//! Render-plan wire serialization and reference parsing.

use std::fmt;
use std::io::Write as _;

use crate::layout;

/// Protocol version shared by config output and the worker handshake
/// (cli-protocol.md "プロトコル版").
pub(crate) const PROTOCOL_VERSION: &str = "7";

/// Incremental, overflow-checked ASCII decimal accumulation shared by the
/// protocol's complete-field parsers and streaming netstring decoder.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct Decimal {
    value: u64,
    digits: usize,
    leading_zero: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DecimalError {
    InvalidDigit,
    LeadingZero,
    Overflow,
}

impl Decimal {
    pub(crate) fn push(&mut self, byte: u8) -> Result<(), DecimalError> {
        let digit = byte
            .checked_sub(b'0')
            .filter(|digit| *digit <= 9)
            .ok_or(DecimalError::InvalidDigit)?;
        self.value = self
            .value
            .checked_mul(10)
            .and_then(|value| value.checked_add(u64::from(digit)))
            .ok_or(DecimalError::Overflow)?;
        self.leading_zero = self.digits == 0 && digit == 0;
        self.digits += 1;
        Ok(())
    }

    pub(crate) fn push_canonical(&mut self, byte: u8) -> Result<(), DecimalError> {
        if !byte.is_ascii_digit() {
            return Err(DecimalError::InvalidDigit);
        }
        if self.leading_zero {
            return Err(DecimalError::LeadingZero);
        }
        self.push(byte)
    }

    pub(crate) fn is_empty(self) -> bool {
        self.digits == 0
    }

    pub(crate) fn value(self) -> u64 {
        self.value
    }
}

pub(crate) fn parse_ascii_u64(value: &[u8]) -> Option<u64> {
    let mut decimal = Decimal::default();
    for &byte in value {
        decimal.push(byte).ok()?;
    }
    (!decimal.is_empty()).then_some(decimal.value())
}

pub(crate) fn parse_canonical_u64(value: &[u8]) -> Option<u64> {
    let mut decimal = Decimal::default();
    for &byte in value {
        decimal.push_canonical(byte).ok()?;
    }
    (!decimal.is_empty()).then_some(decimal.value())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub common_prefix: Vec<u8>,
    pub rows: Vec<Vec<u8>>,
    pub highlights: Vec<Highlight>,
    pub cells: Vec<(usize, usize)>,
    pub navigation: Vec<Navigation>,
    pub inserts: Vec<Vec<u8>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Match,
    Heading,
    HistoryNumber,
}

impl Role {
    fn parse(value: &[u8]) -> Option<Self> {
        match value {
            b"match" => Some(Self::Match),
            b"heading" => Some(Self::Heading),
            b"history-number" => Some(Self::HistoryNumber),
            _ => None,
        }
    }

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Match => "match",
            Self::Heading => "heading",
            Self::HistoryNumber => "history-number",
        }
    }
}

/// A decoded highlight, preserving the wire's `start len` representation.
/// Layout computation keeps its end-exclusive span type until serialization.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Highlight {
    pub role: Role,
    pub pos: usize,
    pub start: usize,
    pub len: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Navigation {
    pub next: usize,
    pub prev: usize,
    pub left: usize,
    pub right: usize,
}

/// Flatten a computed plan into the render-plan wire format. Internal spans
/// stay end-exclusive until this boundary converts them to `start len`.
pub(crate) fn serialize(
    common_prefix: &[u8],
    plan: &layout::Plan,
    insert_texts: &[Vec<u8>],
) -> Vec<u8> {
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
    for highlight in &plan.highlights {
        let _ = write!(
            out,
            "{} {} {} {}",
            highlight.role.as_str(),
            highlight.pos,
            highlight.span.start,
            highlight.span.len()
        );
        out.push(0);
    }
    for cell in &plan.cell_ranges {
        let _ = write!(out, "{} {}", cell.start, cell.len());
        out.push(0);
    }
    for navigation in &plan.nav {
        let _ = write!(
            out,
            "{} {} {} {}",
            navigation.next, navigation.prev, navigation.left, navigation.right
        );
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    EmptyOutput,
    MissingFinalNul,
    InvalidCount {
        field: &'static str,
        value: Vec<u8>,
    },
    FieldCount {
        expected: usize,
        actual: usize,
    },
    InvalidTuple {
        field: &'static str,
        value: Vec<u8>,
    },
    InvalidRole(Vec<u8>),
    OutOfRange {
        field: &'static str,
        value: usize,
        max: usize,
    },
    RangeOutsideListing {
        field: &'static str,
        start: usize,
        len: usize,
        listing_chars: usize,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyOutput => write!(f, "plan output is empty"),
            Self::MissingFinalNul => write!(f, "plan output is not NUL-terminated"),
            Self::InvalidCount { field, value } => {
                write!(f, "{field} is not a non-negative ASCII decimal: {value:?}")
            }
            Self::FieldCount { expected, actual } => {
                write!(f, "plan has {actual} fields, expected {expected}")
            }
            Self::InvalidTuple { field, value } => {
                write!(f, "invalid {field} tuple: {value:?}")
            }
            Self::InvalidRole(value) => write!(f, "invalid highlight role: {value:?}"),
            Self::OutOfRange { field, value, max } => {
                write!(f, "{field} value {value} is outside 0..={max}")
            }
            Self::RangeOutsideListing {
                field,
                start,
                len,
                listing_chars,
            } => write!(
                f,
                "{field} range start {start} + len {len} escapes the \
                 {listing_chars}-char listing text"
            ),
        }
    }
}

impl std::error::Error for Error {}

/// Parse and validate a serialized render plan.
pub fn parse(output: &[u8]) -> Result<Plan, Error> {
    if output.is_empty() {
        return Err(Error::EmptyOutput);
    }
    if output.last() != Some(&0) {
        return Err(Error::MissingFinalNul);
    }

    let fields: Vec<&[u8]> = output[..output.len() - 1]
        .split(|&byte| byte == 0)
        .collect();
    if fields.len() < 4 {
        return Err(Error::FieldCount {
            expected: 4,
            actual: fields.len(),
        });
    }

    let l = count(fields[1], "L")?;
    let p = count(fields[2], "P")?;
    let h_index = 3usize.checked_add(l).ok_or(Error::FieldCount {
        expected: usize::MAX,
        actual: fields.len(),
    })?;
    let h = fields.get(h_index).ok_or(Error::FieldCount {
        expected: h_index.saturating_add(1),
        actual: fields.len(),
    })?;
    let h = count(h, "H")?;
    let expected = 4usize
        .checked_add(l)
        .and_then(|n| n.checked_add(h))
        .and_then(|n| n.checked_add(p.checked_mul(3)?))
        .ok_or(Error::FieldCount {
            expected: usize::MAX,
            actual: fields.len(),
        })?;
    if fields.len() != expected {
        return Err(Error::FieldCount {
            expected,
            actual: fields.len(),
        });
    }

    let mut index = 3;
    let rows: Vec<Vec<u8>> = fields[index..index + l]
        .iter()
        .map(|field| field.to_vec())
        .collect();
    index += l;
    index += 1;

    // cli-protocol.md "オフセット規律": highlight and cell-range offsets are
    // char counts over the listing text -- the L rows joined by `\n`, no
    // leading newline. `\n` is a char boundary in every row's lossy reading,
    // so joining first cannot merge an invalid tail into the next row.
    let listing_chars = String::from_utf8_lossy(&rows.join(&b'\n')).chars().count();

    let mut highlights = Vec::with_capacity(h);
    for field in &fields[index..index + h] {
        highlights.push(parse_highlight(field, p, listing_chars)?);
    }
    index += h;

    let mut cells = Vec::with_capacity(p);
    for field in &fields[index..index + p] {
        cells.push(parse_pair(field, "cell", listing_chars)?);
    }
    index += p;

    let mut navigation = Vec::with_capacity(p);
    for field in &fields[index..index + p] {
        navigation.push(parse_navigation(field, p)?);
    }
    index += p;

    let inserts = fields[index..index + p]
        .iter()
        .map(|field| field.to_vec())
        .collect();

    Ok(Plan {
        common_prefix: fields[0].to_vec(),
        rows,
        highlights,
        cells,
        navigation,
        inserts,
    })
}

fn count(value: &[u8], field: &'static str) -> Result<usize, Error> {
    // zsh's `<->` accepts unbounded digit strings and does not numerically
    // convert cell ranges; this typed reference API deliberately rejects
    // `usize` overflow because the Rust serializer cannot produce it.
    parse_ascii_u64(value)
        .and_then(|number| usize::try_from(number).ok())
        .ok_or_else(|| Error::InvalidCount {
            field,
            value: value.to_vec(),
        })
}

/// `start + len` must stay inside the listing text (cli-protocol.md
/// "オフセット規律"). An overflowing sum is out of range by definition.
fn check_range(
    field: &'static str,
    start: usize,
    len: usize,
    listing_chars: usize,
) -> Result<(), Error> {
    if start.checked_add(len).is_none_or(|end| end > listing_chars) {
        return Err(Error::RangeOutsideListing {
            field,
            start,
            len,
            listing_chars,
        });
    }
    Ok(())
}

fn parse_highlight(
    value: &[u8],
    positions: usize,
    listing_chars: usize,
) -> Result<Highlight, Error> {
    let parts = tuple_parts(value);
    if parts.len() != 4 {
        return Err(Error::InvalidTuple {
            field: "highlight",
            value: value.to_vec(),
        });
    }
    let role = Role::parse(parts[0]).ok_or_else(|| Error::InvalidRole(parts[0].to_vec()))?;
    let pos = count(parts[1], "highlight pos")?;
    if pos > positions {
        return Err(Error::OutOfRange {
            field: "highlight pos",
            value: pos,
            max: positions,
        });
    }
    let start = count(parts[2], "highlight start")?;
    let len = count(parts[3], "highlight len")?;
    check_range("highlight", start, len, listing_chars)?;
    Ok(Highlight {
        role,
        pos,
        start,
        len,
    })
}

fn parse_pair(
    value: &[u8],
    field: &'static str,
    listing_chars: usize,
) -> Result<(usize, usize), Error> {
    let parts = tuple_parts(value);
    if parts.len() != 2 {
        return Err(Error::InvalidTuple {
            field,
            value: value.to_vec(),
        });
    }
    let start = count(parts[0], "cell start")?;
    let len = count(parts[1], "cell len")?;
    check_range(field, start, len, listing_chars)?;
    Ok((start, len))
}

fn parse_navigation(value: &[u8], positions: usize) -> Result<Navigation, Error> {
    let parts = tuple_parts(value);
    if parts.len() != 4 {
        return Err(Error::InvalidTuple {
            field: "navigation",
            value: value.to_vec(),
        });
    }
    let values = [
        count(parts[0], "nav next")?,
        count(parts[1], "nav prev")?,
        count(parts[2], "nav left")?,
        count(parts[3], "nav right")?,
    ];
    for (field, value) in [
        ("nav next", values[0]),
        ("nav prev", values[1]),
        ("nav left", values[2]),
        ("nav right", values[3]),
    ] {
        if value > positions {
            return Err(Error::OutOfRange {
                field,
                value,
                max: positions,
            });
        }
    }
    Ok(Navigation {
        next: values[0],
        prev: values[1],
        left: values[2],
        right: values[3],
    })
}

fn tuple_parts(value: &[u8]) -> Vec<&[u8]> {
    value
        .split(|byte| matches!(byte, b' ' | b'\t' | b'\n'))
        .filter(|part| !part.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONTRACT: &str = "docs/internal/contracts/cli-protocol.md";

    fn read_repo_file(relative_path: &str) -> String {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(relative_path);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    }

    /// PROTOCOL_VERSION is hand-written here, in two contract lines, and in
    /// zsh/zrush.zsh. The tests/cli.rs config golden owns its remaining copy.
    #[test]
    fn protocol_version_matches_docs_and_zsh() {
        let expected: [(&str, String); 3] = [
            (
                CONTRACT,
                format!("- **PROTOCOL_VERSION = {PROTOCOL_VERSION}**"),
            ),
            (
                CONTRACT,
                format!("typeset -g  ZRUSH_PROTOCOL_VERSION='{PROTOCOL_VERSION}'"),
            ),
            (
                "zsh/zrush.zsh",
                format!("typeset -gi _ZRUSH_EXPECTED_PROTO={PROTOCOL_VERSION}"),
            ),
        ];

        let mismatches: Vec<String> = expected
            .iter()
            .filter(|(relative_path, expected_line)| {
                !read_repo_file(relative_path)
                    .lines()
                    .any(|line| line.trim() == expected_line)
            })
            .map(|(relative_path, expected_line)| {
                format!("{relative_path}: expected a line \"{expected_line}\"")
            })
            .collect();

        assert!(
            mismatches.is_empty(),
            "PROTOCOL_VERSION mismatch: src/wire.rs::PROTOCOL_VERSION is \
             {PROTOCOL_VERSION:?}, but the following locations disagree (or are \
             missing the anchor line) and need to be updated to match:\n{}",
            mismatches.join("\n")
        );
    }

    fn fields(values: &[&[u8]]) -> Vec<u8> {
        let mut output = Vec::new();
        for value in values {
            output.extend_from_slice(value);
            output.push(0);
        }
        output
    }

    fn count_plan(l: &[u8], p: &[u8], h: &[u8]) -> Vec<u8> {
        fields(&[b"", l, p, h])
    }

    fn assert_invalid_count(output: &[u8], expected_field: &'static str) {
        assert!(matches!(
            parse(output),
            Err(Error::InvalidCount { field, .. }) if field == expected_field
        ));
    }

    #[test]
    fn empty_output_is_rejected() {
        assert_eq!(parse(b""), Err(Error::EmptyOutput));
    }

    #[test]
    fn missing_final_nul_is_rejected() {
        assert_eq!(parse(b"\0\x30\0\x30\0\x30"), Err(Error::MissingFinalNul));
    }

    #[test]
    fn empty_l_is_rejected() {
        assert_invalid_count(&count_plan(b"", b"0", b"0"), "L");
    }

    #[test]
    fn non_digit_l_is_rejected() {
        assert_invalid_count(&count_plan(b"x", b"0", b"0"), "L");
    }

    #[test]
    fn signed_l_is_rejected() {
        assert_invalid_count(&count_plan(b"-1", b"0", b"0"), "L");
    }

    #[test]
    fn leading_zero_counts_are_accepted_as_nonnegative_digit_strings() {
        assert!(parse(&count_plan(b"00", b"00", b"00")).is_ok());
    }

    #[test]
    fn empty_p_is_rejected() {
        assert_invalid_count(&count_plan(b"0", b"", b"0"), "P");
    }

    #[test]
    fn non_digit_p_is_rejected() {
        assert_invalid_count(&count_plan(b"0", b"x", b"0"), "P");
    }

    #[test]
    fn signed_p_is_rejected() {
        assert_invalid_count(&count_plan(b"0", b"+1", b"0"), "P");
    }

    #[test]
    fn empty_h_is_rejected() {
        assert_invalid_count(&count_plan(b"0", b"0", b""), "H");
    }

    #[test]
    fn non_digit_h_is_rejected() {
        assert_invalid_count(&count_plan(b"0", b"0", b"x"), "H");
    }

    #[test]
    fn signed_h_is_rejected() {
        assert_invalid_count(&count_plan(b"0", b"0", b"-1"), "H");
    }

    #[test]
    fn count_overflow_is_rejected() {
        assert_invalid_count(
            &count_plan(b"999999999999999999999999999999", b"0", b"0"),
            "L",
        );
    }

    #[test]
    fn too_few_fields_are_rejected() {
        assert!(matches!(
            parse(&fields(&[b"", b"1", b"0", b"row"])),
            Err(Error::FieldCount { .. })
        ));
    }

    #[test]
    fn too_many_fields_are_rejected() {
        assert_eq!(
            parse(&fields(&[b"", b"0", b"0", b"0", b"extra"])),
            Err(Error::FieldCount {
                expected: 4,
                actual: 5
            })
        );
    }

    #[test]
    fn malformed_highlight_tuple_is_rejected() {
        assert!(matches!(
            parse(&fields(&[
                b"",
                b"0",
                b"1",
                b"1",
                b"match 1 0",
                b"0 0",
                b"1 0 1 1",
                b"word",
            ])),
            Err(Error::InvalidTuple {
                field: "highlight",
                ..
            })
        ));
    }

    #[test]
    fn malformed_cell_tuple_is_rejected() {
        assert!(matches!(
            parse(&fields(
                &[b"", b"0", b"1", b"0", b"0", b"1 0 1 1", b"word",]
            )),
            Err(Error::InvalidTuple { field: "cell", .. })
        ));
    }

    #[test]
    fn malformed_navigation_tuple_is_rejected() {
        assert!(matches!(
            parse(&fields(
                &[b"", b"0", b"1", b"0", b"0 0", b"1 0 1", b"word",]
            )),
            Err(Error::InvalidTuple {
                field: "navigation",
                ..
            })
        ));
    }

    #[test]
    fn carriage_return_is_not_a_tuple_separator() {
        assert!(matches!(
            parse(&fields(&[
                b"",
                b"0",
                b"1",
                b"1",
                b"match\r1 0 1",
                b"0 0",
                b"1 0 1 1",
                b"word",
            ])),
            Err(Error::InvalidTuple {
                field: "highlight",
                ..
            })
        ));
    }

    #[test]
    fn unknown_highlight_role_is_rejected() {
        assert_eq!(
            parse(&fields(&[
                b"",
                b"0",
                b"1",
                b"1",
                b"other 1 0 1",
                b"0 0",
                b"1 0 1 1",
                b"word",
            ])),
            Err(Error::InvalidRole(b"other".to_vec()))
        );
    }

    #[test]
    fn history_number_highlight_role_is_accepted() {
        let plan = parse(&fields(&[
            b"",
            b"1",
            b"1",
            b"    9  word",
            b"1",
            b"history-number 1 4 1",
            b"0 11",
            b"1 0 1 1",
            b"word",
        ]))
        .unwrap();
        assert_eq!(plan.highlights[0].role, Role::HistoryNumber);
    }

    #[test]
    fn highlight_position_out_of_range_is_rejected() {
        assert_eq!(
            parse(&fields(&[
                b"",
                b"0",
                b"1",
                b"1",
                b"match 2 0 1",
                b"0 0",
                b"1 0 1 1",
                b"word",
            ])),
            Err(Error::OutOfRange {
                field: "highlight pos",
                value: 2,
                max: 1,
            })
        );
    }

    // ---- ranges against the listing text (contract "オフセット規律") ----

    /// One row `alpha` (5 chars), one position, one highlight.
    fn ranged_plan(highlight: &[u8], cell: &[u8]) -> Vec<u8> {
        fields(&[
            b"", b"1", b"1", b"alpha", b"1", highlight, cell, b"1 0 1 1", b"word",
        ])
    }

    #[test]
    fn range_ending_exactly_at_the_listing_end_is_accepted() {
        assert!(parse(&ranged_plan(b"match 1 3 2", b"0 5")).is_ok());
    }

    #[test]
    fn highlight_range_escaping_the_listing_is_rejected() {
        // Neither 4 nor 2 exceeds the 5-char listing on its own; the sum does.
        assert_eq!(
            parse(&ranged_plan(b"match 1 4 2", b"0 5")),
            Err(Error::RangeOutsideListing {
                field: "highlight",
                start: 4,
                len: 2,
                listing_chars: 5,
            })
        );
    }

    #[test]
    fn cell_range_escaping_the_listing_is_rejected() {
        assert_eq!(
            parse(&ranged_plan(b"match 1 0 2", b"3 4")),
            Err(Error::RangeOutsideListing {
                field: "cell",
                start: 3,
                len: 4,
                listing_chars: 5,
            })
        );
    }

    #[test]
    fn range_sum_overflowing_usize_is_rejected() {
        let huge = usize::MAX.to_string();
        let cell = format!("1 {huge}");
        assert!(matches!(
            parse(&ranged_plan(b"match 1 0 2", cell.as_bytes())),
            Err(Error::RangeOutsideListing { field: "cell", .. })
        ));
    }

    #[test]
    fn the_bound_spans_the_whole_listing_not_one_row() {
        // "ab\ncd" is 5 chars, so an offset into row 2 is in range even though
        // it exceeds row 1's length.
        let plan = fields(&[
            b"",
            b"2",
            b"1",
            b"ab",
            b"cd",
            b"1",
            b"match 1 3 2",
            b"3 2",
            b"1 0 1 1",
            b"word",
        ]);
        let parsed = parse(&plan).expect("row-2 offsets are inside the listing");
        assert_eq!(parsed.cells, vec![(3, 2)]);
    }

    #[test]
    fn listing_chars_counts_chars_not_bytes() {
        // "日本語" is 3 chars / 9 bytes: a byte-based bound would wrongly
        // accept a range reaching char 9.
        let plan = fields(&[
            b"",
            b"1",
            b"1",
            "日本語".as_bytes(),
            b"1",
            b"match 1 0 9",
            b"0 3",
            b"1 0 1 1",
            b"word",
        ]);
        assert_eq!(
            parse(&plan),
            Err(Error::RangeOutsideListing {
                field: "highlight",
                start: 0,
                len: 9,
                listing_chars: 3,
            })
        );
    }

    fn assert_navigation_value_is_rejected(tuple: &[u8], expected_field: &'static str) {
        assert!(matches!(
            parse(&fields(&[b"", b"0", b"1", b"0", b"0 0", tuple, b"word"])),
            Err(Error::OutOfRange { field, value: 2, max: 1 }) if field == expected_field
        ));
    }

    #[test]
    fn navigation_next_out_of_range_is_rejected() {
        assert_navigation_value_is_rejected(b"2 0 1 1", "nav next");
    }

    #[test]
    fn navigation_prev_out_of_range_is_rejected() {
        assert_navigation_value_is_rejected(b"1 2 1 1", "nav prev");
    }

    #[test]
    fn navigation_left_out_of_range_is_rejected() {
        assert_navigation_value_is_rejected(b"1 0 2 1", "nav left");
    }

    #[test]
    fn navigation_right_out_of_range_is_rejected() {
        assert_navigation_value_is_rejected(b"1 0 1 2", "nav right");
    }

    #[test]
    fn zero_match_form_is_accepted() {
        assert_eq!(
            parse(b"\0\x30\0\x30\0\x30\0"),
            Ok(Plan {
                common_prefix: Vec::new(),
                rows: Vec::new(),
                highlights: Vec::new(),
                cells: Vec::new(),
                navigation: Vec::new(),
                inserts: Vec::new(),
            })
        );
    }
}
