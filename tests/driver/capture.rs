//! Capture fork -> candidate records -> persistent worker, and the worker
//! lifecycle transitions that ride on it: lazy start, reuse, build-stamp
//! follow, and the two re-source shutdown paths
//! (docs/internal/contracts/cli-protocol.md 「ビルドスタンプ」, 「起動と責務」,
//! docs/internal/specs/behavior.md 「worker ライフサイクル」).

use std::path::Path;
use std::time::Duration;

use crate::fake::{DRAIN_TAIL_BYTES, Mode};
use crate::host::{Host, PlanShape, SHUTDOWN_SEAM, dump_field, keys, state_has};

#[test]
fn fork_capture_round_trip_reuses_one_worker() {
    let mut host = Host::boot();
    host.seed_stdio_baseline();

    // A real compsys fork collects candidates, ships candidate records
    // (b header + w/d), and the worker round trip renders a list.
    host.send_keys("ls fx/basic/al");
    assert!(
        host.expect("alpha.txt", Duration::from_secs(10)),
        "(cap-1a) list not displayed"
    );

    let first = host.worker_state();
    let first_rfd: i32 = dump_field(&first, "rfd").parse().expect("numeric rfd");
    let first_runtime = dump_field(&first, "runtime").to_string();
    // One collection spends one request id and one candidate generation: the
    // `store` that hands the records over. Its listing arrives as the
    // `plan-ready` that store settles, which is no request at all
    // (cli-protocol.md 「入力通知と worker event」).
    assert!(
        first_rfd > 2
            && state_has(
                &first,
                &["ready=1", "seq=1", "candgen=1", "stopping=0", "tainted=0"]
            )
            && first_runtime != "<none>",
        "(worker-1b) unexpected first-request state: {first}"
    );

    host.clear_line();
    host.drain(Duration::from_millis(300));
    host.assert_host_stdio("(fd-2a) lazy worker start preserves host fd 0/1/2");

    // A config reload after the worker is live must still deliver its warning
    // to the host pty.
    host.write_config("[unknown]\nvalue = true\n");
    host.send_line(":");
    assert!(
        host.expect_in_order(
            &["zrush: config: unknown table [unknown]; ignoring", "HP>"],
            Duration::from_secs(5)
        ),
        "(fd-2b) config warning missing after worker startup"
    );
    host.remove_config();
    host.send_line(":");
    host.sync_prompt(Duration::from_secs(5));
    host.assert_host_stdio("(fd-2c) config reload preserves host fd 0/1/2");

    // The batch header's shared X/J tags reach the worker and come back as a
    // heading line (_files' 'file' tag with group-name '').
    host.send_keys("ls fx/headed/");
    assert!(
        host.expect_in_order(&["file", "plainfile.txt"], Duration::from_secs(10)),
        "(cap-1b) 'file' heading not displayed"
    );
    host.clear_line();
    host.drain(Duration::from_millis(300));

    let successive = host.worker_state();
    let successive_seq: u64 = dump_field(&successive, "seq").parse().expect("numeric seq");
    assert!(
        dump_field(&successive, "rfd") == first_rfd.to_string()
            && successive_seq > 1
            && dump_field(&successive, "runtime") == first_runtime,
        "(worker-1c) worker was not reused: first={first} now={successive}"
    );
}

