//! History-menu behavior that only a non-default `config.toml` can show:
//! the `[history].limit` scan window, `[display].min-input` not gating the
//! menu, and -- through a deliberately slow `[display].delay-ms` -- send-break
//! against an input whose quiet period is still running in the worker
//! (docs/internal/specs/behavior.md 「履歴メニュー」「候補収集」,
//! docs/internal/contracts/config-schema.md).
//!
//! Each test writes its own config before its host boots, so the variant is in
//! force from the moment the shell sources zrush.

use std::time::Duration;

use crate::hist::{self, NO_COLLECTION};
use crate::host::{Host, keys};

/// Send-break while the notified input is merely pending -- its quiet period
/// still running in the worker, no collection started yet -- must drop that
/// input generation too.
///
/// This is the third member of the send-break cleanup unit in `hist_compsys`:
/// `worker_death_on_the_synchronous_history_path_leaves_a_clean_line` covers
/// kind/listing across a send-break, and
/// `send_break_during_an_in_flight_collection_clears_the_collection_fds`
/// covers a *live* collection. Neither would catch an input that is only
/// pending, which is what a generous `delay-ms` makes observable: the round trip
/// to dump and assert the pending input through `^Xt` comfortably fits before
/// the quiet period would otherwise expire. (Dropping it through the
/// history-menu open path instead is
/// `hist_compsys::an_up_inside_the_quiet_period_opens_the_menu_and_drops_the_input`.)
#[test]
fn send_break_clears_a_merely_pending_input() {
    let mut host = Host::boot_history_with_config("[display]\ndelay-ms = 2000\n");
    host.send_keys("x");
    host.drain(Duration::from_millis(300)); // comfortably within the 2s quiet period

    // Without this the cleanup assertion below would pass for the wrong reason
    // whenever no input was ever notified.
    let fds = host.input_state("(h26c-pre)");
    assert!(
        !fds.starts_with("gen=0 ") && fds.contains("pending=1"),
        "(h26c-pre) no input was pending before send-break: {fds}"
    );

    assert!(
        host.send_break_and_sync(Duration::from_secs(15)),
        "(h26c-a) send-break did not produce a new prompt during the quiet period"
    );
    assert_eq!(
        host.input_state("(h26c)"),
        NO_COLLECTION,
        "(h26c) the pending input survived the following line-init:"
    );
    assert_eq!(
        host.listing_kind("(h26c-kind)"),
        "kind=none sel=0 listing=0 npos=0",
        "(h26c-kind) kind/listing is not clean:"
    );
}

/// `[history].limit` bounds the worker's scan window over the *index*, not a
/// window over `$history`: the window is the newest `limit` index entries, the
/// duplicate inside it is collapsed to its newest occurrence, and nothing is
/// backfilled from outside it (cli-protocol.md 「history profile」,
/// config-schema.md 「[history]」).
///
/// This is the end-to-end proof that the window moved. The rc file's fixture
/// history is, newest first, dupA, dupA, an excluded framing-byte line, keep3,
/// keep4, oldest-outside and keep5-outside. The excluded line never enters the
/// index -- zsh drops it while synthesizing the snapshot -- so it costs no
/// window slot, and the newest-5 window reaches one entry deeper into the
/// history than a raw window over `$history` would: dupA, dupA, keep3, keep4
/// and oldest-outside, leaving four candidates after dedup. Only
/// keep5-outside, disqualified by nothing but its position, stays out.
#[test]
fn the_history_limit_bounds_the_index_scan_window() {
    let mut host = Host::boot_history_limit_with_config("[history]\nlimit = 5\n");
    host.press(keys::UP);

    let post = host.postdisplay("(h8a)");
    assert!(
        post.contains("dupA")
            && post.contains("keep3")
            && post.contains("keep4")
            && post.contains("oldest-outside")
            && !post.contains("keep5-outside")
            && !post.contains("ctrlone"),
        "(h8a) the newest-5 index window did not yield exactly \
         dupA/keep3/keep4/oldest-outside: {post:?}"
    );

    let dupes = post.split('\n').filter(|row| row.contains("dupA")).count();
    assert_eq!(
        dupes, 1,
        "(h8b) the duplicate within the scan window was not deduplicated to exactly one row: {post:?}"
    );
}

/// The payload byte ceiling bounds the bootstrap synthesis independently of
/// `[history].limit`: with the default limit far larger than this fixture
/// history, what ends the walk is the ceiling, and the entries past it never
/// reach the index -- so no later query can name them, whatever its window
/// (behavior.md 「履歴メニュー」, cli-protocol.md 「history profile」).
///
/// Both queries name a marker that exists exactly once in the fixture, so each
/// assertion is about that one entry reaching the payload or not. The bulk
/// entries between them cannot answer either query (no shared letters), which
/// is what makes "no menu" mean "cut by the ceiling" rather than "matched
/// something else".
#[test]
fn the_payload_byte_ceiling_bounds_the_scan_before_the_history_limit_does() {
    let mut host = Host::boot_history_budget();

    hist::open_menu(&mut host, "zqxinside");
    assert!(
        host.listing_kind("(h8c-kind)")
            .starts_with("kind=history sel=1 listing=1"),
        "(h8c) the newest entry, well inside the ceiling, did not open the menu: {}",
        host.listing_kind("(h8c-kind)")
    );
    assert!(
        host.postdisplay("(h8c-post)").contains("zqxinside"),
        "(h8c-post) the menu opened without the entry the query names: {:?}",
        host.postdisplay("(h8c-post)")
    );

    host.press(keys::DISMISS);
    host.clear_line();

    hist::open_menu(&mut host, "zqxoutside");
    hist::assert_no_history_kind(
        &host.listing_kind("(h8d-kind)"),
        "(h8d) the oldest entry, past the ceiling, still reached the payload:",
    );
}

/// `min-input` does not gate the history menu: even raised well above any
/// possible word length, an empty-buffer Up still opens the full menu.
/// behavior.md: min-input and the blank-buffer suppression rule apply only to
/// the input-following auto display, not to the explicit history menu.
#[test]
fn min_input_does_not_gate_the_history_menu() {
    let mut host = Host::boot_history_with_config("[display]\nmin-input = 50\n");
    host.press(keys::UP);
    let kind = host.listing_kind("(h19a)");
    assert!(
        kind.starts_with("kind=history sel=1 listing=1"),
        "(h19a) empty-buffer Up did not open the history menu with min-input=50: {kind}"
    );
}
