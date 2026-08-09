//! Per-test candidate trees, created under the host's isolated `$HOME`.

use std::fs;
use std::path::Path;

/// Width that forces the grid to a single column at 80 terminal columns, so
/// select-left/right land on the group's first/last position deterministically.
const LONGCOL_PAD: usize = 90;

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
