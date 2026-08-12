# zrush.zsh — ZLE integration for asynchronous completion
#
# Requirements: zsh 5.8+, source after compinit, after zsh-abbr, and before
# zsh-syntax-highlighting. This file is embedded into the `zrush` binary and
# loaded via `source <(zrush init zsh)` (cli-protocol.md "zrush init"), which
# injects $ZRUSH_BIN ahead of this file; an already-set $ZRUSH_BIN overrides it.
#
# zsh captures compsys candidates in a forked shell and hands the raw
# capture stream to the persistent Rust worker, which performs matching,
# ranking, grouping, grid layout, highlight/navigation-table computation,
# and insertion-text construction. This file only captures and applies:
# it does not parse candidate records, compute layout, or reconstruct
# insertion text itself.
#
# See docs/internal/specs/behavior.md for observable behavior and architecture.
# See docs/internal/contracts/cli-protocol.md for the zsh/Rust boundary.
#
# Set ZRUSH_LOG=<file> to append timestamped debug traces; unset is a no-op.

# ---------------------------------------------------------------- Re-source teardown
# This runs while the previous definitions and ledgers are still available.
# It is intentionally keyed on prior state, not _zrush_enabled: the circuit
# breaker disables dispatch but leaves registrations that a re-source must undo.
if (( ${_zrush_installed:-0} || ${_zrush_worker_stopping:-0} ||
      ( ${+_zrush_bound} && $#_zrush_bound ) )); then
  () {
    emulate -L zsh
    local seq w prev cur
    # Re-entering source is not an explicit teardown retry.
    (( !${_zrush_worker_stopping:-0} )) || return 1
    if (( $+functions[_zrush_worker_shutdown] )); then
      _zrush_worker_shutdown || return 1
    fi
    (( $+functions[_zrush_worker_runtime_destroy] )) && _zrush_worker_runtime_destroy
    for seq in "${(@k)_zrush_bound}"; do
      w=$_zrush_bound[$seq]
      cur=${${(z)"$(builtin bindkey -M main -- "$seq" 2>/dev/null)"}[2]:-}
      # Do not overwrite a third-party binding installed above zrush.
      if [[ $cur == $w && ${widgets[$w]:-} == user:$w ]]; then
        prev=${_zrush_dsp_prev[$w]:-}
        if builtin bindkey -M main -- "$seq" ${prev:-undefined-key}; then
          zle -D $w 2>/dev/null
          unfunction -- $w 2>/dev/null
          unset "_zrush_dsp_prev[$w]"
        fi
      fi
    done
    (( $+functions[add-zle-hook-widget] )) && {
      add-zle-hook-widget -d line-pre-redraw _zrush-line-pre-redraw 2>/dev/null
      add-zle-hook-widget -d line-init _zrush-line-init 2>/dev/null
      add-zle-hook-widget -d line-finish _zrush-line-finish 2>/dev/null
    }
    (( $+functions[add-zsh-hook] )) && {
      add-zsh-hook -d precmd _zrush_precmd 2>/dev/null
      add-zsh-hook -d zshexit _zrush_zshexit 2>/dev/null
    }
    (( $+functions[_zrush_input_invalidate] )) && _zrush_input_invalidate
    (( $+functions[_zrush_rh_clear] )) && _zrush_rh_clear
    return 0
  }
  (( $? == 0 )) || return 1
fi

# ---------------------------------------------------------------- Global state
typeset -g  ZRUSH_BIN=${ZRUSH_BIN:-}
typeset -gi _zrush_enabled=0
typeset -g  _zrush_cfg_path= _zrush_cfg_mtime=
# Shell-session identity/latches survive a manual re-source; the
# session-failure breaker below is the explicit recovery exception.
typeset -gi _zrush_request_seq=${_zrush_request_seq:-0}
# candidate_generation is independent of request_id and shares its survival
# rule: monotonic per shell session, never reused, never reset by a worker
# restart or a re-source (cli-protocol.md "要求と応答").
typeset -gi _zrush_cand_gen_seq=${_zrush_cand_gen_seq:-0}
# input_generation is the third shell-owned counter, independent of the two
# above and sharing their survival rule (cli-protocol.md "入力通知と worker
# event"): monotonic per shell session, never reused, never reset by a worker
# restart or a re-source.
typeset -gi _zrush_input_gen_seq=${_zrush_input_gen_seq:-0}
typeset -gi _zrush_worker_warned=${_zrush_worker_warned:-0}
typeset -gi _zrush_build_warned=${_zrush_build_warned:-0}
typeset -gi _zrush_worker_failures=${_zrush_worker_failures:-0}
typeset -gi _zrush_disabled=${_zrush_disabled:-0}
typeset -g  _zrush_disable_reason=${_zrush_disable_reason:-}
typeset -g  _zrush_notice=${_zrush_notice:-}
typeset -gi _zrush_build_following=${_zrush_build_following:-0}
if (( _zrush_build_following )); then
  typeset -gi _zrush_build_verifying=${_zrush_build_verifying:-0}
else
  # An explicit source is a fresh stale-build recovery attempt.
  typeset -gi _zrush_build_verifying=0
  if (( _zrush_disabled )) && [[ $_zrush_disable_reason == session-failure ]]; then
    # A user-requested re-source starts a new recovery epoch. Automatic build
    # following keeps this state latched; see behavior.md "worker ライフサイクル".
    _zrush_disabled=0
    _zrush_disable_reason=
    _zrush_worker_failures=0
    typeset -g _zrush_notice=
    zle -R 2>/dev/null
  fi
fi
# A stale-build guard failure disables only this loaded generation. A later
# explicit re-source starts a fresh attempt; fault-policy disable above survives
# unless it is the session-failure breaker handled above.
typeset -gi _zrush_stale_disabled=0
typeset -gi _zrush_worker_stopping=${_zrush_worker_stopping:-0}
typeset -gi _zrush_installed=0
typeset -gi _zrush_status_rendering=0
# Variables this script consumes from `zrush config` output (validation and rollback)
typeset -ga _ZRUSH_CFG_VARS=(
  ZRUSH_CFG_MAX_LINES ZRUSH_CFG_DELAY_MS ZRUSH_CFG_MIN_INPUT
  ZRUSH_CFG_MODE ZRUSH_CFG_SMART_CASE ZRUSH_CFG_TAB ZRUSH_CFG_TRAILING_SPACE
  ZRUSH_CFG_HL_SELECTED ZRUSH_CFG_HL_MATCH ZRUSH_CFG_HL_HEADING
  ZRUSH_CFG_HL_HISTORY_NUMBER
  ZRUSH_CFG_HISTORY_LIMIT ZRUSH_CFG_KEYBINDS ZRUSH_CFG_WARNINGS
)

# Collection request state
typeset -g  _zrush_query= _zrush_fuzzy= _zrush_buf= _zrush_pty= _zrush_capture_pid=
typeset -gi _zrush_rfd=-1 _zrush_wfd=-1 _zrush_gen=0
typeset -g  _zrush_last_buffer=
typeset -gi _zrush_last_cursor=-1
# The one input_generation this shell currently treats as valid (0 = none), and
# what is still expected of it. Declared without `${...:-}` preservation, so a
# re-source starts without one -- one of its invalidation points
# (behavior.md "worker ライフサイクル").
typeset -gi _zrush_input_gen=0
typeset -gi _zrush_input_pending=0   # no worker event has answered it yet
typeset -gi _zrush_input_latched=0   # its notification named the cache latch's generation
# The input_generation the collection in flight was started for, 0 when none is
# running. What the finished capture answers is this one, not whatever is
# current when it finishes.
typeset -gi _zrush_collect_gen=0
typeset -gi _zrush_kick_fd=${_zrush_kick_fd:--1}  # shell-session permanent; see "Watcher self-repair"

# Persistent Rust worker transport.
typeset -gi _zrush_worker_rfd=-1 _zrush_worker_wfd=-1
typeset -gi _zrush_worker_control_wfd=-1
typeset -gi _zrush_worker_drain_fd=-1
typeset -gi _zrush_worker_ack_fd=-1 _zrush_worker_ready=0
typeset -gi _zrush_worker_runtime_tainted=0
typeset -g  _zrush_worker_rx=
typeset -ga _zrush_worker_txq=()      # complete outbound frames; no send offset exists
typeset -g  _zrush_worker_runtime_dir= _zrush_worker_request_path=
typeset -g  _zrush_worker_response_path= _zrush_worker_control_path=
typeset -gi _zrush_worker_callback_seq=${_zrush_worker_callback_seq:-0}
typeset -gA _zrush_worker_callback_generation=( data 0 ack 0 drain 0 )
typeset -gA _zrush_worker_callback_handler=()
typeset -gA _zrush_worker_pending=()
typeset -gi _zrush_sync_target=0 _zrush_sync_done=0 _zrush_sync_ok=0
# Lifecycle stops may block briefly, but each operation uses one 100ms
# absolute budget, matching the existing synchronous history exchange.
typeset -gi _ZRUSH_WORKER_SHUTDOWN_MS=100
# Byte ceiling on one synthesized history payload (behavior.md "履歴メニュー").
typeset -gi _ZRUSH_HISTORY_PAYLOAD_MAX_BYTES=262144

# Render plan received from the Rust worker (cli-protocol.md "plan の ok body").
# zsh applies these verbatim; it never recomputes layout, offsets, or spans.
typeset -g  _zrush_plan_text=          # L display-row texts, \n-joined
typeset -gi _zrush_plan_nlines=0       # L
typeset -gi _zrush_plan_npos=0         # P
typeset -ga _zrush_plan_hl=()          # H entries, each "role pos start len"
typeset -ga _zrush_plan_cells=()       # P entries, each "start len" (1-based by position)
typeset -ga _zrush_plan_nav=()         # P entries, each "next prev left right"
typeset -ga _zrush_plan_insert=()      # P entries, completed insertion text
typeset -g  _zrush_plan_cp=            # common-prefix
typeset -gi _zrush_listing=0
# Which producer the current plan came from: none (no plan) | compsys | history.
# Single source for the listing kind (behavior.md "履歴メニュー"): confirmation
# rule and key mapping branch on this and on nothing else.
typeset -g  _zrush_plan_kind=none

# Rendering (POSTDISPLAY + region_highlight)
typeset -ga _zrush_rh=()      # ledger of entries added to region_highlight
typeset -g  _zrush_rh_sel=    # selected highlight entry, removed separately on input
typeset -g  _zrush_hl_memo=   # ' memo=zrush' on zsh 5.9+

# Selection and Tab state
typeset -gi _zrush_selected=0      # 0=unselected; >0=one-based, column-major display position
typeset -gi _zrush_tab_pending=0   # Tab was pressed before candidates arrived

# See docs/internal/specs/behavior.md "空語収集キャッシュ".
# Cache storage is separate from working state and survives across prompts.
# The parsed candidates live in the worker's `cache` slot; this side keeps only
# the fingerprint, the save time and the candidate store latch. An empty
# fingerprint means no cache entry.
typeset -g  _zrush_cc_fp=          # fingerprint at save time
typeset -gi _zrush_cc_time=0       # save time (EPOCHSECONDS)
# Candidate store latch: the generation this worker session holds in its
# `cache` slot, 0 when there is none. Belongs to the worker session, so a
# source starts without one (behavior.md "worker ライフサイクル").
typeset -gi _zrush_cc_cand_gen=0
# Cache entries whose `store` is still outstanding, by request_id ->
# "<save time> <fingerprint>"; they become the latch on that store's `ok`.
typeset -gA _zrush_cc_staged=()
typeset -gi _ZRUSH_CC_TTL=300      # seconds; catches same-count replacement and is not configurable

# See docs/internal/specs/behavior.md "履歴メニュー".
# The worker owns the history index; this side keeps only the history index
# latch -- the generation that index holds -- and the baseline the two-level
# fingerprint compares against. Declared without `${...:-}` preservation, so a
# re-source starts without an index, which is one of its invalidation points.
# A generation of 0 is the single "not usable" state: an invalid latch and a
# dirty index both mean the next menu op starts from a snapshot.
typeset -gi _zrush_hist_gen=0      # generation the worker's index holds; 0 = cold
typeset -gi _zrush_hist_head=0     # newest event number the index was told about
typeset -gi _zrush_hist_count=0    # ${#history} when that baseline was recorded
typeset -gi _zrush_hist_unacked=0  # appends enqueued whose terminal response is outstanding
# Bound on unacknowledged appends: past it the index goes dirty rather than
# queueing (behavior.md "履歴メニュー"). Internal constant, not configurable.
typeset -gi _ZRUSH_HIST_MAX_UNACKED=8

# Key bindings (dispatch widget -> predecessor/action)
typeset -gA _zrush_dsp_prev=() _zrush_bound=() _zrush_active_dsp=()
typeset -gi _zrush_dsp_n=${_zrush_dsp_n:-0}

# ---------------------------------------------------------------- Utilities
_zlog() { [[ -n $ZRUSH_LOG ]] && print -r -- "[$$ ${EPOCHREALTIME:-0}] $1" >>| $ZRUSH_LOG; return 0 }

_zrush_warn() { print -ru2 -- "zrush: $1" }

# Display worker state through ZLE's redraw-safe status line. `zle -R` is a
# no-op outside an active editor, which keeps source-time and headless tests
# free of a terminal dependency. The hook calls this again on every redraw so
# a latched notice remains visible while the state lasts.
_zrush_status_refresh() {
  emulate -L zsh
  [[ -n $_zrush_notice ]] || return 0
  (( _zrush_status_rendering )) && return 0
  _zrush_status_rendering=1
  zle -R "$_zrush_notice" 2>/dev/null
  _zrush_status_rendering=0
  return 0
}

_zrush_status_set() {
  emulate -L zsh
  typeset -g _zrush_notice=$1
  if [[ -n $_zrush_notice ]]; then
    _zrush_status_refresh
  else
    zle -R 2>/dev/null
  fi
}

_zrush_close_internal_fd() {  # $1=owned fd; idempotent best-effort close
  emulate -L zsh
  local -i fd=${1:--1}
  (( fd < 0 )) && return 0
  if (( fd <= 2 )); then
    _zlog "fd: refusing to close reserved fd=$fd"
    return 0
  fi
  { exec {fd}>&- } 2>/dev/null
  local -i st=$?
  (( st == 0 )) || _zlog "fd: close failed fd=$fd status=$st"
  return 0
}

# ---------------------------------------------------------------- Watcher self-repair
# zsh's zle event loop stops polling a watcher (`events = 0`, "Don't poll
# this" in Src/Zle/zle_main.c raw_getbyte) when one handler-dispatch round
# removes a watcher and registers a new one that reuses the removed fd's
# number and slot while that slot still holds POLLHUP/POLLERR revents. The
# slot recovers on the next dispatch round -- but nothing forces one when the
# silenced fd is the only pending event, and zrush's disposable fds (ack,
# setup, drain, capture) all read from short-lived children whose final
# readiness usually carries exactly that POLLHUP. Writing one byte to this
# permanent self-pipe right after a registration forces the extra round, so a
# silenced watcher never survives the poll that silenced it. Invariant:
# every `zle -F -w` registration is followed by _zrush_kick.
_zrush_kick_init() {  # source-time; idempotent
  emulate -L zsh
  (( _zrush_kick_fd >= 0 )) && return 0
  local fifo=${TMPDIR:-/tmp}/zrush-kick-$$-$RANDOM
  mkfifo $fifo 2>/dev/null || return 1
  if ! sysopen -rw -o cloexec -u _zrush_kick_fd $fifo; then
    _zrush_kick_fd=-1
    command rm -f $fifo 2>/dev/null
    return 1
  fi
  command rm -f $fifo 2>/dev/null
  if ! zle -F -w $_zrush_kick_fd _zrush-kick-drain 2>/dev/null; then
    _zrush_close_internal_fd $_zrush_kick_fd
    _zrush_kick_fd=-1
    return 1
  fi
  return 0
}

_zrush_kick() {
  (( _zrush_kick_fd >= 0 )) || return 0
  syswrite -o $_zrush_kick_fd -- k 2>/dev/null
  return 0
}

_zrush_kick_drain() {  # zle -F -w handler ($1=fd)
  emulate -L zsh
  (( $1 == _zrush_kick_fd )) || return 0
  local junk=
  sysread -t 0 -i $_zrush_kick_fd junk
  return 0
}

# ---------------------------------------------------------------- Widening
# See docs/internal/specs/behavior.md "候補収集" and cli-protocol.md "起動".
_zrush_widen() {  # $1=buffer through the cursor
                  # → REPLY_WIDENED / REPLY_QUERY / REPLY_KEEP / REPLY_WORD
  emulate -L zsh
  setopt extendedglob
  local buf=$1
  local word=${buf##*[[:space:]]}
  local pre=${buf[1,$#buf-$#word]}
  # run widens the collection string but stays in the query, so it is tracked
  # apart from keep, which alone satisfies word == keep + query.
  local keep= query= run=
  if [[ $word == *[/=]* ]]; then
    query=${word##*[/=]}
    keep=${word[1,$#word-$#query]}
  elif [[ $word == -* ]]; then
    run=${(M)word##-##}
    query=$word
  else
    query=$word
  fi
  typeset -g REPLY_WIDENED=$pre$keep$run REPLY_QUERY=$query REPLY_KEEP=$keep REPLY_WORD=$word
}

# ---------------------------------------------------------------- Configuration
_zrush_config_path() {
  typeset -g _zrush_cfg_path=${XDG_CONFIG_HOME:-$HOME/.config}/zrush/config.toml
}

_zrush_config_mtime() {  # -> REPLY (numeric mtime or 'absent')
  emulate -L zsh
  typeset -g REPLY=absent
  local -a st
  zstat -A st +mtime $_zrush_cfg_path 2>/dev/null && REPLY=$st[1]
  return 0
}

# A generated build stamp is lowercase hex ASCII (cli-protocol.md).
_zrush_valid_build_stamp() {
  emulate -L zsh
  setopt localoptions extendedglob
  [[ -n $1 && $1 == [0-9a-f]## ]]
}

_zrush_build_follow_fail() {
  emulate -L zsh
  local why=$1
  _zlog "build: automatic re-source failed: $why"
  if (( !_zrush_build_warned )); then
    _zrush_warn "build stamp mismatch: automatic re-source failed ($why); zrush disabled"
    _zrush_build_warned=1
  fi
  _zrush_stale_disabled=1
  _zrush_build_verifying=0
  _zrush_enabled=0
  (( $+functions[_zrush_worker_shutdown] )) && _zrush_worker_shutdown
  (( $+functions[_zrush_teardown] )) && _zrush_teardown
  return 1
}

# Load and evaluate the current binary's init output. Return 2 after a
# successful generation replacement so callers from the old generation stop
# immediately instead of continuing into duplicate setup or teardown.
_zrush_follow_build() {  # diagnostic reason
  emulate -L zsh
  local why=$1 out init_file
  local -i restart_worker=$(( ${_zrush_worker_rfd:--1} >= 0 ))
  if (( _zrush_build_following || _zrush_build_verifying )); then
    _zrush_build_follow_fail "stamp still mismatched after re-source"
    return 1
  fi
  _zrush_build_following=1
  _zlog "build: stamp mismatch ($why); re-sourcing $ZRUSH_BIN init zsh"
  if ! out=$("$ZRUSH_BIN" init zsh 2>/dev/null); then
    _zrush_build_following=0
    _zrush_build_follow_fail "'$ZRUSH_BIN init zsh' failed"
    return 1
  fi
  # A process-substitution writer would inherit the live worker transport FDs
  # and could keep them open while the replacement tears the worker down.
  init_file=$(command mktemp "${TMPDIR:-/tmp}/zrush-init-${UID}.XXXXXX" 2>/dev/null) || {
    _zrush_build_following=0
    _zrush_build_follow_fail "could not create a temporary init file"
    return 1
  }
  if ! print -rn -- "$out" >| "$init_file"; then
    command rm -f -- "$init_file"
    _zrush_build_following=0
    _zrush_build_follow_fail "could not write the temporary init file"
    return 1
  fi
  source "$init_file"
  local -i st=$?
  command rm -f -- "$init_file"
  _zrush_build_following=0
  if (( st == 0 && _zrush_enabled && !_zrush_stale_disabled )); then
    if (( restart_worker )); then
      _zrush_build_verifying=1
      if ! _zrush_worker_start; then
        _zrush_build_verifying=0
        _zlog "build: replacement worker start deferred after session failure"
      fi
    fi
    _zlog "build: automatic re-source completed stamp=$_ZRUSH_EXPECTED_BUILD_STAMP"
    return 2
  fi
  (( _zrush_stale_disabled )) || _zrush_build_follow_fail "re-sourced initialization failed"
  return 1
}

# Run and source `zrush config`. $1=initial|reload
# Returns 0 on a normal load, 2 when automatic re-source installed a new
# generation, or 1 on failure.
_zrush_load_config() {
  emulate -L zsh
  (( !${_zrush_worker_stopping:-0} )) || return 1
  local out
  out=$("$ZRUSH_BIN" config 2>/dev/null) || return 1
  # eval assigns the globals in place, so snapshot the previous values first;
  # a failed load rolls back (a failed reload keeps the previous configuration).
  local rollback=
  (( $+ZRUSH_BUILD_STAMP )) && \
    rollback=$(typeset -p ZRUSH_BUILD_STAMP "${(@)_ZRUSH_CFG_VARS}" 2>/dev/null)
  # The protocol restricts output to static typeset assignments; evaluate in this controlled scope.
  if ! eval "$out" 2>/dev/null || ! _zrush_validate_config; then
    [[ -n $rollback ]] && eval "$rollback"
    return 1
  fi
  if [[ $ZRUSH_BUILD_STAMP != $_ZRUSH_EXPECTED_BUILD_STAMP ]]; then
    _zrush_follow_build "zsh expects ${(qqqq)_ZRUSH_EXPECTED_BUILD_STAMP}, config reports ${(qqqq)ZRUSH_BUILD_STAMP}"
    return $?
  fi
  _zrush_config_mtime
  _zrush_cfg_mtime=$REPLY
  _zrush_show_cfg_warnings
  return 0
}

# The loaded output must assign every variable this script consumes and an
# even-length keybind array (cli-protocol.md); anything less fails the load.
_zrush_validate_config() {
  emulate -L zsh
  _zrush_valid_build_stamp "$ZRUSH_BUILD_STAMP" || return 1
  local v
  for v in "${(@)_ZRUSH_CFG_VARS}"; do
    (( ${(P)+v} )) || return 1
  done
  (( $#ZRUSH_CFG_KEYBINDS % 2 == 0 ))
}

# Emit config warnings to stderr, one per line. Loads happen only when the
# config mtime changes, so this cannot repeat on unchanged prompts.
_zrush_show_cfg_warnings() {
  emulate -L zsh
  local w
  for w in "${(@)ZRUSH_CFG_WARNINGS}"; do
    print -ru2 -- "zrush: $w"
  done
  return 0
}

# At each prompt, reconcile the worker's history index and reload config.toml
# when its mtime changes.
_zrush_precmd() {
  emulate -L zsh
  (( _zrush_enabled )) || return 0
  # Ahead of the config block, whose reload branches return early: the index
  # must not skip a prompt (behavior.md "履歴メニュー" 更新経路).
  _zrush_hist_reconcile
  _zrush_config_mtime
  if [[ $REPLY != $_zrush_cfg_mtime ]]; then
    _zlog "precmd: config mtime changed ($_zrush_cfg_mtime -> $REPLY); reloading"
    _zrush_load_config reload
    case $? in
      0) _zrush_apply_keybinds ;; # reapply without capturing this layer as its own predecessor
      2) return 0 ;;               # the replacement generation is already fully initialized
      *)
        _zlog "precmd: config reload failed; keeping previous values"
        # Keep the previous configuration after a failed reload; see cli-protocol.md.
        ;;
    esac
  fi
  return 0
}

# ---------------------------------------------------------------- Capture inside the fork
# compadd's option grammar, shared verbatim by the two zparseopts calls below
# (the capture hook needs -O/-A/-D and -d, the encoder needs the rest) so the
# two cannot drift; an incomplete grammar would make zparseopts stop early and
# miss a later option. Each spec is quoted because ':=' inside an array
# assignment would otherwise trigger '=' filename expansion.
typeset -ga _ZRUSH_COMPADD_SPEC=(
  'P:=apre' 'p:=hpre' 'S:=asuf' 's:=hsuf' 'i:=ipre' 'I:=isuf'
  'd:=dscrs' 'X+:=expl' 'O:=_oad' 'A:=_oad' 'D:=_oad' 'f=isfile' 'x:=__'
  'r:' 'R:' 'W:' 'F:' 'M+:' 'E:' 'q' 'e' 'Q' 'n' 'U' 'C'
  'J:=grpJ' 'V:=__' 'a=__' 'l=__' 'k=__' 'o::=__' '1=__' '2=__'
)

# Pure encoder for one compadd call: argv plus the captured candidate arrays in,
# wire bytes out. Emits the compsys 捕獲 profile wire format (cli-protocol.md
# "compsys 捕獲 profile"):
# one batch header record (tag `b`, then whichever of P/p/S/s/i/I/ip/f/rd/X/J are
# non-empty) followed by one thin record per candidate (`w`, optional `m` only
# when it differs from `w`, optional `d`). Batch NUL-terminated records once per
# compadd call because per-record writes caused one read per record and
# measurably degraded large candidate sets.
#
# No I/O and no completion context, so tests/zsh/vectors.zsh can call it
# directly over tests/vectors/encode/. Inputs, all read from the caller's scope:
#   $@                = the argv the compadd call was made with
#   _zrush_enc_hits   = candidates as captured by `compadd -A`
#   _zrush_enc_dscr   = display strings as captured by `compadd -D`
#   $IPREFIX          = the `ip` field, and the base of the `-f` real directory
# Output: REPLY = the bytes to send; empty means send nothing for this call.
# The two arrays are consumed: sanitization rewrites them in place rather than
# copying, because a copy per compadd call is measurable on large candidate sets.
_zrush_encode_batch() {
  builtin setopt localoptions extendedglob norcexpandparam noshglob
  typeset -g REPLY=
  (( $#_zrush_enc_hits > 0 )) || return 0

  local -A apre hpre asuf hsuf ipre isuf dscrs _oad grpJ
  local -a isfile _opts __ expl
  zparseopts -a _opts "${(@)_ZRUSH_COMPADD_SPEC}"

  # Drop framing bytes from value fields before encoding; same treatment as NUL.
  _zrush_enc_hits=( "${(@)_zrush_enc_hits//(#s)*($'\0'|$'\1'|$'\2')*(#e)/}" )
  _zrush_enc_dscr=( "${(@)_zrush_enc_dscr//(#s)*($'\0'|$'\1'|$'\2')*(#e)/}" )
  local _bad_value="*("$'\0'"|"$'\1'"|"$'\2'")*"
  local -a __decoded=( "${(@Q)_zrush_enc_hits}" )
  local -i _bad_i
  while _bad_i=${__decoded[(I)${~_bad_value}]} && (( _bad_i )); do
    _zrush_enc_hits[_bad_i]=
    _zrush_enc_dscr[_bad_i]=
    __decoded[_bad_i]=
  done
  local _rd=
  if (( $#isfile )); then
    # Resolve the real directory for insertion-time '/' handling. Tilde expansion
    # requires the unquoted nested ${}; see notes-zpty.md "置換範囲モデル".
    _rd=${${(Qe)~${:-$IPREFIX${(v)hpre}}}}
  fi
  local -a _vals=(
    "${(v)apre}" "${(v)hpre}" "${(v)asuf}" "${(v)hsuf}"
    "${(v)ipre}" "${(v)isuf}" "$IPREFIX"
    "$_rd" "${expl[2]:-}" "${(v)grpJ}"
  )
  _vals=( "${(@)_vals//(#s)*($'\0'|$'\1'|$'\2')*(#e)/}" )

  # Batch header: shared fields for this compadd call, always emitted even
  # when every field is empty (cli-protocol.md "バッチヘッダレコード": the
  # receiver needs it to delimit batch boundaries).
  local -a _hdr=( "b"$'\1' )
  [[ -n $_vals[1] ]]  && _hdr+=( "P"$'\1'"$_vals[1]" )
  [[ -n $_vals[2] ]]  && _hdr+=( "p"$'\1'"$_vals[2]" )
  [[ -n $_vals[3] ]]  && _hdr+=( "S"$'\1'"$_vals[3]" )
  [[ -n $_vals[4] ]]  && _hdr+=( "s"$'\1'"$_vals[4]" )
  [[ -n $_vals[5] ]]  && _hdr+=( "i"$'\1'"$_vals[5]" )
  [[ -n $_vals[6] ]]  && _hdr+=( "I"$'\1'"$_vals[6]" )
  [[ -n $_vals[7] ]]  && _hdr+=( "ip"$'\1'"$_vals[7]" )
  if (( $#isfile )); then
    _hdr+=( "f"$'\1'"1" )
    [[ -n $_vals[8] ]] && _hdr+=( "rd"$'\1'"$_vals[8]" )
  fi
  [[ -n $_vals[9] ]]  && _hdr+=( "X"$'\1'"$_vals[9]" )
  [[ -n $_vals[10] ]] && _hdr+=( "J"$'\1'"$_vals[10]" )
  local _out="${(pj:\2:)_hdr}"$'\0'

  local -a _rec
  local -i j
  local _d _m
  for (( j = 1; j <= $#_zrush_enc_hits; ++j )); do
    # A candidate blanked above for containing framing bytes has nothing
    # left to send; the contract puts exclusion on the sender (us), so
    # skip it outright instead of emitting a bare empty-w record (Rust's
    # own empty-w skip stays as a defensive fallback, not the guarantee).
    [[ -z $_zrush_enc_hits[j] ]] && continue
    _rec=( "w"$'\1'"$_zrush_enc_hits[j]" )
    _m=$__decoded[j]
    [[ $_m != "$_zrush_enc_hits[j]" ]] && _rec+=( "m"$'\1'"$_m" )
    _d=${_zrush_enc_dscr[j]:-}
    [[ -n $_d ]] && _rec+=( "d"$'\1'"$_d" )
    _out+="${(pj:\2:)_rec}"$'\0'
  done
  typeset -g REPLY=$_out
  return 0
}

# compadd hook installed in functions[compadd] only inside the fork. Captures
# the candidates -- the only part that needs the completion context -- and
# writes what _zrush_encode_batch makes of them.
_zrush_compadd() {
  builtin setopt localoptions extendedglob norcexpandparam noshglob
  local -A apre hpre asuf hsuf ipre isuf dscrs _oad grpJ
  local -a isfile _opts __ expl
  zparseopts -a _opts "${(@)_ZRUSH_COMPADD_SPEC}"
  # -O/-A/-D are internal matching/array calls; delegate without counting candidates.
  if (( $#_oad != 0 )); then
    builtin compadd "$@"
    return
  fi
  local -a _zrush_enc_hits _zrush_enc_dscr
  (( $#dscrs == 1 )) && _zrush_enc_dscr=( "${(@P)${(v)dscrs}}" )
  builtin compadd -A _zrush_enc_hits -D _zrush_enc_dscr "$@"

  # A zero-hit call still needs the tail-call below (compsys internal state,
  # e.g. compstate bookkeeping, depends on every compadd invocation actually
  # reaching the real builtin); only the record-emission side is skippable,
  # which is what an empty REPLY from the encoder means.
  local REPLY=   # keep the encoder's output out of compsys's own REPLY
  _zrush_encode_batch "$@"
  [[ -n $REPLY ]] && print -rn -u $_zrush_wfd -- "$REPLY" 2>/dev/null
  # Also run the original compadd to keep compsys internal state consistent,
  # regardless of whether this call produced any hits.
  builtin compadd "$@"
}

# list-choices-style completion widget for multiple candidates without insertion
_zrush_capture_complete() {
  _zlog "fork: completion widget invoked (context=${curcontext:-none})"
  unset 'compstate[vared]'
  # Make group metadata deterministic inside the fork without touching the user's
  # interactive zstyles. Split by tag and keep -X headings as plain descriptions.
  zstyle ':completion:*' group-name ''
  zstyle ':completion:*:descriptions' format '%d'
  unfunction compadd 2>/dev/null   # remove compadd wrappers installed by other plugins
  functions[compadd]=$functions[_zrush_compadd]
  {
    _main_complete
    _zlog "fork: _main_complete st=$? nmatches=${compstate[nmatches]}"
  } always {
    unfunction compadd 2>/dev/null
  }
  # Suppress insertion, listing, and menu side effects that would flood the pty or enter a menu.
  compstate[insert]=
  compstate[list]=
  unset MENUSELECT MENUMODE
}

# Ordinary widget that injects the widened query and invokes the completion widget.
# The always block closes the write fd and exits, guaranteeing EOF notification even
# when the completion widget returns without calling a function.
_zrush_capture_entry() {
  {
    LBUFFER=$_zrush_query
    RBUFFER=
    builtin zle _zrush-capture-comp -w 2>>| ${ZRUSH_LOG:-/dev/null}
  } always {
    _zrush_close_internal_fd $_zrush_wfd
    builtin exit 0
  }
}

# Fork body executed by zpty after forking the current shell
_zrush_capture_worker() {
  # Prevent recursive zrush activation.
  typeset -gx ZRUSH_INTERNAL=1
  # Fork hygiene: disable inherited hooks and history writes.
  local -a hooks=( chpwd periodic precmd preexec zshaddhistory zshexit )
  builtin unset ${^hooks}_functions 2>/dev/null
  $hooks[@] () { : }
  _zrush_noop() { : }
  local h
  for h in zle-isearch-exit zle-isearch-update zle-line-pre-redraw \
           zle-line-init zle-line-finish zle-history-line-set zle-keymap-select; do
    (( $+widgets[$h] )) && builtin zle -N $h _zrush_noop
  done
  builtin unset HISTFILE 2>/dev/null
  SAVEHIST=0
  # behavior.md "候補収集": generate dotfile candidates unconditionally; keeping
  # them out of the listing until the query opts in is the matcher's rule.
  setopt globdots
  _zlog "fork: start wfd=$_zrush_wfd"
  # The inherited read-side copy is not needed, nor is the self-pipe.
  _zrush_close_internal_fd $_zrush_rfd
  _zrush_close_internal_fd $_zrush_kick_fd
  _zrush_kick_fd=-1
  # Report the real pid first so the parent can SIGINT its process group on cancellation.
  print -rn -u $_zrush_wfd -- "pid"$'\1'"$sysparams[pid]"$'\0' 2>/dev/null
  # The fork inherits active ZLE state, so it can invoke the widget directly.
  builtin zle _zrush-capture-entry 2>>| ${ZRUSH_LOG:-/dev/null}
  builtin exit 0
}

# ---------------------------------------------------------------- Collection start and cancellation
_zrush_cancel_collection() {
  emulate -L zsh
  if (( _zrush_rfd >= 0 )); then
    zle -F $_zrush_rfd 2>/dev/null
    _zrush_close_internal_fd $_zrush_rfd
    _zrush_rfd=-1
  fi
  if (( _zrush_wfd >= 0 )); then
    _zrush_close_internal_fd $_zrush_wfd
    _zrush_wfd=-1
  fi
  if [[ -n $_zrush_pty ]]; then
    # SIGINT the worker's real process group to interrupt external-command waits.
    # Before the pid arrives, zpty -d HUP plus EPIPE after pipe closure is the fallback.
    if [[ $_zrush_capture_pid == <-> ]] && (( _zrush_capture_pid > 1 )); then
      _zlog "cancel: SIGINT to capture pgid $_zrush_capture_pid"
      kill -INT -$_zrush_capture_pid 2>/dev/null || kill -INT $_zrush_capture_pid 2>/dev/null
    fi
    zpty -d $_zrush_pty 2>/dev/null
    _zrush_pty=
  fi
  _zrush_capture_pid=
  _zrush_buf=
  _zrush_collect_gen=0
}

# Drop the current input_generation. Every invalidation point named in
# behavior.md "worker ライフサイクル" goes through here: the worker keeps
# measuring its quiet period and may still send an event, but this shell no
# longer has a generation for it to match, so it is discarded on arrival. No
# cancellation message is sent. The collection that generation started, if any,
# is cancelled with it (behavior.md "候補収集").
_zrush_input_invalidate() {
  emulate -L zsh
  _zrush_input_gen=0 _zrush_input_pending=0 _zrush_input_latched=0
  _zrush_txq_drop_notifications
  _zrush_cancel_collection
  return 0
}

# Remove only this plugin's region_highlight entries.
# ZLE rewrites offsets after buffer edits, so exact original values cannot identify them.
# zsh 5.9+ uses memo=zrush; 5.8 removes entries in the POSTDISPLAY region
# (start >= $#BUFFER), accepting possible collateral removal there.
_zrush_rh_clear() {
  (( $#_zrush_rh )) || return 0
  if [[ -n $_zrush_hl_memo ]]; then
    region_highlight=( "${(@)region_highlight:#*memo=zrush(|-sel)}" )
  else
    region_highlight=( "${(@)region_highlight:|_zrush_rh}" )
    local e
    local -a keep=()
    for e in "${(@)region_highlight}"; do
      if [[ $e == <->" "* ]] && (( ${e%% *} >= $#BUFFER )); then
        continue
      fi
      keep+=( "$e" )
    done
    region_highlight=( "${(@)keep}" )
  fi
  _zrush_rh=()
  _zrush_rh_sel=
  return 0
}

# Remove only the selection highlight after input or cursor movement; retain list text
# and match/heading/history-number decoration until the next result.
_zrush_rh_clear_sel() {
  [[ -n $_zrush_rh_sel ]] || return 0
  if [[ -n $_zrush_hl_memo ]]; then
    region_highlight=( "${(@)region_highlight:#*memo=zrush-sel}" )
  else
    # On 5.8, remove only an exact match. If ZLE changed its offsets after editing,
    # accept that it remains until the next render.
    local -a _sel=( "$_zrush_rh_sel" )
    region_highlight=( "${(@)region_highlight:|_sel}" )
  fi
  local -a _sel2=( "$_zrush_rh_sel" )
  _zrush_rh=( "${(@)_zrush_rh:|_sel2}" )
  _zrush_rh_sel=
  return 0
}

_zrush_rh_add() {  # $1=start $2=end $3=spec [$4=memo suffix (-sel)]
                   # Offsets are character counts from the start of BUFFER.
  local e="$1 $2 $3${_zrush_hl_memo:+ memo=zrush${4:-}}"
  region_highlight+=( "$e" )
  _zrush_rh+=( "$e" )
  [[ ${4:-} == -sel ]] && _zrush_rh_sel=$e
  return 0
}

# Drop the listing and everything that describes it: display, selection, plan
# (kind included), and any pending Tab. Unconditional -- it never inspects
# _zrush_listing -- so no caller has to reason about whether something is
# currently showing, and stale plan state from an earlier prompt or query can
# never survive to be used by a later pending Tab or confirmation.
# Call only from a ZLE widget context. Work in flight (the input_generation
# awaiting a worker event, the collection it started) is not part of the
# listing; callers that must also stop it call _zrush_input_invalidate first.
_zrush_teardown() {
  POSTDISPLAY=
  _zrush_rh_clear
  _zrush_listing=0
  _zrush_selected=0
  _zrush_tab_pending=0
  _zrush_plan_text= _zrush_plan_nlines=0 _zrush_plan_npos=0
  _zrush_plan_hl=() _zrush_plan_cells=() _zrush_plan_nav=() _zrush_plan_insert=()
  _zrush_plan_cp=
  _zrush_plan_kind=none
  return 0
}

# ---------------------------------------------------------------- Empty-word collection cache
# See docs/internal/specs/behavior.md "空語収集キャッシュ".
# Do not use $#commands: lazy command hashing changes its size independently of the
# candidate set. Directory mtimes detect executable additions and removals.
_zrush_cc_fingerprint() {
  emulate -L zsh
  local fp=$PATH
  local d
  local -i rel=0
  local -a st
  for d in $path; do
    [[ $d == /* ]] || rel=1
    if zstat -A st +mtime $d 2>/dev/null; then
      fp+=":$st[1]"
    else
      fp+=":-"
    fi
  done
  fp+=":$#functions:$#aliases:$#builtins"
  if [[ -o autocd ]] || (( rel )); then
    fp+=":$PWD"
  fi
  typeset -g REPLY=$fp
  return 0
}

# The worker no longer holds the cache slot's generation. Called from every
# invalidation point named in behavior.md "worker ライフサイクル".
_zrush_cc_latch_drop() {
  _zrush_cc_cand_gen=0
  return 0
}

_zrush_cc_invalidate() {
  _zrush_cc_fp=
  _zrush_cc_time=0
  _zrush_cc_latch_drop
  return 0
}

# Is this input the empty-word cache's subject? Asked when the notification is
# made, to name the latched generation on it, and again on the finished capture
# -- which also has to be non-empty -- to pick the `cache` slot. Nothing outside
# the subject can overwrite the latched generation.
_zrush_cc_subject() {
  [[ -z $_zrush_query ]]
}

# Checked when the notification is made (behavior.md "空語収集キャッシュ").
_zrush_cc_check() {  # 0=usable hit; on a miss, log the reason and return nonzero
  emulate -L zsh
  if [[ -z $_zrush_cc_fp ]]; then
    _zlog "cache: miss (empty)"
    return 1
  fi
  if (( _zrush_cc_cand_gen <= 0 )); then
    _zlog "cache: miss (latch)"
    _zrush_cc_invalidate
    return 1
  fi
  if (( EPOCHSECONDS - _zrush_cc_time > _ZRUSH_CC_TTL )); then
    _zlog "cache: miss (ttl)"
    _zrush_cc_invalidate
    return 1
  fi
  _zrush_cc_fingerprint
  if [[ $REPLY != "$_zrush_cc_fp" ]]; then
    _zlog "cache: miss (fingerprint)"
    _zrush_cc_invalidate
    return 1
  fi
  _zlog "cache: hit (generation=$_zrush_cc_cand_gen)"
  return 0
}

# The latch may only name a generation the worker actually holds
# (behavior.md "空語収集キャッシュ"), so an entry is staged when the `cache`
# store goes out and committed when that store's `ok` comes back. The
# fingerprint and the save time are snapshotted here, at collection time:
# computing them on arrival would describe an environment the capture never saw.
_zrush_cc_stage() {  # $1=store request_id
  emulate -L zsh
  _zrush_cc_fingerprint
  _zrush_cc_staged[$1]="$EPOCHSECONDS $REPLY"
  return 0
}

_zrush_cc_commit() {  # $1=store request_id $2=generation the worker accepted
  emulate -L zsh
  local staged=${_zrush_cc_staged[$1]:-}
  unset "_zrush_cc_staged[$1]"
  [[ -n $staged ]] || return 0
  _zrush_cc_time=${staged%% *}
  _zrush_cc_fp=${staged#* }
  _zrush_cc_cand_gen=$2
  _zlog "cache: latched (generation=$2)"
  return 0
}

# Start the compsys collection for the current input_generation, from a widget
# or handler context. Only a `capture-required` event matching that generation
# gets here (behavior.md "候補収集"); the query and the widened collection
# string are the ones snapshotted when its notification was made, because any
# buffer change since would have invalidated the generation.
_zrush_start_collection() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify
  [[ -n $ZRUSH_INTERNAL ]] && return 0
  _zrush_cancel_collection
  _zlog "collect: widened=${(qqqq)_zrush_query} fuzzy=${(qqqq)_zrush_fuzzy} input_generation=$_zrush_input_gen"

  # Anonymous pipe: open both FIFO ends, unlink immediately, and use EOF as terminator.
  local fifo=${TMPDIR:-/tmp}/zrush-$$-$RANDOM.fifo
  mkfifo $fifo 2>/dev/null || return 1
  local rw
  exec {rw}<>$fifo
  exec {_zrush_rfd}<$fifo
  exec {_zrush_wfd}>$fifo
  _zrush_close_internal_fd $rw
  rm -f $fifo

  _zrush_pty=zrush-w$(( ++_zrush_gen ))
  if ! zpty $_zrush_pty _zrush_capture_worker; then
    _zlog "collect: zpty create failed"
    _zrush_cancel_collection
    return 1
  fi
  # Close the parent's write-side copy immediately after the fork so EOF remains detectable.
  _zrush_close_internal_fd $_zrush_wfd
  _zrush_wfd=-1

  # Recorded once the collection really is in flight: this is the generation its
  # capture answers, whatever becomes current before it finishes.
  _zrush_collect_gen=$_zrush_input_gen
  zle -F -w $_zrush_rfd _zrush-on-data
  _zrush_kick
  _zlog "collect: collecting on fd $_zrush_rfd (pty $_zrush_pty) for input_generation=$_zrush_collect_gen"
  return 0
}

# ---------------------------------------------------------------- Receive and finalize
_zrush_on_data() {  # zle -F -w handler ($1=fd)
  emulate -L zsh
  local -i fd=$1
  local chunk= st=0
  sysread -i $fd chunk; st=$?
  if (( st == 0 )); then
    _zrush_buf+=$chunk
    # Consume the leading pid-report record.
    if [[ -z $_zrush_capture_pid && $_zrush_buf == *$'\0'* ]]; then
      local first=${_zrush_buf%%$'\0'*}
      if [[ $first == pid$'\1'<-> ]]; then
        _zrush_capture_pid=${first#pid$'\1'}
        _zrush_buf=${_zrush_buf#*$'\0'}
      fi
    fi
    return 0
  fi
  # EOF (5) or a read error ends reception for this request.
  zle -F $fd 2>/dev/null
  _zrush_close_internal_fd $fd
  _zrush_rfd=-1
  zpty -d $_zrush_pty 2>/dev/null
  _zrush_pty=
  _zrush_capture_pid=
  if (( st == 5 )); then
    _zrush_finalize
    # zle -F -w does not redraw on return, and a failed store clears the listing
    # here; the plan the accepted store produces arrives as an event and redraws
    # on its own.
    zle -R
  else
    _zlog "on-data: read error st=$st; dropping collection"
    _zrush_buf=
  fi
  return 0
}

# Collection payload (pid already stripped) -> one `store` request.
# The payload is handed to Rust unparsed: record parsing, matching,
# ranking, layout, and highlight/nav/insert construction are all Rust's job
# (cli-protocol.md). It goes out once, under a fresh candidate generation and
# bound to the input_generation whose `capture-required` asked for it; zsh
# keeps no copy and pipelines no `plan` behind it, because the worker answers
# an accepted store with the `plan-ready` for that same input. A successful
# empty-word command-position collection is the cache's subject, so it stores
# into the `cache` slot; the latch itself is staged here and taken only once
# that store answers `ok` (behavior.md "空語収集キャッシュ").
_zrush_finalize() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify
  local payload=$_zrush_buf
  _zrush_buf=
  # Marks "transport" (fork -> parent pipe) complete, mirroring every other
  # pipeline stage's own checkpoint; driver-latency.zsh's breakdown reads it.
  _zlog "finalize: ${#payload} bytes"
  # Every store carries the binding of the input this capture answers, and only
  # an input this shell still treats as valid has an answer worth sending: a
  # capture that outlived its generation is dropped rather than stored
  # (behavior.md "候補収集").
  local -i bound=$_zrush_collect_gen
  _zrush_collect_gen=0
  (( bound > 0 && bound == _zrush_input_gen )) || {
    _zlog "finalize: capture generation=$bound is no longer current ($_zrush_input_gen); dropping it"
    return 0
  }
  local slot=live
  _zrush_cc_subject && [[ -n $payload ]] && slot=cache
  _zrush_request_store $slot "$payload" $bound || _zrush_teardown
  return 0
}

# Apply the plan the worker just sent for the current input, then resolve a Tab
# recorded before it arrived, so the pending-Tab handling in behavior.md "Tab"
# ("候補未着時の Tab は...結果到着時に上記の挙動を適用する") lives in one place.
_zrush_settle_plan() {
  emulate -L zsh
  _zrush_apply_plan
  if (( _zrush_tab_pending )); then
    _zrush_tab_pending=0
    _zrush_tab_with_results
  fi
  return 0
}

# ---------------------------------------------------------------- Worker transport
_zrush_netstring() {
  emulate -L zsh
  local LC_ALL=C data=$1
  typeset -g REPLY="${#data}:$data,"
}

# Return 0 with REPLY/REPLY_REST, 1 for incomplete input, or 2 for malformed input.
_zrush_netstring_take() {
  emulate -L zsh
  setopt localoptions extendedglob
  local LC_ALL=C data=$1 digits payload
  typeset -g REPLY= REPLY_REST=
  if [[ $data != *:* ]]; then
    [[ -z $data || $data == [0-9]# ]] && return 1
    return 2
  fi
  digits=${data%%:*}
  [[ $digits == 0 || $digits == [1-9][0-9]# ]] || return 2
  # Reject an unrepresentable declared length lexically, before either the
  # available-byte comparison or zsh integer conversion can truncate it.
  _zrush_dec_le_all 9223372036854775807 "$digits" || return 2
  (( $#digits + 2 <= $#data )) || return 1
  local -i available=$(( $#data - $#digits - 2 ))
  _zrush_dec_le_all $available "$digits" || return 1
  local -i n=$digits start=$(( $#digits + 2 )) comma
  comma=$(( start + n ))
  (( comma <= $#data )) || return 1
  [[ ${data[comma]} == , ]] || return 2
  payload=${data[start,comma-1]}
  typeset -g REPLY=$payload REPLY_REST=${data[comma+1,-1]}
  return 0
}

_zrush_decode_fields() {
  emulate -L zsh
  local data=$1 field rest
  local -a fields=()
  while [[ -n $data ]]; do
    _zrush_netstring_take "$data"
    (( $? == 0 )) || return 1
    field=$REPLY rest=$REPLY_REST
    fields+=( "$field" )
    data=$rest
  done
  typeset -ga reply=( "${(@)fields}" )
  return 0
}

_zrush_encode_message() {
  emulate -L zsh
  local payload= field
  for field in "$@"; do
    _zrush_netstring "$field"
    payload+=$REPLY
  done
  _zrush_netstring "$payload"
}

_zrush_worker_warn_once() {
  (( _zrush_worker_warned )) && return 0
  _zrush_worker_warned=1
  _zrush_status_set "zrush: worker transport failed; retrying once"
}

_zrush_worker_invalidate_callback() {  # data|ack|drain fd
  emulate -L zsh
  local kind=$1 handler=${_zrush_worker_callback_handler[$1]:-}
  local -i fd=${2:--1}
  # Invalidate the registration identity before removing its watcher, widget,
  # or function: a callback already snapshotted by ZLE must fail its generation
  # check even if the numeric fd has since been reused.
  _zrush_worker_callback_generation[$kind]=0
  _zrush_worker_callback_handler[$kind]=
  (( fd >= 0 )) && zle -F $fd 2>/dev/null
  if [[ -n $handler ]]; then
    zle -D $handler 2>/dev/null
    unfunction -- $handler 2>/dev/null
  fi
  return 0
}

_zrush_worker_register_callback() {  # data|ack|drain fd
  emulate -L zsh
  local kind=$1
  local -i fd=$2 generation=$(( ++_zrush_worker_callback_seq ))
  local handler=_zrush-worker-${kind}-${generation}
  _zrush_worker_invalidate_callback $kind -1
  _zrush_worker_callback_generation[$kind]=$generation
  _zrush_worker_callback_handler[$kind]=$handler
  functions[$handler]="_zrush_worker_on_${kind} \"\$1\" $generation"
  if ! zle -N $handler $handler 2>/dev/null ||
     ! zle -F -w $fd $handler 2>/dev/null; then
    _zrush_worker_invalidate_callback $kind $fd
    return 1
  fi
  return 0
}

_zrush_worker_callback_current() {  # kind fd generation
  emulate -L zsh
  local kind=$1
  local -i fd=$2 generation=$3 expected_fd=-1
  (( generation > 0 &&
     generation == ${_zrush_worker_callback_generation[$kind]:-0} )) || return 1
  case $kind in
    data)  expected_fd=$_zrush_worker_rfd ;;
    ack)   expected_fd=$_zrush_worker_ack_fd ;;
    drain) expected_fd=$_zrush_worker_drain_fd ;;
    *) return 1 ;;
  esac
  [[ $kind != drain ]] || (( !_zrush_worker_stopping )) || return 1
  (( fd >= 0 && fd == expected_fd ))
}

_zrush_worker_disarm_drain() {
  _zrush_worker_invalidate_callback drain $_zrush_worker_drain_fd
  if (( _zrush_worker_drain_fd >= 0 )); then
    _zrush_close_internal_fd $_zrush_worker_drain_fd
    _zrush_worker_drain_fd=-1
  fi
}

# Raw response drain. Return 0=EOF, 1=open/EAGAIN, 2=read error, 3=deadline.
_zrush_worker_poll_eof() {  # fd [absolute-deadline [max-reads]]
  emulate -L zsh
  local chunk= deadline=${2:-}
  local -i fd=$1 st reads=0 max_reads=${3:-0}
  while true; do
    [[ -n $deadline ]] && (( EPOCHREALTIME >= deadline )) && return 3
    sysread -t 0 -i $fd chunk; st=$?
    if (( st == 0 )); then
      (( ++reads ))
      (( max_reads > 0 && reads >= max_reads )) && return 1
      continue
    fi
    (( st == 4 )) && return 1
    (( st == 5 )) && return 0
    return 2
  done
}

# Ack alone releases the delegated writer slot. EOF before ack is failure.
_zrush_worker_poll_writer() {  # [absolute-deadline]
  emulate -L zsh
  local ack= deadline=${1:-}
  local -i st
  [[ -n $deadline ]] && (( EPOCHREALTIME >= deadline )) && return 3
  sysread -s 1 -t 0 -i $_zrush_worker_ack_fd ack; st=$?
  (( st == 0 )) && { [[ $ack == 1 ]] && return 0 || return 2 }
  (( st == 4 )) && return 1
  (( st == 5 )) && return 2
  return 2
}

_zrush_worker_wait() {  # deadline fd...
  emulate -L zsh
  local -F deadline=$1 remaining
  shift
  local -a args=()
  local -i fd cs
  for fd in "$@"; do (( fd >= 0 )) && args+=( -r $fd ); done
  (( $#args )) || return 1
  remaining=$(( deadline - EPOCHREALTIME ))
  (( remaining > 0 )) || return 1
  cs=$(( remaining * 100 ))
  (( cs >= 1 )) || return 1
  zselect -t $cs "${(@)args}" >/dev/null 2>&1
}

_zrush_worker_runtime_prepare() {
  emulate -L zsh
  setopt localoptions no_bg_nice
  [[ -z $_zrush_worker_runtime_dir ]] || return 0
  local old_umask=$(umask) dir= req= resp= control=
  umask 077
  dir=$(command mktemp -d "${TMPDIR:-/tmp}/zrush-${UID}.XXXXXX" 2>/dev/null) || {
    umask $old_umask
    return 1
  }
  req=$dir/request resp=$dir/response control=$dir/abort
  if ! command chmod 700 "$dir" 2>/dev/null ||
     ! command mkfifo "$req" "$resp" "$control" 2>/dev/null ||
     ! command chmod 600 "$req" "$resp" "$control" 2>/dev/null; then
    command rm -f "$req" "$resp" "$control" >/dev/null 2>&1
    command rmdir "$dir" >/dev/null 2>&1
    umask $old_umask
    return 1
  fi
  umask $old_umask
  _zrush_worker_runtime_dir=$dir
  _zrush_worker_request_path=$req
  _zrush_worker_response_path=$resp
  _zrush_worker_control_path=$control
  return 0
}

_zrush_worker_runtime_valid() {
  (( !_zrush_worker_runtime_tainted )) &&
    [[ -n $_zrush_worker_runtime_dir && -d $_zrush_worker_runtime_dir &&
       -p $_zrush_worker_request_path && -p $_zrush_worker_response_path &&
       -p $_zrush_worker_control_path ]]
}

_zrush_worker_runtime_taint() {
  emulate -L zsh
  _zrush_worker_runtime_tainted=1
  [[ -n $_zrush_worker_request_path ]] && command rm -f "$_zrush_worker_request_path" >/dev/null 2>&1
  [[ -n $_zrush_worker_response_path ]] && command rm -f "$_zrush_worker_response_path" >/dev/null 2>&1
  [[ -n $_zrush_worker_control_path ]] && command rm -f "$_zrush_worker_control_path" >/dev/null 2>&1
}

_zrush_worker_runtime_destroy() {
  emulate -L zsh
  local dir=$_zrush_worker_runtime_dir
  [[ -n $_zrush_worker_request_path ]] && command rm -f "$_zrush_worker_request_path" >/dev/null 2>&1
  [[ -n $_zrush_worker_response_path ]] && command rm -f "$_zrush_worker_response_path" >/dev/null 2>&1
  [[ -n $_zrush_worker_control_path ]] && command rm -f "$_zrush_worker_control_path" >/dev/null 2>&1
  [[ -n $dir ]] && command rmdir "$dir" >/dev/null 2>&1
  _zrush_worker_runtime_dir= _zrush_worker_request_path=
  _zrush_worker_response_path= _zrush_worker_control_path=
}

_zrush_worker_release_writer() {
  local -i fd=$_zrush_worker_ack_fd
  _zrush_worker_invalidate_callback ack $fd
  (( fd >= 0 )) && _zrush_close_internal_fd $fd
  _zrush_worker_ack_fd=-1
}

_zrush_worker_close_request() {
  (( _zrush_worker_wfd >= 0 )) || return 0
  _zrush_close_internal_fd $_zrush_worker_wfd
  _zrush_worker_wfd=-1
}

_zrush_worker_close_control() {
  (( _zrush_worker_control_wfd >= 0 )) || return 0
  _zrush_close_internal_fd $_zrush_worker_control_wfd
  _zrush_worker_control_wfd=-1
}

_zrush_worker_close_response() {
  _zrush_worker_invalidate_callback data $_zrush_worker_rfd
  if (( _zrush_worker_rfd >= 0 )); then
    _zrush_close_internal_fd $_zrush_worker_rfd
    _zrush_worker_rfd=-1
  fi
  _zrush_worker_rx=
}

_zrush_worker_begin_stop() {
  emulate -L zsh
  _zrush_worker_stopping=1
  # The candidate store and the history index die with the session, whether
  # this is a normal shutdown, an abort, or a session failure
  # (behavior.md "worker ライフサイクル": one invalidation set for both latches).
  _zrush_cc_latch_drop
  _zrush_hist_invalidate session-stop
  # The worker's current input dies with the session too, so the generation it
  # would have answered is invalidated here and never replayed.
  _zrush_input_invalidate
  _zrush_worker_disarm_drain
  _zrush_worker_txq=()
  _zrush_worker_pending=()
  _zrush_cc_staged=()
  _zrush_sync_target=0 _zrush_sync_done=0 _zrush_sync_ok=0
}

_zrush_worker_finalize() {
  emulate -L zsh
  (( _zrush_worker_ack_fd < 0 && _zrush_worker_rfd < 0 )) || return 1
  _zrush_worker_disarm_drain
  _zrush_worker_release_writer
  _zrush_worker_close_request
  _zrush_worker_close_control
  _zrush_worker_ready=0
  _zrush_worker_rx=
  _zrush_worker_txq=()
  _zrush_worker_pending=()
  _zrush_cc_staged=()
  _zrush_sync_target=0 _zrush_sync_done=0 _zrush_sync_ok=0
  _zrush_worker_stopping=0
  _zlog "worker: transport stopped"
  return 0
}

_zrush_worker_signal_abort() {
  emulate -L zsh
  setopt localoptions localtraps
  (( _zrush_worker_control_wfd >= 0 )) || return 0
  trap '' PIPE
  syswrite -o $_zrush_worker_control_wfd -- x 2>/dev/null
  return 0
}

_zrush_worker_stop_progress() {  # sync|async [absolute-deadline]
  emulate -L zsh
  local mode=${1:-async} deadline=${2:-}
  local -i st
  if (( _zrush_worker_ack_fd >= 0 )); then
    if [[ $mode == sync ]]; then
      _zrush_worker_poll_writer $deadline
    else
      _zrush_worker_poll_writer
    fi
    st=$?
    if (( st == 0 || st == 2 )); then
      _zlog "worker: stop writer slot released status=$st"
      _zrush_worker_release_writer
    fi
  fi
  if (( _zrush_worker_rfd >= 0 )); then
    if [[ $mode == sync ]]; then
      _zrush_worker_poll_eof $_zrush_worker_rfd $deadline
    else
      _zrush_worker_poll_eof $_zrush_worker_rfd '' 4
    fi
    st=$?
    if (( st == 0 )); then
      _zrush_worker_close_response
    elif (( st == 2 )); then
      _zlog "worker: stop response drain failed errno=$ERRNO"
      _zrush_worker_invalidate_callback data $_zrush_worker_rfd
    fi
  fi
  if (( _zrush_worker_ack_fd < 0 && _zrush_worker_rfd < 0 )); then
    _zrush_worker_finalize
    return $?
  fi
  return 1
}

_zrush_worker_abort() {  # [absolute-deadline]
  emulate -L zsh
  setopt localoptions no_bg_nice
  (( _zrush_worker_stopping )) || _zrush_worker_begin_stop
  _zrush_worker_signal_abort
  _zrush_worker_close_control
  _zrush_worker_close_request
  local -F deadline=${1:-$(( EPOCHREALTIME + _ZRUSH_WORKER_SHUTDOWN_MS / 1000.0 ))}
  while (( EPOCHREALTIME < deadline )); do
    _zrush_worker_stop_progress sync $deadline && return 0
    _zrush_worker_wait $deadline $_zrush_worker_ack_fd $_zrush_worker_rfd || break
  done
  _zrush_worker_stop_progress async && return 0
  _zlog "worker: abort quarantined after absolute deadline=$deadline"
  return 1
}

_zrush_worker_shutdown() {
  emulate -L zsh
  setopt localoptions no_bg_nice
  if (( _zrush_worker_stopping )); then
    _zrush_worker_stop_progress async
    return $?
  fi
  _zrush_worker_begin_stop
  local -F deadline=$(( EPOCHREALTIME + _ZRUSH_WORKER_SHUTDOWN_MS / 1000.0 ))
  local -i st

  while (( _zrush_worker_ack_fd >= 0 )); do
    _zrush_worker_poll_writer $deadline; st=$?
    if (( st == 0 )); then
      _zrush_worker_release_writer
      break
    fi
    if (( st == 2 || st == 3 )) ||
       ! _zrush_worker_wait $deadline $_zrush_worker_ack_fd; then
      _zlog "worker: healthy writer did not ack; aborting"
      _zrush_worker_abort $deadline
      return $?
    fi
  done

  _zrush_worker_close_request
  _zrush_worker_rx=
  while (( _zrush_worker_rfd >= 0 )); do
    _zrush_worker_poll_eof $_zrush_worker_rfd $deadline; st=$?
    if (( st == 0 )); then
      _zrush_worker_close_response
      break
    fi
    if (( st == 2 || st == 3 )) ||
       ! _zrush_worker_wait $deadline $_zrush_worker_rfd; then
      _zlog "worker: healthy response drain failed or expired; aborting"
      _zrush_worker_abort $deadline
      return $?
    fi
  done
  _zrush_worker_finalize
}
_zrush_worker_disable_policy() {
  emulate -L zsh
  _zlog "worker: disabling: $1"
  (( _zrush_worker_warned )) || _zrush_worker_warned=1
  _zrush_disable_reason=policy
  _zrush_disabled=1
  _zrush_enabled=0
  _zrush_status_set "zrush: worker disabled ($1); start a new shell"
}

_zrush_worker_fail_session() {
  emulate -L zsh
  local why=$1
  _zlog "worker: session failure: $why"
  _zrush_worker_warn_once
  _zrush_worker_abort
  _zrush_teardown
  (( ++_zrush_worker_failures ))
  if (( _zrush_worker_failures >= 2 )); then
    _zrush_disable_reason=session-failure
    _zrush_disabled=1
    _zrush_enabled=0
    _zrush_status_set "zrush: worker disabled after repeated failures; source <(zrush init zsh) to retry"
    _zlog "worker: circuit breaker opened"
  fi
  return 1
}

_zrush_worker_session_fail() {
  (( !_zrush_worker_stopping )) || return 1
  _zrush_worker_fail_session "$1"
}

_zrush_worker_start() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify no_bg_nice localtraps
  (( !_zrush_disabled && !_zrush_worker_stopping && !_zrush_worker_runtime_tainted )) || return 1
  (( _zrush_worker_rfd >= 0 )) && return 0
  # A new session starts with empty slots and an uninitialized index.
  _zrush_cc_latch_drop
  _zrush_hist_invalidate session-start
  _zrush_worker_runtime_valid || {
    _zrush_worker_session_fail "worker runtime unavailable"
    return 1
  }

  local req_anchor= child_in= parent_w=
  local resp_anchor= parent_r= child_out=
  local ctl_anchor= child_ctl= parent_ctl= spawn_fd=
  local -i fd endpoint_failed=0 spawn_ok=0 watcher_ok=0 spawn_st
  if ! sysopen -rw -o cloexec -u req_anchor "$_zrush_worker_request_path" ||
       ! sysopen -r -o cloexec -u child_in "$_zrush_worker_request_path" ||
       ! sysopen -w -o cloexec -u parent_w "$_zrush_worker_request_path" ||
       ! sysopen -rw -o cloexec -u resp_anchor "$_zrush_worker_response_path" ||
       ! sysopen -r -o cloexec -u parent_r "$_zrush_worker_response_path" ||
       ! sysopen -w -o cloexec -u child_out "$_zrush_worker_response_path" ||
       ! sysopen -rw -o cloexec -u ctl_anchor "$_zrush_worker_control_path" ||
       ! sysopen -r -u child_ctl "$_zrush_worker_control_path" ||
       ! sysopen -w -o cloexec -u parent_ctl "$_zrush_worker_control_path"; then
    endpoint_failed=1
  fi
  for fd in $req_anchor $child_in $parent_w $resp_anchor $parent_r \
            $child_out $ctl_anchor $child_ctl $parent_ctl; do
    (( fd > 2 )) || endpoint_failed=1
  done

  if (( endpoint_failed )); then
    for fd in $req_anchor $child_in $parent_w $resp_anchor $parent_r \
              $child_out $ctl_anchor $child_ctl $parent_ctl; do
      [[ -n $fd ]] && (( fd > 2 )) && _zrush_close_internal_fd $fd
    done
    _zrush_worker_session_fail "worker endpoint acquisition failed"
    return 1
  fi

  exec {spawn_fd}< <(
    exec 0<&$child_in || exit 1
    exec 1>&$child_out || exit 1
    exec {child_in}>&- {child_out}>&-
    exec {req_anchor}>&- {parent_w}>&-
    exec {resp_anchor}>&- {parent_r}>&-
    exec {ctl_anchor}>&- {parent_ctl}>&-
    exec "$ZRUSH_BIN" worker --control-fd "$child_ctl" 2>>| "${ZRUSH_LOG:-/dev/null}"
  )
  spawn_st=$?
  (( spawn_st == 0 )) && [[ -n $spawn_fd ]] && (( spawn_fd > 2 )) && spawn_ok=1
  for fd in $spawn_fd $req_anchor $child_in $resp_anchor $child_out $ctl_anchor $child_ctl; do
    [[ -n $fd ]] && (( fd > 2 )) && _zrush_close_internal_fd $fd
  done

  if (( spawn_ok )) && _zrush_worker_register_callback data $parent_r; then
    watcher_ok=1
  fi
  if (( !spawn_ok || !watcher_ok )); then
    _zrush_worker_begin_stop
    _zrush_worker_rfd=$parent_r
    _zrush_worker_wfd=$parent_w
    _zrush_worker_control_wfd=$parent_ctl
    _zrush_worker_ready=0
    _zrush_worker_rx=
    if (( !watcher_ok )); then
      if (( !spawn_ok )) && _zrush_worker_register_callback data $parent_r; then
        watcher_ok=1
        _zrush_kick
      else
        _zrush_worker_runtime_taint
      fi
    fi
    _zrush_worker_fail_session "worker post-spawn publication failed"
    return 1
  fi

  _zrush_worker_rfd=$parent_r
  _zrush_worker_wfd=$parent_w
  _zrush_worker_control_wfd=$parent_ctl
  _zrush_worker_ready=0
  _zrush_worker_rx=
  _zrush_encode_message hello "$_ZRUSH_EXPECTED_BUILD_STAMP"
  _zrush_worker_txq=( "$REPLY" )
  _zrush_kick
  _zlog "worker: started rfd=$_zrush_worker_rfd wfd=$_zrush_worker_wfd controlfd=$_zrush_worker_control_wfd"
  _zrush_worker_flush
}

_zrush_worker_flush() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify no_bg_nice
  local LC_ALL=C
  (( !_zrush_worker_stopping )) || return 0
  (( $#_zrush_worker_txq )) || return 0
  (( _zrush_worker_ack_fd >= 0 )) && return 0
  (( _zrush_worker_wfd >= 0 )) || return 1
  local frame=$_zrush_worker_txq[1] fd=
  local -i spawn_st
  exec {fd}< <(
    { exec {_zrush_worker_rfd}>&- } 2>/dev/null
    { exec {_zrush_worker_control_wfd}>&- } 2>/dev/null
    (( _zrush_worker_drain_fd >= 0 )) && { exec {_zrush_worker_drain_fd}>&- } 2>/dev/null
    syswrite -o $_zrush_worker_wfd -- "$frame" &&
      exec {_zrush_worker_wfd}>&- &&
      print -rn -- 1
  )
  spawn_st=$?
  if (( spawn_st != 0 )) || [[ -z $fd ]] || (( fd <= 2 )); then
    [[ -n $fd ]] && (( fd > 2 )) && _zrush_close_internal_fd $fd
    _zrush_worker_runtime_taint
    _zrush_worker_session_fail "writer child spawn failed"
    return 1
  fi
  _zrush_worker_ack_fd=$fd
  if ! _zrush_worker_register_callback ack $fd; then
    _zrush_worker_runtime_taint
    _zrush_worker_session_fail "ack fd registration failed"
    return 1
  fi
  shift _zrush_worker_txq
  _zrush_kick
  _zlog "worker: sending frame ackfd=$fd bytes=${#frame} queued=$#_zrush_worker_txq"
  return 0
}

# Shared by the ZLE callback and the synchronous history loop. The child's exit
# status is never consulted: an ack byte means the frame reached the FIFO, EOF
# without one means the write failed.
_zrush_worker_consume_ack() {
  emulate -L zsh
  (( !_zrush_worker_stopping )) || return 0
  (( _zrush_worker_ack_fd >= 0 )) || return 0
  local -i st
  _zrush_worker_poll_writer; st=$?
  (( st == 1 )) && return 0
  if (( st == 2 )); then
    _zrush_worker_session_fail "frame write failed"
    return 1
  fi
  _zrush_worker_release_writer
  _zlog "worker: frame sent queued=$#_zrush_worker_txq"
  _zrush_worker_flush
}

_zrush_worker_on_ack() {
  emulate -L zsh
  local -i fd=$1 generation=${2:--1}
  _zrush_worker_callback_current ack $fd $generation || return 0
  if (( _zrush_worker_stopping )); then
    _zrush_worker_stop_progress async
  else
    _zrush_worker_consume_ack
  fi
  return 0
}

_zrush_worker_deadline_expired() {
  [[ -n $1 ]] && (( EPOCHREALTIME >= $1 ))
}

_zrush_worker_handle_message() {  # message [absolute-deadline]
  emulate -L zsh
  setopt localoptions extendedglob
  (( !_zrush_worker_stopping )) || return 0
  local message=$1 deadline=${2:-}
  if _zrush_worker_deadline_expired "$deadline"; then
    _zrush_worker_session_fail "history deadline exceeded request_id=$_zrush_sync_target"
    return 1
  fi
  _zrush_decode_fields "$message" || { _zrush_worker_session_fail "malformed nested response"; return 1 }
  local -a f=( "${(@)reply}" )

  if (( !_zrush_worker_ready )); then
    if (( $#f == 2 )) && [[ $f[1] == ready && $f[2] == $_ZRUSH_EXPECTED_BUILD_STAMP ]]; then
      _zrush_worker_ready=1
      _zrush_build_verifying=0
      _zlog "worker: handshake ready"
      return 0
    fi
    if (( $#f == 2 )) && _zrush_valid_build_stamp "$f[2]" \
       && [[ $f[1] == incompatible || $f[1] == ready ]]; then
      _zrush_follow_build "$f[1] worker stamp ${(qqqq)f[2]}"
      return 1
    fi
    _zrush_worker_disable_policy "invalid handshake response"
    _zrush_worker_abort
    _zrush_teardown
    return 1
  fi

  # The three message kinds are told apart by the kind field alone: worker
  # events carry an input_generation and no request_id, and are correlated and
  # applied entirely on their own terms (cli-protocol.md "メッセージの種別").
  local kind=$f[1]
  case $kind in
    plan-ready|capture-required)
      _zrush_worker_handle_event "${(@)f}"
      return $?
      ;;
    ok|error) ;;
    *) _zrush_worker_session_fail "invalid response kind"; return 1 ;;
  esac

  (( $#f == 3 )) || { _zrush_worker_session_fail "invalid response field count"; return 1 }
  local id=$f[2]
  [[ $id == [1-9][0-9]# ]] && _zrush_dec_le_all 9223372036854775807 "$id" || {
    _zrush_worker_session_fail "noncanonical response request_id"
    return 1
  }
  (( ${+_zrush_worker_pending[$id]} )) || {
    _zrush_worker_session_fail "response for unknown request_id=$id"
    return 1
  }
  # "store <slot> <generation> <input_generation>" for a store,
  # "<kind> <generation>" for the two history writes, "plan <producer>" for a plan.
  local -a req=( ${=_zrush_worker_pending[$id]} )
  local reqkind=$req[1] producer= slot=
  local -i stored_gen=0 bound_gen=0
  case $reqkind in
    store)                           slot=${req[2]:-} stored_gen=${req[3]:-0} bound_gen=${req[4]:-0} ;;
    history-snapshot|history-append) stored_gen=${req[2]:-0} ;;
    *)                               producer=${req[2]:-} ;;
  esac
  # A terminal response, whatever it says, retires the frame from the bound on
  # unacknowledged appends (behavior.md "履歴メニュー" 更新経路).
  if [[ $reqkind == history-append ]] && (( _zrush_hist_unacked > 0 )); then
    (( --_zrush_hist_unacked ))
  fi

  if [[ $kind == error ]]; then
    local code=$f[3]
    [[ $code == invalid-request || $code == invalid-payload ||
       $code == unknown-generation || $code == superseded ]] || {
      _zrush_worker_session_fail "invalid error code"
      return 1
    }
    if (( id == _zrush_sync_target )) && _zrush_worker_deadline_expired "$deadline"; then
      _zrush_worker_session_fail "history deadline exceeded request_id=$id"
      return 1
    fi
    unset "_zrush_worker_pending[$id]"
    # A store that ends in error changed no slot, so its staged entry never
    # becomes a latch -- `superseded` included (cli-protocol.md "応答の検証と
    # zsh 側の適用": only an `ok` moves the latch).
    unset "_zrush_cc_staged[$id]"
    _zrush_worker_failures=0
    _zrush_status_set ""
    # cli-protocol.md "応答の検証と zsh 側の適用": unknown-generation is an
    # ordinary terminal error, and nothing is replayed. The index refused a
    # write, or answered for a generation it does not hold: the latch was
    # optimistic and is now known wrong, so the next menu op starts from a
    # snapshot (behavior.md "worker ライフサイクル").
    if [[ $code == unknown-generation ]] &&
       [[ $reqkind == history-* || $producer == history ]]; then
      _zrush_hist_invalidate unknown-generation
    fi
    if (( id == _zrush_sync_target )); then
      _zrush_sync_done=1 _zrush_sync_ok=0
    elif [[ $reqkind == store ]] && (( bound_gen == _zrush_input_gen )) &&
         [[ $code != superseded ]]; then
      # No plan-ready can follow a store that failed, so the input this capture
      # answered gets no listing at all. `superseded` is the exception the
      # contract names: the input it answered is already gone, and the listing
      # showing belongs to whatever replaced it (behavior.md "候補収集").
      _zrush_teardown
      zle -R 2>/dev/null
    fi
    _zlog "worker: error request_id=$id code=$code"
    return 0
  fi

  if [[ $reqkind == store || $reqkind == history-* ]]; then
    # cli-protocol.md "要求と応答": a successful store or history write answers
    # with an empty body.
    [[ -z $f[3] ]] || {
      _zrush_worker_session_fail "$reqkind ok carries a body request_id=$id"
      return 1
    }
    unset "_zrush_worker_pending[$id]"
    _zrush_worker_failures=0
    _zrush_status_set ""
    # The worker now holds this generation, so the entry staged for it becomes
    # the latch (behavior.md "空語収集キャッシュ"). The history index latch is
    # not staged: it already moved optimistically when the frame was enqueued.
    [[ $slot == cache ]] && _zrush_cc_commit $id $stored_gen
    _zlog "worker: ok $reqkind request_id=$id slot=$slot generation=$stored_gen binding=$bound_gen"
    return 0
  fi

  # Only the synchronous history exchange sends a `plan`, so a plan response is
  # either the one it is waiting for or a stale one it must leave the UI alone
  # for (behavior.md "履歴メニュー").
  local old_text=$_zrush_plan_text old_cp=$_zrush_plan_cp old_kind=$_zrush_plan_kind
  local -i old_l=$_zrush_plan_nlines old_p=$_zrush_plan_npos
  local -a old_hl=( "${(@)_zrush_plan_hl}" ) old_cells=( "${(@)_zrush_plan_cells}" )
  local -a old_nav=( "${(@)_zrush_plan_nav}" ) old_insert=( "${(@)_zrush_plan_insert}" )
  _zrush_parse_plan "$f[3]" || { _zrush_worker_session_fail "malformed render plan request_id=$id"; return 1 }
  if (( id == _zrush_sync_target )) && _zrush_worker_deadline_expired "$deadline"; then
    _zrush_worker_session_fail "history deadline exceeded request_id=$id"
    return 1
  fi
  unset "_zrush_worker_pending[$id]"
  _zrush_worker_failures=0
  _zrush_status_set ""
  if (( id == _zrush_sync_target )); then
    _zrush_plan_kind=$producer
    _zrush_sync_done=1 _zrush_sync_ok=1
  else
    _zrush_plan_text=$old_text _zrush_plan_nlines=$old_l _zrush_plan_npos=$old_p
    _zrush_plan_cp=$old_cp _zrush_plan_kind=$old_kind
    _zrush_plan_hl=( "${(@)old_hl}" ) _zrush_plan_cells=( "${(@)old_cells}" )
    _zrush_plan_nav=( "${(@)old_nav}" ) _zrush_plan_insert=( "${(@)old_insert}" )
  fi
  _zlog "worker: ok request_id=$id producer=$producer"
  return 0
}

# A worker event (cli-protocol.md "入力通知と worker event"). Events carry no
# request_id, get no response, and are never registered anywhere: the whole
# correlation is the input_generation, and only the one this shell still treats
# as valid is applied. A malformed shape is a session failure, because an event
# has no in-band way to report one.
_zrush_worker_handle_event() {  # kind input_generation [plan_body]
  emulate -L zsh
  setopt localoptions extendedglob
  local kind=$1 gen=$2
  if [[ $kind == plan-ready ]]; then
    (( $# == 3 )) || { _zrush_worker_session_fail "invalid plan-ready field count"; return 1 }
  else
    (( $# == 2 )) || { _zrush_worker_session_fail "invalid capture-required field count"; return 1 }
  fi
  [[ $gen == [1-9][0-9]# ]] && _zrush_dec_le_all 9223372036854775807 "$gen" || {
    _zrush_worker_session_fail "noncanonical event input_generation"
    return 1
  }
  # A well-formed event counts like a terminal response for the consecutive
  # failure streak, whether or not its generation still matches
  # (cli-protocol.md "応答の検証と zsh 側の適用").
  _zrush_worker_failures=0
  _zrush_status_set ""
  if (( gen != _zrush_input_gen )); then
    _zlog "worker: dropped $kind for input_generation=$gen (current=$_zrush_input_gen)"
    return 0
  fi
  _zrush_input_pending=0
  if [[ $kind == capture-required ]]; then
    # The notification named the cache latch's generation and the worker turns
    # out not to hold it: the latch is wrong, and this is a notification of that
    # rather than an error (behavior.md "空語収集キャッシュ").
    if (( _zrush_input_latched )); then
      _zrush_input_latched=0
      _zrush_cc_latch_drop
      _zlog "cache: latch dropped by capture-required"
    fi
    _zrush_start_collection
    return 0
  fi
  # The generation is matched above, before the body is parsed, and an accepted
  # body is applied exactly as a plan response's is (cli-protocol.md "zsh 側の規範").
  # zle -F -w callers require an explicit redraw.
  _zrush_parse_plan "$3" || {
    _zrush_worker_session_fail "malformed render plan input_generation=$gen"
    return 1
  }
  _zrush_plan_kind=compsys
  _zrush_settle_plan
  zle -R 2>/dev/null
  _zlog "worker: plan-ready applied input_generation=$gen"
  return 0
}

_zrush_worker_arm_drain() {
  (( !_zrush_worker_stopping )) || return 0
  (( _zrush_worker_drain_fd < 0 )) || return 0
  local fd=
  local -i open_st
  exec {fd}< <(
    { exec {_zrush_worker_rfd}>&- } 2>/dev/null
    { exec {_zrush_worker_wfd}>&- } 2>/dev/null
    { exec {_zrush_worker_control_wfd}>&- } 2>/dev/null
    zselect -t 1
    print
  )
  open_st=$?
  if (( open_st != 0 )) || [[ -z $fd ]] || (( fd <= 2 )); then
    [[ -n $fd ]] && (( fd > 2 )) && _zrush_close_internal_fd $fd
    _zrush_worker_session_fail "read continuation fd allocation failed"
    return 1
  fi
  _zrush_worker_drain_fd=$fd
  _zrush_worker_register_callback drain $fd || {
    _zrush_close_internal_fd $fd
    _zrush_worker_drain_fd=-1
    _zrush_worker_session_fail "read continuation fd registration failed"
    return 1
  }
  _zrush_kick
  return 0
}

_zrush_worker_read() {  # async | sync [absolute-deadline]
  emulate -L zsh
  (( !_zrush_worker_stopping )) || return 0
  local mode=${1:-async} deadline=${2:-} chunk= st
  local -i reads=0 bytes=0 frames=0 got=0
  while true; do
    (( !_zrush_worker_stopping )) || return 0
    if [[ $mode == sync ]] && _zrush_worker_deadline_expired "$deadline"; then
      _zrush_worker_session_fail "history deadline exceeded request_id=$_zrush_sync_target"
      return 1
    fi
    if [[ $mode == async ]] && (( frames >= 32 )); then
      _zrush_worker_arm_drain || return 1
      return 0
    fi
    _zrush_netstring_take "$_zrush_worker_rx"; st=$?
    if (( st == 0 )); then
      local message=$REPLY
      _zrush_worker_rx=$REPLY_REST
      (( ++frames ))
      _zrush_worker_handle_message "$message" "$deadline" || return 1
      # Returning rather than continuing keeps the rest of the buffer off the
      # keystroke path -- the deadline is sync mode's only bound -- and keeps
      # the loop-top check from tripping on a result already committed.
      [[ $mode == sync ]] && (( _zrush_sync_done )) && return 0
      continue
    fi
    if (( st == 2 )); then
      _zrush_worker_session_fail "malformed outer response"
      return 1
    fi
    if [[ $mode == async ]] && (( reads >= 4 || bytes >= 32768 )); then
      return 0
    fi
    got=0
    sysread -c got -t 0 -i $_zrush_worker_rfd chunk; st=$?
    if (( st == 0 )); then
      (( ++reads, bytes += got ))
      _zrush_worker_rx+=$chunk
      continue
    fi
    (( st == 4 )) && return 0
    if (( st == 5 )); then
      _zrush_worker_close_response
      _zrush_worker_session_fail "unexpected stdout EOF"
    else
      _zrush_worker_session_fail "read error status=$st errno=$ERRNO"
    fi
    return 1
  done
}

_zrush_worker_on_data() {
  emulate -L zsh
  local -i fd=$1 generation=${2:--1}
  _zrush_worker_callback_current data $fd $generation || return 0
  if (( _zrush_worker_stopping )); then
    _zrush_worker_stop_progress async
    return 0
  fi
  # The ack is usually ready in the same wakeup as the response it precedes.
  # Consuming it before the plan is painted leaves the ack watcher's own
  # dispatch with nothing to do, because work running in a callback after a
  # paint holds a SIGINT that zsh 5.9 defers onto the next input byte.
  if (( _zrush_worker_ack_fd >= 0 )); then
    _zrush_worker_consume_ack || return 0
  fi
  _zrush_worker_read async
  return 0
}

_zrush_worker_on_drain() {
  emulate -L zsh
  local -i fd=$1 generation=${2:--1}
  _zrush_worker_callback_current drain $fd $generation || return 0
  _zrush_worker_invalidate_callback drain $fd
  _zrush_close_internal_fd $fd
  _zrush_worker_drain_fd=-1
  _zrush_worker_read async
  return 0
}

_zrush_next_request_id() {  # -> REPLY
  emulate -L zsh
  (( _zrush_request_seq < 9223372036854775807 )) || {
    _zrush_worker_disable_policy "request_id exhausted"
    _zrush_worker_shutdown
    _zrush_teardown
    return 1
  }
  typeset -g REPLY=$(( ++_zrush_request_seq ))
  return 0
}

_zrush_next_cand_gen() {  # -> REPLY
  emulate -L zsh
  (( _zrush_cand_gen_seq < 9223372036854775807 )) || {
    _zrush_worker_disable_policy "candidate_generation exhausted"
    _zrush_worker_shutdown
    _zrush_teardown
    return 1
  }
  typeset -g REPLY=$(( ++_zrush_cand_gen_seq ))
  return 0
}

_zrush_next_input_gen() {  # -> REPLY
  emulate -L zsh
  (( _zrush_input_gen_seq < 9223372036854775807 )) || {
    _zrush_worker_disable_policy "input_generation exhausted"
    _zrush_worker_shutdown
    _zrush_teardown
    return 1
  }
  typeset -g REPLY=$(( ++_zrush_input_gen_seq ))
  return 0
}

# The row and column budgets every plan-bearing message carries
# (cli-protocol.md "要求と応答"): rows = min(max-lines, LINES - 1), clamped to
# >= 1 unconditionally (not just when LINES > 1 -- LINES <= 1 must still clamp
# down to the 1-row floor, not silently keep max-lines).
_zrush_geometry() {  # -> REPLY_ROWS / REPLY_WIDTH
  emulate -L zsh
  local -i rows=$(( LINES - 1 )) width=$(( COLUMNS - 1 ))
  (( rows > ZRUSH_CFG_MAX_LINES )) && rows=$ZRUSH_CFG_MAX_LINES
  (( rows < 1 )) && rows=1
  (( width < 1 )) && width=1
  typeset -g REPLY_ROWS=$rows REPLY_WIDTH=$width
  return 0
}

# Undelegated notification frames may be removed or replaced when the
# notification they carry is cancelled or superseded; request frames never are
# (behavior.md "worker ライフサイクル"). A queued frame is a notification when
# its outer payload opens with the `input` or `flush` kind netstring, which is
# the whole wire identity of one -- no parallel bookkeeping to keep in step
# with the queue, and no decoding of a store's candidate payload to find out.
_zrush_txq_drop_notifications() {
  emulate -L zsh
  setopt localoptions extendedglob
  (( $#_zrush_worker_txq )) || return 0
  local frame
  local -a keep=()
  for frame in "${(@)_zrush_worker_txq}"; do
    [[ $frame == [0-9]##:(5:input,|5:flush,)* ]] && continue
    keep+=( "$frame" )
  done
  _zrush_worker_txq=( "${(@)keep}" )
  return 0
}

_zrush_worker_ensure_session() {
  emulate -L zsh
  (( _zrush_worker_rfd >= 0 )) && return 0
  local -i failures_before=$_zrush_worker_failures
  if ! _zrush_worker_start; then
    (( _zrush_worker_failures != failures_before )) || _zrush_worker_session_fail "startup failed"
    return 1
  fi
  return 0
}

# Hand a candidate record stream to one slot of the worker's candidate store
# (cli-protocol.md "要求と応答"). Every store binds the input_generation whose
# `capture-required` asked for this capture; the worker answers an accepted one
# with the `plan-ready` for that input, so nothing is pipelined behind it.
_zrush_request_store() {  # slot payload input-generation -> REPLY = candidate generation
  emulate -L zsh
  setopt localoptions typesetsilent no_monitor no_notify
  local slot=$1 payload=$2
  local -i input_gen=$3
  (( !_zrush_worker_stopping && !_zrush_worker_runtime_tainted )) || return 1
  _zrush_next_request_id || return 1
  local -i id=$REPLY
  _zrush_next_cand_gen || return 1
  local -i gen=$REPLY
  _zrush_worker_pending[$id]="store $slot $gen $input_gen"
  [[ $slot == cache ]] && _zrush_cc_stage $id
  _zrush_worker_ensure_session || return 1
  _zrush_encode_message store "$id" "$slot" "$gen" "$input_gen" "$payload"
  _zrush_worker_txq+=( "$REPLY" )
  _zlog "worker: queued store request_id=$id slot=$slot generation=$gen input_generation=$input_gen bytes=${#REPLY} queued=$#_zrush_worker_txq"
  _zrush_worker_flush || return 1
  typeset -g REPLY=$gen
  return 0
}

# Hand a candidate record stream to the worker's history index: the whole index
# for `history-snapshot`, one event for `history-append` (cli-protocol.md
# "要求と応答"). The caller moves the history index latch optimistically once
# this returns, and the plan that reads the generation back is pipelined behind
# the frame without waiting for its terminal response.
#
# Unlike a store this never starts a worker (behavior.md "履歴メニュー": the
# update path must not defeat lazy start). The cold menu path starts one
# explicitly, inside its deadline, before it gets here.
_zrush_request_history() {  # kind payload [event] -> REPLY = candidate generation
  emulate -L zsh
  setopt localoptions typesetsilent no_monitor no_notify
  local LC_ALL=C kind=$1 payload=$2 event=${3:-}
  (( !_zrush_worker_stopping && !_zrush_worker_runtime_tainted )) || return 1
  (( _zrush_worker_rfd >= 0 )) || return 1
  _zrush_next_request_id || return 1
  local -i id=$REPLY
  _zrush_next_cand_gen || return 1
  local -i gen=$REPLY
  _zrush_worker_pending[$id]="$kind $gen"
  _zrush_encode_message "$kind" "$id" "$gen" "$payload"
  _zrush_worker_txq+=( "$REPLY" )
  _zlog "worker: queued $kind request_id=$id generation=$gen bytes=${#REPLY} queued=$#_zrush_worker_txq"
  if [[ $kind == history-append ]]; then
    _zlog "history: append request_id=$id generation=$gen event=$event"
  else
    _zlog "history: snapshot request_id=$id generation=$gen bytes=${#payload}"
  fi
  _zrush_worker_flush || return 1
  typeset -g REPLY=$gen
  return 0
}

# The explicit query the history menu's synchronous exchange sends
# (behavior.md "履歴メニュー"). Listings that follow the input are made from
# `input` notifications instead, so nothing else sends a `plan`.
_zrush_request_plan() {  # candidate-generation producer query trailing-space
  emulate -L zsh
  setopt localoptions typesetsilent no_monitor no_notify
  local -i gen=$1
  local producer=$2 query=$3 tspace=$4
  (( !_zrush_worker_stopping && !_zrush_worker_runtime_tainted )) || return 1

  _zrush_geometry
  local -i rows=$REPLY_ROWS width=$REPLY_WIDTH

  _zrush_next_request_id || return 1
  local -i id=$REPLY
  _zrush_worker_pending[$id]="plan $producer"
  _zrush_worker_ensure_session || return 1
  # history_limit is mandatory on every plan whichever store the generation
  # resolves to; the worker ignores it unless that is the history index
  # (cli-protocol.md "要求と応答").
  _zrush_encode_message plan "$id" "$gen" "$PWD" "$producer" "$query" \
    "$ZRUSH_CFG_MODE" "$ZRUSH_CFG_SMART_CASE" "$rows" "$width" "$tspace" \
    "$ZRUSH_CFG_HISTORY_LIMIT"
  _zrush_worker_txq+=( "$REPLY" )
  _zlog "worker: queued request_id=$id producer=$producer generation=$gen bytes=${#REPLY} queued=$#_zrush_worker_txq"
  _zrush_worker_flush || return 1
  typeset -g REPLY=$id
  return 0
}

# Tell the worker the buffer changed (cli-protocol.md "入力通知と worker
# event"). A notification carries no request_id and gets no terminal response:
# the worker replaces it while its quiet period runs and answers the survivor
# with one event. The caller has already applied the suppression rules and the
# input-pressure check, so reaching here means a notification is owed.
#
# The quiet period itself is `delay-ms`, measured by the worker; this side has
# no timer. The candidate generation is the empty-word cache's latch when it
# hits and the reserved 0 otherwise (behavior.md "空語収集キャッシュ").
_zrush_send_input() {
  emulate -L zsh
  setopt localoptions typesetsilent no_monitor no_notify
  (( !_zrush_worker_stopping && !_zrush_worker_runtime_tainted )) || return 1
  # A notification is a real message, so it is what starts the worker when none
  # is running. It happens before the cache is consulted because a fresh session
  # holds no slots and drops the latch (behavior.md "worker ライフサイクル").
  _zrush_worker_ensure_session || return 1

  _zrush_widen "$LBUFFER"
  _zrush_query=$REPLY_WIDENED
  _zrush_fuzzy=${REPLY_QUERY//$'\0'/}   # the sender must strip NUL from the query

  local -i cand_gen=0 latched=0
  if _zrush_cc_subject && _zrush_cc_check; then
    cand_gen=$_zrush_cc_cand_gen latched=1
  fi

  _zrush_next_input_gen || return 1
  local -i gen=$REPLY
  _zrush_geometry
  local -i rows=$REPLY_ROWS width=$REPLY_WIDTH delay=$ZRUSH_CFG_DELAY_MS
  _zrush_encode_message input "$gen" "$cand_gen" "$delay" "$PWD" "$_zrush_fuzzy" \
    "$ZRUSH_CFG_MODE" "$ZRUSH_CFG_SMART_CASE" "$rows" "$width" "$ZRUSH_CFG_TRAILING_SPACE"
  # This notification replaces the previous one, so any frame the previous one
  # left unhanded is removed rather than sent (behavior.md "worker ライフサイクル").
  _zrush_txq_drop_notifications
  _zrush_worker_txq+=( "$REPLY" )
  _zrush_input_gen=$gen _zrush_input_pending=1 _zrush_input_latched=$latched
  _zlog "worker: queued input input_generation=$gen candidate_generation=$cand_gen delay=$delay query=${(qqqq)_zrush_fuzzy} queued=$#_zrush_worker_txq"
  _zrush_worker_flush || return 1
  return 0
}

# Cut the current input's quiet period short (behavior.md "Tab"). The worker
# settles it at once and answers with the event it would otherwise have sent
# when the period expired.
_zrush_send_flush() {
  emulate -L zsh
  setopt localoptions typesetsilent no_monitor no_notify
  (( _zrush_input_gen > 0 )) || return 1
  (( !_zrush_worker_stopping && !_zrush_worker_runtime_tainted )) || return 1
  # Never starts a worker: only the session that received the notification can
  # have an input to settle, and a fresh one would discard the flush anyway.
  (( _zrush_worker_rfd >= 0 )) || return 1
  _zrush_encode_message flush "$_zrush_input_gen"
  _zrush_worker_txq+=( "$REPLY" )
  _zlog "worker: queued flush input_generation=$_zrush_input_gen queued=$#_zrush_worker_txq"
  _zrush_worker_flush || return 1
  return 0
}

# Upper-bound check for every non-negative decimal in a plan, without
# arithmetic evaluation. A plan is untrusted input and zsh integers are
# 64-bit: evaluating a wider digit string truncates it after 19 digits, wraps
# it negative -- so an out-of-range value would pass -- and prints a message
# on stderr that would corrupt the zle display. Comparing the canonical digit
# strings instead -- leading zeros dropped, then length, then ASCII order --
# is exact at any width.
_zrush_dec_le_all() {  # $1=bound, $2.. = values, all matched by <->
  emulate -L zsh
  setopt localoptions extendedglob
  local b=${1##0##} v c   # canonical zero is the empty string
  for v in "${@[2,-1]}"; do
    c=${v##0##}
    (( $#c < $#b )) && continue
    (( $#c > $#b )) && return 1
    [[ $c > $b ]] && return 1
  done
  return 0
}

# Validate and split one render-plan buffer into _zrush_plan_*.
# Field layout is fixed (cli-protocol.md "plan の ok body"):
#   common-prefix, L, P, L rows, H, H "role pos start len", P "start len",
#   P "next prev left right", P insert texts -- total 4 + L + H + 3P fields.
_zrush_parse_plan() {  # $1=raw render-plan bytes
  emulate -L zsh
  local out=$1
  [[ $out == *$'\0' ]] || return 1   # final NUL required (cli-protocol.md)
  local -a f=( "${(@0)${out%$'\0'}}" )
  local -i n=$#f
  (( n >= 4 )) || return 1
  [[ $f[2] == <-> && $f[3] == <-> ]] || return 1
  # n = 4 + L + H + 3P bounds each count by n; checking that before any
  # arithmetic keeps the counts inside the integer range from here on.
  _zrush_dec_le_all $n $f[2] $f[3] || return 1
  local -i L=$f[2] P=$f[3]

  local -i idx=4
  (( idx + L - 1 <= n )) || return 1
  local -a rows=( "${(@)f[idx,idx+L-1]}" )
  (( idx += L ))
  (( idx <= n )) || return 1
  [[ $f[idx] == <-> ]] || return 1
  _zrush_dec_le_all $n $f[idx] || return 1
  local -i H=$f[idx]
  (( idx += 1 ))
  (( idx + H - 1 <= n )) || return 1
  local -a hls=( "${(@)f[idx,idx+H-1]}" )
  (( idx += H ))
  (( idx + P - 1 <= n )) || return 1
  local -a cells=( "${(@)f[idx,idx+P-1]}" )
  (( idx += P ))
  (( idx + P - 1 <= n )) || return 1
  local -a navs=( "${(@)f[idx,idx+P-1]}" )
  (( idx += P ))
  (( idx + P - 1 <= n )) || return 1
  local -a inserts=( "${(@)f[idx,idx+P-1]}" )
  (( idx += P ))
  (( idx - 1 == n )) || return 1   # exact field count: 4 + L + H + 3P

  # Tuple shapes, then every 0..P value in one pass; `ranged` collects those,
  # `offs` collects the (start, len) pairs bounded by the listing text.
  local text=${(pj:\n:)rows}
  local -i N=$#text   # $# is this receiver's own character reading (contract)
  local e role pos start len
  local -a tok ranged=() offs=()
  for e in "${(@)hls}"; do
    tok=( ${=e} )
    (( $#tok == 4 )) || return 1
    role=$tok[1] pos=$tok[2] start=$tok[3] len=$tok[4]
    [[ $role == match || $role == heading || $role == history-number ]] || return 1
    [[ $pos == <-> && $start == <-> && $len == <-> ]] || return 1
    ranged+=( $pos )
    offs+=( $start $len )
  done
  for e in "${(@)cells}"; do
    tok=( ${=e} )
    (( $#tok == 2 )) || return 1
    [[ $tok[1] == <-> && $tok[2] == <-> ]] || return 1
    offs+=( "${(@)tok}" )
  done
  for e in "${(@)navs}"; do
    tok=( ${=e} )
    (( $#tok == 4 )) || return 1
    [[ $tok[1] == <-> && $tok[2] == <-> && $tok[3] == <-> && $tok[4] == <-> ]] || return 1
    ranged+=( "${(@)tok}" )
  done
  _zrush_dec_le_all $P "${(@)ranged}" || return 1
  # cli-protocol.md "オフセット規律": ranges stay inside the listing text.
  # Bound each value on its own first -- string compare, no arithmetic -- so
  # the sum below cannot truncate a wide digit string or overflow.
  _zrush_dec_le_all $N "${(@)offs}" || return 1
  local -i i
  for (( i = 1; i <= $#offs; i += 2 )); do
    (( offs[i] + offs[i+1] <= N )) || return 1
  done

  _zrush_plan_cp=$f[1]
  _zrush_plan_nlines=$L
  _zrush_plan_npos=$P
  _zrush_plan_text=$text
  _zrush_plan_hl=( "${(@)hls}" )
  _zrush_plan_cells=( "${(@)cells}" )
  _zrush_plan_nav=( "${(@)navs}" )
  _zrush_plan_insert=( "${(@)inserts}" )
  return 0
}

# ---------------------------------------------------------------- Apply the plan
# Call only from a ZLE widget context. Applies the last successfully parsed
# plan (_zrush_plan_*) to POSTDISPLAY and region_highlight without any
# further computation (cli-protocol.md "適用(zsh 側の規範)").
_zrush_apply_plan() {
  emulate -L zsh
  (( _zrush_selected > _zrush_plan_npos )) && _zrush_selected=$_zrush_plan_npos
  if (( _zrush_plan_nlines > 0 )); then
    POSTDISPLAY=$'\n'$_zrush_plan_text
    _zrush_listing=1
  else
    POSTDISPLAY=
    _zrush_listing=0
  fi
  _zrush_apply_highlights
  _zlog "plan: applied L=$_zrush_plan_nlines P=$_zrush_plan_npos selected=$_zrush_selected"
  return 0
}

# Call only from a ZLE widget context. Rebuilds region_highlight from
# _zrush_plan_hl/_zrush_plan_cells for the current _zrush_selected, without
# re-fetching or recomputing the plan (cli-protocol.md "ハイライト": match
# decoration is skipped for the selected cell and replaced by the selected
# spec built from that position's cell range).
_zrush_apply_highlights() {
  emulate -L zsh
  _zrush_rh_clear
  (( _zrush_plan_nlines > 0 )) || return 0
  local hl_sel=${ZRUSH_CFG_HL_SELECTED-standout}
  local hl_mat=${ZRUSH_CFG_HL_MATCH-underline}
  local hl_head=${ZRUSH_CFG_HL_HEADING-bold}
  local hl_histnum=${ZRUSH_CFG_HL_HISTORY_NUMBER-faint}
  local -i off=$(( $#BUFFER + 1 ))   # account for the leading newline
  local -i sel=$_zrush_selected
  local e role spec
  local -a f
  for e in "${(@)_zrush_plan_hl}"; do
    f=( ${=e} )   # role pos start len
    case $f[1] in
      match)
        (( f[2] == sel )) && continue   # the selected cell's own decoration wins
        spec=$hl_mat
        ;;
      history-number)
        (( f[2] == sel )) && continue
        spec=$hl_histnum
        ;;
      heading) spec=$hl_head ;;
    esac
    [[ -n $spec ]] || continue
    _zrush_rh_add $(( off + f[3] )) $(( off + f[3] + f[4] )) "$spec"
  done
  if (( sel > 0 )) && [[ -n $hl_sel ]]; then
    f=( ${=_zrush_plan_cells[sel]} )   # start len
    _zrush_rh_add $(( off + f[1] )) $(( off + f[1] + f[2] )) "$hl_sel" -sel
  fi
  return 0
}

# ---------------------------------------------------------------- History index and menu
# See docs/internal/specs/behavior.md "履歴メニュー" and cli-protocol.md
# "history profile".

# Forget what the index held. The generation is the whole readiness question:
# an invalid latch and a dirty index are one state, and both make the next menu
# op start from a snapshot.
_zrush_hist_reset() {
  _zrush_hist_gen=0 _zrush_hist_head=0 _zrush_hist_count=0 _zrush_hist_unacked=0
  return 0
}

# Same, for the invalidation points that happen outside the menu's own
# fingerprint check (worker start/stop, unknown-generation, Level A).
_zrush_hist_invalidate() {  # reason
  _zlog "history: index dirty (reason=$1)"
  _zrush_hist_reset
}

# The optimistic latch and the Level B baseline move together, at the moment a
# write is enqueued (behavior.md "履歴メニュー": a frame that never arrives
# surfaces as the next query's unknown-generation, not as a silent stale index).
# HISTCMD at that moment is head + 1, so head carries both halves of the
# recorded (HISTCMD, ${#history}) pair.
_zrush_hist_latch() {  # generation head count
  _zrush_hist_gen=$1 _zrush_hist_head=$2 _zrush_hist_count=$3
  return 0
}

# Is this history line one the sender excludes wholesale (cli-protocol.md
# "history profile")? Empty lines and lines carrying a framing byte. The
# snapshot walk repeats this test inline rather than calling here: one zsh
# function call per history entry measures ~4us, which is ~90ms of the 100ms
# deadline at the 20000-entry retention cap.
_zrush_hist_excluded() {  # line
  [[ -z $1 || $1 == *$'\0'* || $1 == *$'\1'* || $1 == *$'\2'* ]]
}

# Bootstrap payload: the whole in-memory history, newest first, up to the byte
# ceiling. No dedup and no `[history].limit` slicing -- both belong to the
# worker's query (cli-protocol.md "history profile").
#
# $history maps event numbers to lines and its values come out newest first.
# Event numbers have gaps, so this walks the values -- never a decrement from
# HISTCMD, and never `fc` output (multi-line entries break its line-oriented
# format).
_zrush_history_snapshot_payload() {  # -> REPLY = payload, REPLY_HEAD/REPLY_COUNT = the baseline it describes
  emulate -L zsh
  # Byte-exact lengths for the payload ceiling below, as in _zrush_netstring.
  local LC_ALL=C
  # Recorded before the walk: the head a snapshot establishes is HISTCMD - 1 as
  # observed at synthesis, not the largest `n` that made it into the payload
  # (behavior.md "履歴メニュー": the newest events may be excluded or cut).
  typeset -g REPLY_HEAD=$(( HISTCMD - 1 )) REPLY_COUNT=$#history
  local -a kv=( "${(@kv)history}" )   # one bulk expansion: event/line pairs, newest first
  local event line block=b$'\1'
  local -i pending=0 size=0
  local -i total=3          # the leading b\1 and the trailing \0 below
  local -a blocks=()
  for event line in "${(@)kv}"; do   # two elements per entry
    # _zrush_hist_excluded, inlined for the walk's per-entry cost.
    [[ -n $line && $line != *$'\0'* && $line != *$'\1'* && $line != *$'\2'* ]] || continue
    # The scan stops at the record that would cross the payload ceiling, and
    # never mid-record: the payload is a newest-side prefix of the history.
    size=$(( ${#line} + ${#event} + 6 ))   # \0 w \1 line \2 n \1 event
    (( total + size > _ZRUSH_HISTORY_PAYLOAD_MAX_BYTES )) && break
    (( total += size ))
    block+=$'\0'w$'\1'$line$'\2'n$'\1'$event
    # Appending to a zsh string or array copies everything it already holds, so
    # growing either one record at a time is quadratic. Sealing the open block
    # every 16 records bounds both copies and keeps the total linear.
    (( ++pending < 16 )) || { blocks+=( "$block" ); block=; pending=0; }
  done
  blocks+=( "$block" )
  typeset -g REPLY=${(pj::)blocks}$'\0'
  return 0
}

# One event, in the same record stream shape (a header batch, then the record).
_zrush_history_append_payload() {  # event line -> REPLY = payload bytes
  typeset -g REPLY=b$'\1'$'\0'w$'\1'$2$'\2'n$'\1'$1$'\0'
  return 0
}

# Level A, once per prompt: O(1) continuity between the newest event and the
# newest event the index was told about (behavior.md "履歴メニュー" 更新経路).
# Everything expensive -- ${#history}, the bulk expansion, the fingerprint --
# stays out of the path a prompt with no new event takes.
_zrush_hist_reconcile() {
  emulate -L zsh
  setopt localoptions typesetsilent no_monitor no_notify
  (( _zrush_hist_gen > 0 )) || return 0
  # An update neither starts a worker nor queues for an absent one.
  (( _zrush_worker_rfd >= 0 )) || return 0
  (( !_zrush_worker_stopping && !_zrush_worker_runtime_tainted )) || return 0
  local -i newest=$(( HISTCMD - 1 ))
  (( newest == _zrush_hist_head )) && return 0
  if (( newest != _zrush_hist_head + 1 )); then
    _zrush_hist_invalidate continuity
    return 0
  fi
  if (( _zrush_hist_unacked >= _ZRUSH_HIST_MAX_UNACKED )); then
    _zrush_hist_invalidate unacked
    return 0
  fi
  local line=$history[$newest]
  local -i count=$#history
  # An excluded event sends no frame, but head and the baseline advance exactly
  # as they would have: a snapshot would drop that same line, so the index stays
  # exact and the exclusion never reads as a permanent discontinuity.
  if _zrush_hist_excluded "$line"; then
    _zrush_hist_head=$newest _zrush_hist_count=$count
    _zlog "history: append skipped event=$newest (excluded)"
    return 0
  fi
  _zrush_history_append_payload $newest "$line"
  _zrush_request_history history-append "$REPLY" $newest || return 0
  _zrush_hist_latch $REPLY $newest $count
  (( ++_zrush_hist_unacked ))
  return 0
}

# behavior.md "履歴メニュー": one absolute deadline, anchored here -- once the
# payload is synthesized, on the cold path -- covers the lazy worker start, the
# handshake, the optional history-snapshot and the plan pipelined behind it, and
# ends on the plan's terminal response (the snapshot's is consumed on the way
# there). Cold does not get a second deadline.
_zrush_request_plan_sync() {  # cold snapshot-payload snapshot-head snapshot-count query
  emulate -L zsh
  local -i cold=$1
  local payload=$2
  local -i head=$3 count=$4
  local query=$5
  local -F deadline=$(( EPOCHREALTIME + ${ZRUSH_HISTORY_DEADLINE_MS:-100} / 1000.0 )) remaining
  local -i gen=$_zrush_hist_gen
  if (( cold )); then
    # The one path allowed to start a worker synchronously; the update path is
    # not (behavior.md "worker ライフサイクル").
    _zrush_worker_ensure_session || return 1
    _zrush_request_history history-snapshot "$payload" || return 1
    gen=$REPLY
    _zrush_hist_latch $gen $head $count
    _zrush_hist_unacked=0
  fi
  # cli-protocol.md "history profile": trailing-space is always false, so the
  # inserted text is the history line verbatim.
  _zrush_request_plan $gen history "$query" false || return 1
  local -i target=$REPLY cs
  _zlog "history: query request_id=$target generation=$gen limit=$ZRUSH_CFG_HISTORY_LIMIT"
  _zrush_sync_target=$target _zrush_sync_done=0 _zrush_sync_ok=0
  while (( !_zrush_sync_done )); do
    remaining=$(( deadline - EPOCHREALTIME ))
    if (( remaining <= 0 )); then
      _zrush_worker_session_fail "history deadline exceeded request_id=$target"
      return 1
    fi
    cs=$(( remaining * 100 ))
    (( cs < 1 )) && cs=1
    if (( _zrush_worker_ack_fd >= 0 )); then
      zselect -t $cs -r $_zrush_worker_rfd -r $_zrush_worker_ack_fd >/dev/null 2>&1
    else
      zselect -t $cs -r $_zrush_worker_rfd >/dev/null 2>&1
    fi
    if (( EPOCHREALTIME >= deadline )); then
      _zrush_worker_session_fail "history deadline exceeded request_id=$target"
      return 1
    fi
    _zrush_worker_consume_ack || return 1
    (( _zrush_worker_rfd >= 0 )) || return 1
    _zrush_worker_read sync "$deadline" || return 1
  done
  local -i ok=$_zrush_sync_ok
  _zrush_sync_target=0 _zrush_sync_done=0 _zrush_sync_ok=0
  # Only once the synchronous state is cleared, and never propagating the
  # status: arming fails by failing the session, which tears the transport down
  # and would take this exchange's committed result with it.
  [[ -n $_zrush_worker_rx ]] && _zrush_worker_arm_drain
  (( ok ))
}

# The one indivisible transition that opens the history menu: stop everything
# in flight, drop the current listing, then check the index, synthesize when it
# is cold, plan, show and select position 1 in one go. Zero matches and a failed
# plan both leave the buffer alone and consume the key.
_zrush_open_history_menu() {  # ZLE widget context
  emulate -L zsh
  # Opening the menu invalidates the current input_generation, which removes its
  # unhanded notification frames and cancels the collection it started; a late
  # event for it is dropped on arrival, so no completion result can replace the
  # menu (behavior.md "履歴メニュー").
  _zrush_input_invalidate
  _zrush_teardown
  # This action leaves BUFFER/CURSOR alone, so bring the pre-redraw baseline up
  # to date: without it the redraw that follows this very keystroke can be the
  # first one of the line and would read as an external change, erasing the
  # menu the moment it appears.
  _zrush_last_buffer=$BUFFER
  _zrush_last_cursor=$CURSOR
  # Level B, at the entrance of the synchronous window: the recorded baseline is
  # (HISTCMD, ${#history}) as of the last enqueued write, and head is that
  # HISTCMD minus one. ${#history} is read only once the cheap halves agree.
  local payload= reason=
  local -i cold=1 head=0 count=0
  if (( _zrush_hist_gen <= 0 )); then
    reason=index
  elif (( HISTCMD - 1 != _zrush_hist_head )); then
    reason=head
  else
    count=$#history
    if (( count != _zrush_hist_count )); then
      reason=count
    else
      cold=0
    fi
  fi
  if (( cold )); then
    _zlog "history: fingerprint cold (reason=$reason)"
    # Nothing may claim the old index from here on: the snapshot below
    # re-establishes the latch and the baseline together.
    _zrush_hist_reset
    _zrush_history_snapshot_payload
    payload=$REPLY head=$REPLY_HEAD count=$REPLY_COUNT
  else
    _zlog "history: fingerprint warm (generation=$_zrush_hist_gen)"
  fi
  # cli-protocol.md "history profile": the whole buffer is the query (the
  # sender strips NUL from --query).
  if _zrush_request_plan_sync $cold "$payload" $head $count "${BUFFER//$'\0'/}" &&
     (( _zrush_plan_npos > 0 )); then
    _zrush_selected=1
    _zrush_apply_plan
    _zlog "history: menu opened P=$_zrush_plan_npos"
    return 0
  fi
  _zrush_teardown
  _zlog "history: no menu (no match or plan failure)"
  return 0
}

# ---------------------------------------------------------------- ZLE hooks
_zrush_line_pre_redraw() {
  emulate -L zsh
  _zrush_status_refresh
  (( _zrush_enabled )) || return 0
  [[ -n $ZRUSH_INTERNAL ]] && return 0
  [[ $BUFFER == "$_zrush_last_buffer" ]] && (( CURSOR == _zrush_last_cursor )) && return 0
  _zrush_last_buffer=$BUFFER
  _zrush_last_cursor=$CURSOR
  # A buffer change invalidates the current input_generation first of all
  # (behavior.md "候補収集"). Whatever the worker still owes that generation is
  # discarded on arrival, so a late event can neither settle against the new
  # buffer nor consume a Tab meant for it.
  _zrush_input_invalidate
  # Reaching here means the change came from something other than a zrush
  # action (every zrush action tears the listing down itself, leaving kind
  # `none`), so a history menu goes away whole -- listing text included --
  # before the ordinary input flow resumes (behavior.md "履歴メニュー").
  if [[ $_zrush_plan_kind == history ]]; then
    _zlog "history: menu erased by an external buffer/cursor change"
    _zrush_teardown
  fi
  # A buffer change clears selection and pending Tab state. Remove only the selection
  # highlight immediately; retain list text and other decoration until the next result
  # to avoid flashing. ZLE adjusts their offsets with buffer edits.
  _zrush_selected=0
  _zrush_tab_pending=0
  _zrush_rh_clear_sel

  # See docs/internal/specs/behavior.md "候補収集": blank buffers neither collect nor display.
  if [[ -z ${BUFFER//[[:space:]]/} ]]; then
    _zrush_teardown
    return 0
  fi

  # Apply min-input to the current word; blank buffers were handled above.
  _zrush_widen "$LBUFFER"
  if (( ${#REPLY_WORD} < ZRUSH_CFG_MIN_INPUT )); then
    _zrush_teardown
    return 0
  fi

  # Input pressure is visible to zsh alone, so it is judged here: while keys are
  # still queued no notification is made, and the change that key causes makes
  # the next one (behavior.md "候補収集"). The listing is left as it is.
  (( KEYS_QUEUED_COUNT || PENDING )) && return 0

  _zrush_send_input
  return 0
}

_zrush_line_init() {
  emulate -L zsh
  _zrush_last_buffer=
  _zrush_last_cursor=-1
  # A new ZLE session can follow an exit that bypassed _zrush_line_finish
  # (send-break and similar). Invalidate any input_generation and collection
  # left by the previous session before it can leak a result (and thus a stray
  # candidate list or a pending-Tab insertion) into this one.
  _zrush_input_invalidate
  _zrush_teardown
  _zrush_status_refresh
  return 0
}

_zrush_line_finish() {
  emulate -L zsh
  (( _zrush_enabled )) || return 0
  _zrush_input_invalidate
  _zrush_teardown
  _zlog "line-finish: cleared"
  return 0
}

# ---------------------------------------------------------------- Confirmation
# See docs/internal/specs/behavior.md "確定(挿入)" and cli-protocol.md "適用".
# The insertion text (IPREFIX+ipre+apre+hpre+word+hsuf+asuf+isuf, `-f`
# directory '/' synthesis, trailing-space) is already fully built by
# the worker; this only computes the replacement boundary and swaps it in.
_zrush_confirm_pos() {  # $1=one-based position into _zrush_plan_insert
  emulate -L zsh
  local -i pos=$1
  (( pos >= 1 && pos <= $#_zrush_plan_insert )) || return 1
  local text=$_zrush_plan_insert[pos]

  # cli-protocol.md "適用": the listing kind picks the replacement rule.
  if [[ $_zrush_plan_kind == history ]]; then
    BUFFER=$text
    CURSOR=$#BUFFER
  else
    _zrush_widen "$LBUFFER"
    local word=$REPLY_WORD
    local pre=${LBUFFER[1,$#LBUFFER-$#word]}
    LBUFFER=$pre$text      # leave text after the cursor (RBUFFER) unchanged
  fi
  _zlog "confirm: kind=$_zrush_plan_kind pos=$pos insert=${(qqqq)text}"

  # After confirmation, clear selection/list and invalidate the pre-redraw
  # baseline, so the next pre-redraw always treats the insertion as a buffer
  # change and triggers recollection (behavior.md "確定(挿入)"), matching the
  # common-prefix insertion path. Leaving the baseline alone would not do: an
  # insertion identical to what the baseline already records -- confirming the
  # history candidate that equals the current line, say -- would read as "no
  # change" and stall the recollection.
  _zrush_last_buffer=
  _zrush_last_cursor=-1
  _zrush_input_invalidate
  _zrush_teardown
  return 0
}

# ---------------------------------------------------------------- Selection
_zrush_select_start() {
  emulate -L zsh
  (( _zrush_plan_npos > 0 )) || return 0
  _zrush_selected=1
  _zrush_apply_highlights
  _zlog "select: start"
  return 0
}

# Move the current selection using the last plan's navigation table
# (cli-protocol.md "ナビ"); no re-fetch or re-layout involved. A
# self-referencing transition (next/left/right clamped at the boundary) is a
# no-op per the contract; a transition to 0 is what the listing kind decides.
_zrush_select_dir() {  # $1=next|prev|left|right (navigation-table transition)
  emulate -L zsh
  local -i p=$_zrush_selected
  (( p >= 1 && p <= $#_zrush_plan_nav )) || return 0
  local -a f=( ${=_zrush_plan_nav[p]} )   # next prev left right
  local -i new
  case $1 in
    next)  new=$f[1] ;;
    prev)  new=$f[2] ;;
    left)  new=$f[3] ;;
    right) new=$f[4] ;;
    *) return 0 ;;
  esac
  (( new == p )) && return 0
  if (( new == 0 )) && [[ $_zrush_plan_kind == history ]]; then
    # No unselected history menu exists, so losing the selection erases it.
    _zlog "history: menu closed at position 1"
    _zrush_teardown
    return 0
  fi
  _zrush_selected=$new
  _zrush_apply_highlights
  _zlog "select: dir=$1 pos=$_zrush_selected"
  return 0
}

# The one place the select-prev/select-next keys are mapped onto navigation-table
# transitions. A completion listing maps them straight through; a history listing
# inverts them, because there ↑ moves away from the prompt into older history and
# ↓ moves back toward it (behavior.md "履歴メニュー").
_zrush_select_move() {  # $1=select-prev|select-next
  emulate -L zsh
  local t
  if [[ $_zrush_plan_kind == history ]]; then
    [[ $1 == select-prev ]] && t=next || t=prev
  else
    [[ $1 == select-prev ]] && t=prev || t=next
  fi
  _zrush_select_dir $t
  return 0
}

# ---------------------------------------------------------------- State-dependent dispatch
# The dispatch function embeds its predecessor as an argument and sets it here.
# Do not inspect $WIDGET: wrappers such as z-sy-h may reinvoke the original widget
# under another name (for example orig-s2h:*), which must not break fallback.
typeset -g _zrush_dispatch_prev=

_zrush_call_prev() {  # Fall back through the predecessor chain, never directly to a builtin.
  emulate -L zsh
  local prev=$_zrush_dispatch_prev
  if [[ -n $prev && $prev != undefined-key ]] && (( $+widgets[$prev] )); then
    _zlog "dispatch: fallback -> $prev"
    zle $prev -w
  fi
  return 0
}

_zrush_action_next() {
  if (( _zrush_selected > 0 )); then
    _zrush_select_move select-next
    return 0
  fi
  # See docs/internal/specs/behavior.md "選択・キーバインド" for this priority order.
  if [[ $BUFFER == *$'\n'* && ${BUFFER[CURSOR+1,-1]} == *$'\n'* ]]; then
    _zlog "next: multiline-branch"
    _zrush_call_prev; return 0            # 1. middle line in multiline buffer -> cursor movement
  fi
  if (( HISTNO != HISTCMD )); then
    _zlog "next: hist-branch"
    _zrush_call_prev; return 0            # 2. browsing history -> move toward newer history
  fi
  if (( _zrush_listing && _zrush_plan_npos > 0 )); then
    _zrush_select_start; return 0         # 3. visible list -> start selection
  fi
  _zrush_call_prev                        # 4. otherwise -> predecessor
  return 0
}

_zrush_action_prev() {
  if (( _zrush_selected > 0 )); then
    _zrush_select_move select-prev
    return 0
  fi
  # See docs/internal/specs/behavior.md "選択・キーバインド" for this priority order.
  if [[ $LBUFFER == *$'\n'* ]]; then
    _zlog "prev: multiline-branch"
    _zrush_call_prev; return 0            # 1. not on the first line -> cursor movement
  fi
  if (( HISTNO != HISTCMD )); then
    _zlog "prev: hist-branch"
    _zrush_call_prev; return 0            # 2. browsing history -> keep plain history movement
  fi
  _zrush_open_history_menu                # 3. otherwise -> open the history menu
  return 0
}

# select-left/right jump columns only while selected; otherwise fall back to the
# predecessor (cursor movement for the default arrow bindings).
_zrush_action_left() {
  if (( _zrush_selected > 0 )); then
    _zrush_select_dir left
    return 0
  fi
  _zrush_call_prev
  return 0
}

_zrush_action_right() {
  if (( _zrush_selected > 0 )); then
    _zrush_select_dir right
    return 0
  fi
  _zrush_call_prev
  return 0
}

_zrush_action_confirm() {
  if (( _zrush_selected > 0 )); then
    _zrush_confirm_pos $_zrush_selected
    return 0
  fi
  _zrush_call_prev
  return 0
}

_zrush_action_dismiss() {
  if (( _zrush_selected > 0 || _zrush_listing )); then
    _zlog "dismiss: closing list"
    # An input_generation still awaiting an event, or an in-flight collection
    # for a newer keystroke, could otherwise arrive after dismiss and silently
    # reopen the list the user just closed.
    _zrush_input_invalidate
    _zrush_teardown          # leave the buffer unchanged
    return 0
  fi
  _zrush_call_prev
  return 0
}

# Tab follows [insert].tab rather than acting as an independent action.
_zrush_tab_with_results() {  # Tab behavior when results are available
  emulate -L zsh
  case $ZRUSH_CFG_TAB in
    menu)
      _zrush_select_start
      ;;
    insert)
      (( _zrush_plan_npos > 0 )) && _zrush_confirm_pos 1
      ;;
    common-prefix)
      # See cli-protocol.md "common-prefix の意味論" and behavior.md "Tab".
      local cp=$_zrush_plan_cp q=$_zrush_fuzzy
      if [[ -n $cp && $cp != "$q" && $cp == "$q"* ]]; then
        _zrush_widen "$LBUFFER"
        local word=$REPLY_WORD keep=$REPLY_KEEP
        local pre=${LBUFFER[1,$#LBUFFER-$#word]}
        LBUFFER=$pre$keep${(q)cp}
        _zlog "tab: common-prefix inserted ${(qqqq)cp}"
        # Partial insertion is not confirmation; leave last_buffer stale to trigger recollection.
      else
        _zlog "tab: common-prefix fallback -> insert top (cp=${(qqqq)cp} q=${(qqqq)q})"
        (( _zrush_plan_npos > 0 )) && _zrush_confirm_pos 1
      fi
      ;;
  esac
  return 0
}

_zrush_action_tab() {
  emulate -L zsh
  if (( _zrush_selected > 0 )); then
    _zrush_confirm_pos $_zrush_selected   # Tab confirms the selection
    return 0
  fi
  # Before candidates arrive, Tab records the press and is applied when they
  # come (behavior.md "Tab"). While the worker is still measuring the quiet
  # period, a flush cuts it short so the event -- a plan, or the capture request
  # that leads to one -- comes without waiting; once the capture is running,
  # that fast-forward has already happened and only the press is recorded.
  if (( _zrush_input_pending )); then
    _zlog "tab: pending (quiet-period flush of input_generation=$_zrush_input_gen)"
    _zrush_tab_pending=1
    _zrush_send_flush
    return 0
  fi
  if (( _zrush_rfd >= 0 )); then
    _zlog "tab: pending (collection in flight)"
    _zrush_tab_pending=1
    return 0
  fi
  if (( _zrush_listing && _zrush_plan_npos > 0 )); then
    _zrush_tab_with_results
    return 0
  fi
  _zrush_call_prev      # no list and nothing in flight -> predecessor, such as native completion
  return 0
}

_zrush_dispatch() {  # $1=action $2=predecessor $3=dispatcher name
  emulate -L zsh
  _zrush_dispatch_prev=${2:-}
  if (( !_zrush_enabled || _zrush_disabled || ! ${+_zrush_active_dsp[${3:-}]} )); then
    _zrush_call_prev
    return 0
  fi
  case ${1:-} in
    select-next)  _zrush_action_next ;;
    select-prev)  _zrush_action_prev ;;
    select-left)  _zrush_action_left ;;
    select-right) _zrush_action_right ;;
    confirm)      _zrush_action_confirm ;;
    dismiss)      _zrush_action_dismiss ;;
    tab)          _zrush_action_tab ;;
    *)            _zrush_call_prev ;;
  esac
  return 0
}

# ---------------------------------------------------------------- Apply key bindings
# behavior.md "プラグイン共存": caller has restored a directly owned layer.
_zrush_release_dispatch() {  # $1=unbound dispatch widget name
  emulate -L zsh
  local w=$1
  zle -D $w 2>/dev/null
  unfunction -- $w 2>/dev/null
  unset "_zrush_dsp_prev[$w]"
  return 0
}

# Resolve key:<name> into bindable sequences using terminfo plus both CSI/SS3 arrows.
_zrush_key_seqs() {  # $1=key:<name> -> reply=(sequences...)
  emulate -L zsh
  local name=${1#key:}
  local -a seqs=()
  case $name in
    up)        seqs=( "${terminfo[kcuu1]:-}" $'\e[A' $'\eOA' ) ;;
    down)      seqs=( "${terminfo[kcud1]:-}" $'\e[B' $'\eOB' ) ;;
    left)      seqs=( "${terminfo[kcub1]:-}" $'\e[D' $'\eOD' ) ;;
    right)     seqs=( "${terminfo[kcuf1]:-}" $'\e[C' $'\eOC' ) ;;
    shift-tab) seqs=( "${terminfo[kcbt]:-}" ) ;;
    home)      seqs=( "${terminfo[khome]:-}" ) ;;
    end)       seqs=( "${terminfo[kend]:-}" ) ;;
    pgup)      seqs=( "${terminfo[kpp]:-}" ) ;;
    pgdn)      seqs=( "${terminfo[knp]:-}" ) ;;
    delete)    seqs=( "${terminfo[kdch1]:-}" ) ;;
    *) return 1 ;;
  esac
  typeset -ga reply=( ${(u)seqs:#} )   # remove empty entries and duplicates
  (( $#reply > 0 ))
}

# Bind one key sequence to an action's dispatch widget.
# If already bound to our dispatcher, retain its recorded predecessor so reload does not
# capture this layer as its own predecessor; see behavior.md "プラグイン共存".
_zrush_bind_one() {  # $1=action $2=key sequence in bindkey notation or raw form
  emulate -L zsh
  local action=$1 seq=$2
  local cur=${${(z)"$(builtin bindkey -M main -- "$seq" 2>/dev/null)"}[2]:-}
  local prev= wname=${_zrush_bound[$seq]:-}
  if [[ -n $wname && $cur == $wname && ${widgets[$wname]:-} == user:$wname ]]; then
    prev=${_zrush_dsp_prev[$wname]:-}
  else
    [[ -n $cur && $cur != undefined-key ]] && prev=$cur
    wname=_zrush-dsp-$(( ++_zrush_dsp_n ))
  fi
  _zrush_dsp_prev[$wname]=$prev      # ledger for restoration and self-capture detection
  # Embed action and predecessor in the function body to tolerate widget wrappers; see above.
  functions[$wname]="_zrush_dispatch ${(q)action} ${(q)prev} ${(q)wname}"
  zle -N $wname
  builtin bindkey -M main -- "$seq" $wname
  _zrush_new_bound[$seq]=$wname
  return 0
}

_zrush_apply_keybinds() {
  emulate -L zsh
  # Validation guarantees an even-length array; empty means bind nothing.
  local -a kb=( "${(@)ZRUSH_CFG_KEYBINDS}" )
  typeset -gA _zrush_new_bound=()
  local -i i
  local action spec s
  local -a reply
  for (( i = 1; i + 1 <= $#kb; i += 2 )); do
    action=$kb[i] spec=$kb[i+1]
    case $spec in
      seq:*)
        _zrush_bind_one $action "${spec#seq:}"
        ;;
      key:*)
        if _zrush_key_seqs $spec; then
          for s in "${(@)reply}"; do
            _zrush_bind_one $action "$s"
          done
        else
          _zrush_warn "keybinds: no terminfo sequence for '${spec#key:}'; skipping $action"
        fi
        ;;
      *)
        _zrush_warn "keybinds: unknown key spec '${spec}' for $action; skipping"
        ;;
    esac
  done
  # Tab is a fixed hook governed by [insert].tab, not an independent action.
  _zrush_bind_one tab '^I'
  # Restore predecessors for keys removed by this application.
  local seq w p
  for seq in "${(@k)_zrush_bound}"; do
    if [[ -z ${_zrush_new_bound[$seq]:-} ]]; then
      w=${_zrush_bound[$seq]}
      local cur=${${(z)"$(builtin bindkey -M main -- "$seq" 2>/dev/null)"}[2]:-}
      if [[ $cur == $w && ${widgets[$w]:-} == user:$w ]]; then
        p=${_zrush_dsp_prev[$w]:-}
        if builtin bindkey -M main -- "$seq" ${p:-undefined-key}; then
          _zrush_release_dispatch $w
          _zlog "keybinds: restored ${(qqqq)seq} -> ${p:-undefined-key}; released $w"
        fi
      fi
    fi
  done
  typeset -gA _zrush_bound=( "${(@kv)_zrush_new_bound}" )
  typeset -gA _zrush_active_dsp=()
  for w in "${(@v)_zrush_bound}"; do
    _zrush_active_dsp[$w]=1
  done
  unset _zrush_new_bound
  return 0
}

# ---------------------------------------------------------------- Exit cleanup
_zrush_zshexit() {
  emulate -L zsh
  # ZLE is inactive here; readiness cleanup cannot be relied upon after this hook.
  _zrush_worker_shutdown
  _zrush_worker_release_writer
  _zrush_worker_close_response
  _zrush_worker_close_request
  _zrush_worker_close_control
  _zrush_worker_runtime_destroy
  if (( _zrush_rfd >= 0 )); then _zrush_close_internal_fd $_zrush_rfd; _zrush_rfd=-1; fi
  if (( _zrush_wfd >= 0 )); then _zrush_close_internal_fd $_zrush_wfd; _zrush_wfd=-1; fi
  if [[ -n $_zrush_pty ]]; then
    if [[ $_zrush_capture_pid == <-> ]] && (( _zrush_capture_pid > 1 )); then
      kill -INT -$_zrush_capture_pid 2>/dev/null || kill -INT $_zrush_capture_pid 2>/dev/null
    fi
    zpty -d $_zrush_pty 2>/dev/null
    _zrush_pty=
  fi
  return 0
}

# ---------------------------------------------------------------- Initialization
_zrush_init() {
  emulate -L zsh

  if [[ ! -x $ZRUSH_BIN ]]; then
    _zrush_warn "binary not found or not executable: $ZRUSH_BIN (load via 'source <(zrush init zsh)' or set \$ZRUSH_BIN); zrush disabled"
    return 1
  fi

  zmodload zsh/zpty zsh/system zsh/zutil zsh/parameter zsh/zselect zsh/datetime zsh/terminfo 2>/dev/null || {
    _zrush_warn "required zsh modules unavailable; zrush disabled"
    return 1
  }
  zmodload -F zsh/stat b:zstat 2>/dev/null || {
    _zrush_warn "zsh/stat unavailable; zrush disabled"
    return 1
  }
  autoload -Uz add-zsh-hook add-zle-hook-widget is-at-least

  # zsh 5.9+ memo fields let z-sy-h 0.8+ distinguish region_highlight ownership.
  _zrush_hl_memo=
  is-at-least 5.9 $ZSH_VERSION && _zrush_hl_memo=' memo=zrush'

  _zrush_config_path
  # Always load config once at source time to guarantee build-stamp comparison.
  _zrush_load_config initial
  case $? in
    0) ;;
    2) return 0 ;; # the replacement generation is already fully initialized
    *)
      (( _zrush_disabled || _zrush_stale_disabled )) || \
        _zrush_warn "initial 'zrush config' failed; zrush disabled"
      return 1
      ;;
  esac
  (( _zrush_disabled || _zrush_stale_disabled )) && return 1

  _zrush_worker_runtime_prepare || {
    _zrush_warn "worker runtime FIFO setup failed; zrush disabled"
    _zrush_disable_reason=runtime
    _zrush_disabled=1 _zrush_enabled=0
    _zrush_notice="zrush: worker disabled (runtime setup failed); start a new shell"
    return 1
  }

  # Detect compinit via _main_complete, including setups delegated to zsh-autocomplete.
  if (( ! $+functions[_main_complete] )); then
    _zrush_warn "compsys not initialized (run compinit before sourcing zrush.zsh); completions will be empty"
  fi

  # Register widgets; _zrush-capture-* are invoked only inside the fork.
  zle -N _zrush-kick-drain _zrush_kick_drain
  _zrush_kick_init
  zle -N _zrush-on-data _zrush_on_data
  zle -N _zrush-capture-entry _zrush_capture_entry
  zle -C _zrush-capture-comp list-choices _zrush_capture_complete
  zle -N _zrush-line-pre-redraw _zrush_line_pre_redraw
  zle -N _zrush-line-init _zrush_line_init
  zle -N _zrush-line-finish _zrush_line_finish

  # Register through add-zle-hook-widget for supported coexistence with zsh-syntax-highlighting.
  add-zle-hook-widget line-pre-redraw _zrush-line-pre-redraw
  add-zle-hook-widget line-init _zrush-line-init
  add-zle-hook-widget line-finish _zrush-line-finish
  add-zsh-hook precmd _zrush_precmd
  add-zsh-hook zshexit _zrush_zshexit   # preserve existing zshexit handlers via the hook array

  # Apply bindings to the main keymap and record predecessor chains.
  _zrush_apply_keybinds

  _zrush_enabled=1
  _zrush_installed=1
  _zlog "init: enabled (bin=$ZRUSH_BIN stamp=$ZRUSH_BUILD_STAMP)"
  return 0
}

# Test seam: tests/zsh/vectors.zsh sources this file with ZRUSH_NO_INIT=1 to
# exercise _zrush_parse_plan and _zrush_encode_batch alone, without
# zle/compsys/binary side effects.
[[ -n $ZRUSH_NO_INIT ]] || _zrush_init
