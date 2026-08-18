//! Active persistent-worker death: a session that dies with an assigned
//! request, the retry that follows, the circuit breaker two consecutive deaths
//! open, and the explicit re-source that starts a new recovery epoch
//! (docs/internal/specs/behavior.md "Worker Lifecycle",
//! docs/internal/contracts/cli-protocol.md "Response Validation and zsh-Side Application (Normative)").

use std::time::Duration;

use crate::fake::Mode;
use crate::host::{Host, PlanShape, SHUTDOWN_SEAM, dump_field, keys, state_has};
use crate::tab::TAB_FLUSHED;

/// Transport state after a stop has fully unwound.
const STOPPED: &[&str] = &[
    "ready=0",
    "stopping=0",
    "rfd=-1",
    "wfd=-1",
    "control=-1",
    "ack=-1",
    "pending=0",
];

/// One scenario, because the failure streak and the breaker it opens are
/// sequential state on a single shell. Session numbers and `start` counts are
/// taken relative to what this host's own fake has already recorded.
#[test]
fn active_session_deaths_open_the_breaker_and_a_re_source_recovers() {
    let mut host = Host::boot_fake();
    host.seed_stdio_baseline();
    // Every teardown below is asserted as a *completed* handoff. In a full zsh
    // driver run this section inherited the same seam from `sec_capture`.
    host.send_line(SHUTDOWN_SEAM);
    host.sync_prompt(Duration::from_secs(5));

    // Sanity: the delegated real worker behaves normally first.
    host.send_keys("ls fx/basic/al");
    assert!(
        host.expect("alpha.txt", Duration::from_secs(10)),
        "(err-0) real-worker sanity check failed before death injection"
    );
    host.clear_line();
    host.drain(Duration::from_millis(300));

    // Switch only future sessions to the fake.
    let stopped0 = host.log_count("worker: transport stopped");
    host.send_keys(keys::WORKER_TEARDOWN);
    host.drain(Duration::from_millis(300));
    let torn_down = host.worker_state();
    assert!(
        state_has(&torn_down, STOPPED)
            && host.wait_log(
                "worker: transport stopped",
                stopped0,
                Duration::from_secs(5)
            ),
        "(err-setup) explicit teardown did not finalize: {torn_down}"
    );
    host.assert_host_stdio("(fd-4) explicit worker teardown preserves host fd 0/1/2");

    let session0 = host.fake().sessions();
    let (first, second, third) = (session0 + 1, session0 + 2, session0 + 3);
    let starts0 = host.fake().starts();

    // ---- first death: ready, assigned a request, then gone ----
    host.fake().set_mode(Mode::Die);
    let failures0 = host.log_count("worker: session failure:");
    let died0 = host.fake().count(&format!("die {first} "));
    let log_lines0 = host.log_lines();
    host.send_keys("ls fx/basic/al");
    let died = host.wait_fake(&format!("die {first} "), died0, Duration::from_secs(10));
    let failed = host.wait_log(
        "worker: session failure:",
        failures0,
        Duration::from_secs(10),
    );
    assert!(
        host.window_has("zrush: worker transport failed; retrying once"),
        "(fd-5a) worker failure notice missing from pty output: {}",
        host.window_tail()
    );

    let restarts = host.log_count_after(log_lines0, "worker: started rfd=");
    let after_death = host.worker_state();
    assert!(
        died && failed
            && restarts == 1
            && state_has(
                &after_death,
                &["failures=1", "disabled=0", "warned=1", "pending=0"]
            ),
        "(err-1a) active-death state missing: state={after_death} starts={restarts}"
    );
    // The first message of a collection is the `input` notification the
    // keystroke makes, so that is what this session died on
    // (cli-protocol.md "Input Notifications and Worker Events").
    let dead_generation = host
        .fake()
        .last(&format!("die {first} "))
        .expect("(err-1a) the die state line vanished after wait_fake succeeded")
        .rsplit(' ')
        .next()
        .expect("a die line ends with its correlation key")
        .to_string();

    host.drain(Duration::from_millis(500));
    let post = host.postdisplay("(err-1b)");
    assert!(
        post.is_empty(),
        "(err-1b) a stale/unexpected listing was shown: {post:?}"
    );

    host.clear_line();
    host.drain(Duration::from_millis(300));
    host.assert_host_stdio("(fd-5b) session failure teardown preserves host fd 0/1/2");
    let first_death_clean = host
        .wait_worker_state(Duration::from_secs(10), STOPPED)
        .is_ok();

    // ---- the lazy replacement, held after ready and assignment ----
    // The fake parks on the first message it reads, which is the `input`
    // notification the keystroke makes: it answers with no event, so nothing is
    // ever collected and no request goes out behind it
    // (cli-protocol.md "Input Notifications and Worker Events").
    host.fake().set_mode(Mode::Hold);
    let held0 = host.fake().count(&format!("hold {second} "));
    host.send_keys("ls fx/basic/");
    let held = host.wait_fake(&format!("hold {second} "), held0, Duration::from_secs(10));
    let replacement = host.worker_state();
    assert!(
        first_death_clean
            && held
            && state_has(
                &replacement,
                &["ready=1", "failures=1", "disabled=0", "pending=0"]
            )
            && host.fake().starts() == starts0 + 2,
        "(err-1c) held replacement state missing: clean={first_death_clean} held={held} \
         state={replacement}"
    );
    assert_eq!(
        host.fake().notifications_for(&dead_generation),
        1,
        "(err-1d) failed input_generation={dead_generation} was replayed or \
         fake-state accounting changed"
    );

    // A well-formed terminal response is not a session failure. Releasing the
    // hold lets the parked notification settle, and the collection it asks for
    // answers with the `store` this waits on. (The same reset after a terminal
    // *error* is what `a_failed_request_is_not_replayed_and_only_new_input_\
    // makes_a_generation` fixes, on the one path that still sends a `plan`.)
    let answered0 = host.log_count("worker: ok store request_id=");
    host.fake().set_mode(Mode::Error);
    let answered = host.wait_log(
        "worker: ok store request_id=",
        answered0,
        Duration::from_secs(10),
    );
    let after_error = host.worker_state();
    assert!(
        answered && state_has(&after_error, &["failures=0", "disabled=0", "pending=0"]),
        "(err-1e) terminal response did not reset streak: {after_error}"
    );

    // ---- kill that session, then its one lazy replacement: breaker opens ----
    host.fake().set_mode(Mode::Die);
    host.clear_line();
    host.drain(Duration::from_millis(300));
    let died1 = host.fake().count(&format!("die {second} "));
    let failures1 = host.log_count("worker: session failure:");
    host.send_keys("ls fx/basic/al");
    host.wait_fake(&format!("die {second} "), died1, Duration::from_secs(10));
    host.wait_log(
        "worker: session failure:",
        failures1,
        Duration::from_secs(10),
    );
    let second_death_clean = host
        .wait_worker_state(Duration::from_secs(10), STOPPED)
        .is_ok();

    host.clear_line();
    host.drain(Duration::from_millis(300));
    let died2 = host.fake().count(&format!("die {third} "));
    let failures2 = host.log_count("worker: session failure:");
    host.send_keys("ls fx/basic/al");
    host.wait_fake(&format!("die {third} "), died2, Duration::from_secs(10));
    host.wait_log(
        "worker: session failure:",
        failures2,
        Duration::from_secs(10),
    );
    let third_death_clean = host
        .wait_worker_state(Duration::from_secs(10), STOPPED)
        .is_ok();

    // Tab once the death has unwound: no listing, no input awaiting an event
    // and no collection, so it falls through to the predecessor chain and
    // inserts nothing of its own (behavior.md "Tab").
    host.press(keys::TAB);
    host.drain(Duration::from_millis(500));
    host.assert_buffer(
        "ls fx/basic/al",
        "(err-2) Tab resolved against an actively-dead worker inserts nothing",
    );
    let disabled = host.worker_state();
    assert!(
        second_death_clean
            && third_death_clean
            && state_has(
                &disabled,
                &[
                    "failures=2",
                    "disabled=1",
                    "reason=session-failure",
                    "warned=1",
                    "pending=0",
                ]
            )
            && host.fake().starts() == starts0 + 3,
        "(err-3) active-death breaker state missing: second-clean={second_death_clean} \
         third-clean={third_death_clean} state={disabled}"
    );
    // The status line survives the redraw each dump widget provokes, which is
    // why it is still observable after the two dumps above.
    assert!(
        host.window_has(
            "zrush: worker disabled after repeated failures; source <(zrush init zsh) to retry"
        ),
        "(err-3a) disabled worker status missing from pty output: {}",
        host.window_tail()
    );

    host.clear_line();
    host.drain(Duration::from_millis(300));
    host.assert_host_stdio("(fd-6) explicit disable preserves host fd 0/1/2");
    host.send_keys("print HISTMARK-AFTER-ERROR");
    host.send_keys(keys::ENTER);
    assert!(
        host.expect_in_order(&["HISTMARK-AFTER-ERROR", "HP>"], Duration::from_secs(5)),
        "(err-4) shell did not respond after worker failures"
    );
    host.drain(Duration::from_millis(200));

    // ---- explicit re-source: a new recovery epoch, still lazy ----
    host.fake().set_mode(Mode::Proxy);
    host.send_line("source <($ZRUSH_REAL_BIN init zsh)");
    let resynced = host.sync_prompt(Duration::from_secs(10));
    let recovered = host.worker_state();
    assert!(
        resynced
            && state_has(
                &recovered,
                &[
                    "ready=0",
                    "failures=0",
                    "disabled=0",
                    "reason=",
                    "stale=0",
                    "stopping=0",
                    "rfd=-1",
                    "wfd=-1",
                    "control=-1",
                    "ack=-1",
                    "pending=0",
                ]
            ),
        "(err-5a) explicit re-source did not restore a lazy worker: {recovered}"
    );
    // The request counter is the one thing recovery must not reset.
    assert!(
        dump_field(&recovered, "seq") != "0",
        "(err-5a) re-source reset the monotonic request counter: {recovered}"
    );

    // The panic inside send_keys_wait_plan is this case's assertion.
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al"); // (err-5b)
}

