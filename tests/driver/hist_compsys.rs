//! History menu against the completion pipeline it shares a display with:
//! opening it over a live compsys listing, disarming or cancelling whatever
//! collection is under way, resuming the pipeline after a confirm, and the
//! cleanup left behind by a worker death or a send-break
//! (docs/internal/specs/behavior.md 「履歴メニュー」「候補収集」,
//! docs/internal/contracts/cli-protocol.md 「history profile」).
//!
//! Every test here runs on a host booted from `tests/zsh/rc/history.zshrc`.

use std::time::Duration;

use crate::fake::Mode;
use crate::hist::{NO_COLLECTION, assert_no_history_kind, open_menu};
use crate::host::{Host, keys};

/// Down at position 1 erases the whole menu, unlike a completion listing, where
/// the analogous transition only deselects and keeps the text (see
/// `up_at_a_completion_listing_deselects_before_opening_the_history_menu`).
#[test]
fn down_at_position_1_erases_the_whole_history_menu() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "echo");
    let kind = host.listing_kind("(h15-setup)");
    assert!(
        kind.starts_with("kind=history sel=1"),
        "(h15-setup) history menu did not open at position 1: {kind}"
    );

    host.press(keys::DOWN);
    assert_eq!(
        host.listing_kind("(h15a)"),
        "kind=none sel=0 listing=0 npos=0",
        "(h15a) Down at position 1 did not erase the whole menu:"
    );
    host.assert_buffer("echo", "(h15b) buffer is unchanged");
}

/// select-prev at a completion listing's position 1 only deselects, leaving the
/// listing text; pressing it again, now unselected, opens the history menu and
/// replaces the completion listing outright.
#[test]
fn up_at_a_completion_listing_deselects_before_opening_the_history_menu() {
    let mut host = Host::boot_history();
    host.send_keys("ls fx/basic/al");
    assert!(
        host.expect("alpha.txt", Duration::from_secs(10)),
        "(h16a) completion listing did not render"
    );

    host.press(keys::DOWN); // select-start at position 1
    let kind = host.listing_kind("(h16b)");
    assert!(
        kind.starts_with("kind=compsys sel=1"),
        "(h16b) selection did not start on the completion listing: {kind}"
    );

    host.press(keys::UP); // position 1's prev is 0: deselect only
    let kind = host.listing_kind("(h16c)");
    assert!(
        kind.starts_with("kind=compsys sel=0 listing=1"),
        "(h16c) Up at the completion listing's position 1 did not merely deselect: {kind}"
    );

    host.press(keys::UP); // now unselected: opens the history menu
    let kind = host.listing_kind("(h16d)");
    assert!(
        kind.starts_with("kind=history sel=1 listing=1"),
        "(h16d) a second Up did not open the history menu: {kind}"
    );

    let post = host.postdisplay("(h16e)");
    assert!(
        !post.contains("alpha.txt"),
        "(h16e) the completion listing text is still there, merely covered: {post:?}"
    );
}

/// Opening the history menu while the notified input is merely pending -- no
/// collection started yet -- drops that input generation, which
/// `opening_the_menu_cancels_an_in_flight_collection_and_confirm_resumes_it`
/// does not cover: there the collection has already begun. The Up is sent in
/// the same burst as the query, well inside the default 30 ms quiet period, so
/// the input must still be pending when select-prev drops it.
#[test]
fn an_up_inside_the_quiet_period_opens_the_menu_and_drops_the_input() {
    let mut host = Host::boot_history();
    let collecting = "collect: collecting";
    let before = host.log_count(collecting);
    host.send_keys("echo");
    host.send_keys(keys::UP);
    host.drain(Duration::from_millis(500));

    assert_eq!(
        host.listing_kind("(h25a)"),
        "kind=history sel=1 listing=1 npos=6",
        "(h25a) Up sent within the quiet period did not open the history menu:"
    );

    // Comfortably longer than the quiet period plus a real fork/collection round trip.
    host.drain(Duration::from_secs(1));
    let after = host.log_count(collecting);
    assert_eq!(
        after, before,
        "(h25b) a compsys collection started despite the input being dropped"
    );
}

