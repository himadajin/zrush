//! Empty-word collection cache: what a hit skips, what forces a miss, and how
//! the candidate store latch dies with the worker session it belongs to
//! (docs/internal/specs/behavior.md 「空語収集キャッシュ」「worker ライフ
//! サイクル」, docs/internal/contracts/cli-protocol.md 「要求と応答」
//! 「応答の検証と zsh 側の適用」).

use std::time::{Duration, Instant};

use crate::fake::Mode;
use crate::host::{Host, PlanShape, SHUTDOWN_SEAM, dump_field, keys, state_has};

/// A command-position word: the widening rule empties it, so the collection it
/// provokes is the cache's subject (behavior.md 「候補収集」「空語収集キャッシュ」).
const QUERY: &str = "whic";

/// The frame that carries a candidate record stream; a hit sends none.
const STORE: &str = "worker: queued store request_id=";
/// The frame a hit does send.
const PLAN: &str = "worker: queued request_id=";
const COLLECTING: &str = "request: collecting";
const HIT: &str = "cache: hit (generation=";
const LATCHED: &str = "cache: latched";

/// Type [`QUERY`] and wait until the cache has decided that request: either it
/// answered from the latch, or it collected and the worker's `ok` turned the
/// staged entry into the new latch. Returns whether it was a hit. The line is
/// left as typed -- clearing it would make the input no longer current, which
/// is itself one of the conditions under test.
fn query(host: &mut Host, label: &str) -> bool {
    let hits = host.log_count(HIT);
    let latched = host.log_count(LATCHED);
    host.send_keys(QUERY);
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        host.drain(Duration::from_millis(150));
        if host.log_count(HIT) > hits {
            return true;
        }
        if host.log_count(LATCHED) > latched {
            return false;
        }
        assert!(
            Instant::now() < deadline,
            "{label}: the command-position query was neither served from nor written to the cache"
        );
    }
}

/// Repeat the query until one of them is answered from the latch. A host's
/// first completions lazy-load compsys functions, and every load changes the
/// function count the fingerprint covers, so the steady state is reached by
/// repeating rather than by a fixed number of rounds
/// (behavior.md 「空語収集キャッシュ」 「既知の癖」).
fn warm_to_a_hit(host: &mut Host, label: &str) {
    for _ in 0..5 {
        let hit = query(host, label);
        host.clear_line();
        host.drain(Duration::from_millis(300));
        if hit {
            return;
        }
    }
    panic!("{label}: the empty-word cache never reached a steady-state hit");
}

/// The generation of the freshest logged hit -- the one the latch pointed at.
fn hit_generation(host: &Host, label: &str) -> i64 {
    let line = host
        .last_log_line(HIT)
        .unwrap_or_else(|| panic!("{label}: no cache hit has been logged"));
    line.rsplit_once("generation=")
        .and_then(|(_, rest)| rest.trim_end_matches(')').parse().ok())
        .unwrap_or_else(|| panic!("{label}: no generation in {line:?}"))
}

/// Slot and generation of the freshest queued `store`.
fn last_store(host: &Host, label: &str) -> (String, i64) {
    let line = host
        .last_log_line(STORE)
        .unwrap_or_else(|| panic!("{label}: no store has been queued"));
    let generation = dump_field(&line, "generation")
        .parse()
        .unwrap_or_else(|e| panic!("{label}: non-numeric generation in {line:?} ({e})"));
    (dump_field(&line, "slot").to_string(), generation)
}

/// An argument-position completion: widening leaves a non-empty word, so this
/// collection is not the cache's subject and stores into `live`.
fn argument_completion(host: &mut Host) {
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al");
    host.clear_line();
    host.drain(Duration::from_millis(300));
}

/// Open the history menu on an empty buffer and dismiss it again. An empty
/// buffer collects nothing (behavior.md 「候補収集」), and the menu writes the
/// worker's history index rather than any candidate slot, so the only thing
/// this adds is a `history-snapshot` (cold) or nothing at all (warm) plus the
/// `history` plan.
fn history_menu(host: &mut Host, label: &str) {
    let opened = host.log_count("producer=history");
    host.press(keys::UP);
    assert!(
        host.wait_log("producer=history", opened, Duration::from_secs(10)),
        "{label}: the history menu never reached the worker"
    );
    host.press(keys::DISMISS);
    host.drain(Duration::from_millis(300));
}

