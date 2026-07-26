//! config.toml parsing and validation.
//!
//! Schema: docs/internal/contracts/config-schema.md (source of truth).
//! Rules: never fail startup; validate per key and fall back to the
//! default for invalid items, collecting one human-readable warning per
//! error. Only a TOML syntax error invalidates the whole file.

#![allow(dead_code)] // scaffold: wired up in M2

use crate::matching::Mode;

/// Parsed configuration with all defaults applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    // [display]
    pub max_lines: u32, // 1..=1000
    pub delay_ms: u32,  // 0..=10000
    pub min_input: u32, // 0..=100
    // [matching]
    pub mode: Mode,
    pub smart_case: bool,
    // [insert]
    pub tab: TabBehavior,
    pub trailing_space: bool,
    // [keybind] — raw notations; normalization lives in keybind.rs.
    pub select_next: String,
    pub select_prev: String,
    pub confirm: String,
    pub dismiss: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabBehavior {
    CommonPrefix,
    Menu,
    Insert,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            max_lines: 10,
            delay_ms: 50,
            min_input: 0,
            mode: Mode::Typo,
            smart_case: true,
            tab: TabBehavior::Menu,
            trailing_space: true,
            select_next: "down".into(),
            select_prev: "up".into(),
            confirm: "enter".into(),
            dismiss: "ctrl-g".into(),
        }
    }
}

/// Result of loading a config file: the effective config plus warnings
/// (destined for ZRUSH_CFG_WARNINGS).
#[derive(Debug, Default)]
pub struct LoadResult {
    pub config: Config,
    pub warnings: Vec<String>,
}

/// Parse a config.toml document.
///
/// TODO(M2): walk `toml::Table` manually (no derive) so each key can be
/// validated independently: type mismatch / out-of-range / unknown key or
/// table => default + warning; syntax error => all defaults + warning.
pub fn parse(_source: &str) -> LoadResult {
    LoadResult::default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_schema() {
        let c = Config::default();
        assert_eq!(c.max_lines, 10);
        assert_eq!(c.delay_ms, 50);
        assert_eq!(c.min_input, 0);
        assert_eq!(c.mode, Mode::Typo);
        assert!(c.smart_case);
        assert_eq!(c.tab, TabBehavior::Menu);
        assert!(c.trailing_space);
        assert_eq!(c.dismiss, "ctrl-g");
    }

    #[test]
    fn missing_file_is_all_defaults_no_warnings() {
        let r = LoadResult::default();
        assert_eq!(r.config, Config::default());
        assert!(r.warnings.is_empty());
    }
}
