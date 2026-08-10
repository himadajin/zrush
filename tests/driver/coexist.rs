//! Coexistence with third-party zle plugins
//! (docs/internal/specs/behavior.md 「プラグイン共存」, and the
//! abbr -> zrush -> z-sy-h load order docs/user/install.md documents).
//!
//! The other side of each scenario is a double: an rc fragment reproducing the
//! *technique* a real plugin uses -- a widget bound ahead of zrush, a
//! `zle-line-pre-redraw` hook writing into the shared `region_highlight`, a
//! `compadd` wrapper in the parent shell -- not the plugin itself. What zrush
//! promises is to survive wrappers of those shapes, so that is what is
//! asserted; whether a specific released plugin still uses its shape is a
//! dogfooding question (zsh/verify.zsh), deliberately not a CI one.

use std::time::Duration;

use crate::host::{Host, PlanShape, keys};

/// zsh-abbr's shape: a widget bound to Enter *before* zrush loads, which
/// rewrites BUFFER and then accepts the line. zrush records it as the
/// predecessor of its own confirm dispatcher, so an Enter with nothing selected
/// has to fall through to it.
const ABBR_DOUBLE: &str = r#"
_zrt_double_abbr() {
  [[ $BUFFER == zzz ]] && BUFFER='print ABBR-EXPANDED-OK'
  zle .accept-line
}
zle -N _zrt-double-abbr _zrt_double_abbr
bindkey '^M' _zrt-double-abbr
"#;

