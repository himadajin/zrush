#!/bin/zsh -f
# Golden-vector runner for the two zsh-side halves of the wire protocol:
# the capture encoder (_zrush_encode_batch) and the plan decoder
# (_zrush_parse_plan).
#
# Usage:
#   zsh -f tests/zsh/vectors.zsh
#     No arguments, no pty, no terminal. The zrush binary is NOT needed: this
#     runner never starts a process, it only sources zsh/zrush.zsh with
#     ZRUSH_NO_INIT=1 (the test seam at the end of that file) and calls those
#     two functions directly on bytes read from tests/vectors/.
#     $HOME and $XDG_CONFIG_HOME are redirected to a fresh mktemp directory,
#     so the real ~/.zshrc, shell history and ~/.config/zrush are untouched.
#   UPDATE_GOLDEN=1 zsh -f tests/zsh/vectors.zsh
#     Regenerate encode/<name>/expected.bin from the current implementation.
#     Like the Rust runner, this deliberately fails and lists every file it
#     changed, so a regenerated golden cannot land unreviewed.
#
# Scope: tests/vectors/ fixes the `zrush plan` wire format in both directions
# (see its README and docs/internal/contracts/cli-protocol.md).
#   - encode/<name>/: compadd argv plus captured candidate arrays in,
#     expected.bin out. Fixes the sender-side guarantees that never appear in
#     Rust output and so cannot be covered by plan/ vectors.
#   - plan/<name>/expected.bin must parse, and the _zrush_plan_* state must
#     re-serialize to exactly those bytes (a decode/encode round trip).
#     `cargo test` checks the same corpus against the Rust serializer and the
#     Rust reference parser, so both sides are held to one set of bytes.
#   - reject-plan/<name>/plan.bin must be rejected (return 1).
#
# Unlike driver.zsh (a zle/compsys end-to-end smoke test over zpty), nothing
# here touches zle, so a failure points at the encoder or decoder itself.
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

# ---------------- encode/ ----------------
# Read one NUL-terminated list file (encode/ inputs are arbitrary byte strings,
# so they cannot use the line-per-argument form plan/args uses).
read_nul() {  # $1=path -> reply=(elements), or return 1 with REPLY=reason
  emulate -L zsh
  typeset -ga reply=()
  [[ -e $1 ]] || { typeset -g REPLY="missing ${1:t}"; return 1 }
  local s=$(<$1)
  [[ -z $s ]] && return 0
  [[ $s == *$'\0' ]] || { typeset -g REPLY="${1:t} is not NUL-terminated"; return 1 }
  reply=( "${(@0)${s%$'\0'}}" )
  return 0
}

# Apply the vector's environment to this scope only -- IPREFIX, HOME and any
# parameter the -f real-directory expansion reads are restored on return -- and
# call the encoder.
encode_call() {  # $1=env file (may be absent), $2.. = compadd argv -> REPLY
  emulate -L zsh
  local envfile=$1; shift
  local IPREFIX=
  local line
  if [[ -e $envfile ]]; then
    for line in "${(@f)$(<$envfile)}"; do
      [[ -z $line ]] && continue
      [[ $line == *=* ]] || { typeset -g REPLY="env line without '=': $line"; return 1 }
      typeset -- "$line"
    done
  fi
  _zrush_encode_batch "$@"
}

