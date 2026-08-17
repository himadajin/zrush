//! config.toml parsing, validation, and zsh-sourceable output.
//!
//! Schema: docs/internal/contracts/config-schema.md (source of truth).
//! Validation and error handling: config-schema.md "Validation and Error Handling".
//! Output format: cli-protocol.md "`zrush config`" — typeset assignments
//! only, every value single-quoted with `'` escaped as `'\''`.

use std::path::PathBuf;

use crate::keybind;
use crate::matching::Mode;
use crate::wire::BUILD_STAMP;

/// Upper bound of `[history].limit` (config-schema.md). history.rs reuses it
/// as the index's retention cap, and the worker clamps a request's
/// `history_limit` to it (cli-protocol.md 「history profile」).
pub(crate) const HISTORY_LIMIT_MAX: u32 = 20000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabBehavior {
    CommonPrefix,
    Menu,
    Insert,
}

impl TabBehavior {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "common-prefix" => Some(TabBehavior::CommonPrefix),
            "menu" => Some(TabBehavior::Menu),
            "insert" => Some(TabBehavior::Insert),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            TabBehavior::CommonPrefix => "common-prefix",
            TabBehavior::Menu => "menu",
            TabBehavior::Insert => "insert",
        }
    }
}

/// Effective configuration with all defaults applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    // [display]
    pub max_lines: u32,
    pub delay_ms: u32,
    pub min_input: u32,
    // [display.highlight] — zsh region_highlight specs, passed through
    // verbatim; empty string = no decoration (config-schema.md).
    pub hl_selected: String,
    pub hl_match: String,
    pub hl_heading: String,
    pub hl_history_number: String,
    // [matching]
    pub mode: Mode,
    pub smart_case: bool,
    // [insert]
    pub tab: TabBehavior,
    pub trailing_space: bool,
    // [history]
    pub history_limit: u32,
    // [keybind] — normalized seq:/key: spec lists (one action may bind
    // several keys), index-aligned with keybind::ACTIONS.
    pub keybinds: [Vec<String>; keybind::N],
}

