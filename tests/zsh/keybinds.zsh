#!/bin/zsh -f
# Headless regression tests for dispatch-widget ownership across config reload
# and re-source. No worker, pty, interactive ZLE session, or real config is used.
emulate -L zsh
setopt extendedglob typesetsilent

typeset -g HERE=${${(%):-%N}:A:h}
typeset -g REPO=${HERE:h:h}
typeset -gi PASS=0 FAIL=0
typeset -ga WHY=()

out() { print -r -u2 -- "$@" }
ok() { out "PASS: $1"; (( ++PASS )) }
ng() { out "FAIL: $1"; (( ++FAIL )) }
eq() { [[ $2 == "$3" ]] || WHY+=( "$1: got ${(qqq)2}, want ${(qqq)3}" ) }
note() { WHY+=( "$1" ) }
verdict() {
  if (( $#WHY == 0 )); then
    ok "$1"
  else
    ng "$1"
    local why
    for why in "${(@)WHY}"; do out "      - $why"; done
  fi
  WHY=()
}

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-keybinds.XXXXXX)
export HOME=$WORK/home XDG_CONFIG_HOME=$WORK/xdg HISTFILE=$WORK/history
mkdir -p $HOME $XDG_CONFIG_HOME
unset ZDOTDIR
TRAPEXIT() { command rm -rf -- $WORK }

typeset -g ZRUSH_NO_INIT=1
source $REPO/zsh/zrush.zsh || { out "FATAL: cannot source zrush.zsh"; exit 1 }

typeset -ga DSP_FUNCTIONS=() DSP_WIDGETS=()
dispatch_snapshot() {
  DSP_FUNCTIONS=( ${(M)${(k)functions}:#_zrush-dsp-*} )
  DSP_WIDGETS=( ${(M)${(k)widgets}:#_zrush-dsp-*} )
}

bound_for() {  # $1=key sequence in bindkey notation -> REPLY=dispatcher
  emulate -L zsh
  local target=$1 k v
  typeset -g REPLY=
  for k v in "${(@kv)_zrush_bound}"; do
    if [[ $k == $target ]]; then
      REPLY=$v
      return 0
    fi
  done
  return 1
}

key_widget() {  # $1=key sequence in bindkey notation -> REPLY=current widget
  typeset -g REPLY=${${(z)"$(builtin bindkey -M main -- "$1" 2>/dev/null)"}[2]:-}
}

# Moving one action repeatedly must release every direct-owned superseded
# dispatcher. Tab remains the second active/bound dispatcher throughout.
typeset -ga ZRUSH_CFG_KEYBINDS=( confirm 'seq:^X^A' )
_zrush_apply_keybinds
bound_for '^X^A' || note "initial ^X^A binding missing"
typeset -g FIRST_DISPATCH=$REPLY
key_widget '^X^B'
typeset -g B_PREDECESSOR=$REPLY
integer i
for (( i = 0; i < 100; ++i )); do
  ZRUSH_CFG_KEYBINDS=( confirm 'seq:^X^B' ); _zrush_apply_keybinds
  ZRUSH_CFG_KEYBINDS=( confirm 'seq:^X^A' ); _zrush_apply_keybinds
done
dispatch_snapshot
eq "move function count" $#DSP_FUNCTIONS 2
eq "move widget count" $#DSP_WIDGETS 2
eq "move binding count" $#_zrush_bound 2
eq "move active count" $#_zrush_active_dsp 2
eq "move predecessor-ledger count" $#_zrush_dsp_prev 2
(( !$+functions[$FIRST_DISPATCH] )) || note "first moved function remains"
(( !$+widgets[$FIRST_DISPATCH] )) || note "first moved widget remains"
key_widget '^X^B'; eq "removed key restored" $REPLY $B_PREDECESSOR
verdict "moving a key releases superseded dispatch registrations"

# Reapplying the same sequence, including changing only its action, must keep
# the same dispatcher rather than release and recreate it.
bound_for '^X^A' || note "stable ^X^A binding missing"
typeset -g STABLE_DISPATCH=$REPLY
for (( i = 0; i < 100; ++i )); do
  ZRUSH_CFG_KEYBINDS=( dismiss 'seq:^X^A' ); _zrush_apply_keybinds
  ZRUSH_CFG_KEYBINDS=( confirm 'seq:^X^A' ); _zrush_apply_keybinds
done
bound_for '^X^A' || note "post-reapply ^X^A binding missing"
eq "same-sequence dispatcher" $REPLY $STABLE_DISPATCH
dispatch_snapshot
eq "same-sequence function count" $#DSP_FUNCTIONS 2
eq "same-sequence widget count" $#DSP_WIDGETS 2
verdict "an unchanged sequence retains its dispatch registration"

# A successful re-source restores direct-owned keys before rebuilding. The
# serial remains monotonic, but only the new generation's registrations live.
for (( i = 0; i < 20; ++i )); do
  source $REPO/zsh/zrush.zsh || note "re-source $i failed"
  ZRUSH_CFG_KEYBINDS=( confirm 'seq:^X^A' )
  _zrush_apply_keybinds
done
dispatch_snapshot
eq "re-source function count" $#DSP_FUNCTIONS 2
eq "re-source widget count" $#DSP_WIDGETS 2
eq "re-source binding count" $#_zrush_bound 2
eq "re-source active count" $#_zrush_active_dsp 2
eq "re-source predecessor-ledger count" $#_zrush_dsp_prev 2
verdict "re-source releases the previous direct-owned generation"

# Model zsh-syntax-highlighting's in-place wrapper: it moves the original
# function behind a backup widget, then replaces our widget name with its own
# function. This old layer is live predecessor state and must be retained.
bound_for '^X^A' || note "pre-wrapper ^X^A binding missing"
typeset -g WRAPPED_DISPATCH=$REPLY
typeset -g BACKUP_WIDGET=_zrt-orig-$WRAPPED_DISPATCH
typeset -g WRAPPER_FUNCTION=_zrt-wrap-$WRAPPED_DISPATCH
zle -N $BACKUP_WIDGET $WRAPPED_DISPATCH
functions[$WRAPPER_FUNCTION]="zle ${(q)BACKUP_WIDGET} -w"
zle -N $WRAPPED_DISPATCH $WRAPPER_FUNCTION
_zrush_apply_keybinds
bound_for '^X^A' || note "wrapped reapply ^X^A binding missing"
typeset -g LAYERED_DISPATCH=$REPLY
[[ $LAYERED_DISPATCH != $WRAPPED_DISPATCH ]] || note "wrapper did not force a new layer"
eq "layered predecessor" ${_zrush_dsp_prev[$LAYERED_DISPATCH]:-} $WRAPPED_DISPATCH
(( $+functions[$WRAPPED_DISPATCH] )) || note "wrapped predecessor function removed"
[[ ${widgets[$WRAPPED_DISPATCH]:-} == user:$WRAPPER_FUNCTION ]] ||
  note "third-party wrapper widget replaced"

# Removing the action releases only the direct outer layer and restores the
# wrapped predecessor. Repeated re-source then stays bounded at that retained
# layer plus the two current dispatchers (the action and fixed Tab hook).
ZRUSH_CFG_KEYBINDS=()
_zrush_apply_keybinds
key_widget '^X^A'; eq "wrapped predecessor restored" $REPLY $WRAPPED_DISPATCH
(( !$+functions[$LAYERED_DISPATCH] )) || note "outer layered function remains"
(( !$+widgets[$LAYERED_DISPATCH] )) || note "outer layered widget remains"
(( $+functions[$WRAPPED_DISPATCH] )) || note "wrapped function removed with outer layer"
[[ ${widgets[$WRAPPED_DISPATCH]:-} == user:$WRAPPER_FUNCTION ]] ||
  note "wrapped widget removed with outer layer"

ZRUSH_CFG_KEYBINDS=( confirm 'seq:^X^A' )
_zrush_apply_keybinds
for (( i = 0; i < 20; ++i )); do
  source $REPO/zsh/zrush.zsh || note "wrapped re-source $i failed"
  ZRUSH_CFG_KEYBINDS=( confirm 'seq:^X^A' )
  _zrush_apply_keybinds
done
bound_for '^X^A' || note "post-wrapper-resource ^X^A binding missing"
typeset -g CURRENT_DISPATCH=$REPLY
eq "post-re-source wrapped predecessor" ${_zrush_dsp_prev[$CURRENT_DISPATCH]:-} $WRAPPED_DISPATCH
dispatch_snapshot
eq "wrapped re-source function count" $#DSP_FUNCTIONS 3
eq "wrapped re-source widget count" $#DSP_WIDGETS 3
eq "wrapped re-source active count" $#_zrush_active_dsp 2
(( $+functions[$WRAPPED_DISPATCH] )) || note "wrapped predecessor function lost"
[[ ${widgets[$WRAPPED_DISPATCH]:-} == user:$WRAPPER_FUNCTION ]] ||
  note "wrapped predecessor widget lost"
verdict "third-party wrapper layers are retained without unbounded growth"

out "keybinds: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