/// zsh-syntax-highlighting 0.8's shape: a `zle-line-pre-redraw` hook registered
/// through `add-zle-hook-widget` that rewrites the shared `region_highlight`,
/// removing only its own previous entries (by `memo=` where zsh supports it,
/// by ledger subtraction on 5.8) and leaving everyone else's alone.
///
/// Its entry covers the BUFFER region, as a syntax highlighter's does. That
/// also keeps it clear of zrush's 5.8 fallback, which drops entries starting at
/// or beyond `$#BUFFER` (`_zrush_rh_clear` in zsh/zrush.zsh).
const ZSYH_DOUBLE: &str = r#"
autoload -Uz add-zle-hook-widget is-at-least
typeset -g _zrt_double_memo=
is-at-least 5.9 $ZSH_VERSION && _zrt_double_memo=' memo=zrt-double'
typeset -ga _zrt_double_rh=()
_zrt_double_zsyh() {
  if [[ -n $_zrt_double_memo ]]; then
    region_highlight=( "${(@)region_highlight:#*memo=zrt-double}" )
  else
    region_highlight=( "${(@)region_highlight:|_zrt_double_rh}" )
  fi
  _zrt_double_rh=()
  (( $#BUFFER )) || return 0
  local e="0 $#BUFFER fg=red$_zrt_double_memo"
  region_highlight+=( "$e" )
  _zrt_double_rh=( "$e" )
}
add-zle-hook-widget zle-line-pre-redraw _zrt_double_zsyh
"#;

/// zsh-autosuggestions' shape: a `compadd` wrapper living in the interactive
/// shell. behavior.md 「プラグイン共存」 requires the capture fork to strip such
/// wrappers before calling compsys, and to confine that removal to the fork.
const COMPADD_DOUBLE: &str = r#"
typeset -gi _zrt_double_compadd_calls=0
compadd() { (( ++_zrt_double_compadd_calls )); builtin compadd "$@" }
"#;

/// The marker a double's own `region_highlight` entry carries.
const FOREIGN_HL: &str = "fg=red";

/// Listing, selection, and confirmation on the current host: the flow the zsh
/// driver re-ran under every plugin arrangement, because it is what proves
/// dispatch still reaches both zrush and the layers around it.
fn assert_listing_selection_and_confirm(host: &mut Host, label: &str) {
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/subd");
    let post = host.postdisplay(label);
    assert!(
        post.contains("subdir"),
        "{label}: the listing did not reach POSTDISPLAY: {post:?}"
    );
    // Selection-only updates go through _zrush_apply_highlights without a plan
    // re-fetch, so "select: start" is what marks Down actually selecting.
    host.assert_log_grows("select: start", &[keys::DOWN], label);
    host.press(keys::ENTER);
    host.assert_buffer("ls fx/basic/subdir/", label);
    host.clear_line();
}

/// Every `region_highlight` entry that zrush's own ledger does not claim.
fn third_party_highlights(host: &mut Host, label: &str) -> Vec<String> {
    let mine = host.zrush_highlights(label);
    host.all_highlights(label)
        .into_iter()
        .filter(|entry| !mine.contains(entry))
        .collect()
}

/// Type a buffer the double will highlight and return the entries it added.
fn foreign_highlights_for_a_typed_buffer(host: &mut Host, label: &str) -> Vec<String> {
    host.send_keys("qqqqxx");
    host.drain(Duration::from_millis(500));
    let foreign = third_party_highlights(host, label);
    host.clear_line();
    foreign
}

#[test]
fn a_predecessor_bound_ahead_of_zrush_still_receives_enter() {
    let mut host = Host::boot_with_doubles(ABBR_DOUBLE, "");

    host.send_keys("zzz");
    host.drain(Duration::from_millis(500));
    host.send_keys(keys::ENTER);
    assert!(
        host.expect("ABBR-EXPANDED-OK", Duration::from_secs(8)),
        "(cox-1a) Enter with nothing selected did not reach the predecessor: {}",
        host.window_tail()
    );
    host.sync_prompt(Duration::from_secs(5));

    assert_listing_selection_and_confirm(&mut host, "(cox-1b)");
}

#[test]
fn a_pre_redraw_hook_above_zrush_keeps_its_own_highlights() {
    let mut host = Host::boot_with_doubles("", ZSYH_DOUBLE);

    let foreign = foreign_highlights_for_a_typed_buffer(&mut host, "(cox-2a)");
    assert!(
        foreign.iter().any(|entry| entry.contains(FOREIGN_HL)),
        "(cox-2a) the hook's own entry never reached region_highlight: {foreign:?}"
    );

    // With a listing up and a selection made, both sides' entries share the
    // array: zrush's own (memo=zrush from 5.9, its ledger below that) and the
    // hook's, neither clobbering the other.
    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al");
    host.assert_log_grows("select: start", &[keys::DOWN], "(cox-2b)");
    let mine = host.zrush_highlights("(cox-2b)");
    let all = host.all_highlights("(cox-2b)");
    let foreign: Vec<&String> = all.iter().filter(|entry| !mine.contains(entry)).collect();
    assert!(
        !mine.is_empty() && foreign.iter().any(|entry| entry.contains(FOREIGN_HL)),
        "(cox-2b) entries did not coexist: mine={mine:?} all={all:?}"
    );
    assert!(
        !host.has_memo() || mine.iter().all(|entry| entry.contains("memo=zrush")),
        "(cox-2b) zrush's own entries are not memo-tagged on zsh >=5.9: {mine:?}"
    );
    host.clear_line();

    assert_listing_selection_and_confirm(&mut host, "(cox-2c)");
}

#[test]
fn a_wrapper_above_zrush_survives_re_source_and_keybind_reapply() {
    let mut host = Host::boot_with_doubles("", ZSYH_DOUBLE);

    // Re-sourcing rebuilds zrush's transport and registrations while a third
    // party sits above them; the layers above must stay in the chain.
    host.send_line("source <($ZRUSH_REAL_BIN init zsh)");
    host.sync_prompt(Duration::from_secs(10));
    let foreign = foreign_highlights_for_a_typed_buffer(&mut host, "(cox-3a)");
    assert!(
        foreign.iter().any(|entry| entry.contains(FOREIGN_HL)),
        "(cox-3a) the pre-redraw hook was lost across a zrush re-source: {foreign:?}"
    );
    assert_listing_selection_and_confirm(&mut host, "(cox-3b)");

    // A config reload reapplies the binding set. With a third-party wrapper
    // present it must layer rather than overwrite (behavior.md 「プラグイン共存」).
    host.send_line("_zrush_apply_keybinds");
    host.sync_prompt(Duration::from_secs(5));
    assert_listing_selection_and_confirm(&mut host, "(cox-3c)");
}

#[test]
fn zrush_between_a_predecessor_and_a_wrapper_keeps_both() {
    let mut host = Host::boot_with_doubles(ABBR_DOUBLE, ZSYH_DOUBLE);

    assert_listing_selection_and_confirm(&mut host, "(cox-4a)");

    host.send_keys("zzz");
    host.drain(Duration::from_millis(500));
    host.send_keys(keys::ENTER);
    assert!(
        host.expect("ABBR-EXPANDED-OK", Duration::from_secs(8)),
        "(cox-4b) the predecessor stopped receiving Enter with a wrapper above zrush: {}",
        host.window_tail()
    );
    host.sync_prompt(Duration::from_secs(5));

    let foreign = foreign_highlights_for_a_typed_buffer(&mut host, "(cox-4c)");
    assert!(
        foreign.iter().any(|entry| entry.contains(FOREIGN_HL)),
        "(cox-4c) the wrapper's highlights were lost with all three layers loaded: {foreign:?}"
    );
}

#[test]
fn capture_tolerates_a_compadd_wrapper_without_disturbing_the_parent_shell() {
    let mut host = Host::boot_with_doubles(COMPADD_DOUBLE, "");

    host.send_keys_wait_plan(PlanShape::Nonempty, "ls fx/basic/al");
    let post = host.postdisplay("(cox-5a)");
    assert!(
        post.contains("alpha.txt") && post.contains("alsoalpha.txt"),
        "(cox-5a) a third-party compadd wrapper broke candidate capture: {post:?}"
    );
    host.clear_line();

    // The fork removes the wrapper only inside itself: the interactive shell
    // still owns its own function, uncalled by the capture that just ran.
    host.send_line("print WRAPPER=${+functions[compadd]} CALLS=$_zrt_double_compadd_calls");
    assert!(
        host.expect("WRAPPER=1 CALLS=0", Duration::from_secs(5)),
        "(cox-5b) the fork's compadd handling leaked into the parent shell: {}",
        host.window_tail()
    );
}
