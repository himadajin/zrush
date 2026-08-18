//! End-exclusive char-offset spans.
//!
//! Char intervals travel in two shapes: the render-plan wire format writes
//! `start len` (cli-protocol.md "Highlights"), while everything that
//! computes offsets -- matching's match spans, layout's cell ranges --
//! works in `[start, end)`. Both are pairs of usize, so reading one as the
//! other type-checks and has produced real bugs (layout.rs's
//! `match_span_uses_end_exclusive_semantics_not_start_len` pins one).
//!
//! The end-exclusive form therefore travels as this type, and
//! [`CharSpan::len`] is the single operation the wire serializer uses to
//! derive `len` from it.

/// A `[start, end)` range of chars over the lossy UTF-8 reading of some
/// text -- the offset unit of cli-protocol.md "Offset Rules", never a
/// display width.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct CharSpan {
    pub start: usize,
    pub end: usize,
}

impl CharSpan {
    /// `start..end`. An inverted range is an empty span at `start`, so
    /// `len` can never underflow.
    pub fn new(start: usize, end: usize) -> Self {
        CharSpan {
            start,
            end: end.max(start),
        }
    }

    /// The wire format's `len` field: the one place the end-exclusive
    /// form becomes a length.
    pub fn len(self) -> usize {
        self.end - self.start
    }

    pub fn is_empty(self) -> bool {
        self.start == self.end
    }

    /// This span cut down to the first `limit` chars of the text it
    /// indexes.
    pub fn clip(self, limit: usize) -> Self {
        CharSpan {
            start: self.start.min(limit),
            end: self.end.min(limit),
        }
    }

    /// This span moved `by` chars later, to index an enclosing text.
    pub fn shift(self, by: usize) -> Self {
        CharSpan {
            start: self.start + by,
            end: self.end + by,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn len_is_the_end_exclusive_width() {
        assert_eq!(CharSpan::new(3, 7).len(), 4);
        assert_eq!(CharSpan::new(0, 0).len(), 0);
        assert!(CharSpan::new(2, 2).is_empty());
        assert!(!CharSpan::new(2, 3).is_empty());
    }

    #[test]
    fn inverted_input_is_an_empty_span() {
        assert_eq!(CharSpan::new(5, 2), CharSpan::new(5, 5));
        assert_eq!(CharSpan::new(5, 2).len(), 0);
    }

    #[test]
    fn clip_cuts_both_ends_to_the_visible_text() {
        assert_eq!(CharSpan::new(1, 5).clip(3), CharSpan::new(1, 3));
        assert_eq!(CharSpan::new(1, 5).clip(9), CharSpan::new(1, 5));
        // entirely past the limit: empty, not a wrapped range
        assert!(CharSpan::new(4, 6).clip(2).is_empty());
    }

    #[test]
    fn shift_moves_the_whole_span() {
        assert_eq!(CharSpan::new(1, 3).shift(10), CharSpan::new(11, 13));
        assert_eq!(CharSpan::new(1, 3).shift(0), CharSpan::new(1, 3));
    }
}
