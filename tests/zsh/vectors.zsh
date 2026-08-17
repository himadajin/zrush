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
# Unlike the Rust pty harness (tests/driver/, a zle/compsys end-to-end suite),
# nothing here touches zle, so a failure points at the encoder or decoder itself.
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
# the field order of cli-protocol.md "plan の ok body".
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
  typeset -g TEST_BUILD_STAMP=deadbeef
  typeset -g _ZRUSH_EXPECTED_BUILD_STAMP=$TEST_BUILD_STAMP ZRUSH_NO_INIT=1
  source $REPO/zsh/zrush.zsh || { out "FATAL: cannot source zrush.zsh"; exit 1 }
  unset ZRUSH_NO_INIT
  (( $+functions[_zrush_parse_plan] )) || { out "FATAL: _zrush_parse_plan undefined after source"; exit 1 }
  (( $+functions[_zrush_encode_batch] )) || { out "FATAL: _zrush_encode_batch undefined after source"; exit 1 }
  (( $+functions[_zrush_history_snapshot_payload] )) || { out "FATAL: _zrush_history_snapshot_payload undefined after source"; exit 1 }
  (( $+functions[_zrush_history_append_payload] )) || { out "FATAL: _zrush_history_append_payload undefined after source"; exit 1 }
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

  local -i exit_rfd exit_wfd
  exec {exit_rfd}< /dev/null
  exec {exit_wfd}> /dev/null
  _zrush_rfd=$exit_rfd _zrush_wfd=$exit_wfd
  _zrush_pty=
  _zrush_worker_rfd=-1 _zrush_worker_wfd=-1 _zrush_worker_control_wfd=-1
  _zrush_worker_ack_fd=-1 _zrush_worker_drain_fd=-1
  _zrush_zshexit
  if (( _zrush_rfd == -1 && _zrush_wfd == -1 )) \
     && [[ ! -e /dev/fd/$exit_rfd \
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
  _zrush_encode_message ready "$TEST_BUILD_STAMP"
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
    [[ -z $rx && $delivered == 2 && $got[1] == "ready|$TEST_BUILD_STAMP" \
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
  _zrush_worker_ready=0 _zrush_worker_failures=1 _zrush_disabled=0 _zrush_disable_reason= _zrush_enabled=1
  _zrush_netstring_take "$ready_frame"
  _zrush_worker_handle_message "$REPLY"
  local -i ready_kept_failures=$(( _zrush_worker_ready == 1 && _zrush_worker_failures == 1 ))
  typeset -gA _zrush_worker_pending=( 41 'plan history' )
  _zrush_netstring_take "$error_frame"
  _zrush_worker_handle_message "$REPLY"
  if (( ready_kept_failures && _zrush_worker_failures == 0 \
        && ! ${+_zrush_worker_pending[41]} && !_zrush_disabled )); then
    ok "worker lifecycle: handshake keeps failure streak; terminal error resets it"
  else
    ng "worker lifecycle: ready=$ready_kept_failures failures=$_zrush_worker_failures pending=${+_zrush_worker_pending[41]} disabled=$_zrush_disabled"
  fi

  # Only the synchronous history exchange sends a plan, so a well-formed plan
  # response that is not the one it waits for is consumed and must leave the
  # current plan alone.
  read_vector $VECTORS/plan/empty-stdin/expected \
    || { out "FATAL: $REPLY"; exit 1 }
  local stale_plan=$REPLY
  _zrush_worker_ready=1 _zrush_worker_failures=1 _zrush_disabled=0 _zrush_disable_reason= _zrush_enabled=1
  typeset -gA _zrush_worker_pending=( 41 'plan history' )
  _zrush_sync_target=0
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

  # A store's terminal response is consumed on its own: it carries no body and
  # never touches the plan the worker will deliver as an event
  # (cli-protocol.md "要求と応答").
  _zrush_worker_ready=1 _zrush_worker_failures=1 _zrush_enabled=1
  typeset -gA _zrush_worker_pending=( 50 'store live 50 7' )
  _zrush_input_gen=7
  _zrush_plan_text=store-sentinel _zrush_plan_nlines=7
  _zrush_encode_message ok 50 ''
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"; local -i store_ok_st=$?
  if (( store_ok_st == 0 && ! ${+_zrush_worker_pending[50]} \
        && _zrush_worker_failures == 0 && _zrush_plan_nlines == 7 )) \
     && [[ $_zrush_plan_text == store-sentinel ]]; then
    ok "worker lifecycle: an empty-bodied store ok is terminal and leaves the plan alone"
  else
    ng "worker lifecycle: store ok status=$store_ok_st pending=${+_zrush_worker_pending[50]} failures=$_zrush_worker_failures plan=${(qqqq)_zrush_plan_text}"
  fi
  _zrush_plan_text= _zrush_plan_nlines=0

  # unknown-generation is a normal terminal error: it never fails the session
  # and nothing is replayed (cli-protocol.md "応答の検証と zsh 側の適用").
  # Only the history menu's synchronous exchange sends a plan, so that is where
  # it lands -- as an exchange failure that starts no collection and leaves the
  # empty-word cache's latch alone (behavior.md "履歴メニュー").
  local saved_start_collection=$functions[_zrush_start_collection]
  typeset -gi _zrt_collections=0
  functions[_zrush_start_collection]='(( ++_zrt_collections )); return 0'
  _zrush_worker_ready=1 _zrush_worker_failures=0 _zrush_worker_stopping=0
  _zrush_disabled=0 _zrush_disable_reason= _zrush_enabled=1
  typeset -gA _zrush_worker_pending=( 53 'plan history' )
  _zrush_sync_target=53 _zrush_sync_done=0 _zrush_sync_ok=0
  _zrush_cc_fp=fingerprint _zrush_cc_time=$EPOCHSECONDS _zrush_cc_cand_gen=9
  _zrush_encode_message error 53 unknown-generation
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"; local -i unknown_st=$?
  local -i sync_failed=$(( unknown_st == 0 && _zrush_sync_done == 1 && _zrush_sync_ok == 0 \
    && _zrt_collections == 0 && _zrush_worker_failures == 0 && !_zrush_worker_stopping \
    && ! ${+_zrush_worker_pending[53]} && _zrush_cc_cand_gen == 9 ))
  functions[_zrush_start_collection]=$saved_start_collection
  _zrush_sync_target=0 _zrush_sync_done=0 _zrush_sync_ok=0 _zrush_cc_cand_gen=0 _zrush_cc_fp=
  if (( sync_failed )); then
    ok "worker lifecycle: unknown-generation fails the sync exchange without collecting or replaying"
  else
    ng "worker lifecycle: unknown-generation sync outcome done=$_zrush_sync_done ok=$_zrush_sync_ok collections=$_zrt_collections failures=$_zrush_worker_failures"
  fi
  unset _zrt_collections

  # A buffer change invalidates the current input_generation before its
  # successor exists. An event for the old one must be dropped, and a Tab
  # pressed in that window belongs to the newer query: the stale event may not
  # settle it, while the successor's event may.
  local saved_send_input=$functions[_zrush_send_input]
  local saved_settle_plan=$functions[_zrush_settle_plan]
  typeset -gi _zrt_notifications=0 _zrt_settle_calls=0
  functions[_zrush_send_input]='(( ++_zrt_notifications )); _zrush_input_gen=99 _zrush_input_pending=1; return 0'
  functions[_zrush_settle_plan]='(( ++_zrt_settle_calls )); _zrush_tab_pending=0; return 0'
  _zrush_worker_ready=1 _zrush_worker_stopping=0
  _zrush_enabled=1 _zrush_disabled=0 _zrush_disable_reason=
  _zrush_input_gen=41 _zrush_input_pending=1 _zrush_input_latched=0
  _zrush_last_buffer=old _zrush_last_cursor=0
  BUFFER=new LBUFFER=new CURSOR=3
  _zrush_plan_kind=none _zrush_tab_pending=0 _zrush_selected=0
  ZRUSH_CFG_MIN_INPUT=0
  _zrush_line_pre_redraw
  local -i renotified=$(( _zrt_notifications == 1 && _zrush_input_gen == 99 ))
  _zrush_tab_pending=1
  _zrush_encode_message plan-ready 41 "$stale_plan"
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"
  local -i old_stayed_stale=$(( _zrt_settle_calls == 0 && _zrush_tab_pending == 1 ))
  _zrush_encode_message plan-ready 99 "$stale_plan"
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"
  functions[_zrush_send_input]=$saved_send_input
  functions[_zrush_settle_plan]=$saved_settle_plan
  if (( renotified && old_stayed_stale && _zrt_settle_calls == 1 \
        && _zrush_tab_pending == 0 && _zrush_input_pending == 0 )); then
    ok "worker lifecycle: a buffer change strands the old generation's event; its successor settles the pending Tab"
  else
    ng "worker lifecycle: renotified=$renotified old-stale=$old_stayed_stale settles=$_zrt_settle_calls tab=$_zrush_tab_pending"
  fi
  unset _zrt_settle_calls _zrt_notifications
  _zrush_input_gen=0 _zrush_input_pending=0

  # A second mismatch while automatic re-source is already in progress hits
  # the one-attempt guard and disables only the stale loaded generation.
  # Populate every active endpoint slot needed by a healthy stop. stdout is
  # already at EOF, so shutdown must raw-drain it before finalizing.
  zmodload zsh/system zsh/datetime || { out "FATAL: lifecycle modules"; exit 1 }
  _zrush_worker_ready=0 _zrush_worker_failures=0 _zrush_disabled=0 _zrush_disable_reason= _zrush_enabled=1
  _zrush_worker_warned=0 _zrush_build_warned=0 _zrush_worker_stopping=0
  _zrush_build_following=1 _zrush_stale_disabled=0
  local -i mismatch_rfd mismatch_wfd mismatch_control_fd mismatch_drain_fd
  exec {mismatch_rfd}< /dev/null
  exec {mismatch_wfd}> /dev/null
  exec {mismatch_control_fd}> /dev/null
  exec {mismatch_drain_fd}< /dev/null
  _zrush_worker_rfd=$mismatch_rfd _zrush_worker_wfd=$mismatch_wfd
  _zrush_worker_control_wfd=$mismatch_control_fd
  _zrush_worker_ack_fd=-1 _zrush_worker_drain_fd=$mismatch_drain_fd
  _zrush_encode_message incompatible cafebabe
  local mismatch_frame=$REPLY
  _zrush_netstring_take "$mismatch_frame"
  _zrush_worker_handle_message "$REPLY" 2>/dev/null
  if (( !_zrush_disabled && _zrush_stale_disabled && !_zrush_enabled \
        && _zrush_worker_failures == 0 && _zrush_build_warned \
        && _zrush_worker_rfd == -1 && _zrush_worker_wfd == -1 \
        && _zrush_worker_control_wfd == -1 && _zrush_worker_ack_fd == -1 \
        && _zrush_worker_drain_fd == -1 )) \
     && [[ ! -e /dev/fd/$mismatch_rfd && ! -e /dev/fd/$mismatch_wfd \
           && ! -e /dev/fd/$mismatch_control_fd \
           && ! -e /dev/fd/$mismatch_drain_fd ]]; then
    ok "worker lifecycle: repeated build mismatch trips the one-shot guard and closes every transport fd"
  else
    ng "worker lifecycle: mismatch state enabled=$_zrush_enabled disabled=$_zrush_disabled stale=$_zrush_stale_disabled failures=$_zrush_worker_failures warned=$_zrush_build_warned fds=$_zrush_worker_rfd,$_zrush_worker_wfd,$_zrush_worker_control_wfd,$_zrush_worker_ack_fd,$_zrush_worker_drain_fd"
  fi
  _zrush_build_following=0 _zrush_stale_disabled=0
  _zrush_disabled=0 _zrush_disable_reason= _zrush_enabled=0 _zrush_worker_warned=0 _zrush_build_warned=0

  # Two failed sessions without an intervening terminal response open the
  # circuit breaker. The user-facing notice latch remains set after the first
  # failure, while detailed reasons continue to be logged for both sessions.
  local saved_log=${ZRUSH_LOG:-}
  ZRUSH_LOG=$WORK/lifecycle.log
  _zrush_worker_failures=0 _zrush_worker_warned=0 _zrush_disabled=0 _zrush_disable_reason= _zrush_enabled=1
  _zrush_worker_rfd=-1 _zrush_worker_wfd=-1 _zrush_worker_control_wfd=-1
  _zrush_worker_session_fail fixture-first 2>/dev/null
  local -i first_failure_ok=$(( _zrush_worker_failures == 1 && _zrush_worker_warned \
    && !_zrush_disabled && _zrush_enabled ))
  local first_notice=$_zrush_notice
  _zrush_enabled=1
  _zrush_worker_session_fail fixture-second 2>/dev/null
  local lifecycle_log="$(<$ZRUSH_LOG)"
  if (( first_failure_ok && _zrush_worker_failures == 2 && _zrush_disabled \
        && !_zrush_enabled && _zrush_worker_warned )) \
     && [[ $first_notice == 'zrush: worker transport failed; retrying once' \
           && $_zrush_disable_reason == session-failure \
           && $_zrush_notice == 'zrush: worker disabled after repeated failures; source <(zrush init zsh) to retry' ]] \
     && [[ $lifecycle_log == *'fixture-first'* && $lifecycle_log == *'fixture-second'* \
           && $lifecycle_log == *'circuit breaker opened'* ]]; then
    ok "worker lifecycle: second consecutive session failure disables; warning latches once"
  else
    ng "worker lifecycle: breaker state/log mismatch"
  fi
  ZRUSH_LOG=$saved_log
  _zrush_worker_failures=0 _zrush_worker_warned=0 _zrush_disabled=0 _zrush_disable_reason= _zrush_enabled=0

  # ---------------- Empty-word collection cache latch ----------------
  # The latch is the worker session's, not the shell's: a lost session drops it
  # and the entry misses even while fingerprint and TTL are still good
  # (behavior.md "空語収集キャッシュ" / "worker ライフサイクル").
  zmodload -F zsh/stat b:zstat 2>/dev/null
  ZRUSH_LOG=$WORK/cache.log
  local -i cache_ok=1
  _zrush_query=
  _zrush_cc_subject || cache_ok=0
  # A widened word keeps its prefix, so only a line-start empty word is the
  # cache's subject; `sudo ` and `git ` collections use the live slot.
  _zrush_query='sudo '
  _zrush_cc_subject && cache_ok=0
  _zrush_query=
  _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0 _zrush_cc_staged=()
  _zrush_cc_check && cache_ok=0
  # Staging alone is not a latch: only the store's ok turns it into one.
  _zrush_cc_stage 300
  (( _zrush_cc_cand_gen == 0 )) || cache_ok=0
  _zrush_cc_check && cache_ok=0
  _zrush_cc_commit 300 12
  (( _zrush_cc_cand_gen == 12 && $#_zrush_cc_staged == 0 )) || cache_ok=0
  _zrush_cc_check || cache_ok=0
  _zrush_worker_failures=0 _zrush_worker_warned=0 _zrush_disabled=0 _zrush_disable_reason= _zrush_enabled=1
  _zrush_worker_rfd=-1 _zrush_worker_wfd=-1 _zrush_worker_control_wfd=-1
  _zrush_cc_stage 301
  _zrush_worker_session_fail latch-fixture 2>/dev/null
  (( _zrush_cc_cand_gen == 0 && $#_zrush_cc_staged == 0 )) || cache_ok=0
  _zrush_cc_check && cache_ok=0
  [[ -z $_zrush_cc_fp ]] || cache_ok=0
  if (( cache_ok )); then
    ok "cache latch: a session failure drops the latch and turns a live entry into a miss"
  else
    ng "cache latch: subject/latch state fp=${(qqqq)_zrush_cc_fp} generation=$_zrush_cc_cand_gen"
  fi
  ZRUSH_LOG=$saved_log
  _zrush_query= _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0
  _zrush_worker_failures=0 _zrush_worker_warned=0 _zrush_disabled=0 _zrush_disable_reason= _zrush_enabled=0

  # ---------------- Request wiring (observed on the outbound queue) ----------------
  # Pin the callers, not just the message handler. Publishing a response fd
  # makes the session look up, and holding the writer slot busy makes
  # _zrush_worker_flush leave completed frames on _zrush_worker_txq, where the
  # same netstring decoder the worker session uses can read them back. No fork,
  # no worker, no zle.
  local -i wire_fd
  exec {wire_fd}< /dev/null
  wire_fields() {  # $1=frame -> reply=(fields)
    emulate -L zsh
    _zrush_netstring_take "$1" || return 1
    _zrush_decode_fields "$REPLY"
  }
  wire_reset() {
    emulate -L zsh
    _zrush_worker_rfd=$wire_fd _zrush_worker_ack_fd=$wire_fd
    _zrush_worker_wfd=-1 _zrush_worker_control_wfd=-1 _zrush_worker_drain_fd=-1
    _zrush_worker_ready=1 _zrush_worker_stopping=0 _zrush_worker_runtime_tainted=0
    _zrush_worker_failures=0 _zrush_disabled=0 _zrush_disable_reason= _zrush_enabled=1
    _zrush_worker_txq=() _zrush_worker_pending=() _zrush_cc_staged=()
    _zrush_sync_target=0 _zrush_sync_done=0 _zrush_sync_ok=0
    _zrush_input_gen=0 _zrush_input_pending=0 _zrush_input_latched=0
    _zrush_collect_gen=0
    _zrush_buf= _zrush_pty= _zrush_rfd=-1 _zrush_wfd=-1
  }
  ZRUSH_CFG_MODE=prefix ZRUSH_CFG_SMART_CASE=false ZRUSH_CFG_MAX_LINES=10
  ZRUSH_CFG_TRAILING_SPACE=true ZRUSH_CFG_MIN_INPUT=0 ZRUSH_CFG_HISTORY_LIMIT=1234
  ZRUSH_CFG_DELAY_MS=30
  LINES=11 COLUMNS=80
  BUFFER= LBUFFER= RBUFFER=
  local -a sf=() pf=() hf=()
  local store_id=

  # A cache hit collects nothing and stores nothing: it names the latched
  # generation on the notification and lets the worker answer from the slot it
  # already holds. A candidate_generation=0 regression here would recollect the
  # heaviest case on every prompt; a lost latched flag would leave a dead latch
  # in place and false-hit forever.
  wire_reset
  _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0 _zrush_cc_staged=()
  _zrush_cc_stage 400
  _zrush_cc_commit 400 7
  local -i hit_wire=1
  _zrush_send_input 2>/dev/null
  (( $#_zrush_worker_txq == 1 )) || hit_wire=0
  if wire_fields "$_zrush_worker_txq[1]"; then
    hf=( "${(@)reply}" )
    (( $#hf == 11 )) || hit_wire=0
    [[ $hf[1] == input && $hf[3] == 7 && $hf[4] == 30 ]] || hit_wire=0
    (( $hf[2] == _zrush_input_gen )) || hit_wire=0
  else
    hit_wire=0
  fi
  (( _zrush_input_latched == 1 && _zrush_input_pending == 1 )) || hit_wire=0
  (( _zrush_cc_cand_gen == 7 && $#_zrush_cc_staged == 0 )) || hit_wire=0
  # A miss names the reserved 0 instead, and the notification is not latch-backed.
  _zrush_cc_invalidate
  wire_reset
  _zrush_send_input 2>/dev/null
  if wire_fields "$_zrush_worker_txq[1]"; then
    hf=( "${(@)reply}" )
    [[ $hf[1] == input && $hf[3] == 0 ]] || hit_wire=0
  else
    hit_wire=0
  fi
  (( _zrush_input_latched == 0 )) || hit_wire=0
  if (( hit_wire )); then
    ok "request wiring: a cache hit names the latched generation on the notification and stores nothing"
  else
    ng "request wiring: cache notification queued ${#_zrush_worker_txq} frame(s) ${(qqqq)_zrush_worker_txq}"
  fi

  local -i store_wire=1
  # A finished empty-word capture: one store into the cache slot, bound to the
  # input_generation whose capture-required asked for it, with nothing pipelined
  # behind it -- the worker answers an accepted store with the plan-ready for
  # that same input. The latch follows only once that store answers ok.
  wire_reset
  _zrush_input_gen=7 _zrush_collect_gen=7
  _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0 _zrush_cc_staged=()
  _zrush_query= _zrush_fuzzy= _zrush_buf=$'b\1\0w\1ls\0'
  _zrush_finalize
  (( $#_zrush_worker_txq == 1 )) || store_wire=0
  wire_fields "$_zrush_worker_txq[1]" && sf=( "${(@)reply}" ) || store_wire=0
  (( $#sf == 6 )) || store_wire=0
  [[ $sf[1] == store && $sf[3] == cache && $sf[5] == 7 && $sf[6] == $'b\1\0w\1ls\0' ]] || store_wire=0
  store_id=$sf[2]
  [[ ${_zrush_worker_pending[$store_id]} == "store cache $sf[4] 7" ]] || store_wire=0
  (( ${+_zrush_cc_staged[$store_id]} && _zrush_cc_cand_gen == 0 )) || store_wire=0
  _zrush_encode_message ok $store_id ''
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"
  (( _zrush_cc_cand_gen == $sf[4] && $#_zrush_cc_staged == 0 )) || store_wire=0

  # A capture answers the generation it was started for, not whatever is current
  # when it finishes. Once that generation is invalidated -- or replaced by a
  # newer one -- there is nothing left for it to answer and no store goes out at
  # all: every store carries a binding.
  wire_reset
  _zrush_collect_gen=7 _zrush_input_gen=0
  _zrush_query= _zrush_fuzzy= _zrush_buf=$'b\1\0w\1ls\0'
  _zrush_finalize
  (( $#_zrush_worker_txq == 0 && $#_zrush_cc_staged == 0 && _zrush_collect_gen == 0 )) || store_wire=0
  wire_reset
  _zrush_collect_gen=7 _zrush_input_gen=8
  _zrush_query= _zrush_fuzzy= _zrush_buf=$'b\1\0w\1ls\0'
  _zrush_finalize
  (( $#_zrush_worker_txq == 0 && $#_zrush_cc_staged == 0 )) || store_wire=0

  # A store that ends in error changed no slot, so no latch may appear.
  wire_reset
  _zrush_input_gen=7 _zrush_collect_gen=7
  _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0
  _zrush_query= _zrush_fuzzy= _zrush_buf=$'b\1\0w\1ls\0'
  _zrush_finalize
  wire_fields "$_zrush_worker_txq[1]" && sf=( "${(@)reply}" ) || store_wire=0
  _zrush_encode_message error $sf[2] invalid-payload
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"
  (( _zrush_cc_cand_gen == 0 && $#_zrush_cc_staged == 0 )) || store_wire=0

  # A widened word that keeps a prefix is not the cache's subject, and neither
  # is a capture that came back empty: both take the live slot and leave an
  # existing latch alone.
  wire_reset
  _zrush_input_gen=7 _zrush_collect_gen=7
  _zrush_cc_cand_gen=5 _zrush_cc_fp=keep _zrush_cc_time=$EPOCHSECONDS
  _zrush_query='git ' _zrush_fuzzy=lo _zrush_buf=$'b\1\0w\1log\0'
  _zrush_finalize
  wire_fields "$_zrush_worker_txq[1]" && sf=( "${(@)reply}" ) || store_wire=0
  [[ $sf[1] == store && $sf[3] == live ]] || store_wire=0
  (( $#_zrush_cc_staged == 0 )) || store_wire=0
  _zrush_encode_message ok $sf[2] ''
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"
  (( _zrush_cc_cand_gen == 5 )) || store_wire=0
  wire_reset
  _zrush_input_gen=7 _zrush_collect_gen=7
  _zrush_query= _zrush_fuzzy= _zrush_buf=
  _zrush_finalize
  wire_fields "$_zrush_worker_txq[1]" && sf=( "${(@)reply}" ) || store_wire=0
  [[ $sf[1] == store && $sf[3] == live && -z $sf[6] ]] || store_wire=0
  (( $#_zrush_cc_staged == 0 && _zrush_cc_cand_gen == 5 )) || store_wire=0
  if (( store_wire )); then
    ok "request wiring: the slot follows the cache's subject and only a store ok takes the latch"
  else
    ng "request wiring: finalize store/plan pair or latch commit mismatch"
  fi

  # ---- History index requests, observed on the same outbound queue ----
  # The index is generation-addressed like a slot, but it is written by its own
  # two kinds and read by a plan with producer=history
  # (cli-protocol.md "要求と応答" / "history profile").
  local -i hist_wire=1
  local -i snap_gen=0 ev=0
  wire_reset
  _zrush_hist_reset
  _zrush_request_history history-snapshot $'b\1\0w\1ls\2n\17\0' || hist_wire=0
  snap_gen=$REPLY
  wire_fields "$_zrush_worker_txq[1]" && sf=( "${(@)reply}" ) || hist_wire=0
  (( $#sf == 4 )) || hist_wire=0
  [[ $sf[1] == history-snapshot && $sf[3] == $snap_gen && $sf[4] == $'b\1\0w\1ls\2n\17\0' ]] || hist_wire=0
  [[ ${_zrush_worker_pending[$sf[2]]} == "history-snapshot $snap_gen" ]] || hist_wire=0
  # The query behind it: producer=history, the whole buffer as the query,
  # trailing-space false, the configured history_limit, and offset 0.
  _zrush_request_plan $snap_gen history 'ls -l' false || hist_wire=0
  wire_fields "$_zrush_worker_txq[2]" && pf=( "${(@)reply}" ) || hist_wire=0
  (( $#pf == 13 )) || hist_wire=0
  [[ $pf[1] == plan && $pf[3] == $snap_gen && $pf[5] == history && $pf[6] == 'ls -l' \
     && $pf[11] == false && $pf[12] == 1234 && $pf[13] == 0 ]] || hist_wire=0
  [[ ${_zrush_worker_pending[$pf[2]]} == 'plan history' ]] || hist_wire=0
  _zrush_request_plan $snap_gen history 'ls -l' false 3 || hist_wire=0
  wire_fields "$_zrush_worker_txq[3]" && pf=( "${(@)reply}" ) || hist_wire=0
  (( $#pf == 13 && pf[13] == 3 )) || hist_wire=0
  if (( hist_wire )); then
    ok "history wiring: a snapshot frame and the history plan that reads it back"
  else
    ng "history wiring: snapshot/query frames ${(qqqq)_zrush_worker_txq}"
  fi

  # The per-prompt update: one append for the event that follows the head, with
  # the latch and the Level B baseline moving optimistically with the enqueue.
  # `print -s` leaves its newest entry as the current event, so the second push
  # is what makes the first one the newest entry `$history` shows -- the one a
  # precmd would reconcile.
  print -sr -- 'echo wiring-event'
  print -sr -- 'echo wiring-current'
  local -i update_wire=1
  wire_reset
  ev=$(( HISTCMD - 1 ))
  _zrush_hist_latch 40 $(( ev - 1 )) 0
  _zrush_hist_unacked=0
  _zrush_hist_reconcile
  (( $#_zrush_worker_txq == 1 )) || update_wire=0
  wire_fields "$_zrush_worker_txq[1]" && sf=( "${(@)reply}" ) || update_wire=0
  (( $#sf == 4 )) || update_wire=0
  [[ $sf[1] == history-append && $sf[4] == b$'\1'$'\0'w$'\1'"$history[$ev]"$'\2'n$'\1'"$ev"$'\0' ]] ||
    update_wire=0
  [[ ${_zrush_worker_pending[$sf[2]]} == "history-append $sf[3]" ]] || update_wire=0
  (( _zrush_hist_gen == $sf[3] && _zrush_hist_head == ev && _zrush_hist_count == $#history \
     && _zrush_hist_unacked == 1 )) || update_wire=0
  # A prompt that added nothing sends nothing.
  _zrush_hist_reconcile
  (( $#_zrush_worker_txq == 1 )) || update_wire=0
  # The append's terminal response retires it from the unacked bound.
  _zrush_worker_ready=1
  _zrush_encode_message ok $sf[2] ''
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"
  (( _zrush_hist_unacked == 0 && _zrush_hist_gen == $sf[3] )) || update_wire=0
  if (( update_wire )); then
    ok "history wiring: one append per new event, latched at enqueue"
  else
    ng "history wiring: append frames ${(qqqq)_zrush_worker_txq} gen=$_zrush_hist_gen head=$_zrush_hist_head unacked=$_zrush_hist_unacked"
  fi

  # What the update path refuses to do: send for a discontinuity, send past the
  # unacked bound, send without a worker (which would defeat lazy start), and
  # send for an event the sender excludes -- the last one still advancing head
  # and the baseline, so the exclusion is not a permanent discontinuity.
  local -i quiet_wire=1
  wire_reset
  _zrush_hist_latch 40 $(( HISTCMD - 5 )) 0
  _zrush_hist_reconcile
  (( $#_zrush_worker_txq == 0 && _zrush_hist_gen == 0 )) || quiet_wire=0
  wire_reset
  _zrush_hist_latch 41 $(( HISTCMD - 2 )) 0
  _zrush_hist_unacked=$_ZRUSH_HIST_MAX_UNACKED
  _zrush_hist_reconcile
  (( $#_zrush_worker_txq == 0 && _zrush_hist_gen == 0 )) || quiet_wire=0
  wire_reset
  _zrush_worker_rfd=-1
  _zrush_hist_latch 42 $(( HISTCMD - 2 )) 0
  _zrush_hist_unacked=0
  _zrush_hist_reconcile
  (( $#_zrush_worker_txq == 0 && _zrush_hist_gen == 42 && _zrush_hist_head == HISTCMD - 2 )) || quiet_wire=0
  print -sr -- $'ctl\1x'
  print -sr -- 'sentinel-after-ctl'
  wire_reset
  _zrush_hist_latch 43 $(( HISTCMD - 2 )) 0
  _zrush_hist_unacked=0
  _zrush_hist_reconcile
  (( $#_zrush_worker_txq == 0 && _zrush_hist_gen == 43 && _zrush_hist_head == HISTCMD - 1 \
     && _zrush_hist_count == $#history && _zrush_hist_unacked == 0 )) || quiet_wire=0
  if (( quiet_wire )); then
    ok "history wiring: no frame for a discontinuity, a full queue, an absent worker or an excluded event"
  else
    ng "history wiring: silent-update cases queued ${#_zrush_worker_txq} frame(s) gen=$_zrush_hist_gen head=$_zrush_hist_head"
  fi

  # unknown-generation on either write kind or on the history plan drops the
  # index latch; other producers leave it alone
  # (behavior.md "worker ライフサイクル").
  local -i unknown_wire=1
  local kind
  for kind in history-snapshot history-append plan; do
    wire_reset
    _zrush_worker_ready=1
    _zrush_hist_latch 50 5 5
    if [[ $kind == plan ]]; then
      _zrush_worker_pending=( 900 'plan history' )
    else
      _zrush_worker_pending=( 900 "$kind 50" )
    fi
    _zrush_encode_message error 900 unknown-generation
    _zrush_netstring_take "$REPLY"
    _zrush_worker_handle_message "$REPLY"
    (( _zrush_hist_gen == 0 )) || unknown_wire=0
  done
  wire_reset
  _zrush_worker_ready=1
  _zrush_hist_latch 50 5 5
  _zrush_worker_pending=( 901 'store live 60 7' )
  _zrush_encode_message error 901 unknown-generation
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"
  (( _zrush_hist_gen == 50 )) || unknown_wire=0
  if (( unknown_wire )); then
    ok "history wiring: unknown-generation on a history request or query drops the index latch, a store's does not"
  else
    ng "history wiring: index latch after unknown-generation gen=$_zrush_hist_gen"
  fi
  _zrush_hist_reset

  # ---- Notification and event frames (tests/vectors/message/) ----
  # cli-protocol.md "入力通知と worker event" spells six complete messages and
  # the corpus holds those bytes; both directions run against them here.
  local frame_input= frame_flush= frame_store= frame_capture=
  local frame_plan_ready= frame_superseded= vname=
  for vname in input-no-cache flush store-capture capture-required \
               plan-ready-zero-match error-superseded; do
    read_vector $VECTORS/message/$vname/frame || { out "FATAL: $REPLY"; exit 1 }
    case $vname in
      input-no-cache)        frame_input=$REPLY ;;
      flush)                 frame_flush=$REPLY ;;
      store-capture)         frame_store=$REPLY ;;
      capture-required)      frame_capture=$REPLY ;;
      plan-ready-zero-match) frame_plan_ready=$REPLY ;;
      error-superseded)      frame_superseded=$REPLY ;;
    esac
  done

  # The sender: one notification, one flush, one bound store, byte for byte.
  local -i notify_wire=1
  local saved_pwd=$PWD
  wire_reset
  _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0 _zrush_cc_staged=()
  _zrush_input_gen_seq=6
  ZRUSH_CFG_DELAY_MS=30 ZRUSH_CFG_MODE=typo ZRUSH_CFG_SMART_CASE=true
  ZRUSH_CFG_MAX_LINES=10 ZRUSH_CFG_TRAILING_SPACE=true
  LINES=11 COLUMNS=80
  BUFFER=gi LBUFFER=gi RBUFFER= CURSOR=2
  builtin cd -q /tmp 2>/dev/null
  [[ $PWD == /tmp ]] || notify_wire=0
  _zrush_send_input 2>/dev/null
  _zrush_send_flush 2>/dev/null
  builtin cd -q $saved_pwd
  local notify_frame=${_zrush_worker_txq[1]:-} flush_frame=${_zrush_worker_txq[2]:-}
  (( $#_zrush_worker_txq == 2 )) || notify_wire=0
  [[ $notify_frame == $frame_input ]] || notify_wire=0
  [[ $flush_frame == $frame_flush ]] || notify_wire=0
  (( _zrush_input_gen == 7 && _zrush_input_pending == 1 && _zrush_input_latched == 0 )) ||
    notify_wire=0
  wire_reset
  _zrush_input_gen=7 _zrush_collect_gen=7
  _zrush_request_seq=11 _zrush_cand_gen_seq=40
  _zrush_query='sudo ' _zrush_fuzzy= _zrush_buf=$'b\1\0w\1ls\0'
  _zrush_finalize
  (( $#_zrush_worker_txq == 1 )) || notify_wire=0
  [[ $_zrush_worker_txq[1] == $frame_store ]] || notify_wire=0
  if (( notify_wire )); then
    ok "message frames: the notification, flush and bound store match the contract's bytes"
  else
    dump_bytes "$notify_frame";              local got_input=$REPLY
    dump_bytes "$flush_frame";               local got_flush=$REPLY
    dump_bytes "${_zrush_worker_txq[1]:-}";  local got_store=$REPLY
    ng "message frames: sender bytes differ
      input: $got_input
      flush: $got_flush
      store: $got_store"
  fi

  # The receiver. A session failure is stubbed out so a wrong outcome is
  # reported rather than acted on, and so the reason itself can be checked.
  local saved_session_fail_ev=${functions[_zrush_worker_session_fail]}
  local saved_start_collection_ev=${functions[_zrush_start_collection]}
  local saved_tab_ev=${functions[_zrush_tab_with_results]}
  typeset -g _zrt_event_failure=
  typeset -gi _zrt_event_collections=0 _zrt_event_tabs=0
  functions[_zrush_worker_session_fail]='_zrt_event_failure=$1; return 1'
  functions[_zrush_start_collection]='(( ++_zrt_event_collections )); return 0'
  functions[_zrush_tab_with_results]='(( ++_zrt_event_tabs )); return 0'
  event_deliver() {  # $1=outer frame
    emulate -L zsh
    _zrush_netstring_take "$1" || return 1
    _zrush_worker_handle_message "$REPLY"
  }

  # capture-required for the current generation: exactly one collection, and
  # the latch the notification named is dropped, because the worker has just
  # said it does not hold that generation.
  local -i event_wire=1
  wire_reset
  _zrush_input_gen=7 _zrush_input_pending=1 _zrush_input_latched=1
  _zrush_cc_fp=fingerprint _zrush_cc_time=$EPOCHSECONDS _zrush_cc_cand_gen=41
  _zrush_worker_failures=1
  event_deliver "$frame_capture"; (( $? == 0 )) || event_wire=0
  (( _zrt_event_collections == 1 && _zrush_input_pending == 0 \
     && _zrush_input_latched == 0 && _zrush_cc_cand_gen == 0 \
     && _zrush_worker_failures == 0 )) || event_wire=0
  [[ -z $_zrt_event_failure ]] || event_wire=0
  # A stale one starts nothing and leaves the pending input alone.
  _zrush_input_gen=8 _zrush_input_pending=1
  event_deliver "$frame_capture"; (( $? == 0 )) || event_wire=0
  (( _zrt_event_collections == 1 && _zrush_input_pending == 1 )) || event_wire=0
  [[ -z $_zrt_event_failure ]] || event_wire=0

  # plan-ready for the current generation: applied like a plan response, kind
  # compsys, and it resolves a Tab pressed before the candidates arrived.
  wire_reset
  _zrush_input_gen=7 _zrush_input_pending=1
  _zrush_tab_pending=1 _zrush_selected=0 _zrush_plan_kind=none
  BUFFER= POSTDISPLAY=sentinel region_highlight=() _zrush_rh=() _zrush_rh_sel=
  event_deliver "$frame_plan_ready"; (( $? == 0 )) || event_wire=0
  (( _zrush_plan_nlines == 0 && _zrush_plan_npos == 0 && _zrt_event_tabs == 1 \
     && _zrush_tab_pending == 0 && _zrush_input_pending == 0 )) || event_wire=0
  [[ $_zrush_plan_kind == compsys && -z $POSTDISPLAY && -z $_zrt_event_failure ]] || event_wire=0

  # The generation is matched before the body is looked at: a stale plan-ready
  # carrying bytes that are not a plan is dropped, not parsed and not fatal.
  _zrush_plan_text=kept _zrush_plan_nlines=3 _zrush_plan_kind=history
  _zrush_input_gen=8
  _zrush_encode_message plan-ready 7 'not a plan'
  event_deliver "$REPLY"; (( $? == 0 )) || event_wire=0
  [[ -z $_zrt_event_failure && $_zrush_plan_text == kept ]] || event_wire=0
  (( _zrush_plan_nlines == 3 )) || event_wire=0
  # The same bytes for the current generation are a session failure.
  _zrush_input_gen=7
  _zrush_encode_message plan-ready 7 'not a plan'
  event_deliver "$REPLY"
  [[ $_zrt_event_failure == 'malformed render plan input_generation=7' ]] || event_wire=0

  # Shape violations have no in-band error, so they end the session.
  _zrt_event_failure=
  _zrush_encode_message plan-ready 7
  event_deliver "$REPLY"
  [[ $_zrt_event_failure == 'invalid plan-ready field count' ]] || event_wire=0
  _zrt_event_failure=
  _zrush_encode_message capture-required 7 extra
  event_deliver "$REPLY"
  [[ $_zrt_event_failure == 'invalid capture-required field count' ]] || event_wire=0
  _zrt_event_failure=
  _zrush_encode_message capture-required 007
  event_deliver "$REPLY"
  [[ $_zrt_event_failure == 'noncanonical event input_generation' ]] || event_wire=0
  _zrt_event_failure=
  _zrush_encode_message plan-ready-ish 7 body
  event_deliver "$REPLY"
  [[ $_zrt_event_failure == 'invalid response kind' ]] || event_wire=0
  _zrt_event_failure=
  if (( event_wire )); then
    ok "worker events: the current generation is applied, a stale one is dropped unparsed, a broken shape is fatal"
  else
    ng "worker events: collections=$_zrt_event_collections tabs=$_zrt_event_tabs pending=$_zrush_input_pending kind=$_zrush_plan_kind failure=${_zrt_event_failure:-<none>}"
  fi

  # superseded is the normal terminal answer to a capture whose input is
  # already gone: no session failure, no latch, and the listing showing now
  # belongs to whatever replaced that input.
  local -i superseded_wire=1
  wire_reset
  _zrush_input_gen=7
  _zrush_worker_pending=( 12 'store cache 41 7' )
  _zrush_cc_staged=( 12 "$EPOCHSECONDS fingerprint" )
  _zrush_cc_cand_gen=0
  _zrush_worker_failures=1
  _zrush_plan_text=kept _zrush_plan_nlines=3 _zrush_plan_npos=1 _zrush_listing=1
  event_deliver "$frame_superseded"; (( $? == 0 )) || superseded_wire=0
  (( ! ${+_zrush_worker_pending[12]} && $#_zrush_cc_staged == 0 \
     && _zrush_cc_cand_gen == 0 && _zrush_worker_failures == 0 \
     && !_zrush_worker_stopping && _zrush_plan_nlines == 3 )) || superseded_wire=0
  [[ $_zrush_plan_text == kept && -z $_zrt_event_failure ]] || superseded_wire=0
  # Any other store failure leaves that input with no plan-ready coming, so its
  # listing goes.
  _zrush_worker_pending=( 13 'store live 42 7' )
  _zrush_encode_message error 13 invalid-payload
  event_deliver "$REPLY"; (( $? == 0 )) || superseded_wire=0
  (( _zrush_plan_nlines == 0 && _zrush_plan_npos == 0 && !_zrush_listing )) || superseded_wire=0
  [[ $_zrush_plan_kind == none && -z $_zrt_event_failure ]] || superseded_wire=0
  # A store bound to a generation that is no longer current changes nothing.
  _zrush_plan_text=kept _zrush_plan_nlines=3 _zrush_listing=1
  _zrush_worker_pending=( 14 'store live 43 6' )
  _zrush_encode_message error 14 invalid-payload
  event_deliver "$REPLY"
  (( _zrush_plan_nlines == 3 )) || superseded_wire=0
  if (( superseded_wire )); then
    ok "store errors: superseded keeps the listing, another failure clears the input's own"
  else
    ng "store errors: plan L=$_zrush_plan_nlines kind=$_zrush_plan_kind latch=$_zrush_cc_cand_gen failure=${_zrt_event_failure:-<none>}"
  fi

  # Queue discipline: a newer notification replaces the notification frames the
  # older one left unhanded, invalidation removes them, and request frames are
  # never touched (behavior.md "worker ライフサイクル").
  local -i queue_wire=1
  wire_reset
  _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0 _zrush_cc_staged=()
  BUFFER=g LBUFFER=g CURSOR=1
  _zrush_query= _zrush_fuzzy=
  _zrush_request_store live $'b\1\0' 5 >/dev/null
  local request_frame=$_zrush_worker_txq[1]
  _zrush_send_input 2>/dev/null
  local -i first_gen=$_zrush_input_gen
  _zrush_send_flush 2>/dev/null
  (( $#_zrush_worker_txq == 3 )) || queue_wire=0
  _zrush_send_input 2>/dev/null
  (( $#_zrush_worker_txq == 2 && _zrush_input_gen == first_gen + 1 )) || queue_wire=0
  [[ $_zrush_worker_txq[1] == $request_frame ]] || queue_wire=0
  if wire_fields "$_zrush_worker_txq[2]"; then
    hf=( "${(@)reply}" )
    [[ $hf[1] == input && $hf[2] == $_zrush_input_gen ]] || queue_wire=0
  else
    queue_wire=0
  fi
  _zrush_input_invalidate
  (( $#_zrush_worker_txq == 1 && _zrush_input_gen == 0 && _zrush_input_pending == 0 )) || queue_wire=0
  [[ $_zrush_worker_txq[1] == $request_frame ]] || queue_wire=0
  if (( queue_wire )); then
    ok "outbound queue: a newer notification replaces unhanded ones, invalidation removes them, requests stay"
  else
    ng "outbound queue: ${#_zrush_worker_txq} frame(s) left ${(qqqq)_zrush_worker_txq}"
  fi

  # The suppression rules are judged where the notification would be made: a
  # blank buffer, a current word under min-input, and unprocessed key input all
  # invalidate the current generation and produce no notification at all
  # (behavior.md "候補収集"). Only the first two also clear the listing; input
  # pressure merely defers, so what is showing stays until a result replaces it.
  local -i suppress_wire=1
  local why=
  for why in blank min-input pressure; do
    wire_reset
    _zrush_enabled=1 _zrush_disabled=0 _zrush_disable_reason=
    _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0 _zrush_cc_staged=()
    ZRUSH_CFG_MIN_INPUT=0
    _zrush_plan_kind=compsys _zrush_plan_nlines=2 _zrush_plan_npos=1 _zrush_listing=1
    _zrush_last_buffer=old _zrush_last_cursor=0
    _zrush_input_gen=41 _zrush_input_pending=1
    _zrush_worker_txq=( "$frame_input" )   # the old generation's unhanded frame
    case $why in
      blank)     BUFFER='   ' LBUFFER='   ' CURSOR=3 ;;
      min-input) BUFFER=ab LBUFFER=ab CURSOR=2; ZRUSH_CFG_MIN_INPUT=3 ;;
      pressure)  BUFFER=ab LBUFFER=ab CURSOR=2; typeset -g PENDING=1 ;;
    esac
    _zrush_line_pre_redraw
    [[ $why == pressure ]] && PENDING=0
    (( $#_zrush_worker_txq == 0 )) || suppress_wire=0
    (( _zrush_input_gen == 0 && _zrush_input_pending == 0 )) || suppress_wire=0
    if [[ $why == pressure ]]; then
      (( _zrush_plan_nlines == 2 && _zrush_listing == 1 )) || suppress_wire=0
      [[ $_zrush_plan_kind == compsys ]] || suppress_wire=0
    else
      (( _zrush_plan_nlines == 0 && _zrush_plan_npos == 0 && !_zrush_listing )) || suppress_wire=0
      [[ $_zrush_plan_kind == none ]] || suppress_wire=0
    fi
  done
  # The same change with none of the three in the way does make one.
  wire_reset
  _zrush_enabled=1 ZRUSH_CFG_MIN_INPUT=0
  _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0
  _zrush_last_buffer=old _zrush_last_cursor=0
  BUFFER=ab LBUFFER=ab CURSOR=2
  _zrush_line_pre_redraw
  (( $#_zrush_worker_txq == 1 && _zrush_input_gen > 0 && _zrush_input_pending == 1 )) ||
    suppress_wire=0
  if wire_fields "${_zrush_worker_txq[1]:-}"; then
    hf=( "${(@)reply}" )
    [[ $hf[1] == input && $hf[2] == $_zrush_input_gen ]] || suppress_wire=0
  else
    suppress_wire=0
  fi
  if (( suppress_wire )); then
    ok "suppression: a blank buffer, min-input and input pressure invalidate the generation and send nothing"
  else
    ng "suppression: ${#_zrush_worker_txq} frame(s) queued gen=$_zrush_input_gen pending=$_zrush_input_pending L=$_zrush_plan_nlines kind=$_zrush_plan_kind"
  fi
  ZRUSH_CFG_MIN_INPUT=0

  functions[_zrush_worker_session_fail]=$saved_session_fail_ev
  functions[_zrush_start_collection]=$saved_start_collection_ev
  functions[_zrush_tab_with_results]=$saved_tab_ev
  unfunction event_deliver
  unset _zrt_event_failure _zrt_event_collections _zrt_event_tabs
  wire_reset
  _zrush_plan_text= _zrush_plan_nlines=0 _zrush_plan_npos=0 _zrush_plan_kind=none
  _zrush_listing=0 _zrush_tab_pending=0
  POSTDISPLAY=

  unfunction wire_fields wire_reset
  _zrush_worker_rfd=-1 _zrush_worker_ack_fd=-1
  _zrush_close_internal_fd $wire_fd
  _zrush_worker_txq=() _zrush_worker_pending=() _zrush_cc_staged=()
  _zrush_input_gen=0 _zrush_input_pending=0 _zrush_input_latched=0 _zrush_collect_gen=0
  _zrush_enabled=0 _zrush_worker_ready=0
  _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0 _zrush_query= _zrush_fuzzy=

  # ---------------- History snapshot sender ----------------
  # The bootstrap payload is the whole in-memory history, newest first, with no
  # dedup and no `[history].limit` slicing: both moved to the worker's query
  # (cli-protocol.md "history profile"). What the sender still owes is the
  # record shape, the newest-first order, the real event numbers, the wholesale
  # exclusion of empty/framing-byte lines, and the byte ceiling's record-boundary
  # cut.
  # `print -s` leaves its newest entry as the current event until another entry
  # is pushed, so the final sentinel makes "newest" visible without itself
  # entering the `$history` view the payload is built from.
  print -sr -- 'oldest'
  print -sr -- 'dup'
  print -sr -- 'dup'
  print -sr -- 'newest'
  print -sr -- $'bad\1line'
  print -sr -- 'sentinel-not-visible'
  # A limit small enough to slice the payload if anything still honored it.
  ZRUSH_CFG_HISTORY_LIMIT=1
  _zrush_history_snapshot_payload
  local history_payload=$REPLY
  local -i snap_head=$REPLY_HEAD snap_count=$REPLY_COUNT
  local -a history_records=( "${(@0)${history_payload%$'\0'}}" )
  local -i history_ok=1
  local -a lines=() events=()
  local record line event
  [[ $history_records[1] == b$'\1' ]] || history_ok=0
  for record in "${(@)history_records[2,-1]}"; do
    line=${record%%$'\2'*}
    event=${record#*$'\2'}
    [[ $line == w$'\1'* && $event == n$'\1'<-> ]] \
      || { history_ok=0; continue }
    lines+=( "${line#w$'\1'}" )
    events+=( "${event#n$'\1'}" )
  done
  # Every record pairs a real event number with the line stored under it, the
  # walk is newest first, the framing-byte and blank lines are gone whole, and
  # the duplicate is NOT collapsed.
  local -i i
  for (( i = 1; i <= $#lines; i++ )); do
    [[ $history[$events[i]] == "$lines[i]" ]] || history_ok=0
    (( i == 1 )) || (( events[i] < events[i-1] )) || history_ok=0
  done
  [[ ${(j:|:)lines[1,4]} == 'newest|dup|dup|oldest' ]] || history_ok=0
  # The head a snapshot establishes is HISTCMD - 1 as observed at synthesis --
  # not the newest event that reached the payload, which the sentinel and the
  # excluded line both push away from it.
  (( snap_head == HISTCMD - 1 && snap_head > events[1] )) || history_ok=0
  (( snap_count == $#history )) || history_ok=0
  if (( history_ok )); then
    ok "history snapshot: newest-first records with real event numbers, no dedup, no limit slicing"
  else
    dump_bytes "$history_payload"
    ng "history snapshot: unexpected records (head=$snap_head count=$snap_count): $REPLY"
  fi

  # The exclusion rule itself: empty lines and lines carrying a framing byte go
  # whole; every other control byte travels raw and is the display's problem
  # (cli-protocol.md "history profile").
  local -i excl_ok=1
  _zrush_hist_excluded '' || excl_ok=0
  _zrush_hist_excluded $'a\0b' || excl_ok=0
  _zrush_hist_excluded $'a\1b' || excl_ok=0
  _zrush_hist_excluded $'a\2b' || excl_ok=0
  _zrush_hist_excluded 'plain line' && excl_ok=0
  _zrush_hist_excluded $'esc\e[0m tab\t cr\r' && excl_ok=0
  if (( excl_ok )); then
    ok "history exclusion: empty and framing-byte lines only"
  else
    ng "history exclusion: the sender's line filter does not match the profile"
  fi

  # The byte ceiling stops the walk at the record that would cross it, never
  # inside one, so the payload stays a newest-side prefix of the history.
  local -i saved_ceiling=$_ZRUSH_HISTORY_PAYLOAD_MAX_BYTES
  # Room for the framing (b\1 plus the trailing NUL) and the newest record
  # exactly: the second record cannot fit, and half of it must not be sent.
  _ZRUSH_HISTORY_PAYLOAD_MAX_BYTES=$(( 3 + ${#lines[1]} + ${#events[1]} + 6 ))
  _zrush_history_snapshot_payload
  local cut_payload=$REPLY
  _ZRUSH_HISTORY_PAYLOAD_MAX_BYTES=$saved_ceiling
  if [[ $cut_payload == b$'\1'$'\0'w$'\1'newest$'\2'n$'\1'$events[1]$'\0' ]]; then
    ok "history snapshot: the byte ceiling cuts at a record boundary"
  else
    dump_bytes "$cut_payload"
    ng "history snapshot: ceiling cut is not a whole-record prefix: $REPLY"
  fi

  # ---------------- History append sender ----------------
  # One event, same stream shape: a header batch with no shared fields, then the
  # single candidate record (cli-protocol.md "history profile").
  _zrush_history_append_payload 42 'git status'
  if [[ $REPLY == b$'\1'$'\0'w$'\1'"git status"$'\2'n$'\1'42$'\0' ]]; then
    ok "history append: one header batch and one w/n record"
  else
    dump_bytes "$REPLY"
    ng "history append: unexpected payload: $REPLY"
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
