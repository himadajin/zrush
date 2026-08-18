//! The worker's history index as the shell drives it: the cold bootstrap, the
//! warm path that only queries, the per-prompt append, every way the index goes
//! dirty, and what a synchronous exchange that runs out of time leaves behind
//! (docs/internal/specs/behavior.md "History Menu", "Worker Lifecycle",
//! docs/internal/contracts/cli-protocol.md "Requests and Responses" "history profile").
//!
//! Nothing here is asserted against wall-clock time. The shell logs one
//! checkpoint per decision on this path, and every assertion counts those
//! against a baseline taken just before the step under test, so a slow machine
//! delays a test instead of changing its outcome.

use std::time::{Duration, Instant};

use crate::fake::Mode;
use crate::hist::assert_no_history_kind;
use crate::host::{Host, SHUTDOWN_SEAM, dump_field, keys};

/// The menu's synchronization verdict, and what each verdict sends.
const COLD: &str = "history: fingerprint cold (reason=";
const WARM: &str = "history: fingerprint warm (generation=";
/// The whole index, synthesized from `$history`.
const SNAPSHOT: &str = "history: snapshot request_id=";
/// The listing request itself: cold and warm alike end here.
const QUERY: &str = "history: query request_id=";
/// One event, from the prompt hook.
const APPEND: &str = "history: append request_id=";
/// Level A's verdict when the newest event is not one past the head.
const DISCONTINUITY: &str = "history: index dirty (reason=continuity)";
/// The two terminal outcomes of an open, one of which every Up reaches.
const OPENED: &str = "history: menu opened P=";
const NO_MENU: &str = "history: no menu (no match or plan failure)";

/// A command that no fixture query below matches, so accepting it changes the
/// index without changing any listing this file asserts on.
const MARKER: &str = ": zrt-index-marker";

/// Press Up and wait until the synchronous open has decided: either the menu is
/// up or it gave up. Both outcomes are logged, so this waits on the decision
/// rather than on a duration. Returns whether a menu opened.
fn open_menu(host: &mut Host, label: &str) -> bool {
    let opened = host.log_count(OPENED);
    let refused = host.log_count(NO_MENU);
    host.send_keys(keys::UP);
    wait_menu(host, opened, refused, label)
}

/// [`open_menu`]'s wait, for the case that sent the Up itself.
fn wait_menu(host: &mut Host, opened: usize, refused: usize, label: &str) -> bool {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        host.drain(Duration::from_millis(100));
        if host.log_count(OPENED) > opened {
            return true;
        }
        if host.log_count(NO_MENU) > refused {
            return false;
        }
        assert!(
            Instant::now() < deadline,
            "{label}: the history menu neither opened nor gave up"
        );
    }
}

/// The listing rows of the current POSTDISPLAY, oldest first: the history
/// listing grows upward, so the last row is position 1.
fn listing_rows(host: &mut Host, label: &str) -> Vec<String> {
    let post = host.postdisplay(label);
    let listing = post.strip_prefix('\n').unwrap_or(&post).to_string();
    assert!(!listing.is_empty(), "{label}: the listing is empty");
    listing.split('\n').map(str::to_string).collect()
}

/// Whether `row` is the history row for `text`: an event number right-aligned
/// in its own field, the two spaces that separate it from the entry, then the
/// entry. `event` pins which event it has to be; `None` only requires that the
/// number field is there.
fn history_row(row: &str, event: Option<&str>, text: &str) -> bool {
    let rest = row.trim_start();
    let digits = rest.len() - rest.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    if digits == 0 || !rest[digits..].starts_with(&format!("  {text}")) {
        return false;
    }
    match event {
        Some(want) => &rest[..digits] == want,
        None => true,
    }
}

/// The generation the shell believes the worker's index holds; 0 means the next
/// menu op re-snapshots.
fn index_generation(host: &mut Host, label: &str) -> i64 {
    let state = host.history_state();
    dump_field(&state, "gen")
        .parse()
        .unwrap_or_else(|e| panic!("{label}: non-numeric generation in {state:?} ({e})"))
}

