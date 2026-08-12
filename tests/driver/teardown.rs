//! Letting the interactive shell exit for real, with a live persistent worker
//! behind it: the worker is never the shell's job (behavior.md 「worker
//! ライフサイクル」), and a teardown that lands while a frame is still delegated
//! to a writer child stays just as quiet (cli-protocol.md 「abort control と
//! worker 終了」).
//!
//! Both tests read the pty to hang-up instead of killing the host, so what they
//! assert is what a user would have seen on the way out.

use std::time::Duration;

use crate::fake::Mode;
use crate::host::{Exit, Host, PlanShape, dump_field, keys, state_has};

/// zsh announces a job it is about to leave behind and reports one it reaped;
/// none of it may appear because zrush's worker exists.
const JOB_CONTROL_NOTICES: &[&str] = &["zsh: you have running jobs.", "Terminated", "Done"];

#[test]
fn one_exit_terminates_without_job_control_output() {
    let mut host = Host::boot_fake();
    assert_check_jobs(&mut host);

    // The job table does not need the 8 MiB raw-drain stressor: a small
    // terminal response keeps the case on a single `exit`, while zshexit stays
    // free to stop waiting at its fixed deadline.
    let session = host.fake().sessions() + 1;
    host.fake().set_mode(Mode::Error);
    let served0 = host.fake().count(&format!("error {session} "));
    let answered0 = host.log_count("worker: ok store request_id=");
    host.send_keys("ls fx/basic/al");
    let served = host.wait_fake(
        &format!("error {session} "),
        served0,
        Duration::from_secs(10),
    );
    let answered = host.wait_log(
        "worker: ok store request_id=",
        answered0,
        Duration::from_secs(10),
    );
    let live = host.worker_state();
    assert!(
        served && answered && state_has(&live, &["ready=1", "stopping=0"]),
        "(worker-job-table) the host did not reach a live worker: served={served} \
         answered={answered} state={live}"
    );

    host.clear_line();
    host.drain(Duration::from_millis(300));
    host.send_line("exit");
    let exit = host.wait_for_exit(Duration::from_secs(5));
    assert_quiet_exit(
        &exit,
        "(worker-job-table) one exit terminates without job-control output",
    );
}

/// Tearing down between a frame's dispatch to the writer child and its ack.
/// The overflow tree makes that child's single `syswrite` long enough for the
/// window to be reachable at all; whether a given run actually lands inside it
/// is a race, so the test asserts what holds either way and reports which
/// outcome it got (inflight-1c).
#[test]
fn exit_with_a_delegated_frame_stays_quiet_and_pid_free() {
    let mut host = Host::boot_with_overflow();
    assert_check_jobs(&mut host);

    // Warm the worker up on a small request first, so handshake and startup
    // latency cannot masquerade as "frame in flight" below.
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al");
    host.clear_line();
    host.drain(Duration::from_millis(300));

    let sending0 = host.log_count("worker: sending frame");
    let sent0 = host.log_count("worker: frame sent");
    host.send_keys("ls fx/overflow/");
    assert!(
        host.wait_log("worker: sending frame", sending0, Duration::from_secs(15)),
        "(inflight-1) no writer child was delegated for the overflow request"
    );
    let sending = host
        .last_log_line("worker: sending frame")
        .expect("(inflight-1) dispatch log line vanished after wait_log succeeded");
    let sent_at_dispatch = host.log_count("worker: frame sent");

    // No drain here: the point is to tear down as close to the writer-child
    // spawn as possible, before its ack can land. ^U discards only the
    // uncommitted `ls fx/overflow/` buffer text so that `exit` runs on an empty
    // line -- the capture is what queued the frame and already finished, and an
    // empty buffer collects nothing (behavior.md 「候補収集」), so no new
    // request races the exit. ^C would clear the buffer just as well but must
    // not be used: zsh 5.9 defers a SIGINT that arrives while a `zle -F`
    // callback is running -- precisely this window -- until the next input
    // byte, and the deferred send-break then swallows the 'e' of `exit`.
    host.send_keys(keys::KILL_WHOLE_LINE);
    host.send_line("exit");
    let exit = host.wait_for_exit(Duration::from_secs(5));
    assert_quiet_exit(
        &exit,
        "(inflight-1a) exit while the writer child is still delegated produces no job-control output",
    );

    let ack_fd: i32 = dump_field(&sending, "ackfd")
        .parse()
        .unwrap_or_else(|e| panic!("(inflight-1b) non-numeric ackfd in {sending:?} ({e})"));
    assert!(
        ack_fd > 2 && !sending.contains("writer_pid="),
        "(inflight-1b) the delegated writer is not tracked by its ack transport slot alone: \
         {sending}"
    );

    // Reported, never asserted: which side of the race this run landed on.
    if sent_at_dispatch == sent0 {
        println!(
            "(inflight-1c) teardown was dispatched before this frame's ack was consumed \
             (writer child genuinely still delegated)"
        );
    } else {
        println!(
            "(inflight-1c) this frame's ack had already landed before teardown; \
             (inflight-1a/b) still ran, but not against a strictly unacked frame"
        );
    }
}

/// The two options that make a leftover job visible at exit. Without them the
/// quiet exits below would prove nothing.
fn assert_check_jobs(host: &mut Host) {
    host.send_line("[[ -o checkjobs && -o checkrunningjobs ]] && print CHECK-JOBS-ENABLED");
    assert!(
        host.expect_in_order(&["CHECK-JOBS-ENABLED", "HP>"], Duration::from_secs(5)),
        "the host does not have CHECK_JOBS and CHECK_RUNNING_JOBS enabled"
    );
}

fn assert_quiet_exit(exit: &Exit, label: &str) {
    assert!(
        exit.reached_eof,
        "{label}: the shell never exited: {:?}",
        exit.output
    );
    for notice in JOB_CONTROL_NOTICES {
        assert!(
            !exit.output.contains(notice),
            "{label}: job-control output {notice:?} leaked: {:?}",
            exit.output
        );
    }
}
