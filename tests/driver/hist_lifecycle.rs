//! History menu: opening, navigating, confirming and dismissing it, and the
//! hygiene of the entries it offers (docs/internal/specs/behavior.md
//! "History Menu", docs/internal/contracts/cli-protocol.md "history profile").
//!
//! Every test here runs on a host booted from `tests/zsh/rc/history.zshrc`,
//! whose fixture history is what the queries below select from.

use std::time::Duration;

use crate::hist::{assert_no_history_kind, open_menu};
use crate::host::{Host, keys};

/// Whether a rendered history row carries `text` behind an event-number field:
/// digits, then the two spaces that separate the number from the entry.
fn numbered_row(row: &str, text: &str) -> bool {
    let rest = row.trim_start();
    let digits = rest.len() - rest.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    digits > 0 && rest[digits..].starts_with(&format!("  {text}"))
}

/// Mid-input Up opens the menu filtered to the buffer at position 1; Up/Up/Down
/// walks the nav table; Enter replaces the whole line with the landed-on
/// entry's raw text and, being a confirm rather than accept-line, never runs it.
#[test]
fn up_opens_the_filtered_menu_and_enter_confirms_the_landed_entry() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "echo");

    let kind = host.listing_kind("(h1a)");
    assert_eq!(
        kind, "kind=history sel=1 listing=1 npos=6",
        "(h1a) mid-input Up did not open the filtered menu at position 1:"
    );

    let post = host.postdisplay("(h1a')");
    let listing = post.strip_prefix('\n').unwrap_or(&post);
    let first = listing.split('\n').next().expect("a first listing row");
    let last = listing.rsplit('\n').next().expect("a last listing row");
    assert!(
        numbered_row(first, "echo oldest") && numbered_row(last, "echo newest"),
        "(h1a') history is not one column growing upward: {post:?}"
    );

    host.press(keys::UP);
    assert_eq!(
        host.listing_kind("(h1b)"),
        "kind=history sel=2 listing=1 npos=6",
        "(h1b) Up did not move to the next-older entry:"
    );
    host.press(keys::UP);
    assert_eq!(
        host.listing_kind("(h1c)"),
        "kind=history sel=3 listing=1 npos=6",
        "(h1c) a second Up did not move to position 3:"
    );
    host.press(keys::DOWN);
    assert_eq!(
        host.listing_kind("(h1d)"),
        "kind=history sel=2 listing=1 npos=6",
        "(h1d) Down did not move back toward newer:"
    );

    host.press(keys::ENTER);
    host.assert_buffer(
        "echo *.glob 'sq' \"dq\" \\bs -dash 日本語",
        "(h1e) Enter did not replace the whole line with the landed-on entry's raw text",
    );
    let kind = host.listing_kind("(h1f)");
    assert_no_history_kind(&kind, "(h1f) confirm left a residual history-menu kind:");
}

/// Empty buffer plus Up: the unfiltered menu, one candidate per row, capped by
/// the default `[display].max-lines` (the fixture has 13 eligible entries).
/// Each row carries its real `$history` event number, and position 1 is the
/// single newest entry -- all three read the one menu the first step opens.
#[test]
fn an_empty_buffer_opens_the_full_menu_numbered_by_event() {
    let mut host = Host::boot_history();
    host.press(keys::UP);

    let kind = host.listing_kind("(h2a)");
    assert_eq!(
        kind, "kind=history sel=1 listing=1 npos=10",
        "(h2a) empty-buffer Up did not open a max-lines-bounded single-column menu:"
    );
    host.assert_buffer("", "(h2b) buffer did not stay empty while browsing");

    // Resolve the event number inside the host instead of assuming the fixture
    // entries are consecutive or start anywhere in particular.
    let event = host
        .dump_get(keys::DUMP_EVENT, "TESTEVENT")
        .expect("newest-event dump did not run");
    assert!(
        event.chars().all(|c| c.is_ascii_digit()) && !event.is_empty(),
        "(h27) newest fixture event number could not be resolved: {event}"
    );
    let post = host.postdisplay("(h27)");
    assert!(
        post.contains(&format!("{event:>5}  echo newest")),
        "(h27) the newest row lacks its right-aligned event number: event={event} post={post:?}"
    );

    host.press(keys::ENTER);
    host.assert_buffer(
        "echo newest",
        "(h2c) position 1 of the unfiltered menu is not the single newest entry",
    );
}

