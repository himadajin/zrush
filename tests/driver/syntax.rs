//! Buffer syntax highlighting: the decoration group zrush keeps over BUFFER
//! itself (docs/internal/specs/behavior.md "Buffer Syntax Highlighting").
//!
//! What only a real host can show is the part the Rust unit tests cannot: that
//! a keystroke reaches `region_highlight` as the role's configured spec, that
//! the decoration and the listing groups are replaced independently of each
//! other, and that a finished line neither carries stale decoration into the
//! next one nor waits forever for a worker that stopped answering.

use std::time::Duration;

use crate::fake::Mode;
use crate::host::{Host, PlanShape, keys, state_has};

/// `[syntax.highlight]` defaults for the roles these scenarios type
/// (docs/internal/contracts/config-schema.md "[syntax.highlight]").
const COMMAND: &str = "fg=green";
const UNKNOWN: &str = "fg=red,bold";
const SINGLE_QUOTE: &str = "fg=yellow";
const PATH: &str = "underline";

/// The decoration a resolvable two-character command word at the start of the
/// buffer produces -- `ls` under the real worker, and the fixed entry the fake
/// worker is told to answer with.
fn command_word() -> String {
    format!("0 2 {COMMAND}")
}

/// The `region_highlight` entries of the buffer-decoration group, each as
/// `start end spec`.
///
/// From zsh 5.9 the `memo` names the group. Below that it is what the listing
/// ledger (`^Xh`) does not claim *and* lies inside BUFFER: with no memo, an
/// entry ZLE has shifted out from under a ledger's exact values can outlive its
/// group in the POSTDISPLAY region until the next render (behavior.md
/// "Display"), and that is the listing's leftover, not this group's.
fn decoration(host: &mut Host, label: &str) -> Vec<String> {
    if host.has_memo() {
        return host
            .all_highlights(label)
            .into_iter()
            .filter(|entry| entry.contains("memo=zrush-syn"))
            .map(|entry| entry.split(" memo=").next().unwrap_or(&entry).to_string())
            .collect();
    }
    let width = host.buffer(label).chars().count();
    let listing = host.zrush_highlights(label);
    host.all_highlights(label)
        .into_iter()
        .filter(|entry| !listing.contains(entry) && field(entry, 1, label) <= width)
        .collect()
}

/// Type `keys` and wait for the notification they owe to be made.
///
/// A dump key pressed while the typed burst is still queued is input pressure
/// of the harness's own making: the notification that pressure defers is made
/// by the *next* buffer change (behavior.md "Candidate Collection"), and a dump
/// widget is not one -- so without this barrier the scenario could wait for an
/// event nothing will ever ask for.
fn type_keys(host: &mut Host, keys: &str, label: &str) {
    let baseline = host.log_count("worker: queued input input_generation=");
    host.send_keys(keys);
    assert!(
        host.wait_log(
            "worker: queued input input_generation=",
            baseline,
            Duration::from_secs(10)
        ),
        "{label}: typing {keys:?} produced no input notification"
    );
}

/// Poll the decoration group until it is exactly `expected`. The worker answers
/// every accepted notification, so a burst of keystrokes produces a burst of
/// events and only the last one describes the buffer that is now there.
fn wait_decoration(host: &mut Host, expected: &[&str], label: &str) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut have = Vec::new();
    while std::time::Instant::now() < deadline {
        have = decoration(host, label);
        if have == expected {
            return;
        }
        host.drain(Duration::from_millis(200));
    }
    panic!("{label}: buffer decoration is {have:?}, expected {expected:?}");
}

/// The two groups address disjoint regions: decoration lies inside BUFFER, the
/// listing lies in POSTDISPLAY, which starts one character past its end
/// (cli-protocol.md "Buffer Highlight Application (zsh-Side Normative)").
fn assert_groups_are_disjoint(host: &mut Host, label: &str) {
    let width = host.buffer(label).chars().count();
    for entry in decoration(host, label) {
        let end: usize = field(&entry, 1, label);
        assert!(
            end <= width,
            "{label}: decoration entry {entry:?} reaches past a {width}-character buffer"
        );
    }
    for entry in host.zrush_highlights(label) {
        let start: usize = field(&entry, 0, label);
        assert!(
            start > width,
            "{label}: listing entry {entry:?} starts inside a {width}-character buffer"
        );
    }
}

/// One whitespace-separated offset of a `region_highlight` entry.
fn field(entry: &str, index: usize, label: &str) -> usize {
    entry
        .split_whitespace()
        .nth(index)
        .and_then(|value| value.parse().ok())
        .unwrap_or_else(|| panic!("{label}: no offset {index} in {entry:?}"))
}

/// Whether every entry zrush's listing ledger does not claim carries the
/// decoration group's own memo (zsh 5.9+).
fn decoration_is_memo_tagged(host: &mut Host, label: &str) -> bool {
    let listing = host.zrush_highlights(label);
    let all = host.all_highlights(label);
    all.iter()
        .filter(|entry| !listing.contains(entry))
        .all(|entry| entry.contains("memo=zrush-syn"))
}

