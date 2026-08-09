//! Per-test candidate trees, created under the host's isolated `$HOME`.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Width that forces the grid to a single column at 80 terminal columns, so
/// select-left/right land on the group's first/last position deterministically.
const LONGCOL_PAD: usize = 90;
/// Entries sized to overflow the request-FIFO buffer on either platform
/// (8192 bytes macOS / 65536 Linux) once collected into a candidate_payload.
const OVERFLOW_ITEMS: u32 = 7000;

pub fn build(home: &Path) {
    // fx/basic: two candidates sharing a prefix, plus a subdirectory for the
    // '/' synthesis on confirm.
    touch(&home.join("fx/basic/alpha.txt"));
    touch(&home.join("fx/basic/alsoalpha.txt"));
    touch(&home.join("fx/basic/subdir/inner.txt"));

    // fx/spacey: a filename whose quoted and raw forms differ.
    touch(&home.join("fx/spacey/has space.txt"));

    // fx/hidden: dot-prefixed entries sharing a stem with nothing visible.
    touch(&home.join("fx/hidden/.dotted-alpha.txt"));
    touch(&home.join("fx/hidden/.dotted-beta.txt"));
    touch(&home.join("fx/hidden/visible.txt"));

    // fx/headed: a plain file so _files' "file" tag heading reaches the plan.
    touch(&home.join("fx/headed/plainfile.txt"));

    // fx/longcol: names wide enough to clamp the grid to one column.
    let pad = "x".repeat(LONGCOL_PAD);
    for n in 1..=3 {
        touch(&home.join(format!("fx/longcol/item-{pad}-{n}.txt")));
    }
}

fn touch(path: &Path) {
    let parent = path.parent().expect("fixture path has a parent");
    fs::create_dir_all(parent).unwrap_or_else(|e| panic!("create {}: {e}", parent.display()));
    fs::File::create(path).unwrap_or_else(|e| panic!("create {}: {e}", path.display()));
}

/// `0000-marker.txt` sorts first, so it always lands in the rendered listing
/// no matter how the grid clips.
/// Built at a deterministic path under `target/` so the tree survives across
/// runs instead of being rebuilt every time; `OnceLock` gives one build check
/// per process.
fn overflow_tree() -> &'static Path {
    static OVERFLOW: OnceLock<PathBuf> = OnceLock::new();
    OVERFLOW.get_or_init(|| {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/tmp/zrush-overflow-fixture");
        ensure_overflow_tree(&dir);
        dir
    })
}

/// Rebuild only when the entry count doesn't already match (same caching idea
/// as `ensure_many_dir` in tests/zsh/driver-coexist.zsh), so a repeated test
/// run reuses the tree instead of recreating 7001 files every time.
fn ensure_overflow_tree(dir: &Path) {
    let want = OVERFLOW_ITEMS as usize + 1; // + 0000-marker.txt
    let have = fs::read_dir(dir)
        .map(|entries| entries.count())
        .unwrap_or(0);
    if have == want {
        return;
    }
    let _ = fs::remove_dir_all(dir);
    fs::create_dir_all(dir).unwrap_or_else(|e| panic!("create {}: {e}", dir.display()));
    touch(&dir.join("0000-marker.txt"));
    for n in 1..=OVERFLOW_ITEMS {
        touch(&dir.join(format!("item-{n:04}.txt")));
    }
}

/// Symlink the shared overflow tree into `home`'s `fx/overflow`.
pub fn link_overflow(home: &Path) {
    let fx = home.join("fx");
    fs::create_dir_all(&fx).unwrap_or_else(|e| panic!("create {}: {e}", fx.display()));
    let link = fx.join("overflow");
    std::os::unix::fs::symlink(overflow_tree(), &link)
        .unwrap_or_else(|e| panic!("symlink overflow tree at {}: {e}", link.display()));
}