/// Open the menu once and dismiss it, leaving a usable index behind. Every host
/// boots without one, so the warm path only exists once something has made it.
fn warm_index(host: &mut Host, label: &str) {
    assert!(
        open_menu(host, label),
        "{label}: the bootstrap menu did not open"
    );
    host.press(keys::DISMISS);
    assert!(
        index_generation(host, label) > 0,
        "{label}: the bootstrap menu left no index behind"
    );
}

/// Run a command and wait for the prompt hook to have offered it to the index.
fn accept_command(host: &mut Host, command: &str, label: &str) {
    let appends = host.log_count(APPEND);
    host.send_line(command);
    assert!(
        host.sync_prompt(Duration::from_secs(10)),
        "{label}: {command:?} did not return to a prompt"
    );
    assert!(
        host.wait_log(APPEND, appends, Duration::from_secs(10)),
        "{label}: {command:?} never reached the index as an append"
    );
}

/// Position 1 of the open menu is `command`, carrying the event number the
/// index was last told about -- i.e. the real `$history` key of that command,
/// not a number the shell predicted for it.
fn assert_position_1_is(host: &mut Host, command: &str, label: &str) {
    let state = host.history_state();
    let head = dump_field(&state, "head").to_string();
    let rows = listing_rows(host, label);
    let position_1 = rows.last().expect("a non-empty listing has a last row");
    assert!(
        history_row(position_1, Some(&head), command),
        "{label}: position 1 is not {command:?} under event {head} (index state: {state}): \
         {position_1:?}"
    );
}

/// The first menu of a worker session has no index to read, so it synthesizes
/// one and sends it; the next one finds its own baseline intact and sends
/// nothing but the query.
#[test]
fn the_first_menu_builds_the_index_and_the_next_one_only_queries() {
    let mut host = Host::boot_history();

    let (cold, warm) = (host.log_count(COLD), host.log_count(WARM));
    let (snapshots, queries) = (host.log_count(SNAPSHOT), host.log_count(QUERY));
    assert!(
        open_menu(&mut host, "(hx-1a)"),
        "(hx-1a) the first Up did not open a menu"
    );
    assert_eq!(
        [
            host.log_count(COLD) - cold,
            host.log_count(WARM) - warm,
            host.log_count(SNAPSHOT) - snapshots,
            host.log_count(QUERY) - queries,
        ],
        [1, 0, 1, 1],
        "(hx-1a) the first menu did not bootstrap the index with exactly one snapshot \
         [cold, warm, snapshots, queries]:"
    );
    assert!(
        index_generation(&mut host, "(hx-1a)") > 0,
        "(hx-1a) the bootstrap left no index behind"
    );
    host.press(keys::DISMISS);

    let (cold, warm) = (host.log_count(COLD), host.log_count(WARM));
    let (snapshots, queries) = (host.log_count(SNAPSHOT), host.log_count(QUERY));
    assert!(
        open_menu(&mut host, "(hx-1b)"),
        "(hx-1b) the second Up did not open a menu"
    );
    assert_eq!(
        [
            host.log_count(COLD) - cold,
            host.log_count(WARM) - warm,
            host.log_count(SNAPSHOT) - snapshots,
            host.log_count(QUERY) - queries,
        ],
        [0, 1, 0, 1],
        "(hx-1b) the second menu did not plan straight from the index \
         [cold, warm, snapshots, queries]:"
    );
}

