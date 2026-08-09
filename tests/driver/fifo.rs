//! FIFO-capacity frame delegation: a candidate_payload larger than the
//! request-FIFO buffer must still cross in one delegated `syswrite`
//! (docs/internal/specs/behavior.md:81, "writer は 1 回の `syswrite` で
//! frame 全体を書き").

use std::time::Duration;

use crate::host::Host;

#[test]
fn overflow_payload_delegates_in_one_frame_and_renders() {
    let mut host = Host::boot_with_overflow();

    let queued_before = host.log_count("worker: queued request_id=");
    host.send_keys("ls fx/overflow/");
    assert!(
        host.expect("0000-marker.txt", Duration::from_secs(15)),
        "(fifo-1a) list not displayed for an over-capacity payload"
    );

    assert!(
        host.wait_log(
            "worker: queued request_id=",
            queued_before,
            Duration::from_secs(5)
        ),
        "(fifo-1b) no 'worker: queued request_id=' log line for the overflow request"
    );
    let line = host
        .last_log_line("worker: queued request_id=")
        .expect("(fifo-1b) queued-request log line vanished after wait_log succeeded");
    let bytes: usize = line
        .rsplit_once("bytes=")
        .and_then(|(_, rest)| rest.split_whitespace().next())
        .and_then(|token| token.parse().ok())
        .unwrap_or_else(|| panic!("(fifo-1b) no bytes= field in {line:?}"));
    assert!(
        bytes > 65536,
        "(fifo-1b) queued frame was not actually over-capacity (need > 65536): bytes={bytes} line={line:?}"
    );
}
