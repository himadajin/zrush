//! The worker's history index and the query window a `plan` reads from it.
//!
//! Contract: docs/internal/contracts/cli-protocol.md 「要求と応答」 (write
//! kinds, generation stamp, retention cap) and 「history profile」 (payload
//! order, the query window). The index is a third generation-addressable
//! source of candidates beside the candidate store's slots, it lives and dies
//! with the worker session, and it is written only by `history-snapshot` /
//! `history-append`.
//!
//! Newest-first is the single ordering invariant: the payload of both write
//! kinds is newest first, snapshots replace the whole sequence, appends
//! prepend theirs, and a [`Window`] is a prefix of the result. Dedup and the
//! scan window exist here and nowhere else.

use std::collections::{HashSet, VecDeque};

use crate::config::HISTORY_LIMIT_MAX;
use crate::record::{Batch, Candidate, Candidates, Stored};

/// Entries retained at most (cli-protocol.md 「history profile」). It equals
/// the largest `history_limit` a request can name, so eviction can never
/// remove an entry that a legal query window would have scanned.
pub(crate) const RETENTION_CAP: usize = HISTORY_LIMIT_MAX as usize;

/// One history line and the event number it arrived with, both kept as the
/// bytes the sender emitted.
struct Entry {
    line: Box<[u8]>,
    event: Option<Box<[u8]>>,
}

/// A write the index did not accept. Its content and its stamp are unchanged,
/// and the worker answers `unknown-generation`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Rejected;

#[derive(Default)]
pub(crate) struct HistoryIndex {
    /// Newest first, so a query window is a prefix and eviction pops the back.
    entries: VecDeque<Entry>,
    /// The generation of the write that last changed the index; `None` while
    /// uninitialized, which has no stamp at all.
    generation: Option<i64>,
}

impl HistoryIndex {
    /// Whether a `plan` naming this generation resolves to the index.
    pub(crate) fn holds(&self, generation: i64) -> bool {
        self.generation == Some(generation)
    }

    /// Replace every entry with the payload's records and stamp the index.
    pub(crate) fn install(&mut self, generation: i64, stored: &Stored) -> Result<(), Rejected> {
        self.accept(generation)?;
        // Records are newest first, so the oldest surplus is the tail.
        self.entries = stored
            .candidates()
            .take(RETENTION_CAP)
            .map(Entry::from)
            .collect();
        self.generation = Some(generation);
        Ok(())
    }

    /// Prepend the payload's records in payload order and stamp the index.
    pub(crate) fn append(&mut self, generation: i64, stored: &Stored) -> Result<(), Rejected> {
        if self.generation.is_none() {
            return Err(Rejected); // an append cannot initialize the index
        }
        self.accept(generation)?;
        for index in (0..stored.candidate_count()).rev() {
            self.entries
                .push_front(Entry::from(stored.candidate(index)));
        }
        self.entries.truncate(RETENTION_CAP);
        self.generation = Some(generation);
        Ok(())
    }

    /// The entries a `plan` sees: the newest `limit` of them, keeping only
    /// the newest occurrence of each repeated line and never reaching past
    /// the window to replace one that was dropped.
    pub(crate) fn window(&self, limit: usize) -> Window<'_> {
        let scan = limit.min(RETENTION_CAP).min(self.entries.len());
        let mut seen: HashSet<&[u8]> = HashSet::with_capacity(scan);
        let selected = (0..scan)
            .filter(|&index| seen.insert(&self.entries[index].line))
            .collect();
        Window {
            index: self,
            selected,
        }
    }

    /// A write is accepted only when its generation is strictly greater than
    /// the current stamp; an uninitialized index has none, so the condition
    /// holds vacuously.
    fn accept(&self, generation: i64) -> Result<(), Rejected> {
        match self.generation {
            Some(stamp) if generation <= stamp => Err(Rejected),
            _ => Ok(()),
        }
    }
}

