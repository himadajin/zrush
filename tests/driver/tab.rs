//! Tab: pending-before-candidates and `tab = "common-prefix"` over a
//! leading dash run (docs/internal/specs/behavior.md "Tab", "Candidate Collection"
//! 「広げ規則」).

use std::time::Duration;

use crate::host::{Host, PlanShape, keys};

/// The Tab branch that cuts a still-running quiet period short, as opposed to
/// the one that merely records the press over a collection already in flight
/// (behavior.md "Tab").
pub const TAB_FLUSHED: &str = "tab: pending (quiet-period flush";

/// Default `[insert].tab = "menu"`, so a Tab that lands before candidates
/// arrive must, once they arrive, start selection -- not change the buffer.
///
/// The Tab has to land while the worker is still measuring the quiet period,
/// which the contract's longest `delay-ms` makes reachable: the keystrokes are
/// one burst, whose last one is what makes the notification (input pressure
/// suppresses the others, behavior.md "Candidate Collection"), and the Tab follows it as
/// its own press.
///
/// Ten seconds is also what makes the fast-forward observable rather than
/// merely assumed: the press must take the quiet-period branch by name, and the
/// selection it starts must arrive inside a deadline that a worker left to time
/// the period out could not meet (behavior.md "Tab").
#[test]
fn pending_tab_flushes_the_quiet_period_and_starts_selection_on_arrival() {
    let mut host = Host::boot();
    host.write_config("[display]\ndelay-ms = 10000\n");
    host.send_line(":");
    host.sync_prompt(Duration::from_secs(5));

    let notified_baseline = host.log_count("worker: queued input");
    let flushed_baseline = host.log_count(TAB_FLUSHED);
    let select_baseline = host.log_count("select: start");
    host.send_keys("ls fx/basic/al");
    assert!(
        host.wait_log(
            "worker: queued input",
            notified_baseline,
            Duration::from_secs(5)
        ),
        "(tab-1a) the burst never notified an input"
    );
    host.press(keys::TAB);
    assert!(
        host.wait_log(TAB_FLUSHED, flushed_baseline, Duration::from_secs(3)),
        "(tab-1b) Tab did not take the quiet-period flush branch"
    );
    assert!(
        host.wait_log("select: start", select_baseline, Duration::from_secs(3)),
        "(tab-1c) the flushed quiet period did not deliver candidates in time"
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