impl Default for Config {
    fn default() -> Self {
        Config {
            max_lines: 10,
            delay_ms: 30,
            min_input: 0,
            hl_selected: "standout".into(),
            hl_match: "underline".into(),
            hl_heading: "bold".into(),
            hl_history_number: "faint".into(),
            mode: Mode::Typo,
            smart_case: true,
            tab: TabBehavior::Menu,
            trailing_space: true,
            history_limit: 5000,
            keybinds: keybind::default_specs(),
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

/// Load per config-schema.md "Validation and Error Handling".
/// File absence is normal and uses defaults without a warning.
pub fn load() -> LoadResult {
    let Some(path) = config_path() else {
        return LoadResult::default();
    };
    match std::fs::read_to_string(&path) {
        Ok(source) => parse(&source),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => LoadResult::default(),
        Err(e) => LoadResult {
            config: Config::default(),
            warnings: vec![format!(
                "config: cannot read {}: {e}; using all defaults",
                path.display()
            )],
        },
    }
}

/// Config path resolution per cli-protocol.md "`zrush config` Startup".
fn config_path() -> Option<PathBuf> {
    let base = match std::env::var_os("XDG_CONFIG_HOME") {
        Some(x) if !x.is_empty() => PathBuf::from(x),
        _ => PathBuf::from(std::env::var_os("HOME")?).join(".config"),
    };
    Some(base.join("zrush").join("config.toml"))
}

/// Parse a config.toml document, validating item by item.
pub fn parse(source: &str) -> LoadResult {
    let mut warnings = Vec::new();
    let table: toml::Table = match source.parse() {
        Ok(t) => t,
        Err(e) => {
            let msg = e.message().replace('\n', " ");
            warnings.push(format!(
                "config: TOML syntax error: {msg}; using all defaults"
            ));
            return LoadResult {
                config: Config::default(),
                warnings,
            };
        }
    };

    let mut cfg = Config::default();
    let mut kb_user: [Option<Vec<String>>; keybind::N] = Default::default();

    for (tname, tval) in &table {
        match tname.as_str() {
            "display" | "matching" | "insert" | "history" | "keybind" => {
                let Some(sub) = tval.as_table() else {
                    warnings.push(format!(
                        "config: {tname}: expected a table, got {}; using defaults",
                        fmt_got(tval)
                    ));
                    continue;
                };
                for (key, val) in sub {
                    apply_key(&mut cfg, &mut kb_user, tname, key, val, &mut warnings);
                }
            }
            _ if tval.is_table() => {
                warnings.push(format!("config: unknown table [{tname}]; ignoring"));
            }
            _ => {
                warnings.push(format!(
                    "config: unknown key \"{tname}\" (top level); ignoring"
                ));
            }
        }
    }

    cfg.keybinds = keybind::resolve(&kb_user, &mut warnings);
    LoadResult {
        config: cfg,
        warnings,
    }
}

fn apply_key(
    cfg: &mut Config,
    kb_user: &mut [Option<Vec<String>>; keybind::N],
    table: &str,
    key: &str,
    val: &toml::Value,
    warnings: &mut Vec<String>,
) {
    match (table, key) {
        ("display", "highlight") => {
            let Some(sub) = val.as_table() else {
                warnings.push(format!(
                    "config: [display.highlight]: expected a table, got {}; using defaults",
                    fmt_got(val)
                ));
                return;
            };
            for (k, v) in sub {
                let target = match k.as_str() {
                    "selected" => &mut cfg.hl_selected,
                    "match" => &mut cfg.hl_match,
                    "heading" => &mut cfg.hl_heading,
                    "history-number" => &mut cfg.hl_history_number,
                    _ => {
                        warnings.push(format!(
                            "config: [display.highlight] unknown key \"{k}\"; ignoring"
                        ));
                        continue;
                    }
                };
                if let Some(s) = v.as_str() {
                    *target = s.to_string();
                } else {
                    warnings.push(format!(
                        "config: [display.highlight] {k}: expected string, got {}; using default \"{target}\"",
                        fmt_got(v)
                    ));
                }
            }
        }
        ("display", "max-lines") => cfg.max_lines = int_val(val, table, key, 1, 1000, 10, warnings),
        ("display", "delay-ms") => cfg.delay_ms = int_val(val, table, key, 0, 10000, 30, warnings),
        ("display", "min-input") => cfg.min_input = int_val(val, table, key, 0, 100, 0, warnings),
        ("matching", "mode") => {
            if let Some(m) = val.as_str().and_then(Mode::parse) {
                cfg.mode = m;
            } else {
                warnings.push(format!(
                    "config: [matching] mode: expected one of \"prefix\", \"substring\", \"typo\", got {}; using default \"typo\"",
                    fmt_got(val)
                ));
            }
        }
        ("matching", "smart-case") => {
            cfg.smart_case = bool_val(val, table, key, true, warnings);
        }
        ("insert", "tab") => {
            if let Some(t) = val.as_str().and_then(TabBehavior::parse) {
                cfg.tab = t;
            } else {
                warnings.push(format!(
                    "config: [insert] tab: expected one of \"common-prefix\", \"menu\", \"insert\", got {}; using default \"menu\"",
                    fmt_got(val)
                ));
            }
        }
        ("insert", "trailing-space") => {
            cfg.trailing_space = bool_val(val, table, key, true, warnings);
        }
        ("history", "limit") => {
            cfg.history_limit =
                int_val(val, table, key, 1, HISTORY_LIMIT_MAX.into(), 5000, warnings);
        }
        ("keybind", _) => {
            if let Some(i) = keybind::ACTIONS.iter().position(|a| *a == key) {
                match val {
                    toml::Value::String(s) => kb_user[i] = Some(vec![s.clone()]),
                    toml::Value::Array(items) => {
                        let mut list = Vec::with_capacity(items.len());
                        for item in items {
                            if let Some(s) = item.as_str() {
                                list.push(s.to_string());
                            } else {
                                warnings.push(format!(
                                    "config: [keybind] {key}: expected string element, got {}; ignoring this element",
                                    fmt_got(item)
                                ));
                            }
                        }
                        // A non-empty spec whose every element was dropped falls
                        // back to the default list, like invalid notations do;
                        // only an explicit [] disables the action.
                        if list.is_empty() && !items.is_empty() {
                            warnings.push(format!(
                                "config: [keybind] {key}: no valid element remains; using default {}",
                                keybind::default_desc(i)
                            ));
                        } else {
                            kb_user[i] = Some(list);
                        }
                    }
                    _ => {
                        warnings.push(format!(
                            "config: [keybind] {key}: expected string or array of strings, got {}; using default",
                            fmt_got(val)
                        ));
                    }
                }
            } else {
                warnings.push(format!("config: [{table}] unknown key \"{key}\"; ignoring"));
            }
        }
        _ => {
            warnings.push(format!("config: [{table}] unknown key \"{key}\"; ignoring"));
        }
    }
}

fn int_val(
    val: &toml::Value,
    table: &str,
    key: &str,
    lo: i64,
    hi: i64,
    default: u32,
    warnings: &mut Vec<String>,
) -> u32 {
    if let Some(i) = val.as_integer()
        && (lo..=hi).contains(&i)
    {
        return i as u32;
    }
    warnings.push(format!(
        "config: [{table}] {key}: expected integer {lo}..{hi}, got {}; using default {default}",
        fmt_got(val)
    ));
    default
}

fn bool_val(
    val: &toml::Value,
    table: &str,
    key: &str,
    default: bool,
    warnings: &mut Vec<String>,
) -> bool {
    if let Some(b) = val.as_bool() {
        return b;
    }
    warnings.push(format!(
        "config: [{table}] {key}: expected boolean, got {}; using default {default}",
        fmt_got(val)
    ));
    default
}

/// Render an offending value for a warning message.
fn fmt_got(val: &toml::Value) -> String {
    match val {
        toml::Value::String(s) => format!("{s:?}"),
        toml::Value::Integer(i) => i.to_string(),
        toml::Value::Float(f) => f.to_string(),
        toml::Value::Boolean(b) => b.to_string(),
        toml::Value::Datetime(_) => "a datetime".into(),
        toml::Value::Array(_) => "an array".into(),
        toml::Value::Table(_) => "a table".into(),
    }
}

/// Single-quote a value for zsh source output (cli-protocol.md quoting
/// discipline): wrap in '...' and escape embedded ' as '\''.
fn sq(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Render the zsh-sourceable output of `zrush config`.
pub fn to_zsh(result: &LoadResult) -> String {
    use std::fmt::Write as _;
    let c = &result.config;
    let mut o = String::new();
    let scalars: [(&str, String); 13] = [
        ("ZRUSH_BUILD_STAMP", BUILD_STAMP.to_string()),
        ("ZRUSH_CFG_MAX_LINES", c.max_lines.to_string()),
        ("ZRUSH_CFG_DELAY_MS", c.delay_ms.to_string()),
        ("ZRUSH_CFG_MIN_INPUT", c.min_input.to_string()),
        ("ZRUSH_CFG_MODE", c.mode.as_str().to_string()),
        ("ZRUSH_CFG_SMART_CASE", c.smart_case.to_string()),
        ("ZRUSH_CFG_TAB", c.tab.as_str().to_string()),
        ("ZRUSH_CFG_TRAILING_SPACE", c.trailing_space.to_string()),
        ("ZRUSH_CFG_HL_SELECTED", c.hl_selected.clone()),
        ("ZRUSH_CFG_HL_MATCH", c.hl_match.clone()),
        ("ZRUSH_CFG_HL_HEADING", c.hl_heading.clone()),
        ("ZRUSH_CFG_HL_HISTORY_NUMBER", c.hl_history_number.clone()),
        ("ZRUSH_CFG_HISTORY_LIMIT", c.history_limit.to_string()),
    ];
    for (name, value) in &scalars {
        let _ = writeln!(o, "typeset -g  {name}={}", sq(value));
    }
    o.push_str("typeset -ga ZRUSH_CFG_KEYBINDS=(\n");
    for (action, specs) in keybind::ACTIONS.iter().zip(&c.keybinds) {
        for spec in specs {
            let _ = writeln!(o, "  {:<14} {}", sq(action), sq(spec));
        }
    }
    o.push_str(")\n");
    if result.warnings.is_empty() {
        o.push_str("typeset -ga ZRUSH_CFG_WARNINGS=()\n");
    } else {
        o.push_str("typeset -ga ZRUSH_CFG_WARNINGS=(\n");
        for warning in &result.warnings {
            let _ = writeln!(o, "  {}", sq(warning));
        }
        o.push_str(")\n");
    }
    o
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_schema() {
        let c = Config::default();
        assert_eq!(c.max_lines, 10);
        assert_eq!(c.delay_ms, 30);
        assert_eq!(c.min_input, 0);
        assert_eq!(c.hl_selected, "standout");
        assert_eq!(c.hl_match, "underline");
        assert_eq!(c.hl_heading, "bold");
        assert_eq!(c.hl_history_number, "faint");
        assert_eq!(c.mode, Mode::Typo);
        assert!(c.smart_case);
        assert_eq!(c.tab, TabBehavior::Menu);
        assert!(c.trailing_space);
        assert_eq!(c.history_limit, 5000);
        assert_eq!(c.keybinds, keybind::default_specs());
    }

    #[test]
    fn empty_source_is_all_defaults_no_warnings() {
        let r = parse("");
        assert_eq!(r.config, Config::default());
        assert!(r.warnings.is_empty());
    }

    #[test]
    fn full_valid_file_applies_every_key() {
        let r = parse(
            r#"
            [display]
            max-lines = 20
            delay-ms = 100
            min-input = 2

            [display.highlight]
            selected = "fg=blue,standout"
            match = ""
            heading = "fg=green"
            history-number = "fg=yellow,faint"

            [matching]
            mode = "substring"
            smart-case = false

            [insert]
            tab = "insert"
            trailing-space = false

            [history]
            limit = 200

            [keybind]
            select-next = ["ctrl-j", "j"]
            select-prev = "ctrl-k"
            select-left = []
            confirm = "space"
            dismiss = "escape"
            "#,
        );
        assert!(r.warnings.is_empty(), "{:?}", r.warnings);
        let c = r.config;
        assert_eq!(c.max_lines, 20);
        assert_eq!(c.delay_ms, 100);
        assert_eq!(c.min_input, 2);
        assert_eq!(c.mode, Mode::Substring);
        assert!(!c.smart_case);
        assert_eq!(c.tab, TabBehavior::Insert);
        assert!(!c.trailing_space);
        assert_eq!(c.history_limit, 200);
        assert_eq!(c.hl_selected, "fg=blue,standout");
        assert_eq!(c.hl_match, "", "empty string means no decoration");
        assert_eq!(c.hl_heading, "fg=green");
        assert_eq!(c.hl_history_number, "fg=yellow,faint");
        // array, bare string (= one-element list), explicit empty list,
        // and an untouched action keeping its multi-key default
        assert_eq!(c.keybinds[0], vec!["seq:^J", "seq:j"]);
        assert_eq!(c.keybinds[1], vec!["seq:^K"]);
        assert!(c.keybinds[2].is_empty());
        assert_eq!(c.keybinds[3], vec!["key:right", "seq:^F"]);
        assert_eq!(c.keybinds[4], vec!["seq: "]);
        assert_eq!(c.keybinds[5], vec!["seq:^["]);
    }

    #[test]
    fn keybind_array_with_non_string_element_drops_only_that_element() {
        let r = parse("[keybind]\nselect-next = [\"ctrl-j\", 5]\n");
        assert_eq!(r.config.keybinds[0], vec!["seq:^J"]);
        assert_eq!(r.warnings.len(), 1);
        assert!(
            r.warnings[0].contains(
                "[keybind] select-next: expected string element, got 5; ignoring this element"
            ),
            "{}",
            r.warnings[0]
        );
    }

    #[test]
    fn keybind_array_with_no_valid_element_falls_back_to_default() {
        // Unlike an explicit [], a non-empty array losing every element
        // keeps the default list (config-schema.md).
        let r = parse("[keybind]\ndismiss = [1]\n");
        assert_eq!(r.config.keybinds[5], vec!["seq:^G"]);
        assert!(
            r.warnings
                .iter()
                .any(|w| w.contains("[keybind] dismiss: no valid element remains; using default")),
            "{:?}",
            r.warnings
        );
    }

    #[test]
    fn highlight_invalid_and_unknown_keys_fall_back() {
        let r = parse("[display.highlight]\nselected = 5\nmatchh = \"bold\"\n");
        assert_eq!(r.config.hl_selected, "standout");
        assert_eq!(r.warnings.len(), 2);
        assert!(
            r.warnings.iter().any(|w| w.contains(
                "[display.highlight] selected: expected string, got 5; using default \"standout\""
            )),
            "{:?}",
            r.warnings
        );
        assert!(
            r.warnings
                .iter()
                .any(|w| w.contains("[display.highlight] unknown key \"matchh\"; ignoring")),
            "{:?}",
            r.warnings
        );
    }

    #[test]
    fn highlight_non_table_falls_back() {
        let r = parse("[display]\nhighlight = \"standout\"\n");
        assert_eq!(r.config.hl_selected, "standout");
        assert!(
            r.warnings[0].contains(
                "[display.highlight]: expected a table, got \"standout\"; using defaults"
            ),
            "{}",
            r.warnings[0]
        );
    }

    #[test]
    fn type_mismatch_falls_back_with_schema_message() {
        let r = parse("[display]\nmax-lines = \"abc\"\n");
        assert_eq!(r.config.max_lines, 10);
        assert_eq!(
            r.warnings,
            vec![
                "config: [display] max-lines: expected integer 1..1000, got \"abc\"; using default 10"
            ]
        );
    }

    #[test]
    fn out_of_range_falls_back() {
        let r = parse("[display]\nmax-lines = 0\ndelay-ms = 20000\nmin-input = -1\n");
        assert_eq!(r.config.max_lines, 10);
        assert_eq!(r.config.delay_ms, 30);
        assert_eq!(r.config.min_input, 0);
        assert_eq!(r.warnings.len(), 3);
        assert!(
            r.warnings
                .iter()
                .any(|w| w.contains("expected integer 0..10000, got 20000")),
            "{:?}",
            r.warnings
        );
    }

    #[test]
    fn history_limit_out_of_range_falls_back() {
        let r = parse("[history]\nlimit = 0\n");
        assert_eq!(r.config.history_limit, 5000);
        assert_eq!(r.warnings.len(), 1);
        assert!(
            r.warnings[0]
                .contains("[history] limit: expected integer 1..20000, got 0; using default 5000"),
            "{}",
            r.warnings[0]
        );
    }

    #[test]
    fn history_limit_above_the_maximum_falls_back() {
        // config-schema.md [history] limit: 1..20000. The upper bound is
        // the one this test pins (the lower bound is above).
        let r = parse("[history]\nlimit = 20001\n");
        assert_eq!(r.config.history_limit, 5000);
        assert_eq!(r.warnings.len(), 1);
        assert!(
            r.warnings[0].contains("expected integer 1..20000, got 20001"),
            "{}",
            r.warnings[0]
        );
        assert_eq!(
            parse("[history]\nlimit = 20000\n").config.history_limit,
            20000
        );
    }

    #[test]
    fn unknown_enum_value_falls_back() {
        let r = parse("[matching]\nmode = \"fuzzy\"\n");
        assert_eq!(r.config.mode, Mode::Typo);
        assert_eq!(r.warnings.len(), 1);
        assert!(
            r.warnings[0].contains("expected one of \"prefix\", \"substring\", \"typo\""),
            "{}",
            r.warnings[0]
        );
        assert!(r.warnings[0].contains("got \"fuzzy\""));
        assert!(r.warnings[0].contains("using default \"typo\""));
    }

    #[test]
    fn bool_type_mismatch_falls_back() {
        let r = parse("[matching]\nsmart-case = \"yes\"\n");
        assert!(r.config.smart_case);
        assert!(
            r.warnings[0].contains("expected boolean, got \"yes\"; using default true"),
            "{}",
            r.warnings[0]
        );
    }

    #[test]
    fn unknown_key_and_table_warn_but_do_not_fail() {
        // top-level keys must precede any table header in TOML
        let r = parse("top = 1\n\n[display]\nmax-line = 5\n\n[displya]\nmax-lines = 5\n");
        assert_eq!(r.config, Config::default());
        assert_eq!(r.warnings.len(), 3);
        assert!(
            r.warnings
                .iter()
                .any(|w| w == "config: [display] unknown key \"max-line\"; ignoring"),
            "{:?}",
            r.warnings
        );
        assert!(
            r.warnings
                .iter()
                .any(|w| w == "config: unknown table [displya]; ignoring"),
            "{:?}",
            r.warnings
        );
        assert!(
            r.warnings
                .iter()
                .any(|w| w == "config: unknown key \"top\" (top level); ignoring"),
            "{:?}",
            r.warnings
        );
    }

    #[test]
    fn syntax_error_means_all_defaults_one_warning() {
        let r = parse("[display]\nmax-lines = 20\n[oops\n");
        assert_eq!(
            r.config,
            Config::default(),
            "valid-looking part not applied"
        );
        assert_eq!(r.warnings.len(), 1);
        assert!(r.warnings[0].starts_with("config: TOML syntax error:"));
        assert!(r.warnings[0].ends_with("; using all defaults"));
    }

    #[test]
    fn keybind_wrong_type_falls_back() {
        let r = parse("[keybind]\nconfirm = 5\n");
        assert_eq!(r.config.keybinds, keybind::default_specs());
        assert!(
            r.warnings[0].contains(
                "[keybind] confirm: expected string or array of strings, got 5; using default"
            ),
            "{}",
            r.warnings[0]
        );
    }

    #[test]
    fn keybind_duplicate_via_normalization_reverts_both() {
        // dismiss = ctrl-m collides with confirm's default enter (seq:^M).
        let r = parse("[keybind]\ndismiss = \"ctrl-m\"\n");
        assert_eq!(r.config.keybinds, keybind::default_specs());
        assert_eq!(r.warnings.len(), 1);
        assert!(
            r.warnings[0].contains("confirm, dismiss"),
            "{}",
            r.warnings[0]
        );
    }

    #[test]
    fn single_quotes_are_escaped_in_output() {
        assert_eq!(sq("plain"), "'plain'");
        assert_eq!(sq("a'b"), "'a'\\''b'");
        let r = parse("[matching]\nmode = \"ty'po\"\n");
        let out = to_zsh(&r);
        assert!(out.contains("ty'\\''po"), "{out}");
    }

    // Reads a repo file by path relative to the crate root for tests that
    // read the contract doc.
    fn read_repo_file(relative_path: &str) -> String {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(relative_path);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()))
    }

    const CONTRACT: &str = "docs/internal/contracts/cli-protocol.md";

    /// The default `zrush config` output as the contract specifies it: the
    /// fenced zsh block under the "`zrush config` stdout (zsh Source Format)"
    /// heading.
    /// Reading it keeps the doc the only copy on this side; every failure
    /// mode of the extraction panics with the anchor it could not find, so
    /// restructuring the doc breaks this loudly instead of quietly turning
    /// the check into a no-op.
    fn contract_default_output() -> String {
        const HEADING: &str = "### `zrush config` stdout (zsh Source Format)";
        const OPEN: &str = "```zsh\n";
        const CLOSE: &str = "```";

        let doc = read_repo_file(CONTRACT);
        let after_heading = doc
            .split_once(&format!("\n{HEADING}\n"))
            .unwrap_or_else(|| {
                panic!("{CONTRACT}: heading \"{HEADING}\" not found; this test reads the example under it")
            })
            .1;
        // Stop at the next heading: the example must stay the first block of
        // its section, or a later fence would be silently picked up instead.
        let section = after_heading
            .split_once("\n#")
            .map_or(after_heading, |(section, _)| section);
        let body = section
            .split_once(OPEN)
            .unwrap_or_else(|| {
                panic!("{CONTRACT}: no {OPEN:?} block between \"{HEADING}\" and the next heading")
            })
            .1;
        body.split_once(CLOSE)
            .unwrap_or_else(|| {
                panic!(
                    "{CONTRACT}: the example block under \"{HEADING}\" is not closed by {CLOSE:?}"
                )
            })
            .0
            .to_string()
    }

    #[test]
    fn default_output_matches_contract_example() {
        let actual = to_zsh(&LoadResult::default()).replace(BUILD_STAMP, "<build-stamp>");
        assert_eq!(
            actual,
            contract_default_output(),
            "default `zrush config` output disagrees with the example in {CONTRACT}, \
             which is the source of truth"
        );
    }

    #[test]
    fn warnings_are_emitted_as_array_entries() {
        let r = parse("[display]\nmax-lines = 0\n");
        let out = to_zsh(&r);
        assert!(out.contains("typeset -ga ZRUSH_CFG_WARNINGS=(\n  'config: [display] max-lines:"));
    }
}
