//! Fuzzy matching: prefix / substring / typo modes.
//!
//! Semantics and tier ordering: docs/internal/contracts/cli-protocol.md
//! (source of truth). `dcf` -> `dot-config` is a scattered fuzzy match;
//! `dcs` -> `docs` is a one-edit match.
//!
//! The matcher is a hybrid: direct bytes for prefix/substring,
//! nucleo strict-subsequence scoring for fuzzy, and bounded prefix edit
//! distance for transposition/substitution/insertion, which nucleo
//! cannot catch and the edit tier handles.
//!
//! Tier precedence cannot use nucleo's raw score: a scattered fuzzy match
//! can outscore a plain substring match (measured: "doc" scored
//! dot-config 82 > my-docs 80 > mydocs 56).
//!
//! Byte semantics follow cli-protocol.md. Case handling is prepared once,
//! and all four tiers derive input from the same byte sequence; nucleo
//! keeps ignore_case=false and normalize=false.

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
    Edit,
    Fuzzy,
}

impl Tier {
    /// Classify this tier for literal-vs-approximate suppression.
    pub const fn group(self) -> TierGroup {
        match self {
            Self::Prefix | Self::Substring => TierGroup::Literal,
            Self::Edit | Self::Fuzzy => TierGroup::Approximate,
        }
    }
}

/// Broad match class used when suppressing approximate results.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TierGroup {
    Literal,
    Approximate,
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
        // always insensitive (contract: always insensitive).
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

        // Edit tier: bounded prefix edit distance. Checked before fuzzy
        // because it is the higher tier: a <=1-edit prefix match is
        // high-precision/low-volume evidence, while the fuzzy tier can
        // admit thousands of scattered subsequences. Skipped for 1-byte
        // queries: a single-char query within one edit would match every
        // candidate (substitution or trailing deletion), which is pure
        // noise; substring/fuzzy already cover the sensible matches.
        if q.len() >= 2
            && let Some(em) = prefix_edit_within_one(q, cand)
        {
            return Some(MatchScore {
                tier: Tier::Edit,
                score: edit_score(em),
            });
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
        None
    }

    /// Matched spans in one candidate's match-text, for the stdout
    /// match-spans field (cli-protocol.md). Char offsets over the
    /// lossy UTF-8 reading, 0-based end-exclusive, sorted and merged;
    /// empty = no position info (empty query or no match).
    ///
    /// Second pass by design: callers run this only on the top-ranked
    /// (at most max-lines) candidates, so the per-candidate re-match is
    /// cheap and `score()` stays allocation-free for the full set.
    pub fn spans(&mut self, cand_raw: &[u8]) -> Vec<(usize, usize)> {
        if self.query.is_empty() {
            return Vec::new();
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

        // ASCII folding preserves byte offsets, so byte positions found
        // on the folded form index the raw form identically.
        if cand.starts_with(q) {
            return vec![(0, char_count(&cand[..q.len()]))];
        }
        if *mode == Mode::Prefix {
            return Vec::new();
        }
        if q.len() <= cand.len()
            && let Some(pos) = cand.windows(q.len()).position(|w| w == q)
        {
            return vec![(char_count(&cand[..pos]), char_count(&cand[..pos + q.len()]))];
        }
        if *mode == Mode::Substring {
            return Vec::new();
        }
        if q.len() >= 2
            && let Some(em) = prefix_edit_within_one(q, cand)
        {
            // The aligned (corrected-query) prefix of the candidate.
            let consumed = cand.len() - em.suffix_len;
            return vec![(0, char_count(&cand[..consumed]))];
        }
        let cand_lossy = String::from_utf8_lossy(cand);
        let hay = Utf32Str::new(&cand_lossy, hay_char_buf);
        let needle = Utf32Str::new(query_str, query_char_buf);
        let mut indices: Vec<u32> = Vec::new();
        if nucleo.fuzzy_indices(hay, needle, &mut indices).is_none() {
            return Vec::new();
        }
        indices.sort_unstable();
        indices.dedup();
        let mut out: Vec<(usize, usize)> = Vec::new();
        for i in indices {
            let i = i as usize;
            match out.last_mut() {
                Some(last) if last.1 == i => last.1 = i + 1,
                _ => out.push((i, i + 1)),
            }
        }
        out
    }
}

/// Char count of a byte slice under the lossy UTF-8 reading (the span
/// offset unit; cli-protocol.md).
fn char_count(bytes: &[u8]) -> usize {
    String::from_utf8_lossy(bytes).chars().count()
}