/// A config process from a newer build makes the loaded generation re-source
/// the current binary once, and an `incompatible` handshake does the same on
/// the asynchronous path. Both are silent, preserve the shell-session request
/// counter, and restart a previously-live worker.
#[test]
fn build_stamp_mismatch_re_sources_and_restarts_the_worker() {
    // The fake launcher is what makes the second half reachable: only it can
    // answer a handshake with `incompatible`.
    let mut host = Host::boot_fake();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al");
    host.clear_line();
    host.drain(Duration::from_millis(300));

    let live = host.worker_state();
    let seq_before_auto = dump_field(&live, "seq").to_string();
    let runtime_before = dump_field(&live, "runtime").to_string();

    let auto_config0 = host.log_count("build: automatic re-source completed");
    host.send_line(SHUTDOWN_SEAM);
    host.sync_prompt(Duration::from_secs(5));
    host.send_line("_ZRUSH_EXPECTED_BUILD_STAMP=deadbeef");
    host.sync_prompt(Duration::from_secs(5));
    host.write_config("[display]\nmax-lines = 10\n");
    host.send_line(":");
    host.sync_prompt(Duration::from_secs(5));

    let ready = &[
        "ready=1",
        "disabled=0",
        "stale=0",
        "buildwarned=0",
        "following=0",
        "verifying=0",
        "stopping=0",
        "tainted=0",
        "pending=0",
    ];
    let after_config = host
        .wait_worker_state(Duration::from_secs(10), ready)
        .unwrap_or_else(|last| panic!("(build-1a) automatic config follow failed: {last}"));
    assert!(
        host.wait_log(
            "build: automatic re-source completed",
            auto_config0,
            Duration::from_secs(5)
        ),
        "(build-1a) the re-source was not recorded as completed"
    );
    let config_rfd: i32 = dump_field(&after_config, "rfd")
        .parse()
        .expect("numeric rfd");
    let config_runtime = dump_field(&after_config, "runtime").to_string();
    assert!(
        config_rfd > 2
            && state_has(&after_config, &[&format!("seq={seq_before_auto}")])
            && config_runtime != "<none>"
            && config_runtime != runtime_before
            && !Path::new(&runtime_before).exists(),
        "(build-1a) config stamp mismatch did not restart the live worker cleanly: \
         state={after_config} old={runtime_before}"
    );
    host.remove_config();
    host.send_line(":");
    host.sync_prompt(Duration::from_secs(5));

    // The async worker-handshake path uses the same transition. Its pending
    // request is not replayed (one keystroke misses).
    host.send_line(SHUTDOWN_SEAM);
    host.sync_prompt(Duration::from_secs(5));
    host.send_keys(keys::WORKER_TEARDOWN);
    host.wait_worker_state(
        Duration::from_secs(10),
        &[
            "ready=0",
            "stopping=0",
            "rfd=-1",
            "wfd=-1",
            "control=-1",
            "ack=-1",
            "pending=0",
        ],
    )
    .unwrap_or_else(|last| panic!("(build-1b setup) could not stop the prior worker: {last}"));

    let mismatch = format!("mismatch {}", host.fake().sessions() + 1);
    let mismatch0 = host.fake().count_line(&mismatch);
    host.fake().set_mode(Mode::Mismatch);
    let auto_worker0 = host.log_count("build: automatic re-source completed");
    host.send_keys("ls fx/basic/al");
    assert!(
        host.wait_fake_line(&mismatch, mismatch0, Duration::from_secs(10)),
        "(build-1b) no fake session answered the handshake with `incompatible`"
    );
    assert!(
        host.wait_log(
            "build: automatic re-source completed",
            auto_worker0,
            Duration::from_secs(10)
        ),
        "(build-1b) the incompatible handshake did not trigger a completed re-source"
    );
    let after_worker = host
        .wait_worker_state(Duration::from_secs(10), ready)
        .unwrap_or_else(|last| panic!("(build-1b) automatic worker follow failed: {last}"));
    let worker_runtime = dump_field(&after_worker, "runtime");
    assert!(
        worker_runtime != "<none>"
            && worker_runtime != config_runtime
            && !Path::new(&config_runtime).exists(),
        "(build-1b) the replacement did not take over the runtime generation: \
         state={after_worker} old={config_runtime}"
    );

    // Input after the missed keystroke is served by the replacement; the panic
    // inside send_keys_wait_plan is this case's assertion.
    host.fake().set_mode(Mode::Proxy);
    host.send_keys_wait_plan(PlanShape::Nonempty, "p"); // (build-1c)
}