/// The first command-position query has nothing to reuse: it collects, hands
/// the records to the `cache` slot and latches the generation the worker took.
/// A later one plans straight from that latch -- no fork, and no second store.
#[test]
fn a_command_position_query_latches_and_the_next_one_plans_from_the_latch() {
    let mut host = Host::boot();

    let empty0 = host.log_count("cache: miss (empty)");
    let hit = query(&mut host, "(cc-1a)");
    let (slot, _) = last_store(&host, "(cc-1a)");
    assert!(
        !hit && host.log_count("cache: miss (empty)") > empty0 && slot == "cache",
        "(cc-1a) the first command-position query did not miss into the cache slot: slot={slot}"
    );
    host.clear_line();
    host.drain(Duration::from_millis(300));

    warm_to_a_hit(&mut host, "(cc-1b)");

    let collecting = host.log_count(COLLECTING);
    let stores = host.log_count(STORE);
    let plans = host.log_count(PLAN);
    assert!(
        query(&mut host, "(cc-1c)"),
        "(cc-1c) the steady-state query was not served from the latch"
    );
    host.drain(Duration::from_millis(500));
    assert_eq!(
        host.log_count(COLLECTING),
        collecting,
        "(cc-1d) a fork ran despite the cache hit"
    );
    assert_eq!(
        host.log_count(STORE),
        stores,
        "(cc-1e) a store went out despite the cache hit"
    );
    assert_eq!(
        host.log_count(PLAN),
        plans + 1,
        "(cc-1f) the hit did not send exactly one plan"
    );
}

/// The 300 s TTL is a fixed constant, so the saved timestamp is aged rather
/// than waited out. The fingerprint still matches and the latch is still
/// valid: the TTL alone is what forces the recollection.
#[test]
fn an_expired_ttl_recollects_although_the_fingerprint_still_matches() {
    let mut host = Host::boot();
    warm_to_a_hit(&mut host, "(cc-2 setup)");

    host.press(keys::AGE_CACHE);
    let aged = host.cache_state();
    let age: i64 = dump_field(&aged, "age")
        .parse()
        .unwrap_or_else(|e| panic!("(cc-2a) non-numeric age in {aged:?} ({e})"));
    assert!(
        state_has(&aged, &["fpmatch=1"]) && age > 300,
        "(cc-2a) the aged entry is not a TTL-only miss: {aged}"
    );

    let expired = host.log_count("cache: miss (ttl)");
    let collecting = host.log_count(COLLECTING);
    assert!(
        !query(&mut host, "(cc-2b)"),
        "(cc-2b) an entry past its TTL was still served from the latch"
    );
    assert!(
        host.log_count("cache: miss (ttl)") == expired + 1
            && host.log_count(COLLECTING) > collecting,
        "(cc-2c) the expired entry did not recollect"
    );
}

/// A new alias is a new command-position candidate, and the alias count the
/// fingerprint covers is what notices it. TTL and latch stay valid, so the
/// fingerprint alone forces the recollection -- and the recollection is what
/// puts the new command in the listing.
#[test]
fn a_changed_environment_expires_the_fingerprint() {
    let mut host = Host::boot();
    warm_to_a_hit(&mut host, "(cc-3 setup)");

    host.send_line("alias whic-zrt-fresh=:");
    host.sync_prompt(Duration::from_secs(5));
    host.drain(Duration::from_millis(500));
    let changed = host.cache_state();
    assert!(
        state_has(&changed, &["fpmatch=0"]),
        "(cc-3a) a new alias did not change the fingerprint: {changed}"
    );

    let stale = host.log_count("cache: miss (fingerprint)");
    let collecting = host.log_count(COLLECTING);
    let applied = host.log_count("plan: applied");
    assert!(
        !query(&mut host, "(cc-3b)"),
        "(cc-3b) a stale fingerprint was still served from the latch"
    );
    assert!(
        host.log_count("cache: miss (fingerprint)") == stale + 1
            && host.log_count(COLLECTING) > collecting,
        "(cc-3c) the stale entry did not recollect"
    );
    assert!(
        host.wait_log("plan: applied", applied, Duration::from_secs(10)),
        "(cc-3d) the recollection never rendered"
    );
    let post = host.postdisplay("(cc-3d)");
    assert!(
        post.contains("whic-zrt-fresh"),
        "(cc-3d) the recollected listing is missing the new command: {post:?}"
    );
}

