//! Keybind notation normalization.
//!
//! Notation table: config-schema.md "キー記法". Output forms
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

/// Default key notations per action (config-schema.md). Multiple keys
/// per action: arrow keys plus the emacs-style ctrl equivalents.
pub const DEFAULT_NOTATIONS: [&[&str]; N] = [
    &["down", "ctrl-n"],
    &["up", "ctrl-p"],
    &["left", "ctrl-b"],
    &["right", "ctrl-f"],
    &["enter"],
    &["ctrl-g"],
];

/// Normalized spec lists for the default keybinds.
pub fn default_specs() -> [Vec<String>; N] {
    DEFAULT_NOTATIONS.map(|ns| {
        ns.iter()
            .map(|n| normalize(n).expect("default notations are valid"))
            .collect()
    })
}

/// Human-readable default list for warning messages
/// (e.g. `"down"/"ctrl-n"`).
pub(crate) fn default_desc(i: usize) -> String {
    DEFAULT_NOTATIONS[i]
        .iter()
        .map(|n| format!("\"{n}\""))
        .collect::<Vec<_>>()
        .join("/")
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

/// Resolve every action's keybind list from user notations.
///
/// Element-wise validation follows config-schema.md "[keybind]".
///
/// Cross-action rule: the same key on multiple actions (compared AFTER
/// normalization, so enter = ctrl-m = ^M collide) reverts every
/// involved action wholly to its default list (+ one warning per
/// group). Repeats until no collision remains (a reset default can
/// collide with another user-set key); terminates because default
/// lists are pairwise disjoint and every round moves at least one
/// action onto its default.
pub fn resolve(user: &[Option<Vec<String>>; N], warnings: &mut Vec<String>) -> [Vec<String>; N] {
    let mut specs = default_specs();
    for (i, notations) in user.iter().enumerate() {
        let Some(notations) = notations else { continue };
        let mut list: Vec<String> = Vec::new();
        let mut dropped = false;
        for notation in notations {
            match normalize(notation) {
                Some(spec) if spec == "seq:^I" => {
                    warnings.push(format!(
                        "config: [keybind] {}: key \"{}\" is reserved for [insert].tab behavior; ignoring this key",
                        ACTIONS[i], notation
                    ));
                    dropped = true;
                }
                Some(spec) => {
                    if list.contains(&spec) {
                        warnings.push(format!(
                            "config: [keybind] {}: duplicate key \"{}\" ({}); ignoring",
                            ACTIONS[i], notation, spec
                        ));
                    } else {
                        list.push(spec);
                    }
                }
                None => {
                    warnings.push(format!(
                        "config: [keybind] {}: unknown key notation \"{}\"; ignoring this key",
                        ACTIONS[i], notation
                    ));
                    dropped = true;
                }
            }
        }
        if list.is_empty() && dropped {
            warnings.push(format!(
                "config: [keybind] {}: no valid key remains; using default {}",
                ACTIONS[i],
                default_desc(i)
            ));
            continue; // keep the default list
        }
        specs[i] = list; // may be legitimately empty (explicit [])
    }
    while let Some(dup) = first_cross_duplicate(&specs) {
        let group: Vec<usize> = (0..N).filter(|&i| specs[i].contains(&dup)).collect();
        let names: Vec<&str> = group.iter().map(|&i| ACTIONS[i]).collect();
        let defaults: Vec<String> = group.iter().map(|&i| default_desc(i)).collect();
        warnings.push(format!(
            "config: [keybind] {}: same key after normalization ({}); using defaults {}",
            names.join(", "),
            dup,
            defaults.join(", ")
        ));
        for &i in &group {
            specs[i] = DEFAULT_NOTATIONS[i]
                .iter()
                .map(|n| normalize(n).expect("default notations are valid"))
                .collect();
        }
    }
    specs
}

/// A spec assigned to two or more different actions, if any.
fn first_cross_duplicate(specs: &[Vec<String>; N]) -> Option<String> {
    for i in 0..N {
        for spec in &specs[i] {
            for other in specs.iter().skip(i + 1) {
                if other.contains(spec) {
                    return Some(spec.clone());
                }
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

    /// User-notation array with the given (action, key list) pairs set.
    fn user(pairs: &[(&str, &[&str])]) -> [Option<Vec<String>>; N] {
        let mut u: [Option<Vec<String>>; N] = Default::default();
        for (action, notations) in pairs {
            u[idx(action)] = Some(notations.iter().map(|n| (*n).to_string()).collect());
        }
        u
    }

    #[test]
    fn defaults_are_valid_and_pairwise_disjoint() {
        let specs = default_specs();
        assert_eq!(specs[idx("select-next")], ["key:down", "seq:^N"]);
        assert_eq!(specs[idx("select-prev")], ["key:up", "seq:^P"]);
        assert_eq!(specs[idx("select-left")], ["key:left", "seq:^B"]);
        assert_eq!(specs[idx("select-right")], ["key:right", "seq:^F"]);
        assert_eq!(specs[idx("confirm")], ["seq:^M"]);
        assert_eq!(specs[idx("dismiss")], ["seq:^G"]);
        // the collision fixpoint argument requires pairwise-disjoint defaults
        for i in 0..N {
            for s in &specs[i] {
                for (j, other) in specs.iter().enumerate() {
                    if i != j {
                        assert!(!other.contains(s), "{s} in both {i} and {j}");
                    }
                }
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
    fn resolve_multi_key_list_is_normalized_in_order() {
        let mut w = Vec::new();
        let specs = resolve(&user(&[("select-next", &["ctrl-j", "j", "pgdn"])]), &mut w);
        assert!(w.is_empty(), "{w:?}");
        assert_eq!(specs[idx("select-next")], ["seq:^J", "seq:j", "key:pgdn"]);
    }

    #[test]
    fn resolve_explicit_empty_list_unbinds_the_action() {
        let mut w = Vec::new();
        let specs = resolve(&user(&[("select-left", &[])]), &mut w);
        assert!(w.is_empty(), "{w:?}");
        assert!(specs[idx("select-left")].is_empty());
    }

    #[test]
    fn resolve_invalid_element_is_dropped_others_kept() {
        let mut w = Vec::new();
        let specs = resolve(&user(&[("dismiss", &["meta-g", "ctrl-x"])]), &mut w);
        assert_eq!(specs[idx("dismiss")], ["seq:^X"]);
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("dismiss"), "{}", w[0]);
        assert!(w[0].contains("unknown key notation \"meta-g\""), "{}", w[0]);
        assert!(w[0].contains("ignoring this key"), "{}", w[0]);
    }

    #[test]
    fn resolve_no_valid_element_falls_back_to_default_list() {
        let mut w = Vec::new();
        let specs = resolve(&user(&[("select-prev", &["meta-p"])]), &mut w);
        assert_eq!(specs, default_specs());
        assert_eq!(w.len(), 2);
        assert!(w[1].contains("no valid key remains"), "{}", w[1]);
        assert!(w[1].contains("\"up\"/\"ctrl-p\""), "{}", w[1]);
    }

    #[test]
    fn resolve_duplicate_within_action_is_deduped_with_warning() {
        let mut w = Vec::new();
        let specs = resolve(&user(&[("confirm", &["enter", "ctrl-m"])]), &mut w);
        assert_eq!(specs[idx("confirm")], ["seq:^M"]);
        assert_eq!(w.len(), 1);
        assert!(
            w[0].contains("duplicate key \"ctrl-m\" (seq:^M)"),
            "{}",
            w[0]
        );
    }

    #[test]
    fn resolve_rejects_tab_key_assignment() {
        for notation in ["tab", "ctrl-i"] {
            let mut w = Vec::new();
            let specs = resolve(&user(&[("confirm", &[notation])]), &mut w);
            assert_eq!(specs, default_specs(), "notation {notation:?}");
            assert_eq!(w.len(), 2, "notation {notation:?}");
            assert!(w[0].contains("confirm"), "{}", w[0]);
            assert!(
                w[0].contains(&format!(
                    "key \"{notation}\" is reserved for [insert].tab behavior"
                )),
                "{}",
                w[0]
            );
            assert!(w[1].contains("no valid key remains"), "{}", w[1]);
        }
    }

    #[test]
    fn resolve_tab_rejection_composes_with_duplicate_resolution() {
        // Dropping "tab" leaves confirm's "space", so dismiss's "ctrl-m"
        // does not collide and only the reserved-tab warning is emitted.
        let mut w = Vec::new();
        let specs = resolve(
            &user(&[("confirm", &["tab", "space"]), ("dismiss", &["ctrl-m"])]),
            &mut w,
        );
        // confirm: tab dropped -> [space]; dismiss = ^M no longer
        // collides with confirm (which lost its default enter), so it
        // stays as the user set it.
        assert_eq!(specs[idx("confirm")], ["seq: "]);
        assert_eq!(specs[idx("dismiss")], ["seq:^M"]);
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("reserved for [insert].tab"), "{}", w[0]);
    }

    #[test]
    fn resolve_detects_duplicates_after_normalization() {
        // confirm stays default ["enter"] (seq:^M); dismiss = ctrl-m collides.
        let mut w = Vec::new();
        let specs = resolve(&user(&[("dismiss", &["ctrl-m"])]), &mut w);
        assert_eq!(specs, default_specs(), "both revert to defaults");
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("confirm, dismiss"), "{}", w[0]);
        assert!(w[0].contains("seq:^M"), "{}", w[0]);
    }

    #[test]
    fn resolve_collision_on_one_list_element_reverts_whole_lists() {
        // select-next keeps a list; one of its elements collides with
        // dismiss -> both actions revert wholly to their default lists.
        let mut w = Vec::new();
        let specs = resolve(
            &user(&[("select-next", &["j", "ctrl-x"]), ("dismiss", &["ctrl-x"])]),
            &mut w,
        );
        assert_eq!(specs, default_specs());
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("select-next, dismiss"), "{}", w[0]);
        assert!(w[0].contains("seq:^X"), "{}", w[0]);
    }

    #[test]
    fn resolve_duplicate_group_reverts_all_members() {
        let mut w = Vec::new();
        let specs = resolve(
            &user(&[
                ("select-next", &["x"]),
                ("select-prev", &["x"]),
                ("confirm", &["x"]),
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
        // select-prev and confirm both bind "x" -> reset to defaults.
        // dismiss user-binds "up", which now collides with the reset
        // select-prev default -> a second round resets that pair too.
        let mut w = Vec::new();
        let specs = resolve(
            &user(&[
                ("select-prev", &["x"]),
                ("confirm", &["x"]),
                ("dismiss", &["up"]),
            ]),
            &mut w,
        );
        assert_eq!(specs, default_specs());
        assert_eq!(w.len(), 2);
    }
}