/// A well-formed terminal `error` ends its request for good: neither that
/// `plan` nor the `history-snapshot` it was pipelined behind is sent again, and
/// no candidate generation is spent recovering. Only the next real input makes
/// the next generation (cli-protocol.md "Response Validation and zsh-Side Application (Normative)",
/// behavior.md "Worker Lifecycle").
///
/// The history menu is where a `plan` request still goes. The input-following
/// listing sends none: its candidates arrive as the event an accepted `store`
/// settles (cli-protocol.md "Input Notifications and Worker Events").
#[test]
fn a_failed_request_is_not_replayed_and_only_new_input_makes_a_generation() {
    let mut host = Host::boot_history_fake();
    // One session failure first, so the streak the in-band error has to reset
    // below is a non-zero one.
    host.fake().set_mode(Mode::Die);
    let failures0 = host.log_count("worker: session failure:");
    let stopped0 = host.log_count("worker: transport stopped");
    host.press(keys::UP);
    assert!(
        host.wait_log(
            "worker: session failure:",
            failures0,
            Duration::from_secs(15)
        ),
        "(err-6 setup) the worker did not die inside the menu's exchange"
    );
    // A replacement may only start once the dead session has finalized.
    assert!(
        host.wait_log(
            "worker: transport stopped",
            stopped0,
            Duration::from_secs(15)
        ),
        "(err-6 setup) the dead session never finalized"
    );
    let broken = host.worker_state();
    assert!(
        state_has(&broken, &["failures=1", "disabled=0"]),
        "(err-6 setup) the death left no streak for the error to reset: {broken}"
    );

    // Every write this mode sees succeeds and every `plan` gets an in-band
    // `error`, so the failing request is a correlated one -- not a session
    // failure that would discard the pair for a different reason.
    host.fake().set_mode(Mode::Error);

    let errors0 = host.log_count("worker: error request_id=");
    host.press(keys::UP);
    assert!(
        host.wait_log(
            "worker: error request_id=",
            errors0,
            Duration::from_secs(10)
        ),
        "(err-6a) the fake session never answered the plan with an in-band error"
    );
    let reset = host.worker_state();
    assert!(
        state_has(&reset, &["failures=0", "disabled=0"]),
        "(err-6a) a well-formed terminal error did not reset the failure streak: {reset}"
    );

    let snapshot_line = host
        .last_log_line("worker: queued history-snapshot request_id=")
        .expect("(err-6a) no history snapshot was queued for the menu");
    let plan_line = host
        .last_log_line("worker: queued request_id=")
        .expect("(err-6a) no plan was queued for the menu");
    let snapshot_id = dump_field(&snapshot_line, "request_id").to_string();
    let plan_id = dump_field(&plan_line, "request_id").to_string();
    let settled = host.worker_state();
    let candgen = dump_field(&settled, "candgen").to_string();

    // Long enough for a replay or an unsolicited recollection to show up.
    host.drain(Duration::from_secs(1));
    let idle = host.worker_state();
    assert!(
        host.fake().requests_for(&snapshot_id) == 1
            && host.fake().requests_for(&plan_id) == 1
            && state_has(
                &idle,
                &[
                    &format!("candgen={candgen}"),
                    "pending=0",
                    "staged=0",
                    "failures=0",
                    "disabled=0",
                ]
            ),
        "(err-6b) the failed pair was replayed or spent a generation: \
         snapshot={snapshot_id} plan={plan_id} state={idle}"
    );

    // One more keystroke: one new collection, one new generation.
    let stores0 = host.log_count("worker: queued store request_id=");
    host.send_keys("p");
    assert!(
        host.wait_log(
            "worker: queued store request_id=",
            stores0,
            Duration::from_secs(10)
        ),
        "(err-6c) the next real input did not reach the worker"
    );
    let next: i64 = candgen.parse().expect("numeric candgen");
    let after = host.worker_state();
    assert!(
        state_has(&after, &[&format!("candgen={}", next + 1)]),
        "(err-6d) the next input did not make exactly one new generation \
         (was candgen={candgen}): {after}"
    );
}