#[test]
fn typing_decorates_the_buffer_with_each_role_spec() {
    let mut host = Host::boot();

    // `ls` resolves on $PATH and the argument exists relative to the host's
    // own home, so the buffer carries one semantic and one lexical role.
    type_keys(&mut host, "ls fx/basic/subdir", "(syn-1a)");
    wait_decoration(
        &mut host,
        &[&command_word(), &format!("3 18 {PATH}")],
        "(syn-1a)",
    );
    let memo = host.has_memo();
    assert!(
        !memo || decoration_is_memo_tagged(&mut host, "(syn-1b)"),
        "(syn-1b) buffer decoration is not memo-tagged on zsh >=5.9"
    );

    // Finish the line rather than killing it: a new ZLE session starts the
    // group empty on every supported zsh, while what a kill leaves behind on
    // 5.8 is the shifted-entry degradation the spec allows.
    host.press(keys::ENTER);
    assert!(
        host.sync_prompt(Duration::from_secs(10)),
        "(syn-1b) the host did not return to a prompt: {}",
        host.window_tail()
    );

    // An unresolvable command word, and a quoted path whose two entries share
    // one span: the lexical role comes second, and the later entry is the one
    // zsh's own resolution order lets win (cli-protocol.md "`syntax-highlight`
    // body (Buffer Highlight Stream)").
    type_keys(&mut host, "nosuchcmd-zz 'fx/basic'", "(syn-1c)");
    wait_decoration(
        &mut host,
        &[
            &format!("0 12 {UNKNOWN}"),
            &format!("13 23 {SINGLE_QUOTE}"),
            &format!("13 23 {PATH}"),
        ],
        "(syn-1c)",
    );
}

#[test]
fn decoration_and_the_selection_highlight_leave_each_other_alone() {
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al");
    wait_decoration(&mut host, &[&command_word()], "(syn-2a)");

    // Selecting rebuilds the listing groups from the plan without re-fetching
    // it; the decoration group is not part of that rebuild.
    host.assert_log_grows("select: start", &[keys::DOWN], "(syn-2b)");
    let selected = host.zrush_highlights("(syn-2b)");
    assert!(
        selected.iter().any(|entry| entry.contains("memo=zrush-sel")
            || (!host.has_memo() && entry.contains("standout"))),
        "(syn-2b) Down did not decorate the selected cell: {selected:?}"
    );
    let after_select = decoration(&mut host, "(syn-2b)");
    assert_eq!(
        after_select,
        vec![command_word()],
        "(syn-2b) selecting disturbed the buffer decoration"
    );

    // The other direction: a keystroke replaces the decoration group while the
    // listing it is displayed with stays where it is.
    type_keys(&mut host, "p", "(syn-2c)");
    wait_decoration(&mut host, &[&command_word()], "(syn-2c)");
    let listing = host.zrush_highlights("(syn-2c)");
    assert!(
        !listing.is_empty(),
        "(syn-2c) replacing the decoration took the listing entries with it"
    );
    assert_groups_are_disjoint(&mut host, "(syn-2c)");
}

#[test]
fn decoration_survives_a_terminal_resize() {
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/longcol/item");
    wait_decoration(&mut host, &[&command_word()], "(syn-3a)");

    // The decoration addresses BUFFER, so the SIGWINCH and the redraw it
    // provokes leave the group that is already applied exactly as it is --
    // asserted before any keystroke can rebuild it.
    host.resize(40, 24);
    host.drain(Duration::from_millis(500));
    assert_eq!(
        decoration(&mut host, "(syn-3b)"),
        vec![command_word()],
        "(syn-3b) the resize itself disturbed the decoration already applied"
    );

    // The narrower terminal re-lays out the listing on the next render
    // (session.rs covers the layout itself), and the rebuilt groups stay
    // separate.
    host.send_keys_wait_plan(PlanShape::Nonempty, "-");
    wait_decoration(&mut host, &[&command_word()], "(syn-3c)");
    assert_groups_are_disjoint(&mut host, "(syn-3c)");

    // A buffer wider than the terminal wraps onto a second physical line,
    // which changes where zle paints the entries but not what they cover.
    type_keys(&mut host, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "(syn-3d)");
    wait_decoration(&mut host, &[&command_word()], "(syn-3d)");
    assert_groups_are_disjoint(&mut host, "(syn-3d)");
}

#[test]
fn a_finished_line_carries_no_decoration_into_the_next_one() {
    let mut host = Host::boot();
    type_keys(&mut host, "ls fx/basic/subdir", "(syn-4a)");
    wait_decoration(
        &mut host,
        &[&command_word(), &format!("3 18 {PATH}")],
        "(syn-4a)",
    );

    // The finished line burns into scrollback as it stands; the new line
    // starts with the decoration group empty (behavior.md "Line-Finish
    // Settle").
    host.press(keys::ENTER);
    assert!(
        host.expect("inner.txt", Duration::from_secs(10)),
        "(syn-4b) the accepted line did not run: {}",
        host.window_tail()
    );
    host.sync_prompt(Duration::from_secs(10));
    wait_decoration(&mut host, &[], "(syn-4c)");

    // And the next line decorates on its own from the first keystroke, i.e.
    // the settle left nothing latched that would block the ordinary path.
    type_keys(&mut host, "ls fx/basic/subdir", "(syn-4d)");
    wait_decoration(
        &mut host,
        &[&command_word(), &format!("3 18 {PATH}")],
        "(syn-4d)",
    );
}

