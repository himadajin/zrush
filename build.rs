use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock is before the Unix epoch")
        .as_nanos();
    let stamp = format!("{nanos:032x}{:08x}", std::process::id());
    println!("cargo::rustc-env=ZRUSH_BUILD_STAMP={stamp}");
}
