//! Active persistent-worker death: a session that dies with an assigned
//! request, the retry that follows, the circuit breaker two consecutive deaths
//! open, and the explicit re-source that starts a new recovery epoch
//! (docs/internal/specs/behavior.md 「worker ライフサイクル」,
//! docs/internal/contracts/cli-protocol.md 「応答の検証と zsh 側の適用」).

use std::time::Duration;

use crate::fake::Mode;
use crate::host::{Host, PlanShape, SHUTDOWN_SEAM, dump_field, keys, state_has};

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
    let dead_request_id = host
        .fake()
        .last(&format!("die {first} "))
        .expect("(err-1a) the die state line vanished after wait_fake succeeded")
        .rsplit(' ')
        .next()
        .expect("a die line ends with its request id")
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
                &["ready=1", "failures=1", "disabled=0", "pending=1"]
            )
            && host.fake().starts() == starts0 + 2,
        "(err-1c) held replacement state missing: clean={first_death_clean} held={held} \
         state={replacement}"
    );
    assert_eq!(
        host.fake().requests_for(&dead_request_id),
        1,
        "(err-1d) failed request_id={dead_request_id} was replayed or fake-state accounting changed"
    );

    // A well-formed terminal error is not a session failure.
    let errors0 = host.log_count("worker: error request_id=");
    host.fake().set_mode(Mode::Error);
    let answered = host.wait_log(
        "worker: error request_id=",
        errors0,
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
    host.send_keys("ls fx/basic/al\t"); // Tab pending before candidates exist
    host.wait_fake(&format!("die {third} "), died2, Duration::from_secs(10));
    host.wait_log(
        "worker: session failure:",
        failures2,
        Duration::from_secs(10),
    );
    let third_death_clean = host
        .wait_worker_state(Duration::from_secs(10), STOPPED)
        .is_ok();
    host.drain(Duration::from_millis(500));

    host.assert_buffer(
        "ls fx/basic/al",
        "(err-2) pending Tab resolved against an actively-dead worker inserts nothing",
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
