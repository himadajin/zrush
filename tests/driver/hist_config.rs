//! History-menu behavior that only a non-default `config.toml` can show:
//! the `[history].limit` scan window, `[display].min-input` not gating the
//! menu, and -- through a deliberately slow `[display].delay-ms` -- send-break
//! against a debounce timer that is armed but has not started collecting
//! (docs/internal/specs/behavior.md 「履歴メニュー」「候補収集」,
//! docs/internal/contracts/config-schema.md).
//!
//! Each test writes its own config before its host boots, so the variant is in
//! force from the moment the shell sources zrush.

use std::time::Duration;

use crate::hist::NO_COLLECTION;
use crate::host::{Host, keys};

/// Send-break while merely debounce-armed -- timer fd alive, no collection
/// started yet -- must clear the timer too.
///
/// This is the third member of the send-break cleanup unit in `hist_compsys`:
/// `worker_death_on_the_synchronous_history_path_leaves_a_clean_line` covers
/// kind/listing across a send-break, and
/// `send_break_during_an_in_flight_collection_clears_the_collection_fds`
/// covers a *live* collection. Neither would catch a timer that is only armed,
/// which is what a generous `delay-ms` makes observable: the round trip to dump
/// and assert the armed timer through `^Xt` comfortably fits before the
/// debounce would otherwise fire. (Disarming through the history-menu open path
/// instead is `hist_compsys::an_up_inside_the_debounce_window_opens_the_menu_and_disarms_the_timer`.)
#[test]
fn send_break_clears_a_merely_armed_debounce_timer() {
    let mut host = Host::boot_history_with_config("[display]\ndelay-ms = 2000\n");
    host.send_keys("x");
    host.drain(Duration::from_millis(300)); // comfortably within the 2s debounce window

    // Without this the cleanup assertion below would pass for the wrong reason
    // whenever the timer never armed.
    let fds = host.collection_fds("(h26c-pre)");
    assert!(
        !fds.starts_with("timer=-1"),
        "(h26c-pre) the debounce timer was not armed before send-break: {fds}"
    );

    assert!(
        host.send_break_and_sync(Duration::from_secs(15)),
        "(h26c-a) send-break did not produce a new prompt during the debounce wait"
    );
    assert_eq!(
        host.collection_fds("(h26c)"),
        NO_COLLECTION,
        "(h26c) the disarmed debounce timer's fd survived the following line-init:"
    );
    assert_eq!(
        host.listing_kind("(h26c-kind)"),
        "kind=none sel=0 listing=0 npos=0",
        "(h26c-kind) kind/listing is not clean:"
    );
}

/// `[history].limit` bounds the RAW scan window: entries that do not survive
/// the in-window dedup/exclusion are never backfilled from outside that window
/// (cli-protocol.md 「history profile」, config-schema.md 「[history]」).
///
/// The rc file's fixture history is ordered so that the newest 5 raw entries
/// are dupA, dupA, an excluded framing-byte line, keep3 and keep4, leaving
/// three candidates; keep5-outside and oldest-outside sit just past the window
/// and are disqualified by nothing but their position.
#[test]
fn the_history_limit_bounds_the_raw_scan_window() {
    let mut host = Host::boot_history_limit_with_config("[history]\nlimit = 5\n");
    host.press(keys::UP);

    let post = host.postdisplay("(h8a)");
    assert!(
        post.contains("dupA")
            && post.contains("keep3")
            && post.contains("keep4")
            && !post.contains("keep5-outside")
            && !post.contains("oldest-outside"),
        "(h8a) the newest-5 scan window did not yield exactly dupA/keep3/keep4: {post:?}"
    );

    let dupes = post.split('\n').filter(|row| row.contains("dupA")).count();
    assert_eq!(
        dupes, 1,
        "(h8b) the duplicate within the scan window was not deduplicated to exactly one row: {post:?}"
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
