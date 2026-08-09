//! Async plumbing: a slow compsys fork must not block input
//! (docs/internal/specs/behavior.md:27 「入力は決してブロックしない」),
//! and its result still renders once it completes.

use std::time::Duration;

use crate::host::Host;

#[test]
fn slow_fork_does_not_block_input_and_still_completes() {
    let mut host = Host::boot();
    host.send_line(
        "_zrushtestslow() { local -a m=(slowcandA slowcandB slowcandC); sleep 0.5; compadd -a m }",
    );
    host.sync_prompt(Duration::from_secs(5));
    host.send_line("compdef _zrushtestslow zrushtestslow");
    host.sync_prompt(Duration::from_secs(5));

    host.send_keys("zrushtestslow ");
    host.drain(Duration::from_millis(400)); // let debounce elapse and the fork start (still sleeping)
    host.send_keys("zzz"); // typed while the fork is asleep
    assert!(
        host.expect_in_order(&["z", "z", "z"], Duration::from_secs(2)),
        "(async-1a) input blocked during slow collection"
    );

    host.clear_line();
    host.drain(Duration::from_millis(800)); // let the stale in-flight collection settle (cancelled)
    host.send_keys("zrushtestslow ");
    assert!(
        host.expect("slowcandA", Duration::from_secs(5)),
        "(async-1b) slow-completion candidates never rendered"
    );
}
