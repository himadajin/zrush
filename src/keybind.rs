//! Keybind notation normalization.
//!
//! Notation and normalization table: config-schema.md「キー記法」.
//! Output forms (cli-protocol.md):
//! - `seq:<bindkey sequence>` — fully normalized here (e.g. ctrl-g -> seq:^G).
//! - `key:<symbolic name>`    — terminal-dependent keys (up, shift-tab, ...);
//!   zsh resolves them via $terminfo.

#![allow(dead_code)] // scaffold: wired up in M2

/// A normalized key specification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeySpec {
    /// Literal bindkey sequence (`seq:` form).
    Seq(String),
    /// Terminal-dependent symbolic key (`key:` form), resolved by zsh.
    Symbolic(&'static str),
}

/// Normalize a config keybind notation (e.g. "ctrl-g", "enter", "up").
///
/// Returns None for unknown notation (validation error: the action falls
/// back to its default key, per config-schema.md).
///
/// TODO(M2): implement the full table — single chars, ctrl-a..z,
/// ctrl-space, alt-<char>, enter/tab/escape/space, arrow and other
/// terminfo keys. Also the duplicate-key check across actions (both
/// actions revert to defaults + warning).
pub fn normalize(_notation: &str) -> Option<KeySpec> {
    None
}
