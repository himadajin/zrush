//! Keybind notation normalization.
//!
//! Notation table: config-schema.md「キー記法」. Output forms
//! (cli-protocol.md):
//! - `seq:<bindkey sequence>` — fully normalized here (e.g. ctrl-g -> seq:^G).
//! - `key:<symbolic name>`    — terminal-dependent keys (up, shift-tab, ...);
//!   zsh resolves them via $terminfo. Rust only validates the notation.

/// Bindable actions, in output order. Index-aligned with
/// [`DEFAULT_NOTATIONS`] and the resolved spec arrays.
pub const ACTIONS: [&str; 4] = ["select-next", "select-prev", "confirm", "dismiss"];

/// Default key notation per action (config-schema.md).
pub const DEFAULT_NOTATIONS: [&str; 4] = ["down", "up", "enter", "ctrl-g"];

/// Normalized specs for the default keybinds.
pub fn default_specs() -> [String; 4] {
    DEFAULT_NOTATIONS.map(|n| normalize(n).expect("default notations are valid"))
}

/// Normalize a config key notation into its `seq:`/`key:` form.
/// Returns None for notation outside the config-schema.md table
/// (validation error: caller falls back to the action's default).
pub fn normalize(notation: &str) -> Option<String> {
    // Named keys first: "tab" the name wins over a literal-char reading,
    // and "ctrl-space" must be seen before the generic "ctrl-" arm.
    match notation {
        "enter" => return Some("seq:^M".into()),
        "tab" => return Some("seq:^I".into()),
        "escape" => return Some("seq:^[".into()),
        "space" => return Some("seq: ".into()), // single blank character
        "ctrl-space" => return Some("seq:^@".into()),
        "up" | "down" | "left" | "right" | "shift-tab" | "home" | "end" | "pgup" | "pgdn"
        | "delete" => return Some(format!("key:{notation}")),
        _ => {}
    }
    if let Some(rest) = notation.strip_prefix("ctrl-") {
        // Only ctrl-a .. ctrl-z (ctrl-space was handled above).
        let [b] = rest.as_bytes() else { return None };
        if b.is_ascii_lowercase() {
            return Some(format!("seq:^{}", b.to_ascii_uppercase() as char));
        }
        return None;
    }
    if let Some(rest) = notation.strip_prefix("alt-") {
        let [b] = rest.as_bytes() else { return None };
        if is_plain_char(*b) {
            return Some(format!("seq:^[{}", *b as char));
        }
        return None;
    }
    let [b] = notation.as_bytes() else {
        return None;
    };
    if is_plain_char(*b) {
        return Some(format!("seq:{}", *b as char));
    }
    None
}

/// Single-character notation class: a-z, 0-9, symbols (notation is
/// written in lowercase per config-schema.md, so uppercase is invalid).
fn is_plain_char(b: u8) -> bool {
    b.is_ascii_graphic() && !b.is_ascii_uppercase()
}

/// Resolve the four actions' keybinds from user notations.
///
/// - Invalid notation: that action falls back to its default (+ warning).
/// - Same key on multiple actions (compared AFTER normalization, so
///   enter = ctrl-m = ^M collide): every action in the group reverts to
///   its default (+ one warning per group). Repeats until no collision
///   remains (a reset default can collide with another user-set key);
///   terminates because defaults are pairwise distinct and every round
///   moves at least one action onto its default.
pub fn resolve(user: &[Option<String>; 4], warnings: &mut Vec<String>) -> [String; 4] {
    let mut specs = default_specs();
    for (i, notation) in user.iter().enumerate() {
        let Some(notation) = notation else { continue };
        match normalize(notation) {
            Some(spec) => specs[i] = spec,
            None => warnings.push(format!(
                "config: [keybind] {}: unknown key notation \"{}\"; using default \"{}\"",
                ACTIONS[i], notation, DEFAULT_NOTATIONS[i]
            )),
        }
    }
    loop {
        let Some(dup) = first_duplicate(&specs) else {
            break;
        };
        let group: Vec<usize> = (0..4).filter(|&i| specs[i] == dup).collect();
        let names: Vec<&str> = group.iter().map(|&i| ACTIONS[i]).collect();
        let defaults: Vec<String> = group
            .iter()
            .map(|&i| format!("\"{}\"", DEFAULT_NOTATIONS[i]))
            .collect();
        warnings.push(format!(
            "config: [keybind] {}: same key after normalization ({}); using defaults {}",
            names.join(", "),
            dup,
            defaults.join(", ")
        ));
        for &i in &group {
            specs[i] = normalize(DEFAULT_NOTATIONS[i]).expect("default notations are valid");
        }
    }
    specs
}