/// Opening the history menu cancels an in-flight completion collection, and the
/// cancelled collection's late-arriving result never overwrites the menu
/// (behavior.md 「候補収集」). Confirming that same menu then leaves no residual
/// history state behind, and the very next completion request resumes the
/// normal pipeline -- which is what the confirm has to be observed against, so
/// the two run as one chain with no reset in between.
///
/// The slow fixture completion (`_zrushtestslow`) is defined in
/// `tests/zsh/rc/history.zshrc` rather than typed here, so it never becomes a
/// history entry that could confuse the query below.
#[test]
fn opening_the_menu_cancels_an_in_flight_collection_and_confirm_resumes_it() {
    let mut host = Host::boot_history();
    host.send_keys("zrushtestslow ");
    host.drain(Duration::from_millis(200)); // quiet period elapsed, fork started, still asleep
    host.press(keys::UP);

    let kind = host.listing_kind("(h17a)");
    assert!(
        kind.starts_with("kind=history sel=1 listing=1"),
        "(h17a) the history menu did not open with a slow collection in flight: {kind}"
    );

    host.drain(Duration::from_millis(800)); // longer than the fixture's 0.5s sleep
    let kind = host.listing_kind("(h17b)");
    assert!(
        kind.starts_with("kind=history sel=1 listing=1"),
        "(h17b) the cancelled collection's late result overwrote the history menu: {kind}"
    );
    let post = host.postdisplay("(h17c)");
    assert!(
        !post.contains("slowcand"),
        "(h17c) the slow completion's candidates appear in the listing text: {post:?}"
    );

    host.press(keys::ENTER); // confirm the still-open menu
    let kind = host.listing_kind("(h18a)");
    assert_no_history_kind(&kind, "(h18a) confirm left residual history-menu state:");

    host.clear_line();
    host.drain(Duration::from_millis(300));
    host.send_keys("ls fx/basic/al");
    assert!(
        host.expect("alpha.txt", Duration::from_secs(10)),
        "(h18b) completion did not render after a history confirm"
    );
    let kind = host.listing_kind("(h18c)");
    assert!(
        kind.starts_with("kind=compsys"),
        "(h18c) the resumed listing's kind is not 'compsys': {kind}"
    );
}

/// Regression (f6fcf2e): confirming a history candidate byte-identical to the
/// current BUFFER must still trigger recollection. Opening the menu snapshots
/// BUFFER/CURSOR as the pre-redraw baseline (behavior.md 「履歴メニュー」); if
/// confirm left that baseline untouched, an insertion identical to the pre-open
/// buffer would read as "no change" on the next pre-redraw and silently stall
/// recollection (behavior.md 「確定(挿入)」).
#[test]
fn confirming_an_entry_identical_to_the_buffer_recollects_via_enter() {
    assert_exact_match_confirm_recollects(keys::ENTER, "(h22-setup-enter)", "(h22a)");
}

/// [`confirming_an_entry_identical_to_the_buffer_recollects_via_enter`] through
/// the other confirm key.
#[test]
fn confirming_an_entry_identical_to_the_buffer_recollects_via_tab() {
    assert_exact_match_confirm_recollects(keys::TAB, "(h22-setup-tab)", "(h22b)");
}

fn assert_exact_match_confirm_recollects(confirm: &str, setup_label: &str, label: &str) {
    let mut host = Host::boot_history();
    open_menu(&mut host, "echo newest");
    let kind = host.listing_kind(setup_label);
    assert_eq!(
        kind, "kind=history sel=1 listing=1 npos=1",
        "{setup_label} exact-match menu did not open as expected:"
    );

    // The recollection the confirm has to provoke is a compsys one, so what
    // proves it ran is its own `store` reaching the worker.
    let answered = "worker: ok store request_id=";
    let before = host.log_count(answered);
    host.press(confirm);
    assert!(
        host.wait_log(answered, before, Duration::from_secs(3)),
        "{label} no fresh compsys recollection after confirming an exact-BUFFER-match entry"
    );
}

/// The fixture-injection mechanism itself (`print -s`, run from the host's rc
/// file) never becomes a history candidate: a query matching its own invocation
/// text finds nothing.
#[test]
fn the_fixtures_own_injection_commands_are_not_history_candidates() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "print");
    assert_eq!(
        host.listing_kind("(h21)"),
        "kind=none sel=0 listing=0 npos=0",
        "(h21) the fixture's own 'print -s ...' injections appeared as history candidates:"
    );
}

