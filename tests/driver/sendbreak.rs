//! Regression: send-break leaves a clean new prompt (fix 3). An exit that
//! bypasses `_zrush_line_finish` (send-break and similar) must not leak the
//! previous session's plan state into the next one.
//!
//! The 15s prompt-resync deadline is sized against an observed >5s pty-^C
//! interrupt-handling cost on a loaded host (#47).

use std::time::Duration;

use crate::host::{Host, PlanShape};

#[test]
fn send_break_resets_plan_state_for_the_next_prompt() {
    let mut host = Host::boot();
    // A test-only widget dumps _zrush_plan_npos/_zrush_listing directly, since
    // neither is observable through POSTDISPLAY/BUFFER alone once the new
    // prompt's line-init has already cleared the display.
    host.send_line(
        r#"_zrt_dump_plan() { _zlog "TESTPLAN=npos=$_zrush_plan_npos listing=$_zrush_listing" }; zle -N _zrt-dump-plan _zrt_dump_plan; bindkey "^Xy" _zrt-dump-plan"#,
    );
    host.sync_prompt(Duration::from_secs(5));

    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al"); // real, non-empty _zrush_plan_* now populated
    // send-break: abandon the line, bypassing line-finish
    assert!(
        host.send_break_and_sync(Duration::from_secs(15)),
        "(sb-1a) no new prompt appeared after send-break"
    );

    let plan = host
        .dump_get("\x18y", "TESTPLAN")
        .unwrap_or_else(|| panic!("(sb-1b) plan-state dump did not run"));
    assert!(
        plan.contains("npos=0") && plan.contains("listing=0"),
        "(sb-1b) stale plan state survived send-break: {plan}"
    );
}