/// The latch belongs to the worker session. A session failure drops it and so
/// does a re-source, both while the fingerprint matches and the entry is well
/// inside its TTL, and recollection is the only way back. The candidate
/// generation counter is what neither of them may rewind
/// (cli-protocol.md 「要求と応答」 candidate_generation).
#[test]
fn the_latch_dies_with_the_worker_session_and_with_a_re_source() {
    let mut host = Host::boot_fake();
    // The fake has to be the worker before the latch is taken, or the death
    // below would kill a session the latch never came from. Its `store` always
    // succeeds, so the latch is taken exactly as under the real binary; only
    // the `plan` comes back as an in-band error, which is not a session failure
    // and leaves the latch alone.
    host.fake().set_mode(Mode::Error);
    host.send_line(SHUTDOWN_SEAM);
    host.sync_prompt(Duration::from_secs(5));
    warm_to_a_hit(&mut host, "(cc-4 setup)");

    let live = host.worker_state();
    let candgen = dump_field(&live, "candgen").to_string();
    let entry = host.cache_state();
    let age: i64 = dump_field(&entry, "age")
        .parse()
        .unwrap_or_else(|e| panic!("(cc-4a) non-numeric age in {entry:?} ({e})"));
    // Established here, while the session is still alive: from now on the only
    // hit condition that changes is the latch. (The fingerprint counts every
    // function, zrush's own generated `zle -F` handlers included, so it stops
    // being a fixed quantity once a session tears down.)
    assert!(
        candgen != "0" && dump_field(&live, "latch") == candgen,
        "(cc-4a) the cache store did not latch its own generation: {live}"
    );
    assert!(
        state_has(&entry, &["fpmatch=1"]) && (0..=300).contains(&age),
        "(cc-4a) the entry is not fingerprint- and TTL-valid before the death: {entry}"
    );

    // A hit sends nothing but a plan, so this death costs no generation.
    host.fake().set_mode(Mode::Die);
    let failures = host.log_count("worker: session failure:");
    assert!(
        query(&mut host, "(cc-4b)"),
        "(cc-4b) the query that was meant to die on a plan-only hit collected instead"
    );
    assert!(
        host.wait_log(
            "worker: session failure:",
            failures,
            Duration::from_secs(15)
        ),
        "(cc-4b) the worker did not die on the hit's plan"
    );
    host.clear_line();
    host.drain(Duration::from_millis(300));
    host.fake().set_mode(Mode::Proxy);

    let dropped = host
        .wait_worker_state(
            Duration::from_secs(15),
            &["latch=0", "stopping=0", "pending=0"],
        )
        .unwrap_or_else(|last| panic!("(cc-4c) the dead session kept its latch: {last}"));
    assert!(
        state_has(&dropped, &[&format!("candgen={candgen}")]),
        "(cc-4c) the dead session spent a candidate generation: {dropped}"
    );
    let usable = host.cache_state();
    let age: i64 = dump_field(&usable, "age")
        .parse()
        .unwrap_or_else(|e| panic!("(cc-4d) non-numeric age in {usable:?} ({e})"));
    assert!(
        (0..=300).contains(&age),
        "(cc-4d) the entry aged out of its TTL on its own: {usable}"
    );

    // The reason matters: the check tests the latch before the fingerprint, so
    // a `(latch)` miss is the entry being valid up to the lost session.
    let latchless = host.log_count("cache: miss (latch)");
    let collecting = host.log_count(COLLECTING);
    assert!(
        !query(&mut host, "(cc-4e)"),
        "(cc-4e) a latch that died with its worker still served a hit"
    );
    assert!(
        host.log_count("cache: miss (latch)") == latchless + 1
            && host.log_count(COLLECTING) > collecting,
        "(cc-4f) the lost latch did not recollect"
    );
    host.clear_line();
    host.drain(Duration::from_millis(300));

    // ---- and again across an explicit re-source ----
    let before = host.worker_state();
    let candgen: i64 = dump_field(&before, "candgen")
        .parse()
        .unwrap_or_else(|e| panic!("(cc-4g) non-numeric candgen in {before:?} ({e})"));
    host.send_line("source <($ZRUSH_REAL_BIN init zsh)");
    assert!(
        host.sync_prompt(Duration::from_secs(10)),
        "(cc-4g) the re-source did not return to a prompt"
    );
    let resourced = host.worker_state();
    let after: i64 = dump_field(&resourced, "candgen")
        .parse()
        .unwrap_or_else(|e| panic!("(cc-4g) non-numeric candgen in {resourced:?} ({e})"));
    assert!(
        state_has(&resourced, &["latch=0"]) && after >= candgen,
        "(cc-4g) the re-source kept a latch or rewound the generation counter \
         (was {candgen}): {resourced}"
    );

    let hits = host.log_count(HIT);
    let collecting = host.log_count(COLLECTING);
    assert!(
        !query(&mut host, "(cc-4h)"),
        "(cc-4h) a re-sourced shell served the query from a stale latch"
    );
    assert!(
        host.log_count(HIT) == hits && host.log_count(COLLECTING) > collecting,
        "(cc-4i) the re-sourced shell did not recollect"
    );
}

