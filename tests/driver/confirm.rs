//! Confirm: insertion text reaches LBUFFER and RBUFFER survives untouched.

use crate::host::{Host, PlanShape, keys};

#[test]
fn confirm_inserts_the_plans_insertion_text() {
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/subd");
    host.press(keys::DOWN);
    host.press(keys::ENTER);
    host.assert_buffer(
        "ls fx/basic/subdir/",
        "(cfm-1) confirm inserts the plan's insertion text (directory '/' synthesis, no trailing space)",
    );
}

#[test]
fn confirm_mid_word_preserves_rbuffer() {
    let mut host = Host::boot();
    // 'alpEND' matches nothing: the query is case-sensitive because it is uppercase.
    host.send_keys_wait_plan(PlanShape::Zero, "ls fx/basic/alpEND");
    // The cursor lands between 'alp' and 'END'; the move re-collects with the
    // word 'alp', and that second plan is the one confirmed below.
    host.send_keys_wait_plan(PlanShape::Nonempty, keys::CURSOR_LEFT_THREE);
    host.press(keys::DOWN);
    host.press(keys::ENTER);
    host.assert_buffer(
        "ls fx/basic/alpha.txt END",
        "(cfm-2) RBUFFER ('END') is preserved verbatim after confirming mid-word",
    );
}
