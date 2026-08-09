//! Binary framing for long-lived byte streams.

use std::fmt;

use crate::wire::{Decimal, DecimalError};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Error {
    MissingLength,
    LeadingZero,
    LengthOverflow,
    MissingColon,
    InvalidTrailingComma,
    TruncatedFrame,
    DecoderFailed,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::MissingLength => "netstring length is empty",
            Self::LeadingZero => "netstring length has a leading zero",
            Self::LengthOverflow => "netstring length exceeds usize",
            Self::MissingColon => "netstring length is not followed by a colon",
            Self::InvalidTrailingComma => "netstring payload is not followed by a comma",
            Self::TruncatedFrame => "netstring is truncated",
            Self::DecoderFailed => "netstring decoder has already failed",
        };
        f.write_str(message)
    }
}

impl std::error::Error for Error {}

/// Terminal decoding failure together with frames completed earlier in the
/// same input chunk.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct FeedError {
    /// Valid frames preceding the malformed frame.
    pub(crate) completed: Vec<Vec<u8>>,
    /// The terminal framing error that poisoned the decoder.
    pub(crate) error: Error,
}

impl fmt::Display for FeedError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.error.fmt(f)
    }
}

impl std::error::Error for FeedError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.error)
    }
}

#[derive(Debug)]
enum State {
    Length(Decimal),
    Payload { remaining: usize, bytes: Vec<u8> },
    Comma(Vec<u8>),
    Failed,
}

impl State {
    fn length() -> Self {
        Self::Length(Decimal::default())
    }
}

/// Incrementally decodes concatenated netstrings.
///
/// A decoder may be fed at any byte boundary. Completed payloads are returned
/// from the call that receives their trailing comma. Once an error is returned,
/// the decoder is poisoned and must be discarded with its stream.
#[derive(Debug)]
pub(crate) struct Decoder {
    state: State,
}

impl Default for Decoder {
    fn default() -> Self {
        Self::new()
    }
}

impl Decoder {
    pub(crate) fn new() -> Self {
        Self {
            state: State::length(),
        }
    }

    /// Consumes one byte-stream chunk.
    ///
    /// On failure, `FeedError::completed` must be observed before the terminal
    /// error is handled so valid-prefix delivery does not depend on chunking.
    pub(crate) fn feed(&mut self, input: &[u8]) -> Result<Vec<Vec<u8>>, FeedError> {
        let mut completed = Vec::new();
        let mut offset = 0;

        while offset < input.len() {
            let state = std::mem::replace(&mut self.state, State::Failed);
            match state {
                State::Length(mut decimal) => {
                    let byte = input[offset];
                    offset += 1;

                    if byte == b':' {
                        if decimal.is_empty() {
                            return Err(FeedError {
                                completed,
                                error: Error::MissingLength,
                            });
                        }
                        let Ok(value) = usize::try_from(decimal.value()) else {
                            return Err(FeedError {
                                completed,
                                error: Error::LengthOverflow,
                            });
                        };
                        self.state = if value == 0 {
                            State::Comma(Vec::new())
                        } else {
                            State::Payload {
                                remaining: value,
                                bytes: Vec::new(),
                            }
                        };
                    } else if byte.is_ascii_digit() {
                        if let Err(error) = decimal.push_canonical(byte) {
                            return Err(FeedError {
                                completed,
                                error: match error {
                                    DecimalError::LeadingZero => Error::LeadingZero,
                                    DecimalError::Overflow => Error::LengthOverflow,
                                    DecimalError::InvalidDigit => unreachable!(
                                        "ASCII digit was checked before decimal accumulation"
                                    ),
                                },
                            });
                        }
                        if usize::try_from(decimal.value()).is_err() {
                            return Err(FeedError {
                                completed,
                                error: Error::LengthOverflow,
                            });
                        }
                        self.state = State::Length(decimal);
                    } else {
                        return Err(FeedError {
                            completed,
                            error: Error::MissingColon,
                        });
                    }
                }
                State::Payload {
                    remaining,
                    mut bytes,
                } => {
                    let take = remaining.min(input.len() - offset);
                    bytes.extend_from_slice(&input[offset..offset + take]);
                    offset += take;

                    self.state = if take == remaining {
                        State::Comma(bytes)
                    } else {
                        State::Payload {
                            remaining: remaining - take,
                            bytes,
                        }
                    };
                }
                State::Comma(bytes) => {
                    let byte = input[offset];
                    offset += 1;
                    if byte != b',' {
                        return Err(FeedError {
                            completed,
                            error: Error::InvalidTrailingComma,
                        });
                    }
                    completed.push(bytes);
                    self.state = State::length();
                }
                State::Failed => {
                    return Err(FeedError {
                        completed,
                        error: Error::DecoderFailed,
                    });
                }
            }
        }

        Ok(completed)
    }

