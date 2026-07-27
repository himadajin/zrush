//! Keybind notation normalization.
//!
//! Notation table: config-schema.md「キー記法」. Output forms
//! (cli-protocol.md):
//! - `seq:<bindkey sequence>` — fully normalized here (e.g. ctrl-g -> seq:^G).
//! - `key:<symbolic name>`    — terminal-dependent keys (up, shift-tab, ...);
//!   zsh resolves them via $terminfo. Rust only validates the notation.

/// Number of bindable actions.
pub const N: usize = 6;

/// Bindable actions, in output order. Index-aligned with
/// [`DEFAULT_NOTATIONS`] and the resolved spec arrays.
pub const ACTIONS: [&str; N] = [
    "select-next",
    "select-prev",
    "select-left",
    "select-right",
    "confirm",
    "dismiss",
];

/// Default key notation per action (config-schema.md).
pub const DEFAULT_NOTATIONS: [&str; N] = ["down", "up", "left", "right", "enter", "ctrl-g"];

/// Normalized specs for the default keybinds.
pub fn default_specs() -> [String; N] {
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
            // ^ and \ would be misread by bindkey after the ^[ prefix,
            // same escaping rule as the bare single-char forms.
            return Some(match b {
                b'^' => "seq:^[\\^".into(),
                b'\\' => "seq:^[\\\\".into(),
                _ => format!("seq:^[{}", *b as char),
            });
        }
        return None;
    }
    let [b] = notation.as_bytes() else {
        return None;
    };
    if is_plain_char(*b) {
        // `^` and `\` would be misread by bindkey as the start of a
        // caret/backslash escape; emit them escaped (config-schema.md).
        return Some(match *b {
            b'^' => "seq:\\^".into(),
            b'\\' => "seq:\\\\".into(),
            _ => format!("seq:{}", *b as char),
        });
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
/// - The Tab key (`tab` / `ctrl-i`, normalized seq:^I) cannot be
///   assigned to an action (config-schema.md): zsh always binds ^I to
///   the fixed `[insert].tab` behavior hook, so accepting it would
///   silently swallow the assignment. Validation error: default +
///   warning.
/// - Same key on multiple actions (compared AFTER normalization, so
///   enter = ctrl-m = ^M collide): every action in the group reverts to
///   its default (+ one warning per group). Repeats until no collision
///   remains (a reset default can collide with another user-set key);
///   terminates because defaults are pairwise distinct and every round
///   moves at least one action onto its default.
pub fn resolve(user: &[Option<String>; N], warnings: &mut Vec<String>) -> [String; N] {
    let mut specs = default_specs();
    for (i, notation) in user.iter().enumerate() {
        let Some(notation) = notation else { continue };
        match normalize(notation) {
            Some(spec) if spec == "seq:^I" => warnings.push(format!(
                "config: [keybind] {}: key \"{}\" is reserved for [insert].tab behavior; using default \"{}\"",
                ACTIONS[i], notation, DEFAULT_NOTATIONS[i]
            )),
            Some(spec) => specs[i] = spec,
            None => warnings.push(format!(
                "config: [keybind] {}: unknown key notation \"{}\"; using default \"{}\"",
                ACTIONS[i], notation, DEFAULT_NOTATIONS[i]
            )),
        }
    }
    while let Some(dup) = first_duplicate(&specs) {
        let group: Vec<usize> = (0..N).filter(|&i| specs[i] == dup).collect();
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

fn first_duplicate(specs: &[String; N]) -> Option<String> {
    for i in 0..N {
        for j in i + 1..N {
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
        // bindkey-metacharacters are escaped; neighbors stay literal
        assert_eq!(normalize("^").as_deref(), Some("seq:\\^"));
        assert_eq!(normalize("\\").as_deref(), Some("seq:\\\\"));
        assert_eq!(normalize("~").as_deref(), Some("seq:~"));
        assert_eq!(normalize("[").as_deref(), Some("seq:["));
        assert_eq!(normalize("-").as_deref(), Some("seq:-"));
        // ctrl
        assert_eq!(normalize("ctrl-a").as_deref(), Some("seq:^A"));
        assert_eq!(normalize("ctrl-z").as_deref(), Some("seq:^Z"));
        assert_eq!(normalize("ctrl-g").as_deref(), Some("seq:^G"));
        assert_eq!(normalize("ctrl-space").as_deref(), Some("seq:^@"));
        // alt
        assert_eq!(normalize("alt-x").as_deref(), Some("seq:^[x"));
        assert_eq!(normalize("alt-.").as_deref(), Some("seq:^[."));
        assert_eq!(normalize("alt-^").as_deref(), Some("seq:^[\\^"));
        assert_eq!(normalize("alt-\\").as_deref(), Some("seq:^[\\\\"));
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

    /// Index of an action name in ACTIONS (test helper).
    fn idx(action: &str) -> usize {
        ACTIONS.iter().position(|a| *a == action).unwrap()
    }

    /// User-notation array with the given (action, notation) pairs set.
    fn user(pairs: &[(&str, &str)]) -> [Option<String>; N] {
        let mut u: [Option<String>; N] = Default::default();
        for (action, notation) in pairs {
            u[idx(action)] = Some((*notation).into());
        }
        u
    }

    #[test]
    fn defaults_are_valid_and_distinct() {
        let specs = default_specs();
        assert_eq!(
            specs,
            [
                "key:down",
                "key:up",
                "key:left",
                "key:right",
                "seq:^M",
                "seq:^G"
            ]
        );
        for i in 0..N {
            for j in i + 1..N {
                assert_ne!(specs[i], specs[j]);
            }
        }
    }

    #[test]
    fn resolve_all_unset_gives_defaults_no_warnings() {
        let mut w = Vec::new();
        let specs = resolve(&Default::default(), &mut w);
        assert_eq!(specs, default_specs());
        assert!(w.is_empty());
    }

    #[test]
    fn resolve_invalid_notation_falls_back_with_warning() {
        let mut w = Vec::new();
        let specs = resolve(&user(&[("dismiss", "meta-g")]), &mut w);
        assert_eq!(specs, default_specs());
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("dismiss"), "{}", w[0]);
        assert!(w[0].contains("unknown key notation \"meta-g\""), "{}", w[0]);
        assert!(w[0].contains("using default \"ctrl-g\""), "{}", w[0]);
    }

    #[test]
    fn resolve_rejects_tab_key_assignment() {
        for notation in ["tab", "ctrl-i"] {
            let mut w = Vec::new();
            let specs = resolve(&user(&[("confirm", notation)]), &mut w);
            assert_eq!(specs, default_specs(), "notation {notation:?}");
            assert_eq!(w.len(), 1, "notation {notation:?}");
            assert!(w[0].contains("confirm"), "{}", w[0]);
            assert!(
                w[0].contains(&format!(
                    "key \"{notation}\" is reserved for [insert].tab behavior"
                )),
                "{}",
                w[0]
            );
            assert!(w[0].contains("using default \"enter\""), "{}", w[0]);
        }
    }

    #[test]
    fn resolve_tab_rejection_composes_with_duplicate_resolution() {
        // confirm = "tab" is rejected -> falls back to enter (seq:^M);
        // dismiss = "ctrl-m" then collides with that default -> the
        // duplicate loop reverts both, two warnings total.
        let mut w = Vec::new();
        let specs = resolve(&user(&[("confirm", "tab"), ("dismiss", "ctrl-m")]), &mut w);
        assert_eq!(specs, default_specs());
        assert_eq!(w.len(), 2);
        assert!(w[0].contains("reserved for [insert].tab"), "{}", w[0]);
        assert!(w[1].contains("same key after normalization"), "{}", w[1]);
    }

    #[test]
    fn resolve_detects_duplicates_after_normalization() {
        // confirm stays default "enter" (seq:^M); dismiss = ctrl-m collides.
        let mut w = Vec::new();
        let specs = resolve(&user(&[("dismiss", "ctrl-m")]), &mut w);
        assert_eq!(specs, default_specs(), "both revert to defaults");
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("confirm, dismiss"), "{}", w[0]);
        assert!(w[0].contains("seq:^M"), "{}", w[0]);
    }

    #[test]
    fn resolve_duplicate_group_reverts_all_members() {
        let mut w = Vec::new();
        let specs = resolve(
            &user(&[
                ("select-next", "x"),
                ("select-prev", "x"),
                ("confirm", "x"),
            ]),
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
            &user(&[("select-prev", "x"), ("confirm", "x"), ("dismiss", "up")]),
            &mut w,
        );
        assert_eq!(specs, default_specs());
        assert_eq!(w.len(), 2);
    }

    #[test]
    fn resolve_left_right_accept_user_notation() {
        let mut w = Vec::new();
        let specs = resolve(
            &user(&[("select-left", "ctrl-b"), ("select-right", "ctrl-f")]),
            &mut w,
        );
        assert!(w.is_empty(), "{w:?}");
        assert_eq!(specs[idx("select-left")], "seq:^B");
        assert_eq!(specs[idx("select-right")], "seq:^F");
    }
}