#[test]
fn dismiss_closes_the_history_menu_without_touching_the_buffer() {
    let mut host = Host::boot_history();
    host.press(keys::UP);
    let kind = host.listing_kind("(h3-setup)");
    assert!(
        kind.starts_with("kind=history"),
        "(h3-setup) history menu did not open: {kind}"
    );

    host.press(keys::DISMISS);
    assert_eq!(
        host.listing_kind("(h3a)"),
        "kind=none sel=0 listing=0 npos=0",
        "(h3a) dismiss did not close the history menu:"
    );
    host.assert_buffer("", "(h3b) buffer changed across a dismiss");
}

/// Typing while the menu is open erases the whole listing, unlike a completion
/// listing, which keeps its text until the next result arrives.
///
/// The query is an argument-position one (a real path prefix, then a suffix
/// matching no file) rather than a bare command-position character: at command
/// position the typed key hits the empty-word cache and renders a large
/// real-command listing, which only obscures the point.
#[test]
fn typing_erases_the_whole_history_menu() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "ls fx/basic/");
    let kind = host.listing_kind("(h4-setup)");
    assert!(
        kind.starts_with("kind=history sel=1 listing=1"),
        "(h4-setup) history menu did not open: {kind}"
    );

    host.send_keys("ZZZNOMATCH");
    host.drain(Duration::from_millis(600));
    let kind = host.listing_kind("(h4a)");
    assert_no_history_kind(&kind, "(h4a) typing left a residual history kind:");
    let post = host.postdisplay("(h4b)");
    assert!(
        post.is_empty(),
        "(h4b) history listing text left behind: {post:?}"
    );
}

/// A CURSOR-only external change (no BUFFER edit) must erase the menu too.
/// Asserted on the log line `_zrush_line_pre_redraw` emits on exactly this
/// transition, so the check is independent of whatever a same-buffer
/// recollection settles to afterwards.
#[test]
fn a_cursor_only_change_erases_the_history_menu() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "echo");
    let kind = host.listing_kind("(h23-setup)");
    assert!(
        kind.starts_with("kind=history"),
        "(h23-setup) history menu did not open: {kind}"
    );

    let erased = "history: menu erased by an external buffer/cursor change";
    let baseline = host.log_count(erased);
    host.press(keys::BACKWARD_CHAR);
    assert!(
        host.wait_log(erased, baseline, Duration::from_secs(3)),
        "(h23a) a cursor-only external change did not erase the history menu"
    );
    let kind = host.listing_kind("(h23b)");
    assert_no_history_kind(
        &kind,
        "(h23b) kind is still 'history' after a cursor-only change:",
    );
    host.assert_buffer("echo", "(h23c) buffer text changed, not just the cursor");
}

#[test]
fn tab_confirms_the_selected_history_entry() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "echo");
    host.press(keys::TAB);
    host.assert_buffer(
        "echo newest",
        "(h5) Tab did not confirm the selected history entry as a whole-line replacement",
    );
}

/// Ordering is fixed by recency and never re-sorted by match quality: position
/// 1 is the newer substring-only match even though an older prefix match (the
/// higher tier) also matches.
#[test]
fn position_1_is_the_newest_match_rather_than_the_best_tier() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "zqx");
    assert_eq!(
        host.listing_kind("(h6a)"),
        "kind=history sel=1 listing=1 npos=2",
        "(h6a) query 'zqx' did not match both fixture entries:"
    );

    host.press(keys::ENTER);
    host.assert_buffer(
        "aa zqx bb",
        "(h6b) position 1 was not the newer substring-only match",
    );
}

