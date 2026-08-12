//! Dismiss and accept-line: closing a list leaves the buffer untouched, a
//! dismiss wins a race against an in-flight collection, and accept-line
//! resets zrush's line-scoped state (docs/internal/specs/behavior.md
//! "選択・キーバインド", "確定(挿入)").

use std::time::Duration;

use crate::host::{Host, PlanShape, keys};

#[test]
fn dismiss_closes_the_list_without_changing_the_buffer() {
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/");

    host.assert_log_grows(
        "dismiss: closing list",
        &[keys::DISMISS],
        "(dis-1a) dismiss did not work",
    );
    host.assert_buffer("ls fx/basic/", "(dis-1b) buffer is unchanged after dismiss");
}

/// Regression (dis-2): dismiss must cancel any still-pending input or
/// in-flight collection for a newer keystroke, or a late-arriving result can
/// silently reopen the list right after the user closed it. Reproduced with
/// git's naturally slow (~150ms+) subcommand completion; no extra fixture
/// needed.
#[test]
fn dismiss_cancels_an_in_flight_collection() {
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Nonempty, "git c"); // first list applied
    host.send_keys("hec"); // -> 'git chec': notifies a new input and recollects
    host.send_keys(keys::DISMISS); // dismiss immediately, no drain in between
    host.drain(Duration::from_secs(1)); // comfortably longer than 'git chec' compsys (~150-200ms)

    let post = host.postdisplay("(dis-2)");
    assert!(
        post.is_empty(),
        "(dis-2) list reappeared after dismiss (stale collection not cancelled): {post:?}"
    );
}

#[test]
fn accept_line_executes_and_resets_zrush_state() {
    let mut host = Host::boot();
    let baseline = host.log_count("line-finish: cleared");
    host.send_keys("print HISTMARK-ACCEPT");
    host.send_keys(keys::ENTER);
    assert!(
        host.expect("HISTMARK-ACCEPT", Duration::from_secs(5)),
        "(acc-1a) command did not execute"
    );
    host.sync_prompt(Duration::from_secs(5));
    assert!(
        host.wait_log("line-finish: cleared", baseline, Duration::from_secs(3)),
        "(acc-1b) line-finish not logged after accept-line"
    );
}
