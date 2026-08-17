//! What sourcing zrush leaves behind: a stopped persistent worker
//! (docs/internal/specs/behavior.md "Worker Lifecycle" の遅延起動) and a
//! host whose own stdio is untouched by the transport's fd bookkeeping
//! (docs/internal/contracts/cli-protocol.md "Startup and Responsibilities").

use std::time::Duration;

use crate::host::{Host, dump_field, keys, state_has};

/// Descriptor state of a worker that has never started.
const NEVER_STARTED: &[&str] = &[
    "ready=0",
    "stopping=0",
    "tainted=0",
    "rfd=-1",
    "wfd=-1",
    "control=-1",
    "ack=-1",
];

#[test]
fn sourcing_zrush_leaves_the_worker_stopped_and_host_stdio_intact() {
    let mut host = Host::boot();
    host.seed_stdio_baseline();

    let state = host.worker_state();
    assert!(
        state_has(&state, NEVER_STARTED) && dump_field(&state, "seq") == "0",
        "(worker-1a) source/config did not leave the persistent worker stopped: {state}"
    );
    host.assert_host_stdio("(fd-1a) source leaves host fd 0/1/2 attached and writable");
}

/// The transport's auxiliary descriptors -- the writer ack and the raw-drain
/// continuation -- both close through one teardown, and a generated `zle -F`
/// handler that dispatches once invalidates itself. Both run on a shell whose
/// worker has never started, so what they exercise is the bookkeeping alone.
#[test]
fn auxiliary_fd_teardown_and_generated_dispatch_preserve_host_stdio() {
    let mut host = Host::boot();
    host.seed_stdio_baseline();

    let aux = host
        .dump_get(keys::CLOSE_AUX_FDS, "TESTAUX")
        .expect("(fd-1b) auxiliary-fd dump did not run");
    assert_eq!(
        aux, "closed=1 ack=-1 drain=-1",
        "(fd-1b) ack/drain descriptors did not close through shared teardown"
    );
    host.assert_host_stdio("(fd-1c) ack/drain teardown preserves host fd 0/1/2");

    let dispatched0 = host.log_count("TESTGENERATED=dispatched");
    host.send_keys(keys::GENERATED_CALLBACK);
    assert!(
        host.wait_log(
            "TESTGENERATED=dispatched",
            dispatched0,
            Duration::from_secs(5)
        ),
        "(worker-callback) the generated handler never dispatched readiness"
    );
    let dispatch = host
        .last_log_line("TESTGENERATED=dispatched")
        .expect("(worker-callback) dispatch log line vanished after wait_log succeeded");
    let generation = dump_field(&dispatch, "generation");
    assert!(
        generation.parse::<u64>().is_ok()
            && state_has(
                &dispatch,
                &[
                    "kind=drain",
                    "current=0",
                    "drain=-1",
                    "handler_live=0",
                    "widget_live=0",
                ]
            ),
        "(worker-callback) the generated handler did not self-invalidate: {dispatch}"
    );
    let state = host.worker_state();
    assert!(
        state_has(&state, NEVER_STARTED),
        "(worker-callback) readiness dispatch left transport state behind: {state}"
    );
    host.assert_host_stdio("(fd-1d) generated callback dispatch preserves host fd 0/1/2");
}
