//! Properties of the terminal session itself rather than of one feature:
//! several shells running at once, a continuation line, candidates whose
//! display width is not their character count, and a terminal that changes
//! size under a live listing.

use std::time::Duration;

use crate::fixtures;
use crate::host::{Host, PlanShape, keys};

/// Width the resize scenario narrows to. `fx/longcol`'s names are padded past
/// 80 columns, so a listing truncated for this width is unambiguously shorter.
const NARROW_COLS: u16 = 40;

fn widest_line(text: &str) -> usize {
    text.lines()
        .map(|line| line.chars().count())
        .max()
        .unwrap_or(0)
}

#[test]
fn two_shells_collect_and_confirm_independently() {
    // `Host` owns its work dir, pty and log with no process-global state, so
    // two live hosts share nothing; the big tree makes their collections
    // genuinely overlap in time.
    let mut small = Host::boot();
    let mut big = Host::boot_with_overflow();

    small.send_keys("ls fx/basic/subd");
    big.send_keys("ls fx/overflow/");

    assert!(
        small.expect("subdir", Duration::from_secs(15)),
        "(ses-1a) the first shell's listing never arrived: {}",
        small.window_tail()
    );
    assert!(
        big.expect("0000-marker.txt", Duration::from_secs(30)),
        "(ses-1b) the second shell's large collection never rendered: {}",
        big.window_tail()
    );

    small.press(keys::DOWN);
    small.press(keys::ENTER);
    small.assert_buffer(
        "ls fx/basic/subdir/",
        "(ses-1c) confirming in one shell while another is collecting",
    );
}

#[test]
fn a_ps2_continuation_line_lists_selects_and_confirms() {
    let mut host = Host::boot();

    host.send_keys("for i in 1 2");
    host.press(keys::ENTER); // incomplete command -> PS2, a new ZLE session
    host.drain(Duration::from_millis(500));

    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/subd");
    let post = host.postdisplay("(ses-2a)");
    assert!(
        post.contains("subdir"),
        "(ses-2a) no listing on the continuation line: {post:?}"
    );
    host.assert_log_grows(
        "select: start",
        &[keys::DOWN],
        "(ses-2b) selection on the continuation line",
    );
    host.press(keys::ENTER);
    // Each continuation line is its own ZLE session, so BUFFER holds that line
    // alone; a multiline BUFFER would need a self-inserted newline.
    host.assert_buffer(
        "ls fx/basic/subdir/",
        "(ses-2c) confirmed insertion within a continuation line",
    );

    assert!(
        host.send_break_and_sync(Duration::from_secs(10)),
        "(ses-2d) the continuation line was not discarded"
    );
}

#[test]
fn full_width_candidates_render() {
    let mut host = Host::boot_with_fixtures(fixtures::build_wide);

    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/wide/jp-");
    let post = host.postdisplay("(ses-3)");
    assert!(
        post.contains("日本語の長い名前") && post.contains("二つ目の全角"),
        "(ses-3) full-width candidates did not render: {post:?}"
    );
}

#[test]
fn a_resized_terminal_takes_effect_on_the_next_render() {
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/longcol/item");
    let wide = widest_line(&host.postdisplay("(ses-4) before resize"));

    // The kernel raises SIGWINCH on the resize; the next request reads the new
    // COLUMNS (docs/internal/contracts/cli-protocol.md "Startup and Responsibilities"), so a following
    // keystroke is what makes the narrower layout appear.
    host.resize(NARROW_COLS, 24);
    host.send_keys_wait_plan(PlanShape::Nonempty, "-");
    let narrow = widest_line(&host.postdisplay("(ses-4) after resize"));

    let limit = usize::from(NARROW_COLS);
    assert!(
        wide > limit && narrow > 0 && narrow < limit,
        "(ses-4) the listing was not re-laid out for the new width: {wide} -> {narrow}"
    );
}
