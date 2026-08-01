# zrush.zsh — ZLE integration for asynchronous completion
#
# Requirements: zsh 5.8+, source after compinit, after zsh-abbr, and before
# zsh-syntax-highlighting. $ZRUSH_BIN overrides ../target/release/zrush.
#
# zsh captures compsys candidates in a forked shell and hands the raw
# capture stream straight to `zrush plan` (Rust), which performs matching,
# ranking, grouping, grid layout, highlight/navigation-table computation,
# and insertion-text construction. This file only captures and applies:
# it does not parse candidate records, compute layout, or reconstruct
# insertion text itself.
#
# See docs/internal/specs/behavior.md for observable behavior and architecture.
# See docs/internal/contracts/cli-protocol.md for the zsh/Rust boundary.
#
# Set ZRUSH_LOG=<file> to append timestamped debug traces; unset is a no-op.

# Capture the source directory; re-sourcing is allowed and reinitializes state.
typeset -g _zrush_source_dir=${${(%):-%N}:A:h}

# ---------------------------------------------------------------- Re-source teardown
# Re-sourcing this file is supported, but the `typeset -g` block right below
# immediately resets fd/zpty/timer identifiers to -1/empty -- if a previous
# sourcing already completed _zrush_init (_zrush_enabled=1), its live
# timer/collection/zpty worker/region_highlight entries must be torn down
# FIRST, using the still-defined functions and still-live values left over
# from that previous sourcing, or they would be stranded (leaked fds, an
# orphaned worker, dangling region_highlight entries). On a first-ever
# sourcing _zrush_enabled is unset, so this is a no-op.
# Keybind predecessor chains need no action here: they are embedded in each
# dispatch widget's own function body at bind time (_zrush_bind_one), not
# read from these globals, so _zrush_apply_keybinds' normal re-application
# later in _zrush_init already handles them correctly on re-source.
if (( ${+_zrush_enabled} )) && (( _zrush_enabled )); then
  (( $+functions[_zrush_disarm_timer] ))      && _zrush_disarm_timer
  (( $+functions[_zrush_cancel_collection] )) && _zrush_cancel_collection
  (( $+functions[_zrush_rh_clear] ))          && _zrush_rh_clear
fi

# ---------------------------------------------------------------- Global state
typeset -g  ZRUSH_BIN=${ZRUSH_BIN:-$_zrush_source_dir/../target/release/zrush}
typeset -gi _zrush_enabled=0
typeset -gi _ZRUSH_EXPECTED_PROTO=4
typeset -g  _zrush_cfg_path= _zrush_cfg_mtime=
typeset -gi _zrush_plan_warned=0 _zrush_proto_warned=0
# Variables this script consumes from `zrush config` output (validation and rollback)
typeset -ga _ZRUSH_CFG_VARS=(
  ZRUSH_CFG_MAX_LINES ZRUSH_CFG_DELAY_MS ZRUSH_CFG_MIN_INPUT
  ZRUSH_CFG_MODE ZRUSH_CFG_SMART_CASE ZRUSH_CFG_TAB ZRUSH_CFG_TRAILING_SPACE
  ZRUSH_CFG_HL_SELECTED ZRUSH_CFG_HL_MATCH ZRUSH_CFG_HL_HEADING
  ZRUSH_CFG_HISTORY_LIMIT ZRUSH_CFG_KEYBINDS ZRUSH_CFG_WARNINGS
)

# Collection request state
typeset -g  _zrush_query= _zrush_fuzzy= _zrush_buf= _zrush_pty= _zrush_worker_pid=
typeset -gi _zrush_rfd=-1 _zrush_wfd=-1 _zrush_gen=0 _zrush_timer_fd=-1
typeset -g  _zrush_pending_buffer=
typeset -g  _zrush_last_buffer=
typeset -gi _zrush_last_cursor=-1

# Render plan received from `zrush plan` (cli-protocol.md "stdout(描画プラン)").
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
# The stored payload is the raw capture stream (pid record already stripped,
# cli-protocol.md "候補レコード" / "スキップ規律"), fed to `zrush plan` unparsed
# on a hit; an empty fingerprint means no cache entry.
typeset -g  _zrush_cc_fp=          # fingerprint at save time
typeset -gi _zrush_cc_time=0       # save time (EPOCHSECONDS)
typeset -g  _zrush_cc_payload=
typeset -gi _ZRUSH_CC_TTL=300      # seconds; catches same-count replacement and is not configurable