impl From<Candidate<'_>> for Entry {
    fn from(candidate: Candidate<'_>) -> Self {
        Entry {
            line: candidate.w.into(),
            event: candidate.n.map(Box::from),
        }
    }
}

/// One `plan`'s view of the index: the query window of cli-protocol.md
/// 「index の query」, in the index's newest-first order.
pub(crate) struct Window<'a> {
    index: &'a HistoryIndex,
    selected: Vec<usize>,
}

impl Candidates for Window<'_> {
    /// The history payload's single batch header carries no shared field
    /// (cli-protocol.md 「history profile」), so every candidate belongs to an
    /// empty one -- which is also what keeps hidden-candidate exclusion, `-f`
    /// slash synthesis and grouping inert for history listings.
    fn batches(&self) -> Vec<Batch<'_>> {
        vec![Batch::default()]
    }

    fn candidate_count(&self) -> usize {
        self.selected.len()
    }

    fn candidate(&self, index: usize) -> Candidate<'_> {
        let entry = &self.index.entries[self.selected[index]];
        Candidate {
            w: &entry.line,
            m: None,
            d: None,
            n: entry.event.as_deref(),
            batch: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record;
    use proptest::prelude::*;

    /// A history-profile payload: one empty batch header, then `w` (plus `n`
    /// when the entry carries an event number) newest first.
    fn payload(entries: &[(&str, Option<&str>)]) -> record::Stored {
        let mut bytes = b"b\x01\0".to_vec();
        for (line, event) in entries {
            bytes.extend_from_slice(b"w\x01");
            bytes.extend_from_slice(line.as_bytes());
            if let Some(event) = event {
                bytes.extend_from_slice(b"\x02n\x01");
                bytes.extend_from_slice(event.as_bytes());
            }
            bytes.push(0);
        }
        record::parse(bytes).expect("payload is framed")
    }

    /// Lines with events, newest first, as a window sees them.
    fn numbered(entries: &[(&str, &str)]) -> record::Stored {
        let owned: Vec<(&str, Option<&str>)> = entries
            .iter()
            .map(|(line, event)| (*line, Some(*event)))
            .collect();
        payload(&owned)
    }

    fn rows(window: &Window<'_>) -> Vec<(Vec<u8>, Option<Vec<u8>>)> {
        (0..window.candidate_count())
            .map(|index| {
                let candidate = window.candidate(index);
                (candidate.w.to_vec(), candidate.n.map(<[u8]>::to_vec))
            })
            .collect()
    }

    fn lines(window: &Window<'_>) -> Vec<Vec<u8>> {
        rows(window).into_iter().map(|(line, _)| line).collect()
    }

    fn installed(generation: i64, entries: &[(&str, &str)]) -> HistoryIndex {
        let mut index = HistoryIndex::default();
        index.install(generation, &numbered(entries)).unwrap();
        index
    }

    #[test]
    fn a_snapshot_keeps_the_payload_order_and_replaces_the_whole_index() {
        let mut index = installed(4, &[("c", "3"), ("b", "2"), ("a", "1")]);
        assert_eq!(lines(&index.window(10)), [b"c", b"b", b"a"]);
        assert!(index.holds(4));

        index.install(5, &numbered(&[("z", "9")])).unwrap();
        assert_eq!(lines(&index.window(10)), [b"z"]);
        assert!(index.holds(5) && !index.holds(4));
    }

    #[test]
    fn a_window_keeps_the_newest_occurrence_of_a_repeated_line() {
        let index = installed(
            1,
            &[
                ("ls", "10"),
                ("cd", "9"),
                ("ls", "8"),
                ("cd", "7"),
                ("ls", "6"),
            ],
        );
        assert_eq!(
            rows(&index.window(10)),
            [
                (b"ls".to_vec(), Some(b"10".to_vec())),
                (b"cd".to_vec(), Some(b"9".to_vec())),
            ]
        );
    }

    /// cli-protocol.md 「history profile」: event numbers are the sender's
    /// `$history` keys, so gaps stay as received and are never renumbered.
    #[test]
    fn event_numbers_are_kept_verbatim_and_may_be_absent() {
        let mut index = HistoryIndex::default();
        index
            .install(
                1,
                &payload(&[("a", Some("900")), ("b", None), ("c", Some("7"))]),
            )
            .unwrap();
        assert_eq!(
            rows(&index.window(10)),
            [
                (b"a".to_vec(), Some(b"900".to_vec())),
                (b"b".to_vec(), None),
                (b"c".to_vec(), Some(b"7".to_vec())),
            ]
        );
    }

    #[test]
    fn the_limit_bounds_the_raw_scan_window() {
        let index = installed(1, &[("d", "4"), ("c", "3"), ("b", "2"), ("a", "1")]);
        assert_eq!(lines(&index.window(4)), [b"d", b"c", b"b", b"a"]);
        assert_eq!(lines(&index.window(2)), [b"d", b"c"]);
        assert_eq!(lines(&index.window(1)), [b"d"]);
        // A limit past the index size is the whole index, and the retention
        // cap bounds the scan even when the request names more.
        assert_eq!(lines(&index.window(usize::MAX)).len(), 4);
    }

    /// The Rust twin of the end-to-end limit test: a duplicate inside the
    /// window costs a scan slot, and nothing is pulled in from outside it.
    #[test]
    fn a_deduped_entry_is_not_replaced_from_outside_the_window() {
        let index = installed(1, &[("ls", "4"), ("ls", "3"), ("cd", "2"), ("pwd", "1")]);
        assert_eq!(
            rows(&index.window(2)),
            [(b"ls".to_vec(), Some(b"4".to_vec()))]
        );
    }

    #[test]
    fn appends_land_on_the_newest_side_in_payload_order() {
        let mut index = installed(1, &[("b", "2"), ("a", "1")]);
        index
            .append(2, &numbered(&[("d", "4"), ("c", "3")]))
            .unwrap();
        assert_eq!(lines(&index.window(10)), [b"d", b"c", b"b", b"a"]);
        assert!(index.holds(2));

        index.append(3, &numbered(&[("e", "5")])).unwrap();
        assert_eq!(lines(&index.window(10)), [b"e", b"d", b"c", b"b", b"a"]);
    }

    #[test]
    fn an_appended_line_supersedes_the_snapshot_occurrence_in_a_window() {
        let mut index = installed(1, &[("ls", "2"), ("cd", "1")]);
        index.append(2, &numbered(&[("ls", "3")])).unwrap();
        assert_eq!(
            rows(&index.window(10)),
            [
                (b"ls".to_vec(), Some(b"3".to_vec())),
                (b"cd".to_vec(), Some(b"1".to_vec())),
            ]
        );
    }

    #[test]
    fn the_retention_cap_evicts_the_oldest_entries() {
        let over_cap: Vec<(String, String)> = (0..RETENTION_CAP + 2)
            .map(|i| (format!("line{i}"), (RETENTION_CAP + 2 - i).to_string()))
            .collect();
        let borrowed: Vec<(&str, &str)> = over_cap
            .iter()
            .map(|(line, event)| (line.as_str(), event.as_str()))
            .collect();

        let mut index = HistoryIndex::default();
        index.install(1, &numbered(&borrowed)).unwrap();
        let window = index.window(RETENTION_CAP);
        assert_eq!(window.candidate_count(), RETENTION_CAP);
        assert_eq!(window.candidate(0).w, b"line0");
        assert_eq!(
            window.candidate(RETENTION_CAP - 1).w,
            format!("line{}", RETENTION_CAP - 1).as_bytes()
        );

        // An append past the cap drops the same oldest side, and a window of
        // at most the cap never notices.
        index.append(2, &numbered(&[("newest", "1")])).unwrap();
        let window = index.window(RETENTION_CAP);
        assert_eq!(window.candidate_count(), RETENTION_CAP);
        assert_eq!(window.candidate(0).w, b"newest");
    }

    #[test]
    fn an_append_to_an_uninitialized_index_is_rejected_at_any_generation() {
        let mut index = HistoryIndex::default();
        assert_eq!(index.append(1, &numbered(&[("a", "1")])), Err(Rejected));
        assert_eq!(
            index.append(i64::MAX, &numbered(&[("a", "1")])),
            Err(Rejected)
        );
        assert_eq!(index.window(10).candidate_count(), 0);
        assert!(!index.holds(1));
    }

    /// An uninitialized index has no stamp, so "strictly greater" holds
    /// vacuously for a snapshot at any generation.
    #[test]
    fn a_snapshot_initializes_the_index_at_any_generation() {
        let mut index = HistoryIndex::default();
        index.install(1, &numbered(&[("a", "1")])).unwrap();
        assert!(index.holds(1));
    }

    #[test]
    fn a_rejected_write_leaves_both_the_entries_and_the_stamp_untouched() {
        let mut index = installed(5, &[("b", "2"), ("a", "1")]);

        for generation in [1, 5] {
            assert_eq!(
                index.install(generation, &numbered(&[("x", "9")])),
                Err(Rejected)
            );
            assert_eq!(
                index.append(generation, &numbered(&[("x", "9")])),
                Err(Rejected)
            );
        }
        assert_eq!(lines(&index.window(10)), [b"b", b"a"]);
        assert!(index.holds(5));
    }

    fn generated_entries() -> impl Strategy<Value = Vec<(Vec<u8>, Option<Vec<u8>>)>> {
        let entry = (
            prop::collection::vec(prop::sample::select(b"abc".to_vec()), 1..=3),
            prop::option::of(prop::collection::vec(b'0'..=b'9', 1..=3)),
        );
        prop::collection::vec(entry, 0..=24)
    }

    fn generated_payload(entries: &[(Vec<u8>, Option<Vec<u8>>)]) -> record::Stored {
        let mut bytes = b"b\x01\0".to_vec();
        for (line, event) in entries {
            bytes.extend_from_slice(b"w\x01");
            bytes.extend_from_slice(line);
            if let Some(event) = event {
                bytes.extend_from_slice(b"\x02n\x01");
                bytes.extend_from_slice(event);
            }
            bytes.push(0);
        }
        record::parse(bytes).expect("generated payload is framed")
    }

    proptest! {
        /// The window's four defining properties, over arbitrary entries and
        /// limits: it is bounded by the limit, free of repeated lines, a
        /// subsequence of the index's newest-first order, and carries each
        /// line's newest in-window event number.
        #[test]
        fn windows_are_deduped_prefixes_of_the_index(
            snapshot in generated_entries(),
            appended in generated_entries(),
            limit in 1usize..=32,
        ) {
            let mut index = HistoryIndex::default();
            index.install(1, &generated_payload(&snapshot)).unwrap();
            index.append(2, &generated_payload(&appended)).unwrap();

            // The scanned prefix: the appended records sit newest-side of the
            // snapshot's, and the limit cuts the older end.
            let mut scanned: Vec<(Vec<u8>, Option<Vec<u8>>)> = appended;
            scanned.extend(snapshot);
            scanned.truncate(limit);
            // Reference reading of 「index の query」: the first occurrence of
            // each line in that prefix, which is its newest one.
            let mut taken = HashSet::new();
            let expected: Vec<_> = scanned
                .into_iter()
                .filter(|(line, _)| taken.insert(line.clone()))
                .collect();

            let actual = rows(&index.window(limit));
            prop_assert!(actual.len() <= limit);
            let mut seen = HashSet::new();
            prop_assert!(
                actual.iter().all(|(line, _)| seen.insert(line.clone())),
                "window repeats a line: {actual:?}"
            );
            prop_assert_eq!(actual, expected);
        }
    }
}