/// How the single edit reads. Declaration order = intra-tier preference
/// (better first) used as the tie-break after suffix length:
/// transposition carries the strongest signal (both correct characters
/// were typed), then substitution, insertion (the user missed one
/// candidate character), deletion (the query has one extra character).
/// Exact only arises on distance-0 direct calls (`score()` routes those
/// to the prefix tier first).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum EditKind {
    Exact,
    Transposition,
    Substitution,
    Insertion,
    Deletion,
}

/// Best reading of a <=1-edit prefix match.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct EditMatch {
    kind: EditKind,
    /// Candidate bytes after the aligned (corrected-query) prefix.
    /// 0 = the whole candidate is the corrected query.
    suffix_len: usize,
}

/// Does some prefix of `cand` lie within one edit (optimal string
/// alignment: substitution / insertion / deletion / adjacent
/// transposition) of `q`? Byte-based, O(|q|).
///
/// Only a prefix of the candidate is aligned; the remaining candidate
/// suffix is free, so a typo of a word's beginning still matches longer
/// candidates ("gti" -> "git-lfs"). When several readings exist for the
/// same candidate (e.g. "gti" vs "gitb…" reads as transposition or
/// deletion), the lexicographically best (suffix_len, kind) is returned.
/// The aligned length is determined by the kind alone (substitution/
/// transposition consume |q| bytes, insertion |q|+1, deletion |q|-1),
/// so anchoring every reading at the first mismatch is exhaustive.
fn prefix_edit_within_one(q: &[u8], cand: &[u8]) -> Option<EditMatch> {
    let m = q.len();
    let total = cand.len();
    // Any aligned prefix within one edit consumes at most m+1 bytes.
    let b = &cand[..total.min(m + 1)];
    let n = b.len();
    if n + 1 < m {
        return None; // would need more than one deletion
    }
    let k = q.iter().zip(b).take_while(|(a, c)| a == c).count();
    if k == m {
        return Some(EditMatch {
            kind: EditKind::Exact,
            suffix_len: total - m,
        });
    }
    // Exactly one edit at the first mismatch position k; the remainder
    // of q must then match the remainder of b exactly (b may extend
    // beyond — prefix semantics). Collect every valid reading and keep
    // the best (validity guarantees total >= consumed).
    let mut best: Option<EditMatch> = None;
    let mut consider = |kind: EditKind, consumed: usize| {
        let em = EditMatch {
            kind,
            suffix_len: total - consumed,
        };
        if best.is_none_or(|cur| (em.suffix_len, em.kind) < (cur.suffix_len, cur.kind)) {
            best = Some(em);
        }
    };
    if k < n {
        // insertion: b[k] is a character the user failed to type.
        if b[k + 1..].starts_with(&q[k..]) {
            consider(EditKind::Insertion, m + 1);
        }
        // adjacent transposition at k/k+1.
        if k + 1 < m
            && k + 1 < n
            && q[k] == b[k + 1]
            && q[k + 1] == b[k]
            && b[k + 2..].starts_with(&q[k + 2..])
        {
            consider(EditKind::Transposition, m);
        }
        // substitution at k.
        if b[k + 1..].starts_with(&q[k + 1..]) {
            consider(EditKind::Substitution, m);
        }
    }
    // deletion: q[k] is an extra typed character.
    if b[k..].starts_with(&q[k + 1..]) {
        consider(EditKind::Deletion, m - 1);
    }
    best
}

