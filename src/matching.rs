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
//! Implementation: hybrid (decided by the M2 nucleo-matcher evaluation).
//! - prefix/substring tiers: direct byte comparison.
//! - fuzzy tier: nucleo-matcher `fuzzy_match` (strict subsequence with
//!   good intra-tier scoring). It cannot catch transposition /
//!   substitution / insertion (gti->git, verbso->verbose, gir->git all
//!   score None) — those go to:
//! - edit tier: our own bounded prefix edit distance (<= 1 edit,
//!   adjacent transposition counts as one; the candidate may extend
//!   beyond the aligned prefix, so "gti" matches both "git" and
//!   "git-lfs").
//!
//! Tier ordering (prefix > substring > fuzzy > edit) is decided here,
//! not by nucleo's raw score: nucleo can rank a scattered fuzzy match
//! above a plain substring match (measured: "doc" scored dot-config 82 >
//! my-docs 80 > mydocs 56). Intra-tier scores are an implementation
//! detail per the contract.
//!
//! Byte semantics: strings are byte sequences and candidates are never
//! dropped on invalid UTF-8. Case handling is decided once here and
//! applied uniformly to every tier: when insensitive, query and
//! candidate are ASCII-lowercased and nucleo runs with ignore_case=false
//! and normalize=false on the folded bytes, so all four tiers agree.
//! Non-ASCII case folding is intentionally not performed (byte-safe;
//! multi-byte folding can change lengths). The haystack is passed to
//! nucleo via lossy UTF-8 conversion (invalid bytes become U+FFFD) —
//! acceptable because match-text is used only to decide match/score and
//! indices returned to zsh are opaque.

use nucleo_matcher::{Config as NucleoConfig, Matcher, Utf32Str};

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

    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Prefix => "prefix",
            Mode::Substring => "substring",
            Mode::Typo => "typo",
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
    /// Higher is better; only comparable within the same tier.
    pub score: u32,
}

/// Per-invocation matcher: holds the prepared query and scratch buffers,
/// scores one candidate at a time.
pub struct QueryMatcher {
    mode: Mode,
    /// true => case-insensitive (ASCII fold both sides).
    fold: bool,
    /// Query bytes, folded when `fold`.
    query: Vec<u8>,
    /// Lossy string form of `query` for nucleo.
    query_str: String,
    nucleo: Matcher,
    hay_fold_buf: Vec<u8>,
    hay_char_buf: Vec<char>,
    query_char_buf: Vec<char>,
}

impl QueryMatcher {
    pub fn new(query_raw: &[u8], mode: Mode, smart_case: bool) -> Self {
        // smart-case: query all-lowercase => insensitive; any uppercase
        // (Unicode-aware detection) => sensitive. smart_case=false =>
        // always insensitive (contract: "常に区別しない").
        let sensitive = smart_case
            && String::from_utf8_lossy(query_raw)
                .chars()
                .any(char::is_uppercase);
        let fold = !sensitive;
        let query = if fold {
            query_raw.to_ascii_lowercase()
        } else {
            query_raw.to_vec()
        };
        let query_str = String::from_utf8_lossy(&query).into_owned();
        let mut ncfg = NucleoConfig::DEFAULT;
        // Case and normalization are handled on our side so every tier
        // sees identical bytes; keep nucleo strictly literal.
        ncfg.ignore_case = false;
        ncfg.normalize = false;
        ncfg.prefer_prefix = false; // tier ordering handles prefix preference
        QueryMatcher {
            mode,
            fold,
            query,
            query_str,
            nucleo: Matcher::new(ncfg),
            hay_fold_buf: Vec::new(),
            hay_char_buf: Vec::new(),
            query_char_buf: Vec::new(),
        }
    }