    /// Marks the end of the stream, distinguishing a clean frame boundary from
    /// a truncated length, payload, or trailing comma.
    pub(crate) fn finish(&mut self) -> Result<(), Error> {
        match self.state {
            State::Length(decimal) if decimal.is_empty() => Ok(()),
            State::Failed => Err(Error::DecoderFailed),
            _ => {
                self.state = State::Failed;
                Err(Error::TruncatedFrame)
            }
        }
    }
}

pub(crate) fn encode(payload: &[u8]) -> Vec<u8> {
    let length = payload.len().to_string();
    let mut encoded = Vec::new();
    encoded.extend_from_slice(length.as_bytes());
    encoded.push(b':');
    encoded.extend_from_slice(payload);
    encoded.push(b',');
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn decode_chunks(encoded: &[u8], chunk_size: usize) -> Vec<Vec<u8>> {
        let mut decoder = Decoder::new();
        let mut decoded = Vec::new();
        for chunk in encoded.chunks(chunk_size) {
            decoded.extend(decoder.feed(chunk).expect("encoded test frame is valid"));
        }
        decoder.finish().expect("encoded test frame is complete");
        decoded
    }

    #[test]
    fn encodes_canonical_netstrings() {
        assert_eq!(encode(b""), b"0:,");
        assert_eq!(encode(b"hello"), b"5:hello,");
        assert_eq!(encode(&[0, 1, 2, 0xff]), b"4:\0\x01\x02\xff,");
    }

    #[test]
    fn decodes_concatenated_frames_across_every_boundary() {
        let encoded = b"0:,3:a\0b,2:\xff\x01,";
        let expected = vec![Vec::new(), b"a\0b".to_vec(), vec![0xff, 1]];

        for boundary in 0..=encoded.len() {
            let mut decoder = Decoder::new();
            let mut decoded = decoder.feed(&encoded[..boundary]).unwrap();
            decoded.extend(decoder.feed(&encoded[boundary..]).unwrap());
            decoder.finish().unwrap();
            assert_eq!(decoded, expected, "boundary {boundary}");
        }
        assert_eq!(decode_chunks(encoded, 1), expected);
    }

    #[test]
    fn supports_recursive_framing() {
        let inner = [encode(b"one"), encode(&[0, 0xff])].concat();
        let outer = encode(&inner);
        let decoded_outer = decode_chunks(&outer, 2);
        assert_eq!(decoded_outer.len(), 1);
        assert_eq!(
            decode_chunks(&decoded_outer[0], 1),
            [b"one".to_vec(), vec![0, 0xff]]
        );
    }

    #[test]
    fn rejects_noncanonical_or_broken_frames() {
        let cases: &[(&[u8], Error)] = &[
            (b":", Error::MissingLength),
            (b"00:,,", Error::LeadingZero),
            (b"01:a,", Error::LeadingZero),
            (b"1x", Error::MissingColon),
            (b"1:ax", Error::InvalidTrailingComma),
            (b"0:;", Error::InvalidTrailingComma),
        ];

        for &(input, expected) in cases {
            let mut decoder = Decoder::new();
            assert_eq!(
                decoder.feed(input),
                Err(FeedError {
                    completed: Vec::new(),
                    error: expected,
                }),
                "input {input:?}"
            );
            assert_eq!(
                decoder.feed(b"0:,"),
                Err(FeedError {
                    completed: Vec::new(),
                    error: Error::DecoderFailed,
                })
            );
        }
    }

    #[test]
    fn completed_prefix_is_reported_before_a_later_frame_error_at_every_boundary() {
        let input = b"1:a,1:bx";

        for boundary in 0..=input.len() {
            let mut decoder = Decoder::new();
            let mut completed = Vec::new();
            let mut terminal_error = None;

            for chunk in [&input[..boundary], &input[boundary..]] {
                match decoder.feed(chunk) {
                    Ok(frames) => completed.extend(frames),
                    Err(error) => {
                        completed.extend(error.completed);
                        terminal_error = Some(error.error);
                        break;
                    }
                }
            }

            assert_eq!(completed, [b"a".to_vec()], "boundary {boundary}");
            assert_eq!(
                terminal_error,
                Some(Error::InvalidTrailingComma),
                "boundary {boundary}"
            );
            assert_eq!(
                decoder.feed(b"0:,"),
                Err(FeedError {
                    completed: Vec::new(),
                    error: Error::DecoderFailed,
                }),
                "boundary {boundary}"
            );
        }
    }

    #[test]
    fn rejects_length_overflow() {
        let input = format!("{}0:", usize::MAX);
        let mut decoder = Decoder::new();
        assert_eq!(
            decoder.feed(input.as_bytes()),
            Err(FeedError {
                completed: Vec::new(),
                error: Error::LengthOverflow,
            })
        );
    }

    #[test]
    fn rejects_every_kind_of_truncation_at_end_of_stream() {
        for input in [b"1".as_slice(), b"0".as_slice(), b"2:a", b"1:a"] {
            let mut decoder = Decoder::new();
            assert!(decoder.feed(input).unwrap().is_empty());
            assert_eq!(decoder.finish(), Err(Error::TruncatedFrame), "{input:?}");
        }
    }

    #[test]
    fn declared_length_does_not_preallocate_the_payload() {
        let mut decoder = Decoder::new();
        let header = format!("{}:", usize::MAX);
        assert!(decoder.feed(header.as_bytes()).unwrap().is_empty());
        let State::Payload { bytes, .. } = &decoder.state else {
            panic!("expected payload state");
        };
        assert_eq!(bytes.capacity(), 0);
    }

    proptest! {
        #[test]
        fn round_trips_arbitrary_bytes_at_arbitrary_chunk_boundaries(
            payload in prop::collection::vec(any::<u8>(), 0..=1024),
            chunk_size in 1usize..=64,
        ) {
            let encoded = encode(&payload);
            prop_assert_eq!(decode_chunks(&encoded, chunk_size), vec![payload]);
        }

        #[test]
        fn round_trips_concatenated_frames(
            payloads in prop::collection::vec(
                prop::collection::vec(any::<u8>(), 0..=128),
                0..=16,
            ),
            chunk_size in 1usize..=32,
        ) {
            let encoded: Vec<u8> = payloads.iter().flat_map(|payload| encode(payload)).collect();
            prop_assert_eq!(decode_chunks(&encoded, chunk_size), payloads);
        }

        #[test]
        fn decoding_arbitrary_input_is_total(
            input in prop::collection::vec(any::<u8>(), 0..=1024),
            chunk_size in 1usize..=64,
        ) {
            let mut decoder = Decoder::new();
            for chunk in input.chunks(chunk_size) {
                if decoder.feed(chunk).is_err() {
                    return Ok(());
                }
            }
            let _ = decoder.finish();
        }
    }
}