encode_vector() {  # $1=vector directory -> REPLY=wire bytes, or return 1 with REPLY=reason
  emulate -L zsh
  local dir=$1
  read_nul $dir/argv.bin || return 1
  local -a vargv=( "${(@)reply}" )
  read_nul $dir/hits.bin || return 1
  typeset -ga _zrush_enc_hits=( "${(@)reply}" )
  read_nul $dir/dscr.bin || return 1
  typeset -ga _zrush_enc_dscr=( "${(@)reply}" )
  encode_call $dir/env "${(@)vargv}"
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
  (( $+functions[_zrush_encode_batch] )) || { out "FATAL: _zrush_encode_batch undefined after source"; exit 1 }
  (( $+functions[_zrush_history_payload] )) || { out "FATAL: _zrush_history_payload undefined after source"; exit 1 }
  (( _zrush_enabled )) && { out "FATAL: ZRUSH_NO_INIT did not suppress initialization"; exit 1 }

  # ---------------- History payload sender ----------------
  # `print -s` leaves its newest entry as the current event until another
  # entry is pushed, so the final sentinel makes "newest" visible without
  # itself entering the `$history` view used by the payload function.
  print -sr -- 'oldest'
  print -sr -- 'dup'
  print -sr -- 'dup'
  print -sr -- $'bad\1line'
  print -sr -- 'newest'
  print -sr -- 'sentinel-not-visible'
  ZRUSH_CFG_HISTORY_LIMIT=100
  _zrush_history_payload
  local history_payload=$REPLY
  local -a history_records=( "${(@0)${history_payload%$'\0'}}" )
  local -i history_ok=1 dup_count=0 newest_count=0 oldest_count=0
  local record line event
  [[ $history_records[1] == b$'\1' ]] || history_ok=0
  for record in "${(@)history_records[2,-1]}"; do
    line=${record%%$'\2'*}
    event=${record#*$'\2'}
    [[ $line == w$'\1'* && $event == n$'\1'<-> ]] \
      || { history_ok=0; continue }
    line=${line#w$'\1'}
    event=${event#n$'\1'}
    [[ $history[$event] == "$line" ]] || history_ok=0
    [[ $line == dup ]] && (( ++dup_count ))
    [[ $line == newest ]] && (( ++newest_count ))
    [[ $line == oldest ]] && (( ++oldest_count ))
    [[ $line == *bad* ]] && history_ok=0
  done
  if (( history_ok && dup_count == 1 && newest_count == 1 && oldest_count == 1 )); then
    ok "history payload: pairs each distinct line with its real newest event number"
  else
    dump_bytes "$history_payload"
    ng "history payload: unexpected records: $REPLY"
  fi

  # ---------------- Highlight role application ----------------
  BUFFER=
  region_highlight=()
  _zrush_rh=()
  _zrush_rh_sel=
  _zrush_hl_memo=
  _zrush_plan_nlines=1
  _zrush_plan_hl=( 'history-number 1 4 1' 'history-number 2 13 2' )
  _zrush_plan_cells=( '0 10' '11 10' )
  _zrush_selected=1
  ZRUSH_CFG_HL_SELECTED=standout
  ZRUSH_CFG_HL_HISTORY_NUMBER=faint
  _zrush_apply_highlights
  if [[ "${(j:|:)_zrush_rh}" == '14 16 faint|1 11 standout' \
        && $_zrush_rh_sel == '1 11 standout' ]]; then
    ok "history-number highlight: selected cell wins and other numbers use faint"
  else
    ng "history-number highlight: ledger=${(qqqq)_zrush_rh} selected=${(qqqq)_zrush_rh_sel}"
  fi
  _zrush_rh_clear
  _zrush_selected=0
  ZRUSH_CFG_HL_HISTORY_NUMBER=
  _zrush_apply_highlights
  if (( $#_zrush_rh == 0 )); then
    ok "history-number highlight: an empty spec emits no region_highlight entry"
  else
    ng "history-number highlight: empty spec left ledger=${(qqqq)_zrush_rh}"
  fi
  unset REPLY

  # ---------------- Encode ----------------
  typeset -a inputs=( $VECTORS/encode/*/argv.bin(N) )
  (( $#inputs )) || { out "FATAL: no encode vectors under $VECTORS/encode"; exit 1 }
  typeset -a updated=()

  local g v dir goldenfile name expected actual REPLY
  for v in "${(@)inputs}"; do
    dir=${v:h}
    name=${dir:t}
    if ! encode_vector $dir; then
      ng "encode/$name: $REPLY"
      continue
    fi
    actual=$REPLY
    goldenfile=$dir/expected.bin
    print -rn -- "$actual" >| $WORK/actual.bin
    if [[ $UPDATE_GOLDEN == 1 ]]; then
      if cmp -s $WORK/actual.bin $goldenfile 2>/dev/null; then
        ok "encode/$name: golden unchanged"
      else
        cp $WORK/actual.bin $goldenfile
        updated+=( "encode/$name/expected.bin" )
      fi
      continue
    fi
    if [[ ! -e $goldenfile ]]; then
      ng "encode/$name: expected.bin missing (run UPDATE_GOLDEN=1 and review the result)"
      continue
    fi
    if cmp -s $goldenfile $WORK/actual.bin; then
      ok "encode/$name: encodes to the golden bytes"
    else
      dump_file $goldenfile; local want=$REPLY
      dump_bytes "$actual"; local got=$REPLY
      ng "encode/$name: encoded bytes differ
      expected: $want
      actual:   $got"
    fi
  done

  if (( $#updated )); then
    ng "updated golden files (review these diffs against cli-protocol.md, then rerun):
      ${(pj:\n      :)updated}"
  fi

  # ---------------- Encoder output reused as a decoder input ----------------
  # One byte string spans both directions: what the encoder emits for
  # encode/shared-tags-all is exactly what plan/encoder-chain feeds `zrush plan`.
  if cmp -s $VECTORS/encode/shared-tags-all/expected.bin $VECTORS/plan/encoder-chain/payload.bin; then
    ok "chain: plan/encoder-chain/payload.bin is encode/shared-tags-all/expected.bin"
  else
    ng "chain: plan/encoder-chain/payload.bin no longer matches encode/shared-tags-all/expected.bin"
  fi

  # ---------------- Accept + round trip ----------------
  typeset -a golden=( $VECTORS/plan/*/expected.bin(N) )
  (( $#golden )) || { out "FATAL: no plan vectors under $VECTORS/plan"; exit 1 }

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