    /// Score one candidate's match-text. None = no match under the mode.
    pub fn score(&mut self, cand_raw: &[u8]) -> Option<MatchScore> {
        // Empty query: every candidate is a top-tier tie (contract);
        // ranking's stable sort then preserves stdin order.
        if self.query.is_empty() {
            return Some(MatchScore {
                tier: Tier::Prefix,
                score: 0,
            });
        }
        let QueryMatcher {
            mode,
            fold,
            query,
            query_str,
            nucleo,
            hay_fold_buf,
            hay_char_buf,
            query_char_buf,
        } = self;
        let q: &[u8] = query;
        let cand: &[u8] = if *fold {
            hay_fold_buf.clear();
            hay_fold_buf.extend(cand_raw.iter().map(u8::to_ascii_lowercase));
            hay_fold_buf
        } else {
            cand_raw
        };

        if cand.starts_with(q) {
            // Exact equality outranks a proper prefix; further ties keep
            // stdin order.
            let exact = cand.len() == q.len();
            return Some(MatchScore {
                tier: Tier::Prefix,
                score: u32::from(exact),
            });
        }
        if *mode == Mode::Prefix {
            return None;
        }

        if q.len() <= cand.len()
            && let Some(pos) = cand.windows(q.len()).position(|w| w == q)
        {
            // Earlier occurrence ranks higher within the tier.
            return Some(MatchScore {
                tier: Tier::Substring,
                score: u32::MAX - pos as u32,
            });
        }
        if *mode == Mode::Substring {
            return None;
        }

        // Fuzzy tier: nucleo strict-subsequence match.
        let cand_lossy = String::from_utf8_lossy(cand);
        let hay = Utf32Str::new(&cand_lossy, hay_char_buf);
        let needle = Utf32Str::new(query_str, query_char_buf);
        if let Some(s) = nucleo.fuzzy_match(hay, needle) {
            return Some(MatchScore {
                tier: Tier::Fuzzy,
                score: u32::from(s),
            });
        }

        // Edit tier: bounded prefix edit distance. Skipped for 1-byte
        // queries: a single-char query within one edit would match every
        // candidate (substitution or trailing deletion), which is pure
        // noise; substring/fuzzy already cover the sensible matches.
        if q.len() >= 2 && prefix_edit_within_one(q, cand) {
            return Some(MatchScore {
                tier: Tier::Edit,
                score: 0,
            });
        }
        None
    }
}

/// Does some prefix of `cand` lie within one edit (optimal string
/// alignment: substitution / insertion / deletion / adjacent
/// transposition) of `q`? Byte-based, O(|q|).
///
/// Only a prefix of the candidate is aligned; the remaining candidate
/// suffix is free, so a typo of a word's beginning still matches longer
/// candidates ("gti" -> "git-lfs").
fn prefix_edit_within_one(q: &[u8], cand: &[u8]) -> bool {
    let m = q.len();
    // Any aligned prefix within one edit consumes at most m+1 bytes.
    let b = &cand[..cand.len().min(m + 1)];
    let n = b.len();
    if n + 1 < m {
        return false; // would need more than one deletion
    }
    let k = q.iter().zip(b).take_while(|(a, c)| a == c).count();
    if k == m {
        return true; // distance 0 against the prefix b[..m]
    }
    // Exactly one edit at the first mismatch position k; the remainder
    // of q must then match the remainder of b exactly (b may extend
    // beyond — prefix semantics).
    // deletion: q[k] is an extra typed character.
    if b[k..].starts_with(&q[k + 1..]) {
        return true;
    }
    if k < n {
        // substitution at k.
        if b[k + 1..].starts_with(&q[k + 1..]) {
            return true;
        }
        // insertion: b[k] is a character the user failed to type.
        if b[k + 1..].starts_with(&q[k..]) {
            return true;
        }
        // adjacent transposition at k/k+1.
        if k + 1 < m && k + 1 < n && q[k] == b[k + 1] && q[k + 1] == b[k] {
            return b[k + 2..].starts_with(&q[k + 2..]);
        }
    }
    false
}

/// Byte-wise longest common prefix over the matched candidates'
/// match-texts (for the stdout common-prefix field).
pub fn common_prefix<'a>(mut texts: impl Iterator<Item = &'a [u8]>) -> &'a [u8] {
    let Some(mut acc) = texts.next() else {
        return b"";
    };
    for t in texts {
        let l = acc.iter().zip(t).take_while(|(a, b)| a == b).count();
        acc = &acc[..l];
        if acc.is_empty() {
            break;
        }
    }
    acc
}

#[cfg(test)]
mod tests {
    use super::*;

    fn score(q: &[u8], cand: &[u8], mode: Mode, smart_case: bool) -> Option<MatchScore> {
        QueryMatcher::new(q, mode, smart_case).score(cand)
    }

    fn tier(q: &str, cand: &str, mode: Mode) -> Option<Tier> {
        score(q.as_bytes(), cand.as_bytes(), mode, true).map(|m| m.tier)
    }

    #[test]
    fn required_typo_cases() {
        assert_eq!(tier("gti", "git", Mode::Typo), Some(Tier::Edit));
        assert_eq!(tier("gti", "git-lfs", Mode::Typo), Some(Tier::Edit));
        assert_eq!(tier("dcs", "docs", Mode::Typo), Some(Tier::Fuzzy));
        assert_eq!(tier("inte", "internal", Mode::Typo), Some(Tier::Prefix));
        assert_eq!(tier("verbso", "verbose", Mode::Typo), Some(Tier::Edit));
        assert_eq!(tier("gir", "git", Mode::Typo), Some(Tier::Edit));
        // one dropped char in the query = subsequence, but prefix wins here
        assert_eq!(tier("instal", "install", Mode::Typo), Some(Tier::Prefix));
        assert_eq!(tier("installl", "install", Mode::Typo), Some(Tier::Edit));
        // non-matches stay non-matches
        assert_eq!(tier("gti", "grep", Mode::Typo), None);
        assert_eq!(tier("zzz", "docs", Mode::Typo), None);
    }

