//! Empty-word collection cache: a second command-position query hits the
//! cache and forks nothing (docs/internal/specs/behavior.md "空語収集キャッシュ").

use std::time::Duration;

use crate::host::{Host, PlanShape};

#[test]
fn second_command_position_query_hits_the_cache_without_forking() {
    let mut host = Host::boot();
    // Warm-up: a host's very first completion commonly lazy-loads at least one
    // compsys function, which changes the fingerprint (function count) the
    // empty-word cache checks and costs exactly one extra miss (behavior.md
    // "空語収集キャッシュ" 「既知の癖」). Absorb it here so the pair below
    // observes the steady-state fingerprint.
    host.send_keys_wait_plan(PlanShape::Nonempty, "whic");
    host.clear_line();
    host.drain(Duration::from_millis(500));

    host.send_keys_wait_plan(PlanShape::Nonempty, "whic");
    host.clear_line();
    host.drain(Duration::from_millis(500));

    let hit_baseline = host.log_count("cache: hit");
    let collecting_baseline = host.log_count("request: collecting");
    host.send_keys("whic");
    assert!(
        host.wait_log("cache: hit", hit_baseline, Duration::from_secs(5)),
        "(cc-1a) cache hit not logged"
    );

    host.drain(Duration::from_millis(500));
    let collecting_after = host.log_count("request: collecting");
    assert_eq!(
        collecting_after, collecting_baseline,
        "(cc-1b) a fork ran despite the expected cache hit ({collecting_baseline} -> {collecting_after})"
    );
}
