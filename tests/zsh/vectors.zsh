#!/bin/zsh -f
# Golden-vector runner for the zsh-side plan decoder (_zrush_parse_plan).
#
# Usage:
#   zsh -f tests/zsh/vectors.zsh
#     No arguments, no pty, no terminal. The zrush binary is NOT needed: this
#     runner never starts a process, it only sources zsh/zrush.zsh with
#     ZRUSH_NO_INIT=1 (the test seam at the end of that file) and calls
#     _zrush_parse_plan directly on bytes read from tests/vectors/.
#     $HOME and $XDG_CONFIG_HOME are redirected to a fresh mktemp directory,
#     so the real ~/.zshrc, shell history and ~/.config/zrush are untouched.
#
# Scope: tests/vectors/ fixes the `zrush plan` wire format (see its README and
# docs/internal/contracts/cli-protocol.md). `cargo test` checks it against the
# Rust serializer and the Rust reference parser; this runner checks the same
# corpus against the independent hand-written zsh decoder:
#   - plan/<name>/expected.bin must parse, and the _zrush_plan_* state must
#     re-serialize to exactly those bytes (a decode/encode round trip).
#   - reject-plan/<name>/plan.bin must be rejected (return 1).
#
# Unlike driver.zsh (a zle/compsys end-to-end smoke test over zpty), nothing
# here touches zle, so a failure points at the decoder itself.
emulate -L zsh
setopt extended_glob

typeset -g HERE=${${(%):-%N}:A:h}
typeset -g REPO=${HERE:h:h}
typeset -g VECTORS=$REPO/tests/vectors

typeset -gi PASS=0 FAIL=0
out() { print -r -u2 -- "$@" }
ok()  { out "PASS: $1"; (( ++PASS )) }
ng()  { out "FAIL: $1"; (( ++FAIL )) }

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-vectors.XXXXXX)
export HOME=$WORK/home             # isolated; never the real home
export XDG_CONFIG_HOME=$WORK/xdg   # isolated; never the real ~/.config/zrush
export HISTFILE=$WORK/histfile     # nothing writes history, but never the real one either
unset ZDOTDIR
mkdir -p $HOME $XDG_CONFIG_HOME

# Render a byte string with control bytes escaped, so failures are readable.
# nomultibyte makes ${#s} a byte count and $s[i] a single byte.
dump_bytes() {  # $1=byte string -> REPLY
  emulate -L zsh
  setopt nomultibyte
  local s=$1 o= c
  local -i i b
  for (( i = 1; i <= $#s; i++ )); do
    c=$s[i]
    case $c in
      $'\0') o+='\0' ;;
      $'\n') o+='\n' ;;
      $'\r') o+='\r' ;;
      $'\t') o+='\t' ;;
      '\')   o+='\\' ;;
      *)
        b=$(( #c ))
        if (( b >= 32 && b <= 126 )); then
          o+=$c
        else
          o+='\x'${(L)${(l:2::0:)$(([##16]b))}}
        fi
        ;;
    esac
  done
  typeset -g REPLY=$o
}

dump_file() {  # $1=path -> REPLY
  dump_bytes "$(<$1)"
}

# Re-serialize the parsed _zrush_plan_* state back into plan bytes, following
# the field order of cli-protocol.md "stdout(描画プラン)".
# Fails (return 1, reason in REPLY) when _zrush_plan_text does not split back
# into exactly L rows -- that split is only reversible because display rows are
# guaranteed to contain no newline, so checking it tests that guarantee too.
reserialize_plan() {  # -> REPLY=bytes, or return 1 with REPLY=reason
  emulate -L zsh
  local -a rows=()
  if (( _zrush_plan_nlines > 0 )); then
    rows=( "${(@ps:\n:)_zrush_plan_text}" )
    if (( $#rows != _zrush_plan_nlines )); then
      typeset -g REPLY="display text splits into $#rows rows, expected L=$_zrush_plan_nlines"
      return 1
    fi
  elif [[ -n $_zrush_plan_text ]]; then
    typeset -g REPLY="L=0 but display text is non-empty"
    return 1
  fi

  local o= field
  for field in \
    "$_zrush_plan_cp" "$_zrush_plan_nlines" "$_zrush_plan_npos" \
    "${(@)rows}" "$#_zrush_plan_hl" \
    "${(@)_zrush_plan_hl}" "${(@)_zrush_plan_cells}" \
    "${(@)_zrush_plan_nav}" "${(@)_zrush_plan_insert}"
  do
    o+="$field"$'\0'
  done
  typeset -g REPLY=$o
  return 0
}

{
  typeset -g ZRUSH_NO_INIT=1
  source $REPO/zsh/zrush.zsh || { out "FATAL: cannot source zrush.zsh"; exit 1 }
  unset ZRUSH_NO_INIT
  (( $+functions[_zrush_parse_plan] )) || { out "FATAL: _zrush_parse_plan undefined after source"; exit 1 }
  (( _zrush_enabled )) && { out "FATAL: ZRUSH_NO_INIT did not suppress initialization"; exit 1 }

  # ---------------- Accept + round trip ----------------
  typeset -a golden=( $VECTORS/plan/*/expected.bin(N) )
  (( $#golden )) || { out "FATAL: no plan vectors under $VECTORS/plan"; exit 1 }

  local g name expected actual REPLY
  for g in "${(@)golden}"; do
    name=${${g:h}:t}
    expected=$(<$g)
    if ! _zrush_parse_plan "$expected"; then
      dump_file $g
      ng "plan/$name: _zrush_parse_plan rejected a golden plan: $REPLY"
      continue
    fi
    if ! reserialize_plan; then
      ng "plan/$name: cannot re-serialize the parsed state: $REPLY"
      continue
    fi
    actual=$REPLY
    print -rn -- "$actual" >| $WORK/actual.bin
    if cmp -s $g $WORK/actual.bin; then
      ok "plan/$name: parses and round-trips byte for byte"
    else
      dump_bytes "$expected"; local want=$REPLY
      dump_bytes "$actual";   local got=$REPLY
      ng "plan/$name: round trip differs
      expected: $want
      actual:   $got"
    fi
  done

  # ---------------- Reject ----------------
  typeset -a bad=( $VECTORS/reject-plan/*/plan.bin(N) )
  (( $#bad )) || { out "FATAL: no reject-plan vectors under $VECTORS/reject-plan"; exit 1 }

  for g in "${(@)bad}"; do
    name=${${g:h}:t}
    if _zrush_parse_plan "$(<$g)"; then
      dump_file $g
      ng "reject-plan/$name: _zrush_parse_plan accepted a malformed plan: $REPLY"
    else
      ok "reject-plan/$name: rejected"
    fi
  done

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  [[ -n $WORK && $WORK == */zrush-vectors.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