/// The index belongs to the worker session: a session that dies mid-exchange
/// takes it with it, the next menu rebuilds it from scratch, and the generation
/// counter the rebuild spends is past everything the dead session held
/// (cli-protocol.md "Requests and Responses" candidate_generation).
#[test]
fn the_index_dies_with_the_worker_session_and_the_next_menu_rebuilds_it() {
    let mut host = Host::boot_history_fake();
    // The fake has to be the worker before the index is latched, or the death
    // below would kill a session the index never came from. Its history writes
    // always succeed, so the latch is taken exactly as under the real binary;
    // only the `plan` comes back as an in-band error, which is neither a
    // session failure nor one of the latch's invalidation points.
    host.fake().set_mode(Mode::Error);
    assert!(
        !open_menu(&mut host, "(hx-2 setup)"),
        "(hx-2 setup) the erroring plan still opened a menu"
    );
    let latched = index_generation(&mut host, "(hx-2 setup)");
    assert!(
        latched > 0,
        "(hx-2 setup) the snapshot did not latch a generation"
    );

    let (snapshots, warm) = (host.log_count(SNAPSHOT), host.log_count(WARM));
    assert!(
        !open_menu(&mut host, "(hx-2a)"),
        "(hx-2a) the erroring plan still opened a menu"
    );
    assert!(
        host.log_count(WARM) == warm + 1 && host.log_count(SNAPSHOT) == snapshots,
        "(hx-2a) an in-band plan error was treated as an invalidation point"
    );

    // The worker dies inside the synchronous exchange.
    host.fake().set_mode(Mode::Die);
    let failures = host.log_count("worker: session failure:");
    let stopped = host.log_count("worker: transport stopped");
    assert!(
        !open_menu(&mut host, "(hx-2b)"),
        "(hx-2b) the menu opened although the worker died on its query"
    );
    assert!(
        host.wait_log(
            "worker: session failure:",
            failures,
            Duration::from_secs(15)
        ),
        "(hx-2b) the worker's death was not a session failure"
    );
    assert_eq!(
        index_generation(&mut host, "(hx-2c)"),
        0,
        "(hx-2c) the index outlived the session it belonged to"
    );
    // Replacement is allowed only once the dead session has finalized; without
    // this the Up below would fail for want of a worker rather than plan.
    assert!(
        host.wait_log(
            "worker: transport stopped",
            stopped,
            Duration::from_secs(15)
        ),
        "(hx-2c) the dead session never finalized"
    );

    host.fake().set_mode(Mode::Proxy);
    let (snapshots, cold) = (host.log_count(SNAPSHOT), host.log_count(COLD));
    assert!(
        open_menu(&mut host, "(hx-2d)"),
        "(hx-2d) the replacement worker did not serve a menu"
    );
    assert!(
        host.log_count(SNAPSHOT) == snapshots + 1 && host.log_count(COLD) == cold + 1,
        "(hx-2d) the menu after the restart did not rebuild the index"
    );
    let rebuilt = index_generation(&mut host, "(hx-2e)");
    assert!(
        rebuilt > latched,
        "(hx-2e) the rebuilt index rewound the generation counter (was {latched}, now {rebuilt})"
    );
    let post = host.postdisplay("(hx-2f)");
    assert!(
        post.contains("echo newest"),
        "(hx-2f) the rebuilt index is missing the fixture history: {post:?}"
    );
}

/// A re-source starts a shell generation with no index at all -- the state
/// variables carry nothing across -- and the next menu rebuilds it.
#[test]
fn a_re_source_leaves_no_index_and_the_next_menu_rebuilds_it() {
    let mut host = Host::boot_history();
    // The re-source below is asserted as a completed handoff, so give the old
    // generation's shutdown room to finish on a loaded machine.
    host.send_line(SHUTDOWN_SEAM);
    assert!(
        host.sync_prompt(Duration::from_secs(10)),
        "(hx-3 setup) the shutdown seam did not return to a prompt"
    );
    warm_index(&mut host, "(hx-3 setup)");
    let latched = index_generation(&mut host, "(hx-3 setup)");

    host.send_line("source <($ZRUSH_REAL_BIN init zsh)");
    assert!(
        host.sync_prompt(Duration::from_secs(15)),
        "(hx-3a) the re-source did not return to a prompt"
    );
    assert_eq!(
        host.history_state(),
        "gen=0 head=0 count=0 unacked=0",
        "(hx-3a) the re-sourced shell kept index state:"
    );

    let (snapshots, cold) = (host.log_count(SNAPSHOT), host.log_count(COLD));
    assert!(
        open_menu(&mut host, "(hx-3b)"),
        "(hx-3b) the re-sourced shell did not serve a menu"
    );
    assert!(
        host.log_count(SNAPSHOT) == snapshots + 1 && host.log_count(COLD) == cold + 1,
        "(hx-3b) the first menu after the re-source did not rebuild the index"
    );
    let rebuilt = index_generation(&mut host, "(hx-3c)");
    assert!(
        rebuilt > latched,
        "(hx-3c) the re-source rewound the generation counter (was {latched}, now {rebuilt})"
    );
    let post = host.postdisplay("(hx-3d)");
    assert!(
        post.contains("echo newest"),
        "(hx-3d) the rebuilt index is missing the fixture history: {post:?}"
    );
}

