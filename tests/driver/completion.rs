//! Completion scrolling over a real worker, with controllable delivery of its replies.

use crate::host::{Host, PlanShape, keys};
use std::time::Duration;

const RC: &str = r#"
_zrush_test_complete() {
  compadd -J first -X First -- item{001..035}
  compadd -J second -X Second -- item{036..070}
  compadd -J third -X Third -- item{071..100}
}
compdef _zrush_test_complete zrtest
functions[_zrush_test_handle]=$functions[_zrush_worker_handle_message]
typeset -gi _zrush_test_hold=0
typeset -ga _zrush_test_held=()
_zrush_worker_handle_message() {
  local -a reply
  _zrush_decode_fields "$1" || return 1
  if (( _zrush_test_hold )) && [[ $reply[1] == ok && ${_zrush_worker_pending[$reply[2]]:-} == completion\ * ]]; then
    _zrush_test_held+=( "$1" )
    _zlog 'test: completion held'
    return 0
  fi
  _zrush_test_handle "$@"
}
_zrush_test_hold_widget() { _zrush_test_hold=1 }
_zrush_test_release_widget() {
  _zrush_test_hold=0
  local frame
  while (( $#_zrush_test_held )); do
    frame=$_zrush_test_held[-1]
    _zrush_test_held[-1]=()
    _zrush_test_handle "$frame"
  done
  zle -R
}
_zrush_test_fail_widget() {
  local -a reply
  _zrush_decode_fields "$_zrush_test_held[1]"
  local id=$reply[2]
  _zrush_test_held=()
  _zrush_test_hold=0
  _zrush_encode_message error "$id" unknown-generation
  _zrush_test_handle "$REPLY"
  zle -R
}
zle -N _zrush_test_fail_widget
bindkey '^Xy' _zrush_test_fail_widget
zle -N _zrush_test_hold_widget
zle -N _zrush_test_release_widget
bindkey '^Xo' _zrush_test_hold_widget
bindkey '^Xr' _zrush_test_release_widget
"#;
const HOLD: &str = "\x18o";
const RELEASE: &str = "\x18r";
const QUERY: &str = "zrtest item";

fn open(rows: usize, columns: u16) -> Host {
    let mut host = Host::boot_completion(RC, rows);
    host.resize(columns, 24);
    host.send_keys_wait_plan(PlanShape::Nonempty, QUERY);
    host
}

fn wait_scroll(host: &mut Host, baseline: usize) {
    assert!(host.wait_log("completion: scrolled", baseline, Duration::from_secs(8)));
}

#[test]
fn all_candidates_are_reachable_across_columns_and_groups() {
    for columns in [12, 80] {
        let mut host = open(4, columns);
        assert!(host.postdisplay("initial position").ends_with("0/100"));
        let before = host.log_count("confirm: kind=compsys");
        host.press(&[keys::DOWN.repeat(101), keys::ENTER.to_string()].concat());
        assert!(host.wait_log("confirm: kind=compsys", before, Duration::from_secs(15)));
        host.assert_buffer("zrtest item100 ", "last candidate beyond old rows*8 limit");
    }
}

#[test]
fn completion_moves_back_to_global_start_and_deselects() {
    let mut host = open(4, 12);
    host.press(&keys::DOWN.repeat(5));
    let _ = host.postdisplay("after forward moves");
    host.press(&keys::UP.repeat(5));
    let start = std::time::Instant::now();
    loop {
        if host.postdisplay("back at first window").ends_with("0/100") {
            break;
        }
        assert!(start.elapsed() < Duration::from_secs(8));
    }
    host.assert_buffer(QUERY, "navigation never inserts");
    host.press(keys::DOWN);
    assert!(host.postdisplay("select first again").ends_with("1/100"));
}

#[test]
fn delayed_moves_and_confirmation_preserve_press_order() {
    for confirm in [keys::ENTER, keys::TAB] {
        let mut host = open(4, 12);
        host.press(&keys::DOWN.repeat(2));
        host.press(HOLD);
        let held = host.log_count("test: completion held");
        host.press(
            &[
                keys::DOWN,
                keys::DOWN,
                keys::UP,
                keys::RIGHT,
                keys::LEFT,
                confirm,
            ]
            .concat(),
        );
        assert!(host.wait_log("test: completion held", held, Duration::from_secs(8)));
        host.assert_buffer(QUERY, "pending confirmation does not insert old candidate");
        let before = host.log_count("confirm: kind=compsys");
        host.press(RELEASE);
        assert!(host.wait_log("confirm: kind=compsys", before, Duration::from_secs(8)));
        // Window [3,4]: Up selects 3, Right selects 4, Left returns to 3.
        host.assert_buffer("zrtest item003 ", "queued navigation and confirmation");
    }
}

#[test]
fn edits_cursor_changes_and_dismiss_cancel_pending_confirmation() {
    for cancel in ["0", keys::BACKWARD_CHAR, keys::DISMISS] {
        let mut host = open(4, 12);
        host.press(&keys::DOWN.repeat(2));
        host.press(HOLD);
        let held = host.log_count("test: completion held");
        host.press(&[keys::DOWN, keys::ENTER].concat());
        assert!(host.wait_log("test: completion held", held, Duration::from_secs(8)));
        let confirms = host.log_count("confirm: kind=compsys");
        host.press(cancel);
        let buffer = host.buffer("after cancellation");
        host.press(RELEASE);
        host.assert_buffer(&buffer, "late response cannot insert");
        assert_eq!(host.log_count("confirm: kind=compsys"), confirms);
        if cancel == keys::DISMISS {
            assert!(host.postdisplay("dismissed").is_empty());
        }
    }
}

#[test]
fn edits_and_cursor_changes_during_drain_cancel_remaining_operations() {
    let edit_buffer = r#"
_zrush_test_edit_buffer() { RBUFFER=x$RBUFFER }
zle -N backward-char _zrush_test_edit_buffer
"#;
    for (predecessor, expected_buffer, expected_cursor) in [
        ("", QUERY, QUERY.len() - 1),
        (edit_buffer, "zrtest itemx", QUERY.len()),
    ] {
        for confirm in [keys::ENTER, keys::TAB] {
            let mut host = Host::boot_completion(&format!("{RC}\n{predecessor}"), 4);
            host.resize(12, 24);
            host.send_keys_wait_plan(PlanShape::Nonempty, QUERY);
            let before = host.log_count("completion: scrolled");
            host.press(&keys::DOWN.repeat(3));
            wait_scroll(&mut host, before);
            host.press(keys::UP);
            assert!(
                host.postdisplay("global second candidate")
                    .ends_with("2/100")
            );
            host.press(HOLD);
            let held = host.log_count("test: completion held");
            host.press(&[keys::UP, keys::UP, keys::LEFT, keys::DOWN, confirm].concat());
            assert!(host.wait_log("test: completion held", held, Duration::from_secs(8)));
            host.assert_buffer(QUERY, "queued operations wait for the response");
            host.press(RELEASE);
            host.assert_buffer(
                expected_buffer,
                "only the delegated operation changes the buffer",
            );
            assert_eq!(host.cursor("delegated operation cursor"), expected_cursor);
            assert_eq!(host.log_count("confirm: kind=compsys"), 0);
        }
    }
}

#[test]
fn reverse_delivery_does_not_restore_a_cancelled_selection() {
    let mut host = open(4, 12);
    host.press(HOLD);
    host.press(&keys::DOWN.repeat(3));
    assert!(host.wait_log("test: completion held", 0, Duration::from_secs(8)));
    host.press(keys::KILL_WHOLE_LINE);
    host.send_keys_wait_plan(PlanShape::Nonempty, QUERY);
    host.press(&keys::DOWN.repeat(3));
    assert!(host.wait_log("test: completion held", 1, Duration::from_secs(8)));
    let before = host.log_count("completion: scrolled");
    host.press(RELEASE);
    wait_scroll(&mut host, before);
    assert!(host.postdisplay("newer result retained").ends_with("3/100"));
    assert_eq!(host.log_count("completion: scrolled"), before + 1);
}

#[test]
fn next_scroll_uses_resized_geometry_and_keeps_the_target() {
    let mut host = open(4, 12);
    host.press(&keys::DOWN.repeat(2));
    host.resize(80, 24);
    let before = host.log_count("completion: scrolled");
    host.press(keys::DOWN);
    wait_scroll(&mut host, before);
    let shown = host.postdisplay("resized window");
    assert!(shown.ends_with("3/100"));
    assert!(shown.contains("item003") && shown.contains("item016"));
    assert!(shown.trim_start_matches('\n').lines().count() <= 4);
}

#[test]
fn one_line_budget_keeps_candidates_and_scrolls() {
    let mut host = open(1, 12);
    let shown = host.postdisplay("one row");
    assert!(!shown.contains("/100"));
    let before = host.log_count("confirm: kind=compsys");
    host.press(&[keys::DOWN.repeat(10), keys::ENTER.to_string()].concat());
    assert!(host.wait_log("confirm: kind=compsys", before, Duration::from_secs(10)));
    host.assert_buffer("zrtest item010 ", "one-row insertion");
}

#[test]
fn replan_failure_cancels_the_queued_confirmation() {
    let mut host = open(4, 12);
    host.press(&keys::DOWN.repeat(2));
    host.press(HOLD);
    host.press(&[keys::DOWN, keys::ENTER].concat());
    assert!(host.wait_log("test: completion held", 0, Duration::from_secs(8)));
    host.press("\x18y");
    host.assert_buffer(QUERY, "failed replan leaves input alone");
    assert!(host.postdisplay("failed replan closes listing").is_empty());
    assert_eq!(host.log_count("confirm: kind=compsys"), 0);
}

#[test]
fn worker_session_change_drops_pending_navigation_and_confirmation() {
    let mut host = open(4, 12);
    host.press(&keys::DOWN.repeat(2));
    host.press(HOLD);
    host.press(&[keys::DOWN, keys::ENTER].concat());
    assert!(host.wait_log("test: completion held", 0, Duration::from_secs(8)));
    host.press(keys::WORKER_TEARDOWN);
    host.assert_buffer(QUERY, "session change leaves input alone");
    // A fresh input starts a fresh worker and an unselected initial window.
    host.send_keys_wait_plan(PlanShape::Nonempty, "0");
    assert!(host.postdisplay("fresh session").ends_with("0/99"));
    assert_eq!(host.log_count("confirm: kind=compsys"), 0);
}
