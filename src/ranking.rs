//! Ranking of matched candidates.
//!
//! Semantics (cli-protocol.md): sort by match quality descending —
//! stricter tier ranks higher (prefix > substring > order-preserving
//! fuzzy > typo tolerance). Ties keep stdin order (= compsys output
//! order). Intra-tier ordering is an implementation detail
//! (matching.rs assigns the scores).

use crate::matching::MatchScore;

/// Rank matched candidates, best first, truncated to `max_lines`.
///
/// `scored` holds `(stdin position, score)` pairs in stdin order; the
/// returned values are the stdin positions. The sort is stable, so
/// equal (tier, score) pairs keep stdin order per the contract.
pub fn rank(scored: &[(usize, MatchScore)], max_lines: usize) -> Vec<usize> {
    let mut order: Vec<usize> = (0..scored.len()).collect();
    order.sort_by_key(|&k| (scored[k].1.tier, std::cmp::Reverse(scored[k].1.score)));
    order
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

    #[test]
    fn sorts_by_tier_then_score_desc() {
        let scored = vec![
            (0, ms(Tier::Edit, 0)),
            (1, ms(Tier::Prefix, 0)),
            (2, ms(Tier::Fuzzy, 50)),
            (3, ms(Tier::Prefix, 1)),
            (4, ms(Tier::Substring, u32::MAX)),
            (5, ms(Tier::Fuzzy, 90)),
        ];
        assert_eq!(rank(&scored, 10), vec![3, 1, 4, 5, 2, 0]);
    }

    #[test]
    fn ties_keep_stdin_order() {
        let scored = vec![
            (7, ms(Tier::Fuzzy, 10)),
            (3, ms(Tier::Fuzzy, 10)),
            (9, ms(Tier::Fuzzy, 10)),
        ];
        assert_eq!(rank(&scored, 10), vec![7, 3, 9]);
    }

    #[test]
    fn truncates_to_max_lines() {
        let scored: Vec<(usize, MatchScore)> = (0..10).map(|i| (i, ms(Tier::Prefix, 0))).collect();
        assert_eq!(rank(&scored, 3), vec![0, 1, 2]);
        assert_eq!(rank(&scored, 0), Vec::<usize>::new());
    }

    #[test]
    fn empty_input_is_empty_output() {
        assert_eq!(rank(&[], 10), Vec::<usize>::new());
    }
}