#[test]
fn a_settle_deadline_finishes_the_line_best_effort() {
    let mut host = Host::boot_fake();
    host.fake().set_highlight(&["command 0 2"]);
    // A serving session whose `plan` answers fail: what this scenario needs is
    // a worker that answers notifications until it is told to stop.
    host.fake().set_mode(Mode::Error);

    type_keys(&mut host, "ab", "(syn-5a)");
    wait_decoration(&mut host, &[&command_word()], "(syn-5a)");

    // Park the session mid-message: from here nothing the host sends is read,
    // so the generations that follow stay unanswered.
    let held = host.fake().count("hold ");
    host.fake().set_mode(Mode::Hold);
    host.send_keys("c");
    assert!(
        host.wait_fake("hold ", held, Duration::from_secs(10)),
        "(syn-5b) the fake worker never parked"
    );
    let queued = host.log_count("worker: queued input input_generation=");
    host.send_keys("d");
    assert!(
        host.wait_log(
            "worker: queued input input_generation=",
            queued,
            Duration::from_secs(10)
        ),
        "(syn-5b) no notification was made for the keystroke the parked worker must not answer"
    );

    // Enter waits out the fixed deadline once and then finishes the line
    // anyway, with the decoration it already had and without replaying the
    // notification it never got an answer to (behavior.md "Line-Finish
    // Settle").
    let exceeded = host.log_count("syntax: settle deadline exceeded");
    let notified = host.log_count("worker: queued input input_generation=");
    let failed = host.log_count("worker: session failure:");
    host.send_keys(keys::ENTER);
    assert!(
        host.wait_log(
            "syntax: settle deadline exceeded",
            exceeded,
            Duration::from_secs(10)
        ),
        "(syn-5c) the settle did not give up on the unanswered generation"
    );
    assert!(
        host.sync_prompt(Duration::from_secs(10)),
        "(syn-5c) the line was not finished after the settle gave up: {}",
        host.window_tail()
    );
    assert_eq!(
        host.log_count("worker: queued input input_generation="),
        notified,
        "(syn-5c) the settle replayed the notification it gave up on"
    );

    // Overrunning the deadline costs freshness, not the session: the line was
    // finished without an answer, and nothing about that is a worker failure.
    assert_eq!(
        host.log_count("worker: session failure:"),
        failed,
        "(syn-5d) the overrun was reported as a worker session failure"
    );
    let worker = host.worker_state();
    assert!(
        state_has(&worker, &["ready=1", "disabled=0", "stopping=0"]),
        "(syn-5d) the worker session did not survive the overrun: {worker}"
    );
    wait_decoration(&mut host, &[], "(syn-5e)");
}

#[test]
fn disabling_syntax_leaves_the_buffer_undecorated() {
    let mut host = Host::boot_with_config("[syntax]\nenabled = false\n");

    // The listing is unaffected: only the analysis is off, which zsh expresses
    // by sending an empty `buffer` field (config-schema.md "[syntax]"; the
    // wire form itself is pinned by tests/zsh/vectors.zsh).
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/subdir");
    let post = host.postdisplay("(syn-6a)");
    assert!(
        post.contains("subdir"),
        "(syn-6a) the listing did not reach POSTDISPLAY: {post:?}"
    );
    let decorated = decoration(&mut host, "(syn-6b)");
    assert!(
        decorated.is_empty(),
        "(syn-6b) a disabled buffer highlight still decorated: {decorated:?}"
    );
    // The worker does not know the setting: what it sees is a buffer with no
    // token in it, so every event that comes back is the zero-token one
    // (cli-protocol.md "`syntax-highlight` body (Buffer Highlight Stream)").
    let applied = host.log_count("worker: syntax-highlight applied");
    assert!(
        applied > 0,
        "(syn-6c) no decoration event arrived at all, so nothing about the empty buffer was shown"
    );
    assert_eq!(
        applied,
        host.log_count("entries=0"),
        "(syn-6c) an event carrying tokens arrived for a buffer that was sent empty"
    );

    // Finishing the line neither notifies nor waits, so the accepted line
    // reaches its own output with no settle in the way.
    host.press(keys::ENTER);
    assert!(
        host.expect("inner.txt", Duration::from_secs(10)),
        "(syn-6d) the accepted line did not run: {}",
        host.window_tail()
    );
    assert_eq!(
        host.log_count("syntax: settled input_generation=")
            + host.log_count("syntax: settle deadline exceeded"),
        0,
        "(syn-6d) a disabled buffer highlight still took the line-finish settle"
    );
}
