//! Ranking of matched candidates.
//!
//! Semantics (cli-protocol.md "Matching and Ranking Semantics"): the
//! result order is one policy selected by the request producer; this module owns
//! that ordering policy while layout.rs owns the separately selected
//! geometry. Matching and insertion remain producer-independent.

use crate::matching::{TierGroup, TierHit};

/// Result ordering, mapped from the request producer by the plan layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Order {
    /// Match quality descending — stricter tier first (prefix >
    /// substring > typo tolerance > order-preserving fuzzy), ties keeping
    /// stdin order. Intra-tier ordering is an implementation detail
    /// (matching.rs's `MatchRank` is the whole ordering).
    Quality,
    /// stdin order verbatim, whatever the match quality.
    Stdin,
}

/// Order matched candidates per `order`, truncated to `max_lines`.
///
/// `matched` holds `(stdin position, hit)` pairs in stdin order; the
/// surviving pairs are returned in result order. The sort is stable, so
/// equal ranks keep stdin order per the contract.
pub fn rank(matched: &[(usize, TierHit)], max_lines: usize, order: Order) -> Vec<(usize, TierHit)> {
    // Suppress approximate tiers at the matching/ranking boundary whenever a
    // literal result exists.  Apply this before either producer ordering and
    // before truncation so both orders share the same candidate set.
    let has_literal = matched
        .iter()
        .any(|(_, hit)| hit.tier().group() == TierGroup::Literal);
    let mut ranked: Vec<(usize, TierHit)> = matched
        .iter()
        .copied()
        .filter(|(_, hit)| !has_literal || hit.tier().group() != TierGroup::Approximate)
        .collect();
    if order == Order::Quality {
        ranked.sort_by_key(|(_, hit)| hit.rank());
    }
    ranked.truncate(max_lines);
    ranked
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::matching::{EditKind, EditMatch};

    /// Rank and keep only the stdin positions, which is all these cases
    /// are about.
    fn ranked(matched: &[(usize, TierHit)], max_lines: usize, order: Order) -> Vec<usize> {
        rank(matched, max_lines, order)
            .into_iter()
            .map(|(pos, _)| pos)
            .collect()
    }

    fn edit(suffix_len: usize) -> TierHit {
        TierHit::Edit(EditMatch {
            suffix_len,
            kind: EditKind::Substitution,
        })
    }

    /// The mixed-quality fixture checks that approximate tiers are suppressed
    /// once any literal tier is present.
    fn mixed() -> Vec<(usize, TierHit)> {
        vec![
            (0, edit(0)),
            (1, TierHit::Prefix { exact: false }),
            (2, TierHit::Fuzzy { score: 50 }),
            (3, TierHit::Prefix { exact: true }),
            (4, TierHit::Substring { pos: 0 }),
            (5, TierHit::Fuzzy { score: 90 }),
        ]
    }

    #[test]
    fn quality_sorts_by_tier_then_intra_tier_rank() {
        assert_eq!(ranked(&mixed(), 10, Order::Quality), vec![3, 1, 4]);
    }

    #[test]
    fn stdin_order_ignores_match_quality() {
        assert_eq!(
            ranked(&mixed(), 10, Order::Stdin),
            vec![1, 3, 4],
            "Order::Stdin must preserve stdin order after suppression"
        );
    }

    #[test]
    fn approximate_only_inputs_are_preserved() {
        let matched = vec![
            (8, TierHit::Fuzzy { score: 10 }),
            (2, edit(20)),
            (5, TierHit::Fuzzy { score: 30 }),
        ];
        assert_eq!(ranked(&matched, 10, Order::Quality), vec![2, 5, 8]);
        assert_eq!(ranked(&matched, 10, Order::Stdin), vec![8, 2, 5]);
    }

    #[test]
    fn ties_keep_stdin_order() {
        let matched = vec![
            (7, TierHit::Fuzzy { score: 10 }),
            (3, TierHit::Fuzzy { score: 10 }),
            (9, TierHit::Fuzzy { score: 10 }),
        ];
        assert_eq!(ranked(&matched, 10, Order::Quality), vec![7, 3, 9]);
    }

    #[test]
    fn truncates_to_max_lines() {
        let matched: Vec<(usize, TierHit)> = (0..10)
            .map(|i| (i, TierHit::Prefix { exact: false }))
            .collect();
        assert_eq!(ranked(&matched, 3, Order::Quality), vec![0, 1, 2]);
        assert_eq!(ranked(&matched, 0, Order::Quality), Vec::<usize>::new());
        assert_eq!(ranked(&matched, 3, Order::Stdin), vec![0, 1, 2]);

        // Suppression precedes truncation, so approximate entries cannot
        // consume the output cap when literals are available.
        assert_eq!(ranked(&mixed(), 2, Order::Quality), vec![3, 1]);
        assert_eq!(ranked(&mixed(), 2, Order::Stdin), vec![1, 3]);
    }

    #[test]
    fn empty_input_is_empty_output() {
        assert_eq!(ranked(&[], 10, Order::Quality), Vec::<usize>::new());
        assert_eq!(ranked(&[], 10, Order::Stdin), Vec::<usize>::new());
    }
}