/// An explicit re-source tears the transport down and observes response EOF
/// before it replaces the old runtime generation, while the monotonic request
/// counter survives (cli-protocol.md 「要求と応答」 request_id).
#[test]
fn re_source_tears_down_the_transport_and_keeps_the_request_counter() {
    let mut host = Host::boot();
    host.seed_stdio_baseline();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al");
    host.clear_line();
    host.drain(Duration::from_millis(300));

    let live = host.worker_state();
    let seq_before = dump_field(&live, "seq").to_string();
    let runtime_before = dump_field(&live, "runtime").to_string();
    let stopped0 = host.log_count("worker: transport stopped");

    host.send_line(SHUTDOWN_SEAM);
    host.sync_prompt(Duration::from_secs(5));
    host.send_line("source <($ZRUSH_REAL_BIN init zsh)");
    host.sync_prompt(Duration::from_secs(5));

    let after = host.worker_state();
    let after_runtime = dump_field(&after, "runtime");
    assert!(
        state_has(
            &after,
            &[
                "ready=0",
                &format!("seq={seq_before}"),
                "stopping=0",
                "tainted=0",
                "rfd=-1",
                "wfd=-1",
                "control=-1",
                "ack=-1",
                "pending=0",
            ]
        ) && after_runtime != "<none>"
            && after_runtime != runtime_before,
        "(worker-1d) bad post-resource state: {after}"
    );
    assert!(
        host.wait_log(
            "worker: transport stopped",
            stopped0,
            Duration::from_secs(5)
        ) && !Path::new(&runtime_before).exists(),
        "(worker-1e) old completion/runtime cleanup missing: runtime={runtime_before}"
    );
    host.assert_host_stdio("(fd-3) re-source teardown preserves host fd 0/1/2");
}

/// Re-source a healthy fake session whose final stdout bytes are deliberately
/// not a protocol frame: healthy transport shutdown must keep stdout open and
/// drain raw bytes without parsing them (cli-protocol.md 「abort control と
/// worker 終了」). The fake records stdin EOF, the tail write, and clean return
/// in that order, so the observation does not depend on whether a real worker
/// happened to have an outstanding response.
#[test]
fn healthy_re_source_drains_a_raw_stdout_tail() {
    let mut host = Host::boot_fake();
    host.seed_stdio_baseline();
    let session = host.fake().sessions() + 1;
    host.fake().set_mode(Mode::Drain);

    let served0 = host.fake().count(&format!("drain {session} "));
    let stored0 = host.log_count("worker: ok store request_id=");
    host.send_keys("ls fx/basic/al");
    assert!(
        host.wait_fake(
            &format!("drain {session} "),
            served0,
            Duration::from_secs(10)
        ),
        "(worker-1f) the fake session never served a request"
    );
    assert!(
        host.wait_log(
            "worker: ok store request_id=",
            stored0,
            Duration::from_secs(10)
        ),
        "(worker-1f) the terminal response never reached the host"
    );
    let live = host.worker_state();
    assert!(
        state_has(&live, &["ready=1", "stopping=0", "tainted=0"]),
        "(worker-1f/g) healthy fake session did not become ready: {live}"
    );
    let seq = dump_field(&live, "seq").to_string();

    // Each of these records ends at the session number, so they are matched as
    // whole lines rather than with the trailing-space needle convention.
    let (eof, tail, exit) = (
        format!("eof {session}"),
        format!("tail {session} {DRAIN_TAIL_BYTES}"),
        format!("exit {session}"),
    );
    let eof0 = host.fake().count_line(&eof);
    let tail0 = host.fake().count_line(&tail);
    let exit0 = host.fake().count_line(&exit);
    host.clear_line();
    host.drain(Duration::from_millis(200));
    host.send_line(SHUTDOWN_SEAM);
    host.sync_prompt(Duration::from_secs(5));

    host.send_line("source <($ZRUSH_REAL_BIN init zsh)");
    let resynced = host.sync_prompt(Duration::from_secs(5));
    let saw_eof = host.wait_fake_line(&eof, eof0, Duration::from_secs(5));
    let saw_tail = host.wait_fake_line(&tail, tail0, Duration::from_secs(5));
    let saw_exit = host.wait_fake_line(&exit, exit0, Duration::from_secs(5));
    assert!(
        resynced
            && saw_eof
            && saw_tail
            && saw_exit
            && !host.window_has("Terminated")
            && !host.window_has("Done")
            && !host.window_has("zsh: you have running jobs."),
        "(worker-1f) healthy fake shutdown incomplete: prompt={resynced} eof={saw_eof} \
         tail={saw_tail} exit={saw_exit} output={}",
        host.window_tail()
    );

    let after = host.worker_state();
    assert!(
        state_has(
            &after,
            &[
                "ready=0",
                &format!("seq={seq}"),
                "stopping=0",
                "tainted=0",
                "rfd=-1",
                "wfd=-1",
                "control=-1",
                "ack=-1",
                "pending=0",
            ]
        ),
        "(worker-1g) bad post-resource fake-worker state: {after}"
    );
    host.assert_host_stdio("(fd-3b) healthy raw-drain re-source preserves host fd 0/1/2");
}

