//! Plan application: POSTDISPLAY assembly and region_highlight
//! (docs/internal/contracts/cli-protocol.md "Plan Application (zsh-Side Normative)").

use crate::host::{Host, PlanShape, keys};

#[test]
fn postdisplay_and_region_highlight_after_a_listing_plan() {
    let mut host = Host::boot();
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al");

    let post = host.postdisplay("(apl-1a)");
    assert!(
        post.starts_with('\n') && post.contains("alpha.txt") && post.contains("alsoalpha.txt"),
        "(apl-1a) POSTDISPLAY malformed: {post:?}"
    );

    let rh = host
        .dump_get(keys::DUMP_RH, "TESTRH")
        .unwrap_or_else(|| panic!("(apl-1b/c) region_highlight dump did not run"));
    assert!(
        rh.contains("underline"),
        "(apl-1b) no match-role highlight found: {rh}"
    );
    assert!(
        !host.has_memo() || rh.contains("memo=zrush"),
        "(apl-1c) memo=zrush missing on zsh >=5.9: {rh}"
    );
}
