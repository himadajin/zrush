//! Ranking of matched candidates.
//!
//! Semantics (cli-protocol.md "マッチング・ランキングの意味論"): the
//! result order is one policy selected by the request producer; this module owns
//! that ordering policy while layout.rs owns the separately selected
//! geometry. Matching and insertion remain producer-independent.

use crate::matching::{MatchScore, TierGroup};

/// Result ordering, mapped from the request producer by the plan layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Order {
    /// Match quality descending — stricter tier first (prefix >
    /// substring > typo tolerance > order-preserving fuzzy), ties keeping
    /// stdin order. Intra-tier ordering is an implementation detail
    /// (matching.rs assigns the scores).
    Quality,
    /// stdin order verbatim, whatever the match quality.
    Stdin,
}

/// Order matched candidates per `order`, truncated to `max_lines`.
///
/// `scored` holds `(stdin position, score)` pairs in stdin order; the
/// returned values are the stdin positions. The sort is stable, so
/// equal (tier, score) pairs keep stdin order per the contract.
pub fn rank(scored: &[(usize, MatchScore)], max_lines: usize, order: Order) -> Vec<usize> {
    // Suppress approximate tiers at the matching/ranking boundary whenever a
    // literal result exists.  Apply this before either producer ordering and
    // before truncation so both orders share the same candidate set.
    let has_literal = scored
        .iter()
        .any(|(_, score)| score.tier.group() == TierGroup::Literal);
    let mut ranked: Vec<usize> = scored
        .iter()
        .enumerate()
        .filter(|(_, (_, score))| !has_literal || score.tier.group() != TierGroup::Approximate)
        .map(|(k, _)| k)
        .collect();
    if order == Order::Quality {
        ranked.sort_by_key(|&k| (scored[k].1.tier, std::cmp::Reverse(scored[k].1.score)));
    }
    ranked
        .into_iter()
        .take(max_lines)
        .map(|k| scored[k].0)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::matching::Tier;

    fn ms(tier: Tier, score: u32) -> MatchScore {
        MatchScore { tier, score }
    }

    /// The mixed-quality fixture checks that approximate tiers are suppressed
    /// once any literal tier is present.
    fn mixed() -> Vec<(usize, MatchScore)> {
        vec![
            (0, ms(Tier::Edit, 0)),
            (1, ms(Tier::Prefix, 0)),
            (2, ms(Tier::Fuzzy, 50)),
            (3, ms(Tier::Prefix, 1)),
            (4, ms(Tier::Substring, u32::MAX)),
            (5, ms(Tier::Fuzzy, 90)),
        ]
    }

    #[test]
    fn quality_sorts_by_tier_then_score_desc() {
        assert_eq!(rank(&mixed(), 10, Order::Quality), vec![3, 1, 4]);
    }

    #[test]
    fn stdin_order_ignores_match_quality() {
        assert_eq!(
            rank(&mixed(), 10, Order::Stdin),
            vec![1, 3, 4],
            "Order::Stdin must preserve stdin order after suppression"
        );
    }

    #[test]
    fn approximate_only_inputs_are_preserved() {
        let scored = vec![
            (8, ms(Tier::Fuzzy, 10)),
            (2, ms(Tier::Edit, 20)),
            (5, ms(Tier::Fuzzy, 30)),
        ];
        assert_eq!(rank(&scored, 10, Order::Quality), vec![2, 5, 8]);
        assert_eq!(rank(&scored, 10, Order::Stdin), vec![8, 2, 5]);
    }

    #[test]
    fn ties_keep_stdin_order() {
        let scored = vec![
            (7, ms(Tier::Fuzzy, 10)),
            (3, ms(Tier::Fuzzy, 10)),
            (9, ms(Tier::Fuzzy, 10)),
        ];
        assert_eq!(rank(&scored, 10, Order::Quality), vec![7, 3, 9]);
    }

    #[test]
    fn truncates_to_max_lines() {
        let scored: Vec<(usize, MatchScore)> = (0..10).map(|i| (i, ms(Tier::Prefix, 0))).collect();
        assert_eq!(rank(&scored, 3, Order::Quality), vec![0, 1, 2]);
        assert_eq!(rank(&scored, 0, Order::Quality), Vec::<usize>::new());
        assert_eq!(rank(&scored, 3, Order::Stdin), vec![0, 1, 2]);

        // Suppression precedes truncation, so approximate entries cannot
        // consume the output cap when literals are available.
        assert_eq!(rank(&mixed(), 2, Order::Quality), vec![3, 1]);
        assert_eq!(rank(&mixed(), 2, Order::Stdin), vec![1, 3]);
    }

    #[test]
    fn empty_input_is_empty_output() {
        assert_eq!(rank(&[], 10, Order::Quality), Vec::<usize>::new());
        assert_eq!(rank(&[], 10, Order::Stdin), Vec::<usize>::new());
    }
}
