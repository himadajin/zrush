//! Helpers shared by the history-menu modules (`hist_lifecycle`, `hist_compsys`).

use std::time::Duration;

use crate::host::{Host, keys};

/// A same-buffer recollection provoked by the step under test can legitimately
/// have settled by the time the dump runs, so the assertion these cases can
/// make is "no residual history menu", not "kind=none".
pub fn assert_no_history_kind(kind: &str, label: &str) {
    assert!(!kind.starts_with("kind=history"), "{label} {kind}");
}

/// Type a query, let its own recollection settle, then open the history menu.
pub fn open_menu(host: &mut Host, query: &str) {
    host.send_keys(query);
    host.drain(Duration::from_millis(500));
    host.press(keys::UP);
}