/// A synchronous history request assigned to a ready worker which then dies
/// leaves no menu, no residual kind/listing, the buffer untouched and the shell
/// responsive (cli-protocol.md 「エラー時の zsh 側挙動」 covers the history
/// producer's synchronous exchange exactly as it does the asynchronous compsys
/// one). Once that failure has finished unwinding, send-break with the history
/// menu open must not leak kind/listing state into the next line either -- the
/// menu has to reopen on a worker that is provably done stopping, so the two
/// steps are one chain.
///
/// No fd check follows the send-break here: opening the history menu already
/// drops the pending input and cancels any collection *before* it displays, so
/// the state is clear before ^C is even sent. That is what
/// `send_break_during_an_in_flight_collection_clears_the_collection_fds` (and
/// `hist_config::send_break_clears_a_merely_pending_input`, for the input that
/// is pending but has not started collecting) cover instead.
#[test]
fn worker_death_on_the_synchronous_history_path_leaves_a_clean_line() {
    let mut host = Host::boot_history_fake();
    // An empty buffer rather than a typed query: typing would arm a compsys
    // collection of its own, which could start an unrelated request before the
    // history-menu attempt.
    let session = host.fake().sessions() + 1;
    host.fake().set_mode(Mode::Die);
    let died0 = host.fake().count(&format!("die {session} "));
    let failures0 = host.log_count("worker: session failure:");
    let stopped0 = host.log_count("worker: transport stopped");

    host.send_keys(keys::UP);
    let died = host.wait_fake(&format!("die {session} "), died0, Duration::from_secs(10));
    let failed = host.wait_log(
        "worker: session failure:",
        failures0,
        Duration::from_secs(10),
    );
    assert!(
        died && failed,
        "(h24a) active worker death was not recorded on the synchronous history path: \
         died={died} failed={failed}"
    );
    assert_eq!(
        host.listing_kind("(h24b)"),
        "kind=none sel=0 listing=0 npos=0",
        "(h24b) menu/kind/listing survived the failed sync plan:"
    );
    host.assert_buffer("", "(h24c) buffer is unchanged after the failed sync plan");

    host.fake().set_mode(Mode::Proxy);
    host.clear_line();
    host.drain(Duration::from_millis(300));
    host.send_keys("print HISTMARK-AFTER-HIST-PLAN-ERROR");
    host.send_keys(keys::ENTER);
    assert!(
        host.expect_in_order(
            &["HISTMARK-AFTER-HIST-PLAN-ERROR", "HP>"],
            Duration::from_secs(5)
        ),
        "(h24d) the shell stopped responding after the failed history-menu plan"
    );

    // The session-failure log can precede response EOF when abort exhausts its
    // synchronous budget, so the next history request must not race the
    // retained stopping gate.
    let worker_clean = host.wait_log(
        "worker: transport stopped",
        stopped0,
        Duration::from_secs(10),
    );

    open_menu(&mut host, "echo");
    let kind = host.listing_kind("(h26-setup)");
    assert!(
        kind.starts_with("kind=history") && worker_clean,
        "(h26-setup) history menu did not open after worker cleanup={worker_clean}: {kind}"
    );

    // abandon the line, bypassing confirm/dismiss/line-finish
    assert!(
        host.send_break_and_sync(Duration::from_secs(15)),
        "(h26a) send-break did not produce a new prompt"
    );
    assert_eq!(
        host.listing_kind("(h26b)"),
        "kind=none sel=0 listing=0 npos=0",
        "(h26b) kind/listing state leaked into the new prompt:"
    );
}

/// Send-break while a real collection is in flight -- rfd/pty alive, not merely
/// a pending input -- clears those fds too. Same slow fixture as
/// `opening_the_menu_cancels_an_in_flight_collection_and_confirm_resumes_it`,
/// ending in ^C instead of Up.
#[test]
fn send_break_during_an_in_flight_collection_clears_the_collection_fds() {
    let mut host = Host::boot_history();
    host.send_keys("zrushtestslow ");
    host.drain(Duration::from_millis(200)); // quiet period elapsed, fork started, still asleep (0.5s)

    // Without this the cleanup assertion below would pass for the wrong reason
    // whenever no collection is actually in flight.
    let fds = host.input_state("(h26d-pre)");
    assert_ne!(
        fds, NO_COLLECTION,
        "(h26d-pre) no in-flight collection detected before send-break:"
    );

    assert!(
        host.send_break_and_sync(Duration::from_secs(15)),
        "(h26d-a) send-break did not produce a new prompt"
    );
    assert_eq!(
        host.input_state("(h26d)"),
        NO_COLLECTION,
        "(h26d) the cancelled collection's fds/pty survived the following line-init:"
    );
    assert_eq!(
        host.listing_kind("(h26d-kind)"),
        "kind=none sel=0 listing=0 npos=0",
        "(h26d-kind) kind/listing is not clean:"
    );
}
