//! Ranking of matched candidates.
//!
//! Semantics (cli-protocol.md "マッチング・ランキングの意味論"): the
//! result order is one policy selected by `--producer`; this module owns
//! that ordering policy while layout.rs owns the separately selected
//! geometry. Matching and insertion remain producer-independent.

use crate::matching::MatchScore;

/// Result ordering, mapped from `--producer` by the CLI layer.
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
    let mut ranked: Vec<usize> = (0..scored.len()).collect();
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

    /// The mixed-quality fixture both orderings are checked against, so
    /// the two tests differ only in the ordering they pass.
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
        assert_eq!(rank(&mixed(), 10, Order::Quality), vec![3, 1, 4, 0, 5, 2]);
    }

    #[test]
    fn stdin_order_ignores_match_quality() {
        assert_eq!(
            rank(&mixed(), 10, Order::Stdin),
            vec![0, 1, 2, 3, 4, 5],
            "Order::Stdin must not reorder by tier or score"
        );
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
    }

    #[test]
    fn empty_input_is_empty_output() {
        assert_eq!(rank(&[], 10, Order::Quality), Vec::<usize>::new());
        assert_eq!(rank(&[], 10, Order::Stdin), Vec::<usize>::new());
    }
}
