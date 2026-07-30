//! Insertion-text construction for one selectable position.
//!
//! Semantics: docs/internal/contracts/cli-protocol.md "挿入テキスト"
//! (source of truth). Byte concatenation only, in the contract's fixed
//! tag order; no zsh quoting semantics are reproduced here (`w` already
//! arrives pre-quoted from record.rs, per cli-protocol.md "共通事項").
//!
//! The `-f` directory-synthesis stat is injected as a predicate rather
//! than performed here: plan.rs owns the "stat only the P displayed `f=1`
//! candidates" budget (cli-protocol.md "起動"), so this module stays a
//! pure per-candidate builder and is trivially unit-testable with a fake.

use crate::record::{Batch, Candidate};

/// Build the completed insertion text for one candidate.
///
/// `is_dir(path)` answers "does `path`, resolved against the current
/// directory with symlinks followed, exist and name a directory?"
/// (cli-protocol.md: stat failure or a non-directory both read as
/// `false`). Called at most once, and only when `batch.f == "1"` and the
/// plain concatenation doesn't already end in `/`.
pub(crate) fn build(
    batch: &Batch<'_>,
    candidate: &Candidate<'_>,
    trailing_space: bool,
    is_dir: &dyn Fn(&[u8]) -> bool,
) -> Vec<u8> {
    // Concatenation order is the contract's, not record.rs's field
    // names: ip, i(i_vis), P(p_vis), p(p_hidden), w, s(s_hidden),
    // S(s_vis), I(i_hidden).
    let mut out = Vec::new();
    out.extend_from_slice(batch.ip);
    out.extend_from_slice(batch.i_vis);
    out.extend_from_slice(batch.p_vis);
    out.extend_from_slice(batch.p_hidden);
    out.extend_from_slice(candidate.w);
    out.extend_from_slice(batch.s_hidden);
    out.extend_from_slice(batch.s_vis);
    out.extend_from_slice(batch.i_hidden);

    // nospace: any visible/hidden/ignored suffix is present, or a `/`
    // got synthesized below (cli-protocol.md "末尾スペース").
    let mut nospace =
        !batch.s_vis.is_empty() || !batch.s_hidden.is_empty() || !batch.i_hidden.is_empty();

    if batch.f == b"1" && !out.ends_with(b"/") {
        // stat path = rd + match-text, raw bytes (cli-protocol.md
        // "合成 `/`"); match-text prefers `m`, falling back to `w`.
        let mut path = Vec::with_capacity(batch.rd.len() + candidate.match_text().len());
        path.extend_from_slice(batch.rd);
        path.extend_from_slice(candidate.match_text());
        if is_dir(&path) {
            out.push(b'/');
            nospace = true;
        }
    }

    if trailing_space && !nospace {
        out.push(b' ');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn cand<'a>(w: &'a [u8], m: Option<&'a [u8]>) -> Candidate<'a> {
        Candidate {
            w,
            m,
            d: None,
            batch: 0,
        }
    }

    fn never_called(_: &[u8]) -> bool {
        panic!("is_dir should not be called");
    }

    fn always_false(_: &[u8]) -> bool {
        false
    }

    #[test]
    fn plain_word_with_and_without_trailing_space() {
        let batch = Batch::default();
        let c = cand(b"git", None);
        assert_eq!(build(&batch, &c, true, &always_false), b"git ");
        assert_eq!(build(&batch, &c, false, &always_false), b"git");
    }

    #[test]
    fn visible_suffix_suppresses_trailing_space() {
        let batch = Batch {
            s_vis: b"=",
            ..Batch::default()
        };
        let c = cand(b"opt", None);
        assert_eq!(build(&batch, &c, true, &always_false), b"opt=");
    }

    #[test]
    fn hidden_suffix_suppresses_trailing_space() {
        let batch = Batch {
            s_hidden: b"HIDDEN",
            ..Batch::default()
        };
        let c = cand(b"opt", None);
        // hidden suffix contributes to the byte stream (per the fixed
        // concatenation order) but the point under test is nospace.
        assert_eq!(build(&batch, &c, true, &always_false), b"optHIDDEN");
    }

    #[test]
    fn ignored_suffix_suppresses_trailing_space() {
        let batch = Batch {
            i_hidden: b"IGN",
            ..Batch::default()
        };
        let c = cand(b"opt", None);
        assert_eq!(build(&batch, &c, true, &always_false), b"optIGN");
    }

    #[test]
    fn dir_synthesis_appends_slash_and_suppresses_trailing_space() {
        // `rd` only feeds the stat path, not the insertion text itself.
        let batch = Batch {
            f: b"1",
            rd: b"/proj/",
            ..Batch::default()
        };
        let c = cand(b"src", None);
        let out = build(&batch, &c, true, &|_| true);
        assert_eq!(out, b"src/");
    }

    #[test]
    fn dir_synthesis_does_not_double_slash_when_already_present() {
        // `w` already ends in `/` (e.g. compsys quoted a trailing slash);
        // synthesis must not run at all, so `is_dir` is never called.
        let batch = Batch {
            f: b"1",
            rd: b"/proj/",
            ..Batch::default()
        };
        let c = cand(b"src/", None);
        let out = build(&batch, &c, true, &never_called);
        assert_eq!(out, b"src/ ");
    }

    #[test]
    fn is_dir_receives_rd_concatenated_with_match_text_preferring_m() {
        let batch = Batch {
            f: b"1",
            rd: b"/proj/",
            ..Batch::default()
        };
        // `w` is the quoted form; `m` is the unquoted raw text that
        // should be used for the stat path.
        let c = cand(b"weird\\ name", Some(b"weird name"));
        let calls: RefCell<Vec<Vec<u8>>> = RefCell::new(Vec::new());
        let is_dir = |path: &[u8]| {
            calls.borrow_mut().push(path.to_vec());
            false
        };
        build(&batch, &c, false, &is_dir);
        assert_eq!(calls.borrow().as_slice(), [b"/proj/weird name".to_vec()]);
    }

    #[test]
    fn non_file_candidate_never_calls_is_dir() {
        let batch = Batch::default(); // f is empty, not "1"
        let c = cand(b"word", None);
        build(&batch, &c, true, &never_called); // panics if called
    }

    #[test]
    fn f_present_but_not_one_never_calls_is_dir() {
        let batch = Batch {
            f: b"0",
            ..Batch::default()
        };
        let c = cand(b"word", None);
        build(&batch, &c, true, &never_called);
    }

    #[test]
    fn full_field_order_ip_i_p_p_w_s_s_i() {
        let batch = Batch {
            ip: b"IP-",
            i_vis: b"IV-",
            p_vis: b"PV-",
            p_hidden: b"PH-",
            s_hidden: b"-SH",
            s_vis: b"-SV",
            i_hidden: b"-IH",
            ..Batch::default()
        };
        let c = cand(b"WORD", None);
        let out = build(&batch, &c, false, &always_false);
        assert_eq!(out, b"IP-IV-PV-PH-WORD-SH-SV-IH");
    }
}
