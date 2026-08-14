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
#     Regenerate encode/<name>/expected from the current implementation.
#     Like the Rust runner, this deliberately fails and lists every file it
#     changed, so a regenerated golden cannot land unreviewed.
#
# Scope: tests/vectors/ fixes candidate encoding and render-plan decoding
# (see its README and docs/internal/contracts/cli-protocol.md).
#   - every corpus file must be canonical escaped text, so the codec below
#     cannot silently substitute one byte string for another.
#   - encode/<name>/: compadd argv plus captured candidate arrays in,
#     expected out. Fixes the sender-side guarantees that never appear in
#     Rust output and so cannot be covered by plan/ vectors.
#   - plan/<name>/expected must parse, and the _zrush_plan_* state must
#     re-serialize to exactly those bytes (a decode/encode round trip).
#     `cargo test` checks the same corpus against the Rust serializer and the
#     Rust reference parser, so both sides are held to one set of bytes.
#   - reject-plan/<name>/plan must be rejected (return 1).
#
# Unlike driver.zsh (a zle/compsys end-to-end smoke test over zpty), nothing
# here touches zle, so a failure points at the encoder or decoder itself.
emulate -L zsh
setopt extended_glob typeset_silent

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

# ---------------- corpus text format ----------------
# Every file under tests/vectors/ stores its byte string as escaped text; a
# line break is layout, never data (tests/vectors/README.md).
# nomultibyte makes ${#s} a byte count and $s[i] a single byte.
enc_bytes() {  # $1=byte string -> REPLY=text
  emulate -L zsh
  setopt nomultibyte
  local s=$1 o= c
  local -i i b
  for (( i = 1; i <= $#s; i++ )); do
    c=$s[i]
    b=$(( #c ))
    case $b in
      0)  o+='\0'$'\n' ;;
      1)  o+='\1' ;;
      2)  o+='\2'$'\n' ;;
      9)  o+='\t' ;;
      10) o+='\n' ;;
      13) o+='\r' ;;
      92) o+='\\' ;;
      *)
        if (( b >= 32 && b <= 126 )); then
          o+=$c
        else
          o+='\x'${(L)${(l:2::0:)$(([##16]b))}}
        fi
        ;;
    esac
  done
  [[ -z $o || $o == *$'\n' ]] || o+=$'\n'
  typeset -g REPLY=$o
}

dec_bytes() {  # $1=text -> REPLY=byte string, or return 1 with REPLY=reason
  emulate -L zsh
  setopt nomultibyte
  local t=$1 o= c n h
  local -i i b
  for (( i = 1; i <= $#t; i++ )); do
    c=$t[i]
    b=$(( #c ))
    (( b == 10 )) && continue
    if (( b != 92 )); then
      if (( b < 32 || b > 126 )); then
        typeset -g REPLY="raw byte outside the escape alphabet at offset $i"
        return 1
      fi
      o+=$c
      continue
    fi
    (( ++i ))
    n=$t[i]
    case $n in
      0) o+=$'\0' ;;
      1) o+=$'\1' ;;
      2) o+=$'\2' ;;
      n) o+=$'\n' ;;
      r) o+=$'\r' ;;
      t) o+=$'\t' ;;
      x) h=$t[i+1,i+2]; (( i += 2 ))
         if [[ $h != [0-9a-fA-F][0-9a-fA-F] ]]; then
           typeset -g REPLY="bad \\x escape at offset $i"
           return 1
         fi
         o+=${(#)$((16#$h))} ;;
      '') typeset -g REPLY='trailing backslash'; return 1 ;;
      *)
        if (( $(( #n )) == 92 )); then
          o+='\'
        else
          typeset -g REPLY="unknown escape \\$n at offset $i"
          return 1
        fi
        ;;
    esac
  done
  typeset -g REPLY=$o
  return 0
}

# $(<file) strips every trailing newline, which would hide a non-canonical
# file from the corpus check below; read to the first NUL instead, and the
# corpus (being text) has none.
read_text() {  # $1=path -> REPLY=exact file contents, or return 1 with REPLY=reason
  emulate -L zsh
  [[ -e $1 ]] || { typeset -g REPLY="missing ${1:t}"; return 1 }
  typeset -g REPLY=
  IFS= read -rd '' REPLY < $1
  return 0
}

read_vector() {  # $1=path -> REPLY=byte string, or return 1 with REPLY=reason
  emulate -L zsh
  read_text $1 || return 1
  dec_bytes "$REPLY" || { typeset -g REPLY="${1:t}: $REPLY"; return 1 }
  return 0
}

# Single-line rendering for failure messages. Layout newlines are the only
# literal newlines enc_bytes emits, so dropping them collapses the escaped
# form onto one line without touching the escapes themselves.
dump_bytes() {  # $1=byte string -> REPLY
  emulate -L zsh
  enc_bytes "$1"
  typeset -g REPLY=${REPLY//$'\n'/}
}

# ---------------- encode/ ----------------
# Read one NUL-terminated list file.
read_nul() {  # $1=path -> reply=(elements), or return 1 with REPLY=reason
  emulate -L zsh
  typeset -ga reply=()
  read_vector $1 || return 1
  local s=$REPLY
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
  read_nul $dir/argv || return 1
  local -a vargv=( "${(@)reply}" )
  read_nul $dir/hits || return 1
  typeset -ga _zrush_enc_hits=( "${(@)reply}" )
  read_nul $dir/dscr || return 1
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

  # ---------------- Internal fd close ----------------
  # Preserve duplicates of the runner's stdio so the helper contract can be
  # checked without assuming those descriptors point at a terminal.
  local saved_fd_log=${ZRUSH_LOG:-}
  ZRUSH_LOG=$WORK/fd-close.log
  local -i saved_stdin saved_stdout saved_stderr read_fd write_fd
  exec {saved_stdin}<&0
  exec {saved_stdout}>&1
  exec {saved_stderr}>&2
  exec {read_fd}< /dev/null
  exec {write_fd}> /dev/null

  _zrush_close_internal_fd $read_fd
  _zrush_close_internal_fd $read_fd
  _zrush_close_internal_fd $write_fd
  _zrush_close_internal_fd -1
  _zrush_close_internal_fd 0
  _zrush_close_internal_fd 1
  _zrush_close_internal_fd 2

  local fd_close_log=$(<$ZRUSH_LOG)
  if [[ ! -e /dev/fd/$read_fd && ! -e /dev/fd/$write_fd \
        && /dev/fd/0 -ef /dev/fd/$saved_stdin \
        && /dev/fd/1 -ef /dev/fd/$saved_stdout \
        && /dev/fd/2 -ef /dev/fd/$saved_stderr \
        && $fd_close_log == *"fd: close failed fd=$read_fd status="* \
        && $fd_close_log == *'fd: refusing to close reserved fd=0'* \
        && $fd_close_log == *'fd: refusing to close reserved fd=1'* \
        && $fd_close_log == *'fd: refusing to close reserved fd=2'* ]]; then
    ok "fd lifecycle: internal close is idempotent and preserves fd 0/1/2"
  else
    ng "fd lifecycle: close/open state, stdio target, or diagnostic mismatch"
  fi

  local -i exit_timer_fd exit_rfd exit_wfd
  exec {exit_timer_fd}< /dev/null
  exec {exit_rfd}< /dev/null
  exec {exit_wfd}> /dev/null
  _zrush_timer_fd=$exit_timer_fd _zrush_rfd=$exit_rfd _zrush_wfd=$exit_wfd
  _zrush_pty=
  _zrush_worker_rfd=-1 _zrush_worker_wfd=-1 _zrush_worker_control_wfd=-1
  _zrush_worker_ack_fd=-1 _zrush_worker_drain_fd=-1
  _zrush_zshexit
  if (( _zrush_timer_fd == -1 && _zrush_rfd == -1 && _zrush_wfd == -1 )) \
     && [[ ! -e /dev/fd/$exit_timer_fd && ! -e /dev/fd/$exit_rfd \
           && ! -e /dev/fd/$exit_wfd \
           && /dev/fd/0 -ef /dev/fd/$saved_stdin \
           && /dev/fd/1 -ef /dev/fd/$saved_stdout \
           && /dev/fd/2 -ef /dev/fd/$saved_stderr ]]; then
    ok "fd lifecycle: zshexit closes owned descriptors and preserves fd 0/1/2"
  else
    ng "fd lifecycle: zshexit close/open state or stdio target mismatch"
  fi
  _zrush_close_internal_fd $saved_stdin
  _zrush_close_internal_fd $saved_stdout
  _zrush_close_internal_fd $saved_stderr
  ZRUSH_LOG=$saved_fd_log

  # ---------------- Persistent-session framing ----------------
  # Exercise the same incremental loop as _zrush_worker_read without a process
  # or zle. Every byte boundary is tried, and two responses deliberately share
  # one stream so delivery cannot depend on read chunking.
  _zrush_encode_message ready 8
  local ready_frame=$REPLY
  _zrush_encode_message error 41 invalid-request
  local error_frame=$REPLY
  local response_stream=$ready_frame$error_frame
  local -i split framing_ok=1 st delivered
  local rx chunk message
  local -a got=()
  for (( split = 0; split <= $#response_stream; ++split )); do
    rx= got=() delivered=0
    for chunk in "${response_stream[1,split]}" "${response_stream[split+1,-1]}"; do
      rx+=$chunk
      while [[ -n $rx ]]; do
        _zrush_netstring_take "$rx"; st=$?
        if (( st == 0 )); then
          message=$REPLY rx=$REPLY_REST
          _zrush_decode_fields "$message" || { framing_ok=0; break 2 }
          got+=( "${(j:|:)reply}" )
          (( ++delivered ))
        elif (( st == 1 )); then
          break
        else
          framing_ok=0
          break 2
        fi
      done
    done
    [[ -z $rx && $delivered == 2 && $got[1] == 'ready|8' \
       && $got[2] == 'error|41|invalid-request' ]] || { framing_ok=0; break }
  done
  (( framing_ok )) \
    && ok "session framing: arbitrary response chunking and multiple frames" \
    || ng "session framing: split=$split delivered=$delivered rx=${(qqqq)rx} got=${(qqqq)got}"

  # A malformed later frame is fatal, but already-complete prefix frames must
  # have been surfaced first (the framing foundation's valid-prefix rule).
  rx=$response_stream'01:x,' got=() delivered=0 st=0
  while [[ -n $rx ]]; do
    _zrush_netstring_take "$rx"; st=$?
    if (( st == 0 )); then
      message=$REPLY rx=$REPLY_REST
      got+=( "$message" )
      (( ++delivered ))
    else
      break
    fi
  done
  if (( delivered == 2 && st == 2 )); then
    ok "session framing: valid prefix is delivered before later corruption"
  else
    ng "session framing: delivered=$delivered terminal-status=$st"
  fi

  # Length parsing stays lexical until the declaration is known to fit a zsh
  # integer. The maximum representable declaration is a valid (incomplete)
  # shape here; its successor, wider decimals, and leading-zero spellings are
  # malformed immediately rather than waiting forever for impossible bytes.
  _zrush_netstring_take '9223372036854775807:'; local -i max_length_st=$?
  _zrush_netstring_take '9223372036854775808:x,'; local -i overflow_length_st=$?
  _zrush_netstring_take '999999999999999999999999999999:x,'; local -i wide_length_st=$?
  _zrush_netstring_take '09223372036854775807:x,'; local -i leading_zero_st=$?
  if (( max_length_st == 1 && overflow_length_st == 2 \
        && wide_length_st == 2 && leading_zero_st == 2 )); then
    ok "session framing: representable maximum is incomplete; overflow/noncanonical lengths are malformed"
  else
    ng "session framing: length statuses max=$max_length_st overflow=$overflow_length_st wide=$wide_length_st leading-zero=$leading_zero_st"
  fi

  # The real reader must turn that malformed parser status into the fatal
  # outer-response path without attempting an OS read.
  local saved_session_fail=${functions[_zrush_worker_session_fail]}
  typeset -g _zrt_session_failure=
  functions[_zrush_worker_session_fail]='_zrt_session_failure=$1; return 0'
  _zrush_worker_rx='9223372036854775808:x,'
  _zrush_worker_read async; local -i overflow_reader_st=$?
  functions[_zrush_worker_session_fail]=$saved_session_fail
  if (( overflow_reader_st == 1 )) \
     && [[ $_zrt_session_failure == 'malformed outer response' ]]; then
    ok "session framing: overflow is fatal in the worker reader"
  else
    ng "session framing: overflow reader status=$overflow_reader_st failure=${_zrt_session_failure:-<none>}"
  fi
  unset _zrt_session_failure

  # A handshake alone is not a successful terminal response and therefore
  # must not reset the consecutive-session failure streak. A request-level
  # error is terminal, clears its pending request, and does reset the streak.
  _zrush_worker_ready=0 _zrush_worker_failures=1 _zrush_disabled=0 _zrush_enabled=1
  _zrush_netstring_take "$ready_frame"
  _zrush_worker_handle_message "$REPLY"
  local -i ready_kept_failures=$(( _zrush_worker_ready == 1 && _zrush_worker_failures == 1 ))
  typeset -gA _zrush_worker_pending=( 41 compsys )
  _zrush_current_request=0
  _zrush_netstring_take "$error_frame"
  _zrush_worker_handle_message "$REPLY"
  if (( ready_kept_failures && _zrush_worker_failures == 0 \
        && ! ${+_zrush_worker_pending[41]} && !_zrush_disabled )); then
    ok "worker lifecycle: handshake keeps failure streak; terminal error resets it"
  else
    ng "worker lifecycle: ready=$ready_kept_failures failures=$_zrush_worker_failures pending=${+_zrush_worker_pending[41]} disabled=$_zrush_disabled"
  fi

  # A well-formed stale success is consumed but must not replace the plan for
  # the currently relevant request.
  read_vector $VECTORS/plan/empty-stdin/expected \
    || { out "FATAL: $REPLY"; exit 1 }
  local stale_plan=$REPLY
  _zrush_worker_ready=1 _zrush_worker_failures=1 _zrush_disabled=0 _zrush_enabled=1
  typeset -gA _zrush_worker_pending=( 41 compsys )
  _zrush_current_request=42
  _zrush_plan_text=sentinel _zrush_plan_cp=sentinel-cp _zrush_plan_kind=history
  _zrush_plan_nlines=7 _zrush_plan_npos=0
  _zrush_plan_hl=() _zrush_plan_cells=() _zrush_plan_nav=() _zrush_plan_insert=()
  _zrush_encode_message ok 41 "$stale_plan"
  local stale_frame=$REPLY
  _zrush_netstring_take "$stale_frame"
  _zrush_worker_handle_message "$REPLY"
  if [[ $_zrush_plan_text == sentinel && $_zrush_plan_cp == sentinel-cp \
        && $_zrush_plan_kind == history ]] && (( _zrush_plan_nlines == 7 \
        && ! ${+_zrush_worker_pending[41]} && _zrush_worker_failures == 0 )); then
    ok "worker lifecycle: stale well-formed success is discarded"
  else
    ng "worker lifecycle: stale response changed current plan or remained pending"
  fi

  # A buffer/cursor change invalidates the old async request before debounce
  # assigns its successor. A Tab pressed in that window belongs to the newer
  # query: the delayed old response must leave it pending, while the successor
  # response may settle it normally.
  local saved_arm_timer=$functions[_zrush_arm_timer]
  local saved_settle_plan=$functions[_zrush_settle_plan]
  functions[_zrush_arm_timer]='return 0'
  typeset -gi _zrt_settle_calls=0
  functions[_zrush_settle_plan]='(( ++_zrt_settle_calls )); _zrush_tab_pending=0; return 0'
  _zrush_enabled=1 _zrush_disabled=0 _zrush_current_request=41
  _zrush_last_buffer=old _zrush_last_cursor=0
  BUFFER=new LBUFFER=new CURSOR=3
  _zrush_plan_kind=none _zrush_tab_pending=0 _zrush_selected=0
  ZRUSH_CFG_MIN_INPUT=0
  _zrush_line_pre_redraw
  local -i invalidated=$(( _zrush_current_request == 0 ))
  _zrush_tab_pending=1
  typeset -gA _zrush_worker_pending=( 41 compsys )
  _zrush_encode_message ok 41 "$stale_plan"
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"
  local -i old_stayed_stale=$(( _zrt_settle_calls == 0 && _zrush_tab_pending == 1 ))
  _zrush_current_request=42
  _zrush_worker_pending[42]=compsys
  _zrush_encode_message ok 42 "$stale_plan"
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"
  functions[_zrush_arm_timer]=$saved_arm_timer
  functions[_zrush_settle_plan]=$saved_settle_plan
  if (( invalidated && old_stayed_stale && _zrt_settle_calls == 1 \
        && _zrush_tab_pending == 0 )); then
    ok "worker lifecycle: buffer change makes old response stale; successor settles pending Tab"
  else
    ng "worker lifecycle: invalidated=$invalidated old-stale=$old_stayed_stale settles=$_zrt_settle_calls tab=$_zrush_tab_pending"
  fi
  unset _zrt_settle_calls

  # An explicit incompatible handshake opens the permanent shell-session
  # disable immediately; it is not counted as the first retryable failure.
  # Populate every active endpoint slot needed by a healthy stop. stdout is
  # already at EOF, so shutdown must raw-drain it before finalizing.
  zmodload zsh/system zsh/datetime || { out "FATAL: lifecycle modules"; exit 1 }
  _zrush_worker_ready=0 _zrush_worker_failures=0 _zrush_disabled=0 _zrush_enabled=1
  _zrush_worker_warned=0 _zrush_worker_stopping=0
  local -i mismatch_rfd mismatch_wfd mismatch_control_fd mismatch_drain_fd
  exec {mismatch_rfd}< /dev/null
  exec {mismatch_wfd}> /dev/null
  exec {mismatch_control_fd}> /dev/null
  exec {mismatch_drain_fd}< /dev/null
  _zrush_worker_rfd=$mismatch_rfd _zrush_worker_wfd=$mismatch_wfd
  _zrush_worker_control_wfd=$mismatch_control_fd
  _zrush_worker_ack_fd=-1 _zrush_worker_drain_fd=$mismatch_drain_fd
  _zrush_encode_message incompatible 7
  local mismatch_frame=$REPLY
  _zrush_netstring_take "$mismatch_frame"
  _zrush_worker_handle_message "$REPLY" 2>/dev/null
  if (( _zrush_disabled && !_zrush_enabled && _zrush_worker_failures == 0 \
        && _zrush_worker_warned && _zrush_worker_rfd == -1 && _zrush_worker_wfd == -1 \
        && _zrush_worker_control_wfd == -1 && _zrush_worker_ack_fd == -1 \
        && _zrush_worker_drain_fd == -1 )) \
     && [[ ! -e /dev/fd/$mismatch_rfd && ! -e /dev/fd/$mismatch_wfd \
           && ! -e /dev/fd/$mismatch_control_fd \
           && ! -e /dev/fd/$mismatch_drain_fd ]]; then
    ok "worker lifecycle: protocol mismatch disables immediately and closes every transport fd"
  else
    ng "worker lifecycle: mismatch state enabled=$_zrush_enabled disabled=$_zrush_disabled failures=$_zrush_worker_failures warned=$_zrush_worker_warned fds=$_zrush_worker_rfd,$_zrush_worker_wfd,$_zrush_worker_control_wfd,$_zrush_worker_ack_fd,$_zrush_worker_drain_fd"
  fi
  _zrush_disabled=0 _zrush_enabled=0 _zrush_worker_warned=0

  # Two failed sessions without an intervening terminal response open the
  # circuit breaker. The user-facing warning latch remains set after the first
  # failure, while detailed reasons continue to be logged for both sessions.
  local saved_log=${ZRUSH_LOG:-}
  ZRUSH_LOG=$WORK/lifecycle.log
  _zrush_worker_failures=0 _zrush_worker_warned=0 _zrush_disabled=0 _zrush_enabled=1
  _zrush_worker_rfd=-1 _zrush_worker_wfd=-1 _zrush_worker_control_wfd=-1
  _zrush_worker_session_fail fixture-first 2>/dev/null
  local -i first_failure_ok=$(( _zrush_worker_failures == 1 && _zrush_worker_warned \
    && !_zrush_disabled && _zrush_enabled ))
  _zrush_enabled=1
  _zrush_worker_session_fail fixture-second 2>/dev/null
  local lifecycle_log="$(<$ZRUSH_LOG)"
  if (( first_failure_ok && _zrush_worker_failures == 2 && _zrush_disabled \
        && !_zrush_enabled && _zrush_worker_warned )) \
     && [[ $lifecycle_log == *'fixture-first'* && $lifecycle_log == *'fixture-second'* \
           && $lifecycle_log == *'circuit breaker opened'* ]]; then
    ok "worker lifecycle: second consecutive session failure disables; warning latches once"
  else
    ng "worker lifecycle: breaker state/log mismatch"
  fi
  ZRUSH_LOG=$saved_log
  _zrush_worker_failures=0 _zrush_worker_warned=0 _zrush_disabled=0 _zrush_enabled=0

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

  # ---------------- Corpus is canonical text ----------------
  # Without this a dec_bytes bug could quietly map a vector onto some *other*
  # byte string -- a reject-plan/ vector mangled into a different malformed
  # plan is still rejected, and that check would pass while fixing nothing.
  # `env` holds zsh parameter assignments, not a wire byte string.
  typeset -a corpus=( $VECTORS/**/*(.N^-/) )
  corpus=( ${(@)corpus:#*/(env|README.md)} )
  (( $#corpus )) || { out "FATAL: no corpus files under $VECTORS"; exit 1 }
  typeset -a noncanonical=()
  local f text
  for f in "${(@)corpus}"; do
    read_text $f; text=$REPLY
    if ! dec_bytes "$text"; then
      noncanonical+=( "${f#$VECTORS/}: $REPLY" )
      continue
    fi
    enc_bytes "$REPLY"
    [[ $REPLY == $text ]] || noncanonical+=( "${f#$VECTORS/}" )
  done
  if (( $#noncanonical )); then
    ng "corpus files that are not canonical text:
      ${(pj:\n      :)noncanonical}"
  else
    ok "corpus: all $#corpus files are canonical escaped text"
  fi

  # ---------------- Encode ----------------
  typeset -a inputs=( $VECTORS/encode/*/argv(N) )
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
    # Comparing in text space keeps a wrong enc_bytes from ever producing a
    # false pass: it can only make the two forms differ.
    enc_bytes "$REPLY"; actual=$REPLY
    goldenfile=$dir/expected
    if [[ $UPDATE_GOLDEN == 1 ]]; then
      if read_text $goldenfile && [[ $actual == $REPLY ]]; then
        ok "encode/$name: golden unchanged"
      else
        print -rn -- "$actual" >| $goldenfile
        updated+=( "encode/$name/expected" )
      fi
      continue
    fi
    if ! read_text $goldenfile; then
      ng "encode/$name: expected missing (run UPDATE_GOLDEN=1 and review the result)"
      continue
    fi
    expected=$REPLY
    if [[ $actual == $expected ]]; then
      ok "encode/$name: encodes to the golden bytes"
    else
      ng "encode/$name: encoded bytes differ
      expected: ${expected//$'\n'/}
      actual:   ${actual//$'\n'/}"
    fi
  done

  if (( $#updated )); then
    ng "updated golden files (review these diffs against cli-protocol.md, then rerun):
      ${(pj:\n      :)updated}"
  fi

  # ---------------- Encoder output reused as a decoder input ----------------
  # One byte string spans both directions: what the encoder emits for
  # encode/shared-tags-all is exactly the candidate payload used by plan/encoder-chain.
  if cmp -s $VECTORS/encode/shared-tags-all/expected $VECTORS/plan/encoder-chain/payload; then
    ok "chain: plan/encoder-chain/payload is encode/shared-tags-all/expected"
  else
    ng "chain: plan/encoder-chain/payload no longer matches encode/shared-tags-all/expected"
  fi

  # ---------------- Accept + round trip ----------------
  typeset -a golden=( $VECTORS/plan/*/expected(N) )
  (( $#golden )) || { out "FATAL: no plan vectors under $VECTORS/plan"; exit 1 }

  for g in "${(@)golden}"; do
    name=${${g:h}:t}
    if ! read_vector $g; then
      ng "plan/$name: $REPLY"
      continue
    fi
    expected=$REPLY
    if ! _zrush_parse_plan "$expected"; then
      dump_bytes "$expected"
      ng "plan/$name: _zrush_parse_plan rejected a golden plan: $REPLY"
      continue
    fi
    if ! reserialize_plan; then
      ng "plan/$name: cannot re-serialize the parsed state: $REPLY"
      continue
    fi
    actual=$REPLY
    if [[ $actual == $expected ]]; then
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
  typeset -a bad=( $VECTORS/reject-plan/*/plan(N) )
  (( $#bad )) || { out "FATAL: no reject-plan vectors under $VECTORS/reject-plan"; exit 1 }

  for g in "${(@)bad}"; do
    name=${${g:h}:t}
    if ! read_vector $g; then
      ng "reject-plan/$name: $REPLY"
      continue
    fi
    expected=$REPLY
    if _zrush_parse_plan "$expected"; then
      dump_bytes "$expected"
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