/// Pack an EditMatch into the intra-tier score (higher = better):
/// shorter unmatched suffix first, then the EditKind preference.
fn edit_score(em: EditMatch) -> u32 {
    const SUFFIX_MAX: u32 = 0x0FFF_FFFF; // 28 bits
    let suffix = u32::try_from(em.suffix_len)
        .unwrap_or(SUFFIX_MAX)
        .min(SUFFIX_MAX);
    let kind_rank = em.kind as u32; // Exact=0 .. Deletion=4, lower = better
    ((SUFFIX_MAX - suffix) << 4) | (0xF - kind_rank)
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
        // one missed char now reads as the edit tier (insertion), which
        // outranks scattered fuzzy matches under the edit > fuzzy order
        assert_eq!(tier("dcs", "docs", Mode::Typo), Some(Tier::Edit));
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
        // "doc" vs "dot-config" reads as a substitution (do[c/t]) — edit
        // tier, which now sits above fuzzy
        assert_eq!(tier("doc", "dot-config", Mode::Typo), Some(Tier::Edit));
        // a subsequence not reachable by one edit stays in the fuzzy tier
        assert_eq!(tier("dcf", "dot-config", Mode::Typo), Some(Tier::Fuzzy));
    }

    #[test]
    fn tier_classification_separates_literal_and_approximate() {
        assert_eq!(Tier::Prefix.group(), TierGroup::Literal);
        assert_eq!(Tier::Substring.group(), TierGroup::Literal);
        assert_eq!(Tier::Edit.group(), TierGroup::Approximate);
        assert_eq!(Tier::Fuzzy.group(), TierGroup::Approximate);
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
        // ("cfx" is a subsequence of caf\xe9x but not within one edit)
        assert_eq!(
            score(b"cfx", b"caf\xe9x", Mode::Typo, true).map(|m| m.tier),
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
        let em = |q: &[u8], c: &[u8]| prefix_edit_within_one(q, c);
        let hit = |kind, suffix_len| Some(EditMatch { kind, suffix_len });
        assert_eq!(em(b"gti", b"git"), hit(EditKind::Transposition, 0));
        assert_eq!(em(b"gti", b"git-lfs"), hit(EditKind::Transposition, 4));
        assert_eq!(em(b"verbso", b"verbose"), hit(EditKind::Transposition, 1));
        assert_eq!(em(b"gir", b"git"), hit(EditKind::Substitution, 0));
        assert_eq!(em(b"installl", b"install"), hit(EditKind::Deletion, 0));
        assert_eq!(em(b"dcs", b"docs"), hit(EditKind::Insertion, 0));
        // "instal" is a plain prefix of "install" (score() never reaches
        // the edit tier for it, but the direct call reports Exact)
        assert_eq!(em(b"instal", b"install"), hit(EditKind::Exact, 1));
        // "gt" vs "grep": substitution g[t/r]+"ep" (suffix 2) beats the
        // trailing-deletion reading "g"+"rep" (suffix 3)
        assert_eq!(em(b"gt", b"grep"), hit(EditKind::Substitution, 2));
        // multiple readings: "gti" vs "gitb" is a transposition (suffix
        // 1) and also a deletion (suffix 2) — best reading wins
        assert_eq!(em(b"gti", b"gitb"), hit(EditKind::Transposition, 1));
        assert_eq!(em(b"gti", b"grep"), None);
        assert_eq!(em(b"abc", b"a"), None);
        assert_eq!(em(b"ab", b""), None);
    }

    #[test]
    fn edit_scores_rank_by_suffix_then_kind() {
        let s = |q: &[u8], c: &[u8]| score(q, c, Mode::Typo, true).unwrap();
        // all Edit tier for query "gti"
        let git = s(b"gti", b"git"); // transposition, suffix 0
        let gtsort = s(b"gti", b"gtsort"); // substitution,  suffix 3
        let glibtool = s(b"gti", b"glibtool"); // substitution,  suffix 5
        let gif2webp = s(b"gti", b"gif2webp"); // deletion,      suffix 6
        for m in [git, gtsort, glibtool, gif2webp] {
            assert_eq!(m.tier, Tier::Edit);
        }
        assert!(git.score > gtsort.score);
        assert!(gtsort.score > glibtool.score);
        assert!(glibtool.score > gif2webp.score);
        // equal suffix: kind breaks the tie (insertion beats deletion)
        let docs = s(b"dcs", b"docs"); // insertion, suffix 0
        let dash = s(b"dcs", b"dash"); // substitution, suffix 1
        assert_eq!(docs.tier, Tier::Edit);
        assert_eq!(dash.tier, Tier::Edit);
        assert!(docs.score > dash.score);
        // kind preference at equal suffix: transposition > substitution
        let transp = edit_score(EditMatch {
            kind: EditKind::Transposition,
            suffix_len: 2,
        });
        let subst = edit_score(EditMatch {
            kind: EditKind::Substitution,
            suffix_len: 2,
        });
        let insert = edit_score(EditMatch {
            kind: EditKind::Insertion,
            suffix_len: 2,
        });
        let delete = edit_score(EditMatch {
            kind: EditKind::Deletion,
            suffix_len: 2,
        });
        assert!(transp > subst);
        assert!(subst > insert);
        assert!(insert > delete);
        // suffix dominates kind
        let far_transp = edit_score(EditMatch {
            kind: EditKind::Transposition,
            suffix_len: 3,
        });
        assert!(delete > far_transp);
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
                    prefix_edit_within_one(q, c).is_some(),
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
