//! Reference parser for the `zrush plan` stdout wire format.

use std::fmt;

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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Highlight {
    pub role: Role,
    pub pos: usize,
    pub start: usize,
    pub len: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Navigation {
    pub next: usize,
    pub prev: usize,
    pub left: usize,
    pub right: usize,
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
        }
    }
}

impl std::error::Error for Error {}

/// Parse and validate a serialized `zrush plan` output.
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
    let rows = fields[index..index + l]
        .iter()
        .map(|field| field.to_vec())
        .collect();
    index += l;
    index += 1;

    let mut highlights = Vec::with_capacity(h);
    for field in &fields[index..index + h] {
        highlights.push(parse_highlight(field, p)?);
    }
    index += h;

    let mut cells = Vec::with_capacity(p);
    for field in &fields[index..index + p] {
        cells.push(parse_pair(field, "cell")?);
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
    if value.is_empty() || !value.iter().all(u8::is_ascii_digit) {
        return Err(Error::InvalidCount {
            field,
            value: value.to_vec(),
        });
    }
    value.iter().try_fold(0usize, |number, digit| {
        number
            .checked_mul(10)
            .and_then(|number| number.checked_add(usize::from(*digit - b'0')))
            .ok_or_else(|| Error::InvalidCount {
                field,
                value: value.to_vec(),
            })
    })
}

fn parse_highlight(value: &[u8], positions: usize) -> Result<Highlight, Error> {
    let parts = tuple_parts(value);
    if parts.len() != 4 {
        return Err(Error::InvalidTuple {
            field: "highlight",
            value: value.to_vec(),
        });
    }
    let role = match parts[0] {
        b"match" => Role::Match,
        b"heading" => Role::Heading,
        other => return Err(Error::InvalidRole(other.to_vec())),
    };
    let pos = count(parts[1], "highlight pos")?;
    if pos > positions {
        return Err(Error::OutOfRange {
            field: "highlight pos",
            value: pos,
            max: positions,
        });
    }
    Ok(Highlight {
        role,
        pos,
        start: count(parts[2], "highlight start")?,
        len: count(parts[3], "highlight len")?,
    })
}

fn parse_pair(value: &[u8], field: &'static str) -> Result<(usize, usize), Error> {
    let parts = tuple_parts(value);
    if parts.len() != 2 {
        return Err(Error::InvalidTuple {
            field,
            value: value.to_vec(),
        });
    }
    Ok((count(parts[0], "cell start")?, count(parts[1], "cell len")?))
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
                b"0 1",
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
                &[b"", b"0", b"1", b"0", b"0 1", b"1 0 1", b"word",]
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
                b"0 1",
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
                b"0 1",
                b"1 0 1 1",
                b"word",
            ])),
            Err(Error::InvalidRole(b"other".to_vec()))
        );
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
                b"0 1",
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

    fn assert_navigation_value_is_rejected(tuple: &[u8], expected_field: &'static str) {
        assert!(matches!(
            parse(&fields(&[b"", b"0", b"1", b"0", b"0 1", tuple, b"word"])),
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