#[test]
fn a_duplicated_history_line_yields_one_candidate() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "dup");
    assert_eq!(
        host.listing_kind("(h7)"),
        "kind=history sel=1 listing=1 npos=1",
        "(h7) a duplicated history line was not deduplicated to a single candidate:"
    );
}

/// A history line carrying a framing byte (SOH here) is excluded whole rather
/// than stripped and kept: querying its surviving text finds nothing.
#[test]
fn a_framing_byte_excludes_the_whole_history_line() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "ctrlone");
    assert_eq!(
        host.listing_kind("(h9)"),
        "kind=none sel=0 listing=0 npos=0",
        "(h9) a history line containing a framing byte became a candidate:"
    );
    host.assert_buffer(
        "ctrlone",
        "(h9b) buffer changed although no menu opened (the key is still consumed)",
    );
}

/// A history line that itself contains a newline: the listing shows it
/// flattened to one row, but confirming inserts the raw multi-line text.
#[test]
fn a_multi_line_entry_is_flattened_in_the_listing_and_inserted_raw() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "multi");
    assert_eq!(
        host.listing_kind("(h10a)"),
        "kind=history sel=1 listing=1 npos=1",
        "(h10a) the multi-line fixture entry was not the sole match:"
    );

    let post = host.postdisplay("(h10b)");
    assert!(
        post.contains("multi line2") && !post.contains("multi\nline2"),
        "(h10b) the listing row is not flattened: {post:?}"
    );

    host.press(keys::ENTER);
    host.assert_buffer(
        "echo multi\nline2",
        "(h10c) confirming did not insert the raw multi-line text",
    );
}

/// Glob characters, quotes, a backslash, a leading dash and Japanese text are
/// shown and inserted byte for byte, never interpreted.
#[test]
fn meta_characters_are_displayed_and_inserted_verbatim() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "glob");
    assert_eq!(
        host.listing_kind("(h11a)"),
        "kind=history sel=1 listing=1 npos=1",
        "(h11a) the meta-character fixture entry was not the sole match:"
    );

    let entry = "echo *.glob 'sq' \"dq\" \\bs -dash 日本語";
    let post = host.postdisplay("(h11b)");
    assert!(
        post.contains(entry),
        "(h11b) the listing does not display the meta-character line verbatim: {post:?}"
    );

    host.press(keys::ENTER);
    host.assert_buffer(
        entry,
        "(h11c) confirming did not insert the meta-character line verbatim",
    );
}

/// A nonempty query with zero matches: no menu opens, the key is consumed, and
/// the buffer is left alone -- no fallback to native history search.
#[test]
fn a_zero_match_query_opens_nothing_and_leaves_the_buffer() {
    let mut host = Host::boot_history();
    open_menu(&mut host, "zzqqxx000");
    assert_eq!(
        host.listing_kind("(h12a)"),
        "kind=none sel=0 listing=0 npos=0",
        "(h12a) a zero-match query opened a menu:"
    );
    host.assert_buffer(
        "zzqqxx000",
        "(h12b) buffer changed on a zero-match query (key consumed, no native fallback)",
    );
}