/// The cached generation lives in its own slot: argument completions keep
/// storing into `live` and the worker drops only the previous generation *of
/// the same slot*, so the cached one survives them. The history menu is the
/// other traffic that used to share the `live` slot and now writes the history
/// index instead -- a third generation-addressable place that is not a slot at
/// all -- so it must not touch the cached generation either
/// (cli-protocol.md 「要求と応答」 slot and index semantics).
#[test]
fn live_slot_stores_leave_the_cached_generation_intact() {
    let mut host = Host::boot_history();
    // Both live-slot producers run once up front: their compsys lazy-loading
    // is a fingerprint change, and it must not land between latch and hit.
    argument_completion(&mut host);
    history_menu(&mut host, "(cc-5 setup)");
    warm_to_a_hit(&mut host, "(cc-5 setup)");
    let cached = hit_generation(&host, "(cc-5 setup)");

    argument_completion(&mut host);
    let (slot, argument) = last_store(&host, "(cc-5a)");
    assert!(
        slot == "live" && argument > cached,
        "(cc-5a) the argument completion did not store a newer generation into live: \
         slot={slot} generation={argument} cached={cached}"
    );
    let stores = host.log_count(STORE);
    history_menu(&mut host, "(cc-5b)");
    let (slot, stored) = last_store(&host, "(cc-5b)");
    assert!(
        host.log_count(STORE) == stores && slot == "live" && stored == argument,
        "(cc-5b) the history menu stored into a candidate slot instead of the index: \
         slot={slot} generation={stored} previous={argument}"
    );

    let collecting = host.log_count(COLLECTING);
    assert!(
        query(&mut host, "(cc-5c)"),
        "(cc-5c) the cached generation did not survive the live-slot stores"
    );
    assert!(
        hit_generation(&host, "(cc-5c)") == cached && host.log_count(COLLECTING) == collecting,
        "(cc-5d) the hit did not come from the generation latched before the live stores \
         (cached={cached})"
    );
}

/// `unknown-generation` is an ordinary terminal error: it costs no session
/// failure and replays nothing. Only the `plan` that read the latch drops it
/// and recollects; the one that merely followed its own `store` is dropped and
/// waits for the next real input
/// (cli-protocol.md 「応答の検証と zsh 側の適用」).
#[test]
fn unknown_generation_recollects_only_for_the_plan_that_read_the_latch() {
    let mut host = Host::boot_fake();
    // A worker whose candidate store never holds the referenced generation,
    // while its `store` keeps answering `ok` -- so the latch is taken normally
    // and every plan, latched or not, comes back with `unknown-generation`.
    host.fake().set_mode(Mode::UnknownGeneration);

    // A miss: this collection's own store succeeds and latches, and the plan
    // pipelined behind it never read the latch.
    let unknown = host.log_count("code=unknown-generation");
    assert!(
        !query(&mut host, "(cc-6a)"),
        "(cc-6a) the first query of a fresh host was served from a latch"
    );
    let collecting = host.log_count(COLLECTING);
    assert!(
        host.wait_log("code=unknown-generation", unknown, Duration::from_secs(10)),
        "(cc-6b) the plan was not answered with unknown-generation"
    );
    // The recollection, when there is one, is decided before the error is
    // logged, so the counts either side of that line settle the question.
    let kept = host.worker_state();
    assert!(
        host.log_count(COLLECTING) == collecting
            && dump_field(&kept, "latch") != "0"
            && state_has(
                &kept,
                &["failures=0", "disabled=0", "pending=0", "staged=0"]
            ),
        "(cc-6c) a plan that never read the latch recollected or dropped the latch: {kept}"
    );
    host.clear_line();
    host.drain(Duration::from_millis(300));

    // A hit: that plan does read the latch, so its error drops the latch and
    // starts a fresh collection for the still-current input.
    let mut read_the_latch = false;
    for _ in 0..5 {
        let collecting = host.log_count(COLLECTING);
        let latchless = host.log_count("cache: miss (latch)");
        if query(&mut host, "(cc-6d)") {
            assert!(
                host.wait_log("cache: miss (latch)", latchless, Duration::from_secs(10)),
                "(cc-6e) the latched plan's unknown-generation did not drop the latch"
            );
            assert!(
                host.log_count(COLLECTING) > collecting,
                "(cc-6f) the latched plan's unknown-generation did not recollect"
            );
            read_the_latch = true;
            break;
        }
        host.clear_line();
        host.drain(Duration::from_millis(300));
    }
    assert!(
        read_the_latch,
        "(cc-6d) the cache never hit, so no plan ever read the latch"
    );

    let after = host.worker_state();
    assert!(
        state_has(&after, &["failures=0", "disabled=0"]),
        "(cc-6g) unknown-generation was counted against the worker session: {after}"
    );
}
