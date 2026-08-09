//! When select-prev/select-next do *not* open or move the history menu but
//! fall through to what the key was bound to before zrush, or to plain cursor
//! movement (docs/internal/specs/behavior.md 「選択・キーバインド」 priority
//! rules, docs/internal/contracts/config-schema.md 「[keybind]」).
//!
//! Every test here runs on a host booted from `tests/zsh/rc/history.zshrc`.

use std::time::Duration;

use crate::hist::assert_no_history_kind;
use crate::host::{Host, keys};

/// While plain history is being browsed (`HISTNO != HISTCMD`, entered through
/// the rc file's raw `^Xu` binding), select-prev and select-next both delegate
/// to their predecessor instead of opening or moving a history menu.
///
/// Each raw history step changes BUFFER to a real history line, which -- like
/// any buffer edit -- can arm and settle an ordinary recollection before the
/// following dump runs, and that legitimately reports 'compsys'. So the kind
/// assertions here are "never 'history'", not "always 'none'".
///
/// "kind != history" alone would also pass if the key were simply swallowed as
/// a no-op rather than delegated, so the transition is additionally pinned down
/// through BUFFER: Up must move one further step back in plain history (a
/// different line), and Down must land back on exactly the line seen before Up
/// (a round trip), which only up-line-or-history/down-line-or-history produce.
#[test]
fn browsing_plain_history_delegates_both_directions() {
    let mut host = Host::boot_history();

    host.press(keys::RAW_HISTORY_UP);
    // A second raw step, so the round trip below has room: the delegated Up
    // spends one more step backwards, and the delegated Down after it must
    // still have a newer entry to return to.
    host.press(keys::RAW_HISTORY_UP);

    let kind = host.listing_kind("(h13-setup)");
    assert_no_history_kind(
        &kind,
        "(h13-setup) unexpected history-menu kind after raw history browsing:",
    );
    let base = host.buffer("(h13-setup)");

    host.press(keys::UP);
    let kind = host.listing_kind("(h13a)");
    assert_no_history_kind(
        &kind,
        "(h13a) Up while browsing plain history opened a history menu:",
    );
    let after_up = host.buffer("(h13a')");
    assert_ne!(
        after_up, base,
        "(h13a') buffer did not change; Up may have been silently swallowed instead of delegated"
    );

    host.press(keys::DOWN);
    let kind = host.listing_kind("(h13b)");
    assert_no_history_kind(
        &kind,
        "(h13b) Down while browsing plain history opened a history menu:",
    );
    let after_down = host.buffer("(h13b')");
    assert_eq!(
        after_down, base,
        "(h13b') the delegated Down did not move one step forward, back to the plain-history line seen before Up"
    );
}

/// A multiline buffer with the cursor off the first line: Up is cursor
/// movement, not a history-menu open (behavior.md priority rule 1, symmetric
/// with select-next's own multiline rule).
///
/// "buffer unchanged" alone would also pass if Up were a pure no-op, so the
/// cursor is read on both sides of the key: 'echo a' occupies positions 0..6
/// (the newline sits at 6), so landing anywhere in 0..6 means "on line 1".
#[test]
fn a_cursor_below_the_first_line_makes_up_a_cursor_movement() {
    let mut host = Host::boot_history();
    host.send_keys("echo a");
    host.send_keys(keys::QUOTED_NEWLINE);
    host.send_keys("b");
    host.drain(Duration::from_millis(500));

    let before = host.cursor("(h14-setup)");
    assert_eq!(
        before, 8,
        "(h14-setup) the cursor is not at the end of 'echo a\\nb':"
    );

    host.press(keys::UP);
    let kind = host.listing_kind("(h14a)");
    // A same-buffer recollection for the "b" argument word may already have
    // settled (cli-protocol.md records it as 'compsys' either way); only a
    // 'history' kind would mean the menu wrongly opened.
    assert_no_history_kind(
        &kind,
        "(h14a) Up with a newline in LBUFFER opened a history menu:",
    );
    host.assert_buffer(
        "echo a\nb",
        "(h14b) buffer content changed, although only the cursor should have moved",
    );

    let after = host.cursor("(h14c)");
    assert!(
        after < 7 && after != before,
        "(h14c) the cursor did not move onto the first line (before={before} after={after}; line 1 spans 0..6)"
    );
}

/// Remapping select-prev to just `["up"]` leaves ctrl-p bound to its
/// predecessor, i.e. plain history movement, while Up -- still in the remapped
/// list -- keeps opening the history menu.
///
/// Up is exercised first, on the pristine just-started state: ctrl-p's own
/// predecessor is real native history movement and would otherwise leave
/// `HISTNO != HISTCMD` behind it, which changes what a *later* Up does
/// (behavior.md priority rule 2) -- unrelated to what this remap is about.
///
/// "kind != history" alone would pass for ctrl-p being silently swallowed as a
/// no-op, so the delegation is pinned down by requiring a real, nonempty buffer
/// change out of its predecessor.
#[test]
fn dropping_ctrl_p_from_select_prev_leaves_it_on_native_history_movement() {
    let mut host = Host::boot_history_with_config("[keybind]\nselect-prev = [\"up\"]\n");

    host.press(keys::UP);
    let kind = host.listing_kind("(h20b)");
    assert!(
        kind.starts_with("kind=history sel=1 listing=1"),
        "(h20b) Up (still in the remapped select-prev list) did not open the history menu: {kind}"
    );

    host.press(keys::DISMISS); // back to an empty buffer, HISTNO still untouched
    let before = host.buffer("(h20a')");

    host.press(keys::CTRL_P);
    let kind = host.listing_kind("(h20a)");
    // ctrl-p's predecessor may move BUFFER to a real history line, which can
    // arm and settle an ordinary recollection before this dump runs.
    assert_no_history_kind(
        &kind,
        "(h20a) ctrl-p (excluded from select-prev) opened the history menu:",
    );
    let after = host.buffer("(h20a')");
    assert!(
        !after.is_empty() && after != before,
        "(h20a') ctrl-p did not change the buffer; it may have been silently swallowed instead of delegated (before={before:?} after={after:?})"
    );
}