/// The unfiltered menu is a `max-lines` window over 13 eligible fixture
/// entries. select-prev at the oldest visible row slides that window toward
/// the past; select-next at the newest visible row slides it back; left
/// jumps to the newest match; right stays on the oldest row still in view.
#[test]
fn the_history_menu_scrolls_past_the_row_budget() {
    let mut host = Host::boot_history();
    host.press(keys::UP);
    assert_eq!(
        host.listing_kind("(h28a)"),
        "kind=history sel=1 listing=1 npos=10",
        "(h28a) empty-buffer Up did not open the max-lines window:"
    );

    let opened = listing_rows(&mut host, "(h28a')");
    assert!(
        numbered_row(opened.last().expect("bottom row"), "echo newest")
            && numbered_row(opened.first().expect("top row"), "aa zqx bb"),
        "(h28a') the opening window is not newest..aa zqx bb: {opened:?}"
    );

    for _ in 0..9 {
        host.press(keys::UP);
    }
    assert_eq!(
        host.listing_kind("(h28b)"),
        "kind=history sel=10 listing=1 npos=10",
        "(h28b) nine Ups did not land on the oldest visible row:"
    );
    assert_eq!(
        listing_rows(&mut host, "(h28b')"),
        opened,
        "(h28b') moving inside the window scrolled it"
    );

    let scrolled = host.log_count("history: scrolled");
    host.press(keys::UP);
    assert!(
        host.wait_log("history: scrolled", scrolled, Duration::from_secs(3)),
        "(h28c) Up at the oldest visible row did not replan"
    );
    assert_eq!(
        host.listing_kind("(h28c')"),
        "kind=history sel=10 listing=1 npos=10",
        "(h28c') the scrolled window did not keep the new oldest selected:"
    );
    let after_one = listing_rows(&mut host, "(h28c'')");
    assert!(
        numbered_row(
            after_one.last().expect("bottom row"),
            "note: zrushtestslow is a fixture completion function"
        ) && numbered_row(after_one.first().expect("top row"), "echo mid1"),
        "(h28c'') the window did not slide one row older: {after_one:?}"
    );

    host.press(keys::UP);
    host.press(keys::UP);
    let at_end = listing_rows(&mut host, "(h28d)");
    assert!(
        numbered_row(at_end.first().expect("top row"), "echo oldest"),
        "(h28d) two more Ups did not reveal the oldest match: {at_end:?}"
    );
    host.press(keys::UP);
    assert_eq!(
        listing_rows(&mut host, "(h28d')"),
        at_end,
        "(h28d') Up at the scan-range end moved the window"
    );
    assert_eq!(
        host.listing_kind("(h28d'')"),
        "kind=history sel=10 listing=1 npos=10",
        "(h28d'') Up at the scan-range end left the menu:"
    );

    host.press(keys::LEFT);
    assert_eq!(
        host.listing_kind("(h28e)"),
        "kind=history sel=1 listing=1 npos=10",
        "(h28e) Left did not jump to the newest match:"
    );
    assert_eq!(
        listing_rows(&mut host, "(h28e')"),
        opened,
        "(h28e') Left did not restore the opening window"
    );

    host.press(keys::RIGHT);
    assert_eq!(
        host.listing_kind("(h28f)"),
        "kind=history sel=10 listing=1 npos=10",
        "(h28f) Right did not jump to the oldest visible row:"
    );
    assert_eq!(
        listing_rows(&mut host, "(h28f')"),
        opened,
        "(h28f') Right scrolled instead of staying in the window"
    );

    host.press(keys::UP);
    for _ in 0..9 {
        host.press(keys::DOWN);
    }
    assert_eq!(
        host.listing_kind("(h28g)"),
        "kind=history sel=1 listing=1 npos=10",
        "(h28g) Down did not walk back to the newest visible row:"
    );
    let back = host.log_count("history: scrolled");
    host.press(keys::DOWN);
    assert!(
        host.wait_log("history: scrolled", back, Duration::from_secs(3)),
        "(h28h) Down at the newest visible row of a shifted window did not replan"
    );
    assert_eq!(
        host.listing_kind("(h28h')"),
        "kind=history sel=1 listing=1 npos=10",
        "(h28h') scrolling newer did not select the newly revealed newest:"
    );
    assert_eq!(
        listing_rows(&mut host, "(h28h'')"),
        opened,
        "(h28h'') Down did not restore the opening window"
    );
}

fn listing_rows(host: &mut Host, label: &str) -> Vec<String> {
    let post = host.postdisplay(label);
    let listing = post.strip_prefix('\n').unwrap_or(&post);
    assert!(!listing.is_empty(), "{label}: the listing is empty");
    listing.split('\n').map(str::to_string).collect()
}