fn first_duplicate(specs: &[String; 4]) -> Option<String> {
    for i in 0..4 {
        for j in i + 1..4 {
            if specs[i] == specs[j] {
                return Some(specs[i].clone());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_every_table_row() {
        // single characters
        assert_eq!(normalize("a").as_deref(), Some("seq:a"));
        assert_eq!(normalize("z").as_deref(), Some("seq:z"));
        assert_eq!(normalize("0").as_deref(), Some("seq:0"));
        assert_eq!(normalize("9").as_deref(), Some("seq:9"));
        assert_eq!(normalize("/").as_deref(), Some("seq:/"));
        assert_eq!(normalize("'").as_deref(), Some("seq:'"));
        // ctrl
        assert_eq!(normalize("ctrl-a").as_deref(), Some("seq:^A"));
        assert_eq!(normalize("ctrl-z").as_deref(), Some("seq:^Z"));
        assert_eq!(normalize("ctrl-g").as_deref(), Some("seq:^G"));
        assert_eq!(normalize("ctrl-space").as_deref(), Some("seq:^@"));
        // alt
        assert_eq!(normalize("alt-x").as_deref(), Some("seq:^[x"));
        assert_eq!(normalize("alt-.").as_deref(), Some("seq:^[."));
        // named
        assert_eq!(normalize("enter").as_deref(), Some("seq:^M"));
        assert_eq!(normalize("tab").as_deref(), Some("seq:^I"));
        assert_eq!(normalize("escape").as_deref(), Some("seq:^["));
        assert_eq!(normalize("space").as_deref(), Some("seq: "));
        // terminal-dependent
        for k in [
            "up",
            "down",
            "left",
            "right",
            "shift-tab",
            "home",
            "end",
            "pgup",
            "pgdn",
            "delete",
        ] {
            assert_eq!(normalize(k), Some(format!("key:{k}")), "key {k}");
        }
    }

    #[test]
    fn ctrl_m_and_enter_normalize_to_same_seq() {
        assert_eq!(normalize("ctrl-m"), normalize("enter"));
        assert_eq!(normalize("ctrl-i"), normalize("tab"));
    }

    #[test]
    fn rejects_unknown_notation() {
        for n in [
            "",
            "A",
            "aa",
            "ctrl-",
            "ctrl-1",
            "ctrl-A",
            "ctrl-mm",
            "alt-",
            "alt-A",
            "meta-x",
            "spacex",
            " ",
            "f1",
            "ctrl-alt-a",
            "é",
        ] {
            assert_eq!(normalize(n), None, "notation {n:?} should be invalid");
        }
    }

    #[test]
    fn defaults_are_valid_and_distinct() {
        let specs = default_specs();
        assert_eq!(specs, ["key:down", "key:up", "seq:^M", "seq:^G"]);
        for i in 0..4 {
            for j in i + 1..4 {
                assert_ne!(specs[i], specs[j]);
            }
        }
    }

    #[test]
    fn resolve_all_unset_gives_defaults_no_warnings() {
        let mut w = Vec::new();
        let specs = resolve(&[None, None, None, None], &mut w);
        assert_eq!(specs, default_specs());
        assert!(w.is_empty());
    }

    #[test]
    fn resolve_invalid_notation_falls_back_with_warning() {
        let mut w = Vec::new();
        let specs = resolve(&[None, None, None, Some("meta-g".into())], &mut w);
        assert_eq!(specs, default_specs());
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("dismiss"), "{}", w[0]);
        assert!(w[0].contains("unknown key notation \"meta-g\""), "{}", w[0]);
        assert!(w[0].contains("using default \"ctrl-g\""), "{}", w[0]);
    }

    #[test]
    fn resolve_detects_duplicates_after_normalization() {
        // confirm stays default "enter" (seq:^M); dismiss = ctrl-m collides.
        let mut w = Vec::new();
        let specs = resolve(&[None, None, None, Some("ctrl-m".into())], &mut w);
        assert_eq!(specs, default_specs(), "both revert to defaults");
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("confirm, dismiss"), "{}", w[0]);
        assert!(w[0].contains("seq:^M"), "{}", w[0]);
    }

    #[test]
    fn resolve_duplicate_group_reverts_all_members() {
        let mut w = Vec::new();
        let specs = resolve(
            &[Some("x".into()), Some("x".into()), Some("x".into()), None],
            &mut w,
        );
        assert_eq!(specs, default_specs());
        assert_eq!(w.len(), 1);
        assert!(
            w[0].contains("select-next, select-prev, confirm"),
            "{}",
            w[0]
        );
    }

    #[test]
    fn resolve_cascading_duplicate_reaches_fixpoint() {
        // select-prev and confirm both bind "x" -> reset to up / enter.
        // dismiss user-binds "up", which now collides with the reset
        // select-prev -> a second round resets that pair too.
        let mut w = Vec::new();
        let specs = resolve(
            &[None, Some("x".into()), Some("x".into()), Some("up".into())],
            &mut w,
        );
        assert_eq!(specs, default_specs());
        assert_eq!(w.len(), 2);
    }
}