    #[test]
    fn modes_are_cumulative() {
        // prefix mode: prefix only
        assert_eq!(tier("sta", "star", Mode::Prefix), Some(Tier::Prefix));
        assert_eq!(tier("tar", "star", Mode::Prefix), None);
        assert_eq!(tier("gti", "git", Mode::Prefix), None);
        // substring mode: prefix + substring, no fuzzy/edit
        assert_eq!(tier("tar", "star", Mode::Substring), Some(Tier::Substring));
        assert_eq!(tier("dcs", "docs", Mode::Substring), None);
        assert_eq!(tier("gti", "git", Mode::Substring), None);
        // typo mode: everything
        assert_eq!(tier("tar", "star", Mode::Typo), Some(Tier::Substring));
    }

    #[test]
    fn tier_assignment_prefers_stricter_tiers() {
        assert_eq!(tier("doc", "docs", Mode::Typo), Some(Tier::Prefix));
        assert_eq!(tier("doc", "mydocs", Mode::Typo), Some(Tier::Substring));
        assert_eq!(tier("doc", "dot-config", Mode::Typo), Some(Tier::Fuzzy));
    }

    #[test]
    fn exact_prefix_match_outscores_proper_prefix() {
        let exact = score(b"git", b"git", Mode::Typo, true).unwrap();
        let proper = score(b"git", b"gitk", Mode::Typo, true).unwrap();
        assert_eq!(exact.tier, Tier::Prefix);
        assert_eq!(proper.tier, Tier::Prefix);
        assert!(exact.score > proper.score);
    }

    #[test]
    fn earlier_substring_occurrence_scores_higher() {
        let early = score(b"doc", b"mydocs", Mode::Typo, true).unwrap();
        let late = score(b"doc", b"my-old-docs", Mode::Typo, true).unwrap();
        assert_eq!(early.tier, Tier::Substring);
        assert_eq!(late.tier, Tier::Substring);
        assert!(early.score > late.score);
    }

    #[test]
    fn smart_case_semantics() {
        // all-lowercase query: insensitive
        assert_eq!(tier("read", "README.md", Mode::Typo), Some(Tier::Prefix));
        // uppercase in query: sensitive
        assert_eq!(tier("READ", "README.md", Mode::Typo), Some(Tier::Prefix));
        assert_eq!(score(b"READ", b"readme", Mode::Typo, true), None);
        // smart_case=false: always insensitive
        assert_eq!(
            score(b"READ", b"readme", Mode::Typo, false).map(|m| m.tier),
            Some(Tier::Prefix)
        );
        // case folding applies to the edit tier too
        assert_eq!(tier("gti", "GIT", Mode::Typo), Some(Tier::Edit));
        assert_eq!(score(b"GTI", b"git", Mode::Typo, true), None);
    }

