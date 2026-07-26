//! Ranking of matched candidates.
//!
//! Semantics (cli-protocol.md): sort by match quality descending —
//! stricter match ranks higher (prefix > word-boundary > substring >
//! typo tolerance). Ties keep stdin order (= compsys output order).
//! An empty query means every candidate is a top-score tie, so the
//! output is simply the first max-lines candidates in stdin order.

#![allow(dead_code)] // scaffold: wired up in M2

use crate::matching::MatchScore;

/// Rank matched candidates and return their stdin indices, best first,
/// truncated to `max_lines`.
///
/// TODO(M2): stable sort by (tier asc, score desc); stability preserves
/// stdin order for ties per the contract.
pub fn rank(_scored: Vec<(usize, MatchScore)>, _max_lines: usize) -> Vec<usize> {
    Vec::new()
}