/// `fc -R` replaces a stretch of history in one go. However the fingerprint
/// notices -- the newest event jumps, or the pair the menu compares moves --
/// the next menu has to re-snapshot, and the bulk-loaded lines have to be in
/// the listing it opens.
#[test]
fn a_bulk_load_makes_the_next_menu_rebuild_the_index() {
    let mut host = Host::boot_history_sync();
    warm_index(&mut host, "(hx-4a setup)");

    host.send_line("fc -R $ZRUSH_TEST_TMP/histfile-sync-bulk");
    assert!(
        host.sync_prompt(Duration::from_secs(10)),
        "(hx-4a) the bulk load did not return to a prompt"
    );

    let snapshots = host.log_count(SNAPSHOT);
    assert!(
        open_menu(&mut host, "(hx-4a)"),
        "(hx-4a) the menu after the bulk load did not open"
    );
    assert_eq!(
        host.log_count(SNAPSHOT),
        snapshots + 1,
        "(hx-4a) the bulk load did not cost exactly one snapshot:"
    );
    let post = host.postdisplay("(hx-4a')");
    assert!(
        post.contains("echo bulkone") && post.contains("echo bulktwo") && post.contains("syncbase"),
        "(hx-4a') the rebuilt index does not hold the bulk-loaded history: {post:?}"
    );
}

/// A line pushed straight into `$history` makes the next prompt's event two
/// past the one the index knows: Level A's discontinuity, which drops the index
/// there and then rather than at the next menu.
#[test]
fn a_direct_history_injection_makes_the_next_menu_rebuild_the_index() {
    let mut host = Host::boot_history_sync();
    warm_index(&mut host, "(hx-4b setup)");

    let dirty = host.log_count(DISCONTINUITY);
    host.send_line("print -sr -- 'echo injected'");
    assert!(
        host.sync_prompt(Duration::from_secs(10)),
        "(hx-4b) the injection did not return to a prompt"
    );
    assert!(
        host.wait_log(DISCONTINUITY, dirty, Duration::from_secs(10)),
        "(hx-4b) the injected event was not seen as a discontinuity"
    );
    assert_eq!(
        index_generation(&mut host, "(hx-4b)"),
        0,
        "(hx-4b) the discontinuity left the index usable"
    );

    let snapshots = host.log_count(SNAPSHOT);
    assert!(
        open_menu(&mut host, "(hx-4b')"),
        "(hx-4b') the menu after the injection did not open"
    );
    assert_eq!(
        host.log_count(SNAPSHOT),
        snapshots + 1,
        "(hx-4b') the injection did not cost exactly one snapshot:"
    );
    assert_position_1_is(&mut host, "echo injected", "(hx-4b')");
}