/// A Tab recorded while the worker still owed an event, on a session that then
/// dies: the failure drops the input generation, so the press it left behind
/// has nothing to resolve against and the buffer is never touched
/// (behavior.md "Tab", "Worker Lifecycle").
///
/// `Hold` is what makes that window deterministic. The parked `input`
/// notification cannot be answered while the mode holds, so the Tab provably
/// lands on a still-pending input -- it has to take the quiet-period flush
/// branch to pass -- and the death is only released afterwards.
#[test]
fn a_pending_tab_whose_worker_dies_inserts_nothing() {
    let mut host = Host::boot_fake();
    let session = host.fake().sessions() + 1;
    host.fake().set_mode(Mode::Hold);

    let held0 = host.fake().count(&format!("hold {session} "));
    let flushed0 = host.log_count(TAB_FLUSHED);
    host.send_keys("ls fx/basic/al");
    assert!(
        host.wait_fake(&format!("hold {session} "), held0, Duration::from_secs(10)),
        "(err-7a) the fake never parked the input notification"
    );

    host.press(keys::TAB);
    assert!(
        host.wait_log(TAB_FLUSHED, flushed0, Duration::from_secs(5)),
        "(err-7b) Tab did not record itself against the still-pending input"
    );

    let failures0 = host.log_count("worker: session failure:");
    host.fake().set_mode(Mode::Die);
    assert!(
        host.wait_log(
            "worker: session failure:",
            failures0,
            Duration::from_secs(15)
        ),
        "(err-7c) the parked session did not die once the hold was released"
    );
    assert!(
        host.wait_worker_state(Duration::from_secs(15), STOPPED)
            .is_ok(),
        "(err-7c) the dead session never finalized"
    );

    host.drain(Duration::from_millis(500));
    host.assert_buffer(
        "ls fx/basic/al",
        "(err-7d) the pending Tab inserted something after its worker died",
    );
    assert_eq!(
        host.postdisplay("(err-7d)"),
        "",
        "(err-7d) a listing survived the worker the pending Tab was waiting on"
    );
}