    #[test]
    fn empty_query_matches_everything_equally() {
        let a = score(b"", b"anything", Mode::Prefix, true).unwrap();
        let b = score(b"", b"", Mode::Typo, true).unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn single_char_query_skips_edit_tier() {
        assert_eq!(tier("g", "grep", Mode::Typo), Some(Tier::Prefix));
        assert_eq!(tier("g", "log", Mode::Typo), Some(Tier::Substring));
        // no edit-tier noise: "a" must not match an unrelated candidate
        assert_eq!(tier("a", "zzz", Mode::Typo), None);
    }

    #[test]
    fn non_utf8_candidates_are_matchable_and_never_dropped() {
        // byte-exact prefix works regardless of encoding
        assert_eq!(
            score(b"caf", b"caf\xe9.txt", Mode::Prefix, true).map(|m| m.tier),
            Some(Tier::Prefix)
        );
        // fuzzy tier goes through lossy conversion without dropping
        assert_eq!(
            score(b"cf", b"caf\xe9x", Mode::Typo, true).map(|m| m.tier),
            Some(Tier::Fuzzy)
        );
        // edit tier is byte-based
        assert_eq!(
            score(b"cfa\xe9", b"caf\xe9", Mode::Typo, true).map(|m| m.tier),
            Some(Tier::Edit)
        );
    }

    #[test]
    fn prefix_edit_examples() {
        assert!(prefix_edit_within_one(b"gti", b"git")); // transposition
        assert!(prefix_edit_within_one(b"gti", b"git-lfs")); // + free suffix
        assert!(prefix_edit_within_one(b"verbso", b"verbose")); // transposition
        assert!(prefix_edit_within_one(b"gir", b"git")); // substitution
        assert!(prefix_edit_within_one(b"installl", b"install")); // deletion
        assert!(prefix_edit_within_one(b"instal", b"install")); // insertion
        assert!(prefix_edit_within_one(b"gt", b"grep")); // trailing deletion
        assert!(!prefix_edit_within_one(b"gti", b"grep"));
        assert!(!prefix_edit_within_one(b"abc", b"a"));
        assert!(!prefix_edit_within_one(b"ab", b""));
    }

    /// Cross-check the O(|q|) case analysis against a straightforward
    /// OSA (Damerau-Levenshtein without repeated edits) DP reference,
    /// exhaustively over a small alphabet.
    #[test]
    fn prefix_edit_matches_dp_reference_exhaustively() {
        #[allow(clippy::needless_range_loop)] // literal textbook DP transcription
        fn dp_reference(q: &[u8], cand: &[u8]) -> bool {
            let m = q.len();
            let b = &cand[..cand.len().min(m + 1)];
            let n = b.len();
            let w = n + 1;
            let mut d = vec![0u8; (m + 1) * w];
            for j in 0..=n {
                d[j] = j.min(2) as u8;
            }
            for i in 1..=m {
                d[i * w] = i.min(2) as u8;
                for j in 1..=n {
                    let cost = u8::from(q[i - 1] != b[j - 1]);
                    let mut v = (d[(i - 1) * w + j] + 1)
                        .min(d[i * w + j - 1] + 1)
                        .min(d[(i - 1) * w + j - 1] + cost);
                    if i >= 2 && j >= 2 && q[i - 1] == b[j - 2] && q[i - 2] == b[j - 1] {
                        v = v.min(d[(i - 2) * w + j - 2] + 1);
                    }
                    d[i * w + j] = v.min(2);
                }
            }
            d[m * w..].iter().any(|&v| v <= 1)
        }

        fn all_strings(alphabet: &[u8], max_len: usize) -> Vec<Vec<u8>> {
            let mut out: Vec<Vec<u8>> = vec![Vec::new()];
            let mut layer: Vec<Vec<u8>> = vec![Vec::new()];
            for _ in 0..max_len {
                let mut next = Vec::new();
                for s in &layer {
                    for &c in alphabet {
                        let mut t = s.clone();
                        t.push(c);
                        next.push(t);
                    }
                }
                out.extend(next.iter().cloned());
                layer = next;
            }
            out
        }

        let queries = all_strings(b"abc", 4);
        let cands = all_strings(b"abc", 5);
        for q in &queries {
            if q.is_empty() {
                continue;
            }
            for c in &cands {
                assert_eq!(
                    prefix_edit_within_one(q, c),
                    dp_reference(q, c),
                    "q={:?} cand={:?}",
                    String::from_utf8_lossy(q),
                    String::from_utf8_lossy(c),
                );
            }
        }
    }

    #[test]
    fn common_prefix_cases() {
        assert_eq!(common_prefix(std::iter::empty()), b"");
        let one: [&[u8]; 1] = [b"docs/"];
        assert_eq!(common_prefix(one.iter().copied()), b"docs/");
        let shared: [&[u8]; 3] = [b"git", b"gitk", b"git-lfs"];
        assert_eq!(common_prefix(shared.iter().copied()), b"git");
        let disjoint: [&[u8]; 2] = [b"abc", b"xyz"];
        assert_eq!(common_prefix(disjoint.iter().copied()), b"");
        let same: [&[u8]; 2] = [b"same", b"same"];
        assert_eq!(common_prefix(same.iter().copied()), b"same");
    }

    #[test]
    fn mode_parses_contract_notation() {
        assert_eq!(Mode::parse("prefix"), Some(Mode::Prefix));
        assert_eq!(Mode::parse("substring"), Some(Mode::Substring));
        assert_eq!(Mode::parse("typo"), Some(Mode::Typo));
        assert_eq!(Mode::parse("Typo"), None);
        assert_eq!(Mode::parse(""), None);
    }

    /// Canary for the hybrid design's core assumption: nucleo's fuzzy
    /// match is strict-subsequence. If an upgrade starts catching
    /// transpositions, revisit the edit tier.
    #[test]
    fn nucleo_is_strict_subsequence() {
        use nucleo_matcher::{Config, Matcher, Utf32Str};
        let mut m = Matcher::new(Config::DEFAULT);
        let mut qb = Vec::new();
        let mut hb = Vec::new();
        let mut hit = |q: &str, h: &str| {
            m.fuzzy_match(Utf32Str::new(h, &mut hb), Utf32Str::new(q, &mut qb))
                .is_some()
        };
        assert!(hit("dcs", "docs"));
        assert!(hit("inte", "internal"));
        assert!(!hit("gti", "git"));
        assert!(!hit("verbso", "verbose"));
    }
}