/// `fc -p` swaps the whole history out and `fc -P` swaps it back; both ends of
/// the round trip are discontinuities, and the menu that follows rebuilds the
/// index over the restored history.
#[test]
fn a_history_stack_switch_makes_the_next_menu_rebuild_the_index() {
    let mut host = Host::boot_history_sync();
    warm_index(&mut host, "(hx-4c setup)");

    let dirty = host.log_count(DISCONTINUITY);
    host.send_line("fc -p");
    assert!(
        host.sync_prompt(Duration::from_secs(10)),
        "(hx-4c) the pushed history did not return to a prompt"
    );
    assert!(
        host.wait_log(DISCONTINUITY, dirty, Duration::from_secs(10)),
        "(hx-4c) the pushed history stack was not seen as a discontinuity"
    );
    host.send_line("fc -P");
    assert!(
        host.sync_prompt(Duration::from_secs(10)),
        "(hx-4c) the popped history did not return to a prompt"
    );

    let snapshots = host.log_count(SNAPSHOT);
    assert!(
        open_menu(&mut host, "(hx-4c')"),
        "(hx-4c') the menu after the stack round trip did not open"
    );
    assert_eq!(
        host.log_count(SNAPSHOT),
        snapshots + 1,
        "(hx-4c') the stack round trip did not cost exactly one snapshot:"
    );
    let post = host.postdisplay("(hx-4c'')");
    assert!(
        post.contains("echo syncnewest") && post.contains("echo syncbase"),
        "(hx-4c'') the rebuilt index does not hold the restored history: {post:?}"
    );
}

/// The steady state between menus: each accepted command reaches the index as
/// one append, and the menu that follows plans from the index it already has --
/// no re-synthesis, and the appended line carries its real event number.
#[test]
fn an_accepted_command_reaches_the_index_as_one_append() {
    let mut host = Host::boot_history();
    warm_index(&mut host, "(hx-5 setup)");

    let appends = host.log_count(APPEND);
    accept_command(&mut host, MARKER, "(hx-5a)");
    assert_eq!(
        host.log_count(APPEND),
        appends + 1,
        "(hx-5a) the accepted command did not cost exactly one append:"
    );

    let (snapshots, warm) = (host.log_count(SNAPSHOT), host.log_count(WARM));
    assert!(
        open_menu(&mut host, "(hx-5b)"),
        "(hx-5b) the menu after the append did not open"
    );
    assert!(
        host.log_count(SNAPSHOT) == snapshots && host.log_count(WARM) == warm + 1,
        "(hx-5b) the menu after an append did not take the warm path"
    );
    assert_position_1_is(&mut host, MARKER, "(hx-5c)");
}

/// A deadline no exchange can meet: the synchronous open fails as a worker
/// session failure, and what it leaves behind is nothing -- no menu, an
/// untouched buffer, no index, and no request re-issued on its own.
///
/// Only the structure of that branch is testable here; whether the production
/// 100 ms is enough for a real history is `tests/zsh/driver-latency.zsh`'s
/// question, and that driver deliberately has no deadline seam.
#[test]
fn a_deadline_the_exchange_cannot_meet_leaves_nothing_behind() {
    let mut host = Host::boot_history_with_deadline_ms(1);
    host.send_keys("echo");
    host.drain(Duration::from_millis(500));

    let expired = host.log_count("history deadline exceeded");
    let queries = host.log_count(QUERY);
    assert!(
        !open_menu(&mut host, "(hx-6a)"),
        "(hx-6a) an exchange with a 1 ms deadline still opened a menu"
    );
    assert!(
        host.wait_log(
            "history deadline exceeded",
            expired,
            Duration::from_secs(10)
        ),
        "(hx-6a) the exchange did not fail on its deadline"
    );
    assert_no_history_kind(
        &host.listing_kind("(hx-6b)"),
        "(hx-6b) the failed exchange left a history listing behind:",
    );
    host.assert_buffer("echo", "(hx-6c) the failed exchange changed the buffer");
    assert_eq!(
        index_generation(&mut host, "(hx-6d)"),
        0,
        "(hx-6d) the failed session left a usable index"
    );

    host.drain(Duration::from_secs(1));
    assert_eq!(
        host.log_count(QUERY),
        queries + 1,
        "(hx-6e) the failed exchange re-issued its request without a new keypress:"
    );
}

/// Ordering, waiting for the append: a command accepted immediately before Up
/// is position 1 of the menu that Up opens.
#[test]
fn a_command_accepted_before_up_is_position_1() {
    let mut host = Host::boot_history();
    warm_index(&mut host, "(hx-7a setup)");

    accept_command(&mut host, MARKER, "(hx-7a)");
    assert!(
        open_menu(&mut host, "(hx-7a)"),
        "(hx-7a) the menu after the accepted command did not open"
    );
    assert_position_1_is(&mut host, MARKER, "(hx-7a)");
}