# Key bindings (dispatch widget -> predecessor/action)
typeset -gA _zrush_dsp_prev=() _zrush_bound=()
typeset -gi _zrush_dsp_n=0

# ---------------------------------------------------------------- Utilities
_zlog() { [[ -n $ZRUSH_LOG ]] && print -r -- "[$$ ${EPOCHREALTIME:-0}] $1" >>| $ZRUSH_LOG; return 0 }

_zrush_warn() { print -ru2 -- "zrush: $1" }

# ---------------------------------------------------------------- Widening
# See docs/internal/specs/behavior.md "候補収集" and cli-protocol.md "起動".
_zrush_widen() {  # $1=buffer through the cursor
                  # → REPLY_WIDENED / REPLY_QUERY / REPLY_KEEP / REPLY_WORD
  emulate -L zsh
  setopt extendedglob
  local buf=$1
  local word=${buf##*[[:space:]]}
  local pre=${buf[1,$#buf-$#word]}
  local keep= query=
  if [[ $word == *[/=]* ]]; then
    query=${word##*[/=]}
    keep=${word[1,$#word-$#query]}
  elif [[ $word == -* ]]; then
    keep=${(M)word##-##}
    query=${word[$#keep+1,-1]}
  else
    query=$word
  fi
  typeset -g REPLY_WIDENED=$pre$keep REPLY_QUERY=$query REPLY_KEEP=$keep REPLY_WORD=$word
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

# Run and source `zrush config`. $1=initial|reload
# Returns 0 on success after updating global ZRUSH_CFG_* / ZRUSH_PROTOCOL_VERSION.
_zrush_load_config() {
  emulate -L zsh
  local out
  out=$("$ZRUSH_BIN" config 2>/dev/null) || return 1
  # eval assigns the globals in place, so snapshot the previous values first;
  # a failed load rolls back (a failed reload keeps the previous configuration).
  local rollback=
  (( $+ZRUSH_PROTOCOL_VERSION )) && \
    rollback=$(typeset -p ZRUSH_PROTOCOL_VERSION "${(@)_ZRUSH_CFG_VARS}" 2>/dev/null)
  # The protocol restricts output to static typeset assignments; evaluate in this controlled scope.
  if ! eval "$out" 2>/dev/null || ! _zrush_validate_config; then
    [[ -n $rollback ]] && eval "$rollback"
    return 1
  fi
  # A version mismatch warns once and does not disable the session.
  if [[ $ZRUSH_PROTOCOL_VERSION != $_ZRUSH_EXPECTED_PROTO ]] && (( ! _zrush_proto_warned )); then
    _zrush_warn "protocol version mismatch: zsh expects $_ZRUSH_EXPECTED_PROTO, binary reports $ZRUSH_PROTOCOL_VERSION (rebuild zrush?)"
    _zrush_proto_warned=1
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
  [[ -n $ZRUSH_PROTOCOL_VERSION ]] || return 1
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

# At each prompt, reload config.toml when its mtime changes.
_zrush_precmd() {
  emulate -L zsh
  (( _zrush_enabled )) || return 0
  _zrush_config_mtime
  if [[ $REPLY != $_zrush_cfg_mtime ]]; then
    _zlog "precmd: config mtime changed ($_zrush_cfg_mtime -> $REPLY); reloading"
    if _zrush_load_config reload; then
      _zrush_apply_keybinds    # reapply without capturing this layer as its own predecessor
    else
      _zlog "precmd: config reload failed; keeping previous values"
      # Keep the previous configuration after a failed reload; see cli-protocol.md.
    fi
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
    exec {_zrush_wfd}>&-
    builtin exit 0
  }
}

# Fork body executed by zpty after forking the current shell
_zrush_worker() {
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
  _zlog "fork: start wfd=$_zrush_wfd"
  # The inherited read-side copy is not needed.
  (( _zrush_rfd >= 0 )) && exec {_zrush_rfd}<&-
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
    exec {_zrush_rfd}<&-
    _zrush_rfd=-1
  fi
  if (( _zrush_wfd >= 0 )); then
    exec {_zrush_wfd}>&-
    _zrush_wfd=-1
  fi
  if [[ -n $_zrush_pty ]]; then
    # SIGINT the worker's real process group to interrupt external-command waits.
    # Before the pid arrives, zpty -d HUP plus EPIPE after pipe closure is the fallback.
    if [[ $_zrush_worker_pid == <-> ]] && (( _zrush_worker_pid > 1 )); then
      _zlog "cancel: SIGINT to worker pgid $_zrush_worker_pid"
      kill -INT -$_zrush_worker_pid 2>/dev/null || kill -INT $_zrush_worker_pid 2>/dev/null
    fi
    zpty -d $_zrush_pty 2>/dev/null
    _zrush_pty=
  fi
  _zrush_worker_pid=
  _zrush_buf=
}

_zrush_disarm_timer() {
  emulate -L zsh
  if (( _zrush_timer_fd >= 0 )); then
    zle -F $_zrush_timer_fd 2>/dev/null
    exec {_zrush_timer_fd}<&-
    _zrush_timer_fd=-1
  fi
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
# and match/heading decoration until the next result.
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
# Call only from a ZLE widget context. In-flight work (debounce timer,
# collection) is not part of the listing; callers that must also stop it call
# _zrush_disarm_timer / _zrush_cancel_collection first.
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

_zrush_cc_invalidate() {
  _zrush_cc_fp=
  _zrush_cc_payload=
  _zrush_cc_time=0
  return 0
}

_zrush_cc_check() {  # 0=usable hit; on a miss, log the reason and return nonzero
  emulate -L zsh
  if [[ -z $_zrush_cc_fp ]]; then
    _zlog "cache: miss (empty)"
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
  _zlog "cache: hit (${#_zrush_cc_payload} bytes)"
  return 0
}

_zrush_cc_save() {  # $1=raw capture payload (pid stripped)
  emulate -L zsh
  _zrush_cc_fingerprint
  _zrush_cc_fp=$REPLY
  _zrush_cc_time=$EPOCHSECONDS
  _zrush_cc_payload=$1
  _zlog "cache: saved (${#1} bytes)"
  return 0
}

# Start a collection request from a widget or handler context.
_zrush_start_request() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify
  [[ -n $ZRUSH_INTERNAL ]] && return 0
  _zrush_cancel_collection

  # Recompute widening from the buffer at start time. pre-redraw normally re-arms the
  # timer after any change during debounce, so this should already be current.
  _zrush_widen "$LBUFFER"
  _zrush_query=$REPLY_WIDENED
  _zrush_fuzzy=${REPLY_QUERY//$'\0'/}   # the sender must strip NUL from --query
  _zlog "request: widened=${(qqqq)_zrush_query} fuzzy=${(qqqq)_zrush_fuzzy}"

  # See behavior.md "空語収集キャッシュ". zle -F -w callers require explicit redraw.
  if [[ -z $_zrush_query ]] && _zrush_cc_check; then
    _zrush_run_plan "$_zrush_cc_payload" compsys "$_zrush_fuzzy" "$ZRUSH_CFG_TRAILING_SPACE"
    _zrush_settle_plan $?
    zle -R
    return 0
  fi

  # Anonymous pipe: open both FIFO ends, unlink immediately, and use EOF as terminator.
  local fifo=${TMPDIR:-/tmp}/zrush-$$-$RANDOM.fifo
  mkfifo $fifo 2>/dev/null || return 1
  local rw
  exec {rw}<>$fifo
  exec {_zrush_rfd}<$fifo
  exec {_zrush_wfd}>$fifo
  exec {rw}>&-
  rm -f $fifo

  _zrush_pty=zrush-w$(( ++_zrush_gen ))
  if ! zpty $_zrush_pty _zrush_worker; then
    _zlog "request: zpty create failed"
    _zrush_cancel_collection
    return 1
  fi
  # Close the parent's write-side copy immediately after the fork so EOF remains detectable.
  exec {_zrush_wfd}>&-
  _zrush_wfd=-1

  zle -F -w $_zrush_rfd _zrush-on-data
  _zlog "request: collecting on fd $_zrush_rfd (pty $_zrush_pty)"
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
    if [[ -z $_zrush_worker_pid && $_zrush_buf == *$'\0'* ]]; then
      local first=${_zrush_buf%%$'\0'*}
      if [[ $first == pid$'\1'<-> ]]; then
        _zrush_worker_pid=${first#pid$'\1'}
        _zrush_buf=${_zrush_buf#*$'\0'}
      fi
    fi
    return 0
  fi
  # EOF (5) or a read error ends reception for this request.
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  _zrush_rfd=-1
  zpty -d $_zrush_pty 2>/dev/null
  _zrush_pty=
  _zrush_worker_pid=
  if (( st == 5 )); then
    _zrush_finalize
    # zle -F -w does not redraw on return. Apply POSTDISPLAY, region_highlight, and
    # any BUFFER change from a pending Tab in one explicit redraw.
    zle -R
  else
    _zlog "on-data: read error st=$st; dropping request"
    _zrush_buf=
  fi
  return 0
}

# Collection payload (pid already stripped) -> `zrush plan`, applied on success.
# The payload is handed to `zrush plan` unparsed: record parsing, matching,
# ranking, layout, and highlight/nav/insert construction are all Rust's job
# (cli-protocol.md). Cache successful empty-word command-position results
# across prompts (behavior.md "空語収集キャッシュ").
_zrush_finalize() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify
  local payload=$_zrush_buf
  _zrush_buf=
  # Marks "transport" (fork -> parent pipe) complete, mirroring every other
  # pipeline stage's own checkpoint; driver-latency.zsh's breakdown reads it.
  _zlog "finalize: ${#payload} bytes"
  if [[ -z $_zrush_query && -n $payload ]]; then
    _zrush_cc_save "$payload"
  fi
  _zrush_run_plan "$payload" compsys "$_zrush_fuzzy" "$ZRUSH_CFG_TRAILING_SPACE"
  _zrush_settle_plan $?
  return 0
}

# Apply (or discard, on failure) the plan just fetched by `_zrush_run_plan`,
# then resolve a Tab recorded before it arrived. $1=0 on success (state
# already populated), nonzero on failure. Shared by both `_zrush_run_plan`
# call sites (fresh collection and cache hit) so the pending-Tab handling
# in behavior.md "Tab" ("候補未着時の Tab は...結果到着時に上記の挙動を適用する")
# cannot be forgotten on one path but not the other.
#
# On failure, a pending Tab is discarded outright -- it is never resolved
# against _zrush_plan_* here (cli-protocol.md "エラー時の zsh 側挙動").
_zrush_settle_plan() {
  emulate -L zsh
  if (( $1 == 0 )); then
    _zrush_apply_plan
    if (( _zrush_tab_pending )); then
      _zrush_tab_pending=0
      _zrush_tab_with_results
    fi
  else
    _zrush_teardown
  fi
  return 0
}

# ---------------------------------------------------------------- Plan retrieval
# See docs/internal/contracts/cli-protocol.md "`zrush plan`" and "stdout(描画プラン)".
# Runs the pure `zrush plan` pipeline over a payload and populates
# _zrush_plan_* on success. The argument values that differ per producer
# (query, trailing-space) belong to the producer profile, so the caller that
# owns the payload passes them in rather than this function guessing.
_zrush_run_plan() {  # $1=NUL-terminated payload ("" is valid: 0 candidates)
                     # $2=producer  $3=--query value  $4=--trailing-space value
  emulate -L zsh
  setopt localoptions typesetsilent no_monitor no_notify
  local payload=$1 producer=$2 query=$3 tspace=$4

  # cli-protocol.md "起動": rows = min(max-lines, LINES - 1), clamped to >= 1
  # unconditionally (not just when LINES > 1 -- LINES <= 1 must still clamp
  # down to the 1-row floor, not silently keep max-lines).
  local -i rows=$(( LINES - 1 ))
  (( rows > ZRUSH_CFG_MAX_LINES )) && rows=$ZRUSH_CFG_MAX_LINES
  (( rows < 1 )) && rows=1
  local -i width=$(( COLUMNS - 1 ))
  (( width < 1 )) && width=1

  # `zrush plan` is pure over its arguments and stdin; suppress stderr to protect ZLE.
  local out
  out=$(print -rn -- "$payload" | \
        "$ZRUSH_BIN" plan --producer "$producer" \
                          --query "$query" --mode "$ZRUSH_CFG_MODE" \
                          --smart-case "$ZRUSH_CFG_SMART_CASE" \
                          --rows $rows --width $width \
                          --trailing-space "$tspace" 2>/dev/null)
  local -i rc=$?
  if (( rc == 0 )) && _zrush_parse_plan "$out"; then
    _zrush_plan_kind=$producer
    _zlog "plan: ok producer=$producer L=$_zrush_plan_nlines P=$_zrush_plan_npos"
    return 0
  fi
  # cli-protocol.md "エラー時の zsh 側挙動": discard, warn once per session; the
  # caller is responsible for clearing any existing display.
  if (( ! _zrush_plan_warned )); then
    _zrush_warn "zrush plan failed or returned a malformed plan; suppressing further warnings this session"
    _zrush_plan_warned=1
  fi
  _zlog "plan: failed (exit=$rc)"
  return 1
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

# Validate and split one `zrush plan` stdout buffer into _zrush_plan_*.
# Field layout is fixed (cli-protocol.md "stdout(描画プラン)"):
#   common-prefix, L, P, L rows, H, H "role pos start len", P "start len",
#   P "next prev left right", P insert texts -- total 4 + L + H + 3P fields.
_zrush_parse_plan() {  # $1=raw `zrush plan` stdout
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
    [[ $role == match || $role == heading ]] || return 1
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
  local -i off=$(( $#BUFFER + 1 ))   # account for the leading newline
  local -i sel=$_zrush_selected
  local e role spec
  local -a f
  for e in "${(@)_zrush_plan_hl}"; do
    f=( ${=e} )   # role pos start len
    if [[ $f[1] == match ]]; then
      (( f[2] == sel )) && continue   # the selected cell's own decoration wins
      spec=$hl_mat
    else
      spec=$hl_head
    fi
    [[ -n $spec ]] || continue
    _zrush_rh_add $(( off + f[3] )) $(( off + f[3] + f[4] )) "$spec"
  done
  if (( sel > 0 )) && [[ -n $hl_sel ]]; then
    f=( ${=_zrush_plan_cells[sel]} )   # start len
    _zrush_rh_add $(( off + f[1] )) $(( off + f[1] + f[2] )) "$hl_sel" -sel
  fi
  return 0
}

# ---------------------------------------------------------------- History menu
# See docs/internal/specs/behavior.md "履歴メニュー" and cli-protocol.md
# "history profile".
#
# $history maps event numbers to lines and its values come out newest first.
# Event numbers have gaps, so the newest `limit` entries are the first `limit`
# values -- never a decrement from HISTCMD, and never `fc` output (multi-line
# entries break its line-oriented format).
_zrush_history_payload() {  # -> REPLY = payload bytes for `zrush plan` stdin
  emulate -L zsh
  local -i limit=$ZRUSH_CFG_HISTORY_LIMIT
  local -a lines=()
  if (( limit > 0 )); then
    lines=( "${(@)history}" )
    (( $#lines > limit )) && lines=( "${(@)lines[1,limit]}" )
    # Within that range (nothing is pulled in from outside it to make up for a
    # drop): empty lines cannot be candidates, and a line carrying a framing
    # byte is dropped whole rather than stripped. Every other control byte is
    # sent as-is; normalizing it for display is `zrush plan`'s job.
    lines=( "${(@)lines:#(|*($'\0'|$'\1'|$'\2')*)}" )
    lines=( "${(@u)lines}" )   # identical lines: (u) keeps the newest occurrence
  fi
  local w=w$'\1'
  local -a recs=( b$'\1' "${(@)lines/#/$w}" )
  typeset -g REPLY=${(pj:\0:)recs}$'\0'
  return 0
}

# The one indivisible transition that opens the history menu: stop everything
# in flight, drop the current listing, then synthesize, plan, show and select
# position 1 in one go. Zero matches and a failed plan both leave the buffer
# alone and consume the key.
_zrush_open_history_menu() {  # ZLE widget context
  emulate -L zsh
  _zrush_disarm_timer
  _zrush_cancel_collection
  _zrush_teardown
  # This action leaves BUFFER/CURSOR alone, so bring the pre-redraw baseline up
  # to date: without it the redraw that follows this very keystroke can be the
  # first one of the line and would read as an external change, erasing the
  # menu the moment it appears.
  _zrush_last_buffer=$BUFFER
  _zrush_last_cursor=$CURSOR
  _zrush_history_payload
  # cli-protocol.md "history profile": the whole buffer is the query (the
  # sender strips NUL from --query) and trailing-space is always false.
  if _zrush_run_plan "$REPLY" history "${BUFFER//$'\0'/}" false && (( _zrush_plan_npos > 0 )); then
    _zrush_selected=1
    _zrush_apply_plan
    _zlog "history: menu opened P=$_zrush_plan_npos"
    return 0
  fi
  _zrush_teardown
  _zlog "history: no menu (no match or plan failure)"
  return 0
}

# ---------------------------------------------------------------- Debounce timer
_zrush_arm_timer() {  # ZLE widget context
  emulate -L zsh
  _zrush_disarm_timer
  local -i delay=$ZRUSH_CFG_DELAY_MS
  if (( delay <= 0 )); then
    _zrush_start_request
    return 0
  fi
  local -i cs=$(( delay / 10 ))
  (( cs < 1 )) && cs=1
  _zrush_pending_buffer=$BUFFER
  local tfd
  exec {tfd}< <( zselect -t $cs; print )
  _zrush_timer_fd=$tfd
  zle -F -w $tfd _zrush-timer-fire
  return 0
}

_zrush_timer_fire() {  # zle -F -w handler ($1=fd)
  emulate -L zsh
  local -i fd=$1
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  (( fd == _zrush_timer_fd )) && _zrush_timer_fd=-1
  # Discard if the buffer changed; pre-redraw has armed a newer timer.
  [[ $BUFFER == "$_zrush_pending_buffer" ]] || return 0
  (( KEYS_QUEUED_COUNT || PENDING )) && return 0   # defer under input pressure; re-arm on change
  _zrush_start_request
  return 0
}

# ---------------------------------------------------------------- ZLE hooks
_zrush_line_pre_redraw() {
  emulate -L zsh
  (( _zrush_enabled )) || return 0
  [[ -n $ZRUSH_INTERNAL ]] && return 0
  [[ $BUFFER == "$_zrush_last_buffer" ]] && (( CURSOR == _zrush_last_cursor )) && return 0
  _zrush_last_buffer=$BUFFER
  _zrush_last_cursor=$CURSOR
  # Reaching here means the change came from something other than a zrush
  # action (every zrush action tears the listing down itself, leaving kind
  # `none`), so a history menu goes away whole -- listing text included --
  # before the ordinary debounce flow resumes (behavior.md "履歴メニュー").
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
    _zrush_disarm_timer
    _zrush_cancel_collection
    _zrush_teardown
    return 0
  fi

  # Apply min-input to the current word; blank buffers were handled above.
  _zrush_widen "$LBUFFER"
  if (( ${#REPLY_WORD} < ZRUSH_CFG_MIN_INPUT )); then
    _zrush_disarm_timer
    _zrush_cancel_collection
    _zrush_teardown
    return 0
  fi

  _zrush_arm_timer
  return 0
}

_zrush_line_init() {
  emulate -L zsh
  _zrush_last_buffer=
  _zrush_last_cursor=-1
  # A new ZLE session can follow an exit that bypassed _zrush_line_finish
  # (send-break and similar). Tear down any leftover timer/collection from
  # the previous session before it can leak a result (and thus a stray
  # candidate list or a pending-Tab insertion) into this one.
  _zrush_disarm_timer
  _zrush_cancel_collection
  _zrush_teardown
  return 0
}

_zrush_line_finish() {
  emulate -L zsh
  (( _zrush_enabled )) || return 0
  _zrush_disarm_timer
  _zrush_cancel_collection
  _zrush_teardown
  _zlog "line-finish: cleared"
  return 0
}

# ---------------------------------------------------------------- Confirmation
# See docs/internal/specs/behavior.md "確定(挿入)" and cli-protocol.md "適用".
# The insertion text (IPREFIX+ipre+apre+hpre+word+hsuf+asuf+isuf, `-f`
# directory '/' synthesis, trailing-space) is already fully built by
# `zrush plan`; this only computes the replacement boundary and swaps it in.
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

  # After confirmation, clear selection/list. last_buffer stays stale so the next
  # pre-redraw treats the insertion as a buffer change and triggers recollection,
  # matching the common-prefix insertion path.
  _zrush_disarm_timer
  _zrush_cancel_collection
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
    # A still-armed debounce timer or an in-flight collection for a newer
    # keystroke could otherwise complete after dismiss and silently reopen
    # the list the user just closed.
    _zrush_disarm_timer
    _zrush_cancel_collection
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
  # During debounce or collection, record Tab, fast-forward collection, and apply on arrival.
  if (( _zrush_timer_fd >= 0 )); then
    _zlog "tab: pending (debounce fast-forward)"
    _zrush_tab_pending=1
    _zrush_disarm_timer
    _zrush_start_request
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
  _zrush_call_prev      # no list or pending request -> predecessor, such as native completion
  return 0
}

_zrush_dispatch() {  # $1=action $2=predecessor widget name embedded at binding time
  emulate -L zsh
  _zrush_dispatch_prev=${2:-}
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
  local prev=
  if [[ $cur == _zrush-dsp-* ]]; then
    prev=${_zrush_dsp_prev[$cur]:-}
  elif [[ -n $cur && $cur != undefined-key ]]; then
    prev=$cur
  fi
  local wname=${_zrush_bound[$seq]:-}
  if [[ -z $wname ]]; then
    wname=_zrush-dsp-$(( ++_zrush_dsp_n ))
  fi
  _zrush_dsp_prev[$wname]=$prev      # ledger for restoration and self-capture detection
  # Embed action and predecessor in the function body to tolerate widget wrappers; see above.
  functions[$wname]="_zrush_dispatch ${(q)action} ${(q)prev}"
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
      p=${_zrush_dsp_prev[$w]:-}
      builtin bindkey -M main -- "$seq" ${p:-undefined-key}
      _zlog "keybinds: restored ${(qqqq)seq} -> ${p:-undefined-key}"
    fi
  done
  typeset -gA _zrush_bound=( "${(@kv)_zrush_new_bound}" )
  unset _zrush_new_bound
  return 0
}

# ---------------------------------------------------------------- Exit cleanup
_zrush_zshexit() {
  emulate -L zsh
  # ZLE is inactive here; leave it untouched and reliably close only fds and zpty.
  (( _zrush_timer_fd >= 0 )) && { exec {_zrush_timer_fd}<&- 2>/dev/null; _zrush_timer_fd=-1 }
  if (( _zrush_rfd >= 0 )); then exec {_zrush_rfd}<&-; _zrush_rfd=-1; fi
  if (( _zrush_wfd >= 0 )); then exec {_zrush_wfd}>&-; _zrush_wfd=-1; fi
  if [[ -n $_zrush_pty ]]; then
    if [[ $_zrush_worker_pid == <-> ]] && (( _zrush_worker_pid > 1 )); then
      kill -INT -$_zrush_worker_pid 2>/dev/null || kill -INT $_zrush_worker_pid 2>/dev/null
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
    _zrush_warn "binary not found or not executable: $ZRUSH_BIN (set \$ZRUSH_BIN or run 'cargo build --release'); zrush disabled"
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
  # Always load config once at source time to guarantee protocol-version comparison.
  if ! _zrush_load_config initial; then
    _zrush_warn "initial 'zrush config' failed; zrush disabled"
    return 1
  fi

  # Detect compinit via _main_complete, including setups delegated to zsh-autocomplete.
  if (( ! $+functions[_main_complete] )); then
    _zrush_warn "compsys not initialized (run compinit before sourcing zrush.zsh); completions will be empty"
  fi

  # Register widgets; _zrush-capture-* are invoked only inside the fork.
  zle -N _zrush-on-data _zrush_on_data
  zle -N _zrush-timer-fire _zrush_timer_fire
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
  _zlog "init: enabled (bin=$ZRUSH_BIN proto=$ZRUSH_PROTOCOL_VERSION)"
  return 0
}

# Test seam: tests/zsh/vectors.zsh sources this file with ZRUSH_NO_INIT=1 to
# exercise _zrush_parse_plan and _zrush_encode_batch alone, without
# zle/compsys/binary side effects.
[[ -n $ZRUSH_NO_INIT ]] || _zrush_init
