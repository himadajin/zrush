//! Selection: navigation table plus the highlight swap it drives.

use std::time::Duration;

use crate::host::{Host, PlanShape, keys};

#[test]
fn selection_starts_moves_and_releases() {
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al");

    let start = host.log_count("select: start");
    host.press(keys::DOWN);
    assert!(
        host.wait_log("select: start", start, Duration::from_secs(3)),
        "(sel-1a) Down with a visible list did not start selection"
    );

    let rh = host
        .dump_get(keys::DUMP_RH, "TESTRH")
        .expect("(sel-1b) region_highlight dump did not run");
    let decorated = rh.contains("memo=zrush-sel") || (!host.has_memo() && rh.contains("standout"));
    assert!(
        decorated,
        "(sel-1b) pos=1's own decoration did not replace its match highlight: {rh}"
    );

    host.assert_log_grows(
        "select: dir=next",
        &[keys::DOWN],
        "(sel-1c) Down again moves via the nav table (select-next)",
    );
    // The second Up leaves position 1, whose prev is 0 (deselect).
    host.assert_log_grows(
        "select: dir=prev",
        &[keys::UP, keys::UP],
        "(sel-1d) Up moves via the nav table (select-prev)",
    );

    let rh = host
        .dump_get(keys::DUMP_RH, "TESTRH")
        .expect("(sel-1e) region_highlight dump did not run");
    assert!(
        !rh.contains("-sel") && !rh.contains("standout"),
        "(sel-1e) Up at position 1 did not release the selection: {rh}"
    );
}

#[test]
fn selection_left_right_jump_within_a_single_column_group() {
    // Why a one-column group turns left/right into a jump to the group's
    // ends: cli-protocol.md "ナビ".
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/longcol/item");
    host.press(keys::DOWN);

    host.assert_log_grows(
        "select: dir=right",
        &[keys::RIGHT],
        "(sel-2a) Right jumps toward the group's last position",
    );
    host.assert_log_grows(
        "select: dir=left",
        &[keys::LEFT],
        "(sel-2b) Left jumps back toward the group's first position",
    );
}
