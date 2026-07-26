//! Fuzzy matching: prefix / substring / typo modes.
//!
//! Semantics: docs/internal/contracts/cli-protocol.md (source of truth).
//! Modes widen cumulatively: typo ⊇ substring ⊇ prefix.
//! - prefix:    match-text starts with the query.
//! - substring: match-text contains the query.
//! - typo:      additionally, order-preserving fuzzy (dcs -> docs) and
//!   light typos — adjacent transposition or one
//!   substitution/insertion/deletion (gti -> git).
//!
//! Implementation strategy (decided by the M2 nucleo-matcher evaluation):
//! hybrid. nucleo-matcher's fuzzy match is strict-subsequence, so it
//! covers the order-preserving fuzzy part (and deletions, which are
//! subsequences) with good intra-tier scoring, but it can NOT catch
//! transposition / substitution / insertion (gti->git, verbso->verbose,
//! gir->git all score None). Those are covered by our own bounded
//! prefix-edit-distance (<= 1 edit incl. adjacent transposition).
//! Tier ordering (prefix > boundary > substring > fuzzy/typo) is decided
//! by us, not by nucleo's raw score: nucleo can rank a scattered fuzzy
//! match above a plain substring match (measured: "doc" scored
//! dot-config 82 > my-docs 80 > mydocs 56).

#![allow(dead_code)] // scaffold: wired up in M2

/// Matching strength, cumulative.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Prefix,
    Substring,
    Typo,
}

impl Mode {
    /// Parse the config/CLI notation ("prefix" | "substring" | "typo").
    pub fn parse(s: &str) -> Option<Mode> {
        match s {
            "prefix" => Some(Mode::Prefix),
            "substring" => Some(Mode::Substring),
            "typo" => Some(Mode::Typo),
            _ => None,
        }
    }
}

/// How a candidate matched. Discriminant order = rank tier order
/// (better first); ranking.rs sorts by (tier, intra-tier score).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Tier {
    Prefix,
    Substring,
    Fuzzy,
    Edit,
}

/// Match result for one candidate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MatchScore {
    pub tier: Tier,
    /// Higher is better, only comparable within the same tier.
    pub score: u32,
}

/// Match one candidate against the query under the given mode.
///
/// Strings are byte sequences (no encoding validation may drop a
/// candidate). smart_case: query all-lowercase => case-insensitive.
///
/// TODO(M2): implement.
/// - prefix/substring tiers: direct byte comparison.
/// - fuzzy tier: nucleo-matcher fuzzy_match (lossy UTF-8 conversion of
///   the haystack only for matching; indices returned to zsh are opaque,
///   so candidates are never dropped or altered).
/// - edit tier: own bounded prefix edit distance (1 edit, adjacent
///   transposition counts as one) so "gti" matches "git" and "git-lfs".
pub fn match_candidate(
    _query: &[u8],
    _candidate: &[u8],
    _mode: Mode,
    _smart_case: bool,
) -> Option<MatchScore> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mode_parses_contract_notation() {
        assert_eq!(Mode::parse("prefix"), Some(Mode::Prefix));
        assert_eq!(Mode::parse("substring"), Some(Mode::Substring));
        assert_eq!(Mode::parse("typo"), Some(Mode::Typo));
        assert_eq!(Mode::parse("Typo"), None);
        assert_eq!(Mode::parse(""), None);
    }

    #[test]
    fn tier_ordering_matches_ranking_semantics() {
        assert!(Tier::Prefix < Tier::Substring);
        assert!(Tier::Substring < Tier::Fuzzy);
        assert!(Tier::Fuzzy < Tier::Edit);
    }

    /// Canary for the M2 evaluation result the hybrid design relies on:
    /// nucleo's fuzzy match is strict-subsequence — it must keep catching
    /// subsequences and must NOT suddenly catch transpositions (if this
    /// changes on an upgrade, revisit the edit tier).
    #[test]
    fn nucleo_is_strict_subsequence() {
        use nucleo_matcher::{Config, Matcher, Utf32Str};
        let mut m = Matcher::new(Config::DEFAULT);
        let mut qb = Vec::new();
        let mut hb = Vec::new();
        let hit = |m: &mut Matcher, q: &str, h: &str, qb: &mut Vec<char>, hb: &mut Vec<char>| {
            m.fuzzy_match(Utf32Str::new(h, hb), Utf32Str::new(q, qb))
                .is_some()
        };
        assert!(hit(&mut m, "dcs", "docs", &mut qb, &mut hb));
        assert!(hit(&mut m, "inte", "internal", &mut qb, &mut hb));
        assert!(!hit(&mut m, "gti", "git", &mut qb, &mut hb));
        assert!(!hit(&mut m, "verbso", "verbose", &mut qb, &mut hb));
    }
}
