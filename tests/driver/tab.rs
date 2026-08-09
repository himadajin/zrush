//! Tab: pending-before-candidates and `tab = "common-prefix"` over a
//! leading dash run (docs/internal/specs/behavior.md "Tab", "候補収集"
//! 「広げ規則」).

use std::time::Duration;

use crate::host::{Host, PlanShape, keys};

#[test]
fn pending_tab_starts_selection_once_candidates_arrive() {
    // Default [insert].tab=menu, so a Tab that lands before candidates arrive
    // must, once they arrive, start selection -- not change the buffer.
    let mut host = Host::boot();
    let pending_baseline = host.log_count("tab: pending");
    let select_baseline = host.log_count("select: start");
    host.send_keys("ls fx/basic/al\t"); // Tab in the same burst, before debounce elapses
    assert!(
        host.wait_log("tab: pending", pending_baseline, Duration::from_secs(3)),
        "(tab-1a) pending path not logged"
    );
    assert!(
        host.wait_log("select: start", select_baseline, Duration::from_secs(5)),
        "(tab-1b) pending Tab was not applied on arrival"
    );
}

/// `[insert].tab = "common-prefix"` over a leading dash run. The widening
/// rule keeps the run in the collection string so compsys yields option
/// candidates, and compsys returns those dash-included; the run must
/// therefore stay in the query too, or the common-prefix insertion prepends a
/// second dash (behavior.md "広げ規則"). A compdef fixture pins the candidate
/// set: the real `ls -` option list differs per platform.
#[test]
fn common_prefix_tab_over_a_leading_dash_run_does_not_double_the_dash() {
    let mut host = Host::boot();
    host.send_line("_zrushtestopt() { local -a m=(-alpha -alt); compadd -a m }");
    host.sync_prompt(Duration::from_secs(5));
    host.send_line("compdef _zrushtestopt zrushtestopt");
    host.sync_prompt(Duration::from_secs(5));
    host.write_config("[insert]\ntab = \"common-prefix\"\n");
    host.send_line(":");
    host.sync_prompt(Duration::from_secs(5));

    host.send_keys_wait_plan(PlanShape::Nonempty, "zrushtestopt -");
    let applied_baseline = host.log_count("plan: applied");
    host.press(keys::TAB);
    host.assert_buffer(
        "zrushtestopt -al",
        "(tab-2a) tab=common-prefix over a lone '-' inserts the common prefix without doubling the dash",
    );

    // The partial insertion is not a confirmation: it retriggers collection,
    // and that second listing is what the Tab below acts on.
    assert!(
        host.wait_log("plan: applied", applied_baseline, Duration::from_secs(5)),
        "(tab-2b) the common-prefix insertion did not retrigger collection"
    );
    host.press(keys::TAB);
    host.assert_buffer(
        "zrushtestopt -alpha ",
        "(tab-2b) a common-prefix that no longer grows falls back to confirming the top candidate",
    );
}