/// Ordering, not waiting: the same expectation when the Up is typed with the
/// command itself, i.e. before its append has had any chance to be answered.
///
/// This is deterministic rather than a race. The Up sits in the terminal's
/// input buffer while the command runs, so zle reads it only after the prompt
/// hook that enqueues the append has run, and the queue that carries both is
/// serial and never reordered or coalesced (behavior.md "Worker Lifecycle") --
/// the append is ahead of the query, whoever answers first.
#[test]
fn a_command_accepted_before_up_is_position_1_without_waiting_for_the_append() {
    let mut host = Host::boot_history();
    warm_index(&mut host, "(hx-7b setup)");

    let opened = host.log_count(OPENED);
    let refused = host.log_count(NO_MENU);
    host.send_keys(&format!("{MARKER}{}{}", keys::ENTER, keys::UP));
    assert!(
        wait_menu(&mut host, opened, refused, "(hx-7b)"),
        "(hx-7b) the Up typed with the command did not open a menu"
    );
    assert_position_1_is(&mut host, MARKER, "(hx-7b)");
}

/// The listing invariants themselves (#14/#15) hold on both paths: the menu a
/// fresh session synthesizes and the menu planned from an index kept current by
/// appends are the same menu. Every host boots without an index, so the warm
/// repeat has to make its warmth explicitly.
#[test]
fn the_listing_invariants_hold_cold_and_warm() {
    let mut host = Host::boot_history();

    let snapshots = host.log_count(SNAPSHOT);
    assert_listing_invariants(&mut host, "(hx-8 cold)");
    assert_eq!(
        host.log_count(SNAPSHOT),
        snapshots + 1,
        "(hx-8 cold) the first menu of the session was not the cold path:"
    );

    accept_command(&mut host, MARKER, "(hx-8 warm-up)");

    let (snapshots, warm) = (host.log_count(SNAPSHOT), host.log_count(WARM));
    assert_listing_invariants(&mut host, "(hx-8 warm)");
    assert!(
        host.log_count(SNAPSHOT) == snapshots && host.log_count(WARM) == warm + 1,
        "(hx-8 warm) the repeat did not take the warm path"
    );
}

/// One filtered menu, from opening it to confirming out of it: the shape it
/// opens with, the single column growing upward under its event-number field,
/// the walk over the navigation table, and the whole-line confirm. These are
/// `hist_lifecycle`'s assertions for a fresh host, factored so that the warm
/// path can be held to exactly the same ones.
fn assert_listing_invariants(host: &mut Host, label: &str) {
    host.send_keys("echo");
    host.drain(Duration::from_millis(500));
    assert!(open_menu(host, label), "{label}: Up did not open a menu");
    assert_eq!(
        host.listing_kind(label),
        "kind=history sel=1 listing=1 npos=6",
        "{label}: the filtered menu did not open at position 1 over 6 matches:"
    );

    let rows = listing_rows(host, label);
    let first = rows.first().expect("a non-empty listing has a first row");
    let last = rows.last().expect("a non-empty listing has a last row");
    let newest = host
        .dump_get(keys::DUMP_EVENT, "TESTEVENT")
        .unwrap_or_else(|| panic!("{label}: the newest-event dump did not run"));
    assert!(
        history_row(first, None, "echo oldest") && history_row(last, Some(&newest), "echo newest"),
        "{label}: the listing is not one numbered column growing upward \
         (newest event {newest}): {rows:?}"
    );

    host.press(keys::UP);
    host.press(keys::UP);
    host.press(keys::DOWN);
    assert_eq!(
        host.listing_kind(label),
        "kind=history sel=2 listing=1 npos=6",
        "{label}: Up/Up/Down did not land on position 2:"
    );

    host.press(keys::ENTER);
    host.assert_buffer(
        "echo *.glob 'sq' \"dq\" \\bs -dash 日本語",
        &format!("{label}: Enter did not replace the line with the landed-on entry"),
    );
    host.clear_line();
    host.drain(Duration::from_millis(300));
}