/// w vs m: a candidate whose quoted form differs from its raw text. The listing
/// shows the raw text (m, cli-protocol.md 「候補レコード」) and confirming
/// inserts the quoted form (w) so the shell word stays valid.
#[test]
fn listing_shows_raw_text_and_confirming_inserts_the_quoted_form() {
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/spacey/has");

    let post = host.postdisplay("(cap-1c)");
    assert!(
        post.contains("has space.txt"),
        "(cap-1c) raw text not found in POSTDISPLAY dump: {post:?}"
    );

    host.press(keys::DOWN); // select the (only) candidate
    host.press(keys::ENTER);
    host.assert_buffer(
        "ls fx/spacey/has\\ space.txt ",
        "(cap-1c') confirmation inserts the quoted (w) form 'has\\ space.txt'",
    );
}

/// A compadd call with zero hits must still tail-call the real builtin
/// (`_zrush_compadd`), or compsys internal state can desync and break the
/// *next* completion.
#[test]
fn a_zero_candidate_prefix_leaves_compsys_state_intact() {
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Zero, "ls fx/basic/ZZZNOMATCH");
    let post = host.postdisplay("(cap-2a)");
    assert!(
        post.is_empty(),
        "(cap-2a) unexpected listing for a zero-candidate prefix: {post:?}"
    );

    host.clear_line();
    host.drain(Duration::from_millis(300));
    host.send_keys("ls fx/basic/al");
    assert!(
        host.expect("alpha.txt", Duration::from_secs(10)),
        "(cap-2b) completion broke after a zero-candidate collection"
    );
}

/// Hidden files: the fork collects them unconditionally (globdots,
/// behavior.md 「候補収集」) and the matcher keeps them out until the query
/// starts with a dot (cli-protocol.md 「隠し候補の除外」).
#[test]
fn hidden_entries_stay_out_until_the_query_starts_with_a_dot() {
    let mut host = Host::boot();

    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/hidden/");
    let post = host.postdisplay("(cap-3a)");
    assert!(
        post.contains("visible.txt") && !post.contains("dotted"),
        "(cap-3a) hidden entries leaked into a dotless listing: {post:?}"
    );

    host.clear_line();
    host.drain(Duration::from_millis(300));
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/hidden/.");
    let post = host.postdisplay("(cap-3b)");
    assert!(
        post.contains(".dotted-alpha.txt") && post.contains(".dotted-beta.txt"),
        "(cap-3b) hidden entries missing after the dot: {post:?}"
    );

    host.clear_line();
    host.drain(Duration::from_millis(300));
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/hidden/.dotted-be");
    let post = host.postdisplay("(cap-3c)");
    assert!(
        post.contains(".dotted-beta.txt") && !post.contains("alpha"),
        "(cap-3c) hidden entries not filtered: {post:?}"
    );
}
