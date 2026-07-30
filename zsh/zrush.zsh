# zrush.zsh — ZLE integration for asynchronous completion
#
# Requirements: zsh 5.8+, source after compinit, after zsh-abbr, and before
# zsh-syntax-highlighting. $ZRUSH_BIN overrides ../target/release/zrush.
#
# See docs/internal/specs/behavior.md for observable behavior and architecture.
# See docs/internal/contracts/cli-protocol.md for the zsh/Rust boundary.
# See docs/internal/plans/001-prototype/notes-zpty.md for zpty constraints and measurements.
#
# Set ZRUSH_LOG=<file> to append timestamped debug traces; unset is a no-op.

# Capture the source directory; re-sourcing is allowed and reinitializes state.
typeset -g _zrush_source_dir=${${(%):-%N}:A:h}

# ---------------------------------------------------------------- Global state
typeset -g  ZRUSH_BIN=${ZRUSH_BIN:-$_zrush_source_dir/../target/release/zrush}
typeset -gi _zrush_enabled=0
typeset -gi _ZRUSH_EXPECTED_PROTO=3
typeset -g  _zrush_cfg_path= _zrush_cfg_mtime= _zrush_cfg_warn_shown=
typeset -gi _zrush_match_warned=0 _zrush_proto_warned=0

# Collection request state
typeset -g  _zrush_query= _zrush_fuzzy= _zrush_keep= _zrush_buf= _zrush_pty= _zrush_worker_pid=
typeset -gi _zrush_rfd=-1 _zrush_wfd=-1 _zrush_gen=0 _zrush_timer_fd=-1
typeset -g  _zrush_pending_buffer=
typeset -g  _zrush_last_buffer=
typeset -gi _zrush_last_cursor=-1

# Received results, retaining source records and insertion forms for selection and confirmation
typeset -ga _zrush_recs=() _zrush_krecs=() _zrush_words=() _zrush_match=() _zrush_disp=()
typeset -g  _zrush_payload=   # stdin for `zrush match`, paired with parsed records
typeset -ga _zrush_ranked=() _zrush_shown=()
typeset -gA _zrush_spans=()   # candidate index -> match-spans (CLI protocol v2)
typeset -g  _zrush_common_prefix=
typeset -gi _zrush_listing=0

# Rendering (POSTDISPLAY + region_highlight)
typeset -ga _zrush_rh=()      # ledger of entries added to region_highlight
typeset -g  _zrush_rh_sel=    # selected highlight entry, removed separately on input
typeset -g  _zrush_hl_memo=   # ' memo=zrush' on zsh 5.9+

# Selection and Tab state
typeset -gi _zrush_selected=0      # 0=unselected; >0=one-based, column-major display position
typeset -gi _zrush_tab_pending=0   # Tab was pressed before candidates arrived

# See docs/internal/specs/behavior.md "空語収集キャッシュ".
# Cache storage is separate from working arrays and survives across prompts.
typeset -gi _zrush_cc_valid=0
typeset -g  _zrush_cc_fp=          # fingerprint at save time
typeset -gi _zrush_cc_time=0       # save time (EPOCHSECONDS)
typeset -ga _zrush_cc_krecs=() _zrush_cc_words=() _zrush_cc_match=() _zrush_cc_disp=()
typeset -g  _zrush_cc_payload=
typeset -gi _ZRUSH_CC_TTL=300      # seconds; catches same-count replacement and is not configurable

# Per-position grid metadata for select-left/right strides and group bounds
typeset -ga _zrush_pos_rows=() _zrush_pos_gs=() _zrush_pos_ge=()
typeset -gi _zrush_render_retry=0

# Grid column limit, also used to estimate --max-lines as max-lines times this value
typeset -gi _ZRUSH_MAX_COLS=8

# Key bindings (dispatch widget -> predecessor/action)
typeset -gA _zrush_dsp_prev=() _zrush_dsp_action=() _zrush_bound=()
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
  # The protocol restricts output to static typeset assignments; evaluate in this controlled scope.
  eval "$out" 2>/dev/null || return 1
  [[ -n $ZRUSH_PROTOCOL_VERSION ]] || return 1
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

# Emit config warnings to stderr, one per line.
# Suppress an unchanged consecutive warning set; a clean result resets the dedupe state.
_zrush_show_cfg_warnings() {
  emulate -L zsh
  (( $#ZRUSH_CFG_WARNINGS )) || { _zrush_cfg_warn_shown=; return 0 }
  local joined=${(pj:\n:)ZRUSH_CFG_WARNINGS}
  [[ $joined == $_zrush_cfg_warn_shown ]] && return 0
  local w
  for w in "${(@)ZRUSH_CFG_WARNINGS}"; do
    print -ru2 -- "zrush: $w"
  done
  _zrush_cfg_warn_shown=$joined
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
# compadd hook installed in functions[compadd] only inside the fork.
# Encode each candidate and its metadata as \2-joined <tag>\1<value> fields.
# Batch NUL-terminated records once per compadd call because per-record writes caused
# one read per record and measurably degraded large candidate sets.
_zrush_compadd() {
  builtin setopt localoptions extendedglob norcexpandparam noshglob
  local -A apre hpre asuf hsuf ipre isuf dscrs _oad _mesg grpJ grpV
  local -a isfile _opts __ expl
  zparseopts -a _opts P:=apre p:=hpre S:=asuf s:=hsuf i:=ipre I:=isuf \
             d:=dscrs X+:=expl O:=_oad A:=_oad D:=_oad f=isfile x:=_mesg \
             r: R: W: F: M+: E: q e Q n U C \
             J:=grpJ V:=grpV a=__ l=__ k=__ o::=__ 1=__ 2=__
  # -O/-A/-D are internal matching/array calls; delegate without counting candidates.
  if (( $#_oad != 0 )); then
    builtin compadd "$@"
    return
  fi
  local -a __hits __dscr
  (( $#dscrs == 1 )) && __dscr=( "${(@P)${(v)dscrs}}" )
  builtin compadd -A __hits -D __dscr "$@"
  local -i ret=$?
  (( $#__hits == 0 )) && return ret

  # Drop framing bytes from value fields before encoding; same treatment as NUL.
  __hits=( "${(@)__hits//(#s)*($'\0'|$'\1'|$'\2')*(#e)/}" )
  __dscr=( "${(@)__dscr//(#s)*($'\0'|$'\1'|$'\2')*(#e)/}" )
  local _bad_value="*("$'\0'"|"$'\1'"|"$'\2'")*"
  local -a __decoded=( "${(@Q)__hits}" )
  local -i _bad_i
  while _bad_i=${__decoded[(I)${~_bad_value}]} && (( _bad_i )); do
    __hits[_bad_i]=
    __dscr[_bad_i]=
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
    "${(v)ipre}" "${(v)isuf}" "$IPREFIX" "$ISUFFIX" "$PREFIX" "$SUFFIX"
    "$_rd" "${expl[2]:-}" "${(v)grpJ}" "${(v)grpV}" "${(v)_mesg}"
  )
  _vals=( "${(@)_vals//(#s)*($'\0'|$'\1'|$'\2')*(#e)/}" )

  local _out=
  local -a _rec
  local -i j
  local _d
  for (( j = 1; j <= $#__hits; ++j )); do
    _rec=( "w"$'\1'"$__hits[j]" )
    _d=${__dscr[j]:-}
    [[ -n $_d ]]           && _rec+=( "d"$'\1'"$_d" )
    [[ -n $_vals[1] ]]     && _rec+=( "P"$'\1'"$_vals[1]" )
    [[ -n $_vals[2] ]]     && _rec+=( "p"$'\1'"$_vals[2]" )
    [[ -n $_vals[3] ]]     && _rec+=( "S"$'\1'"$_vals[3]" )
    [[ -n $_vals[4] ]]     && _rec+=( "s"$'\1'"$_vals[4]" )
    [[ -n $_vals[5] ]]     && _rec+=( "i"$'\1'"$_vals[5]" )
    [[ -n $_vals[6] ]]     && _rec+=( "I"$'\1'"$_vals[6]" )
    [[ -n $_vals[7] ]]     && _rec+=( "ip"$'\1'"$_vals[7]" )
    [[ -n $_vals[8] ]]     && _rec+=( "is"$'\1'"$_vals[8]" )
    [[ -n $_vals[9] ]]     && _rec+=( "pr"$'\1'"$_vals[9]" )
    [[ -n $_vals[10] ]]    && _rec+=( "su"$'\1'"$_vals[10]" )
    (( ${_opts[(I)-U]} ))  && _rec+=( "U"$'\1'"1" )
    if (( $#isfile )); then
      _rec+=( "f"$'\1'"1" )
      [[ -n $_vals[11] ]] && _rec+=( "rd"$'\1'"$_vals[11]" )
    fi
    [[ -n $_vals[12] ]]    && _rec+=( "X"$'\1'"$_vals[12]" )
    [[ -n $_vals[13] ]]    && _rec+=( "J"$'\1'"$_vals[13]" )
    [[ -n $_vals[14] ]]    && _rec+=( "V"$'\1'"$_vals[14]" )
    [[ -n $_vals[15] ]]    && _rec+=( "x"$'\1'"$_vals[15]" )
    _out+="${(pj:\2:)_rec}"$'\0'
  done
  print -rn -u $_zrush_wfd -- "$_out" 2>/dev/null
  # Also run the original compadd to keep compsys internal state consistent.
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

_zrush_clear_display() {  # Call only from a ZLE widget context.
  _zrush_selected=0
  (( _zrush_listing )) || return 0
  POSTDISPLAY=
  _zrush_rh_clear
  _zrush_listing=0
  _zrush_recs=() _zrush_krecs=() _zrush_words=() _zrush_match=() _zrush_disp=()
  _zrush_payload=
  _zrush_ranked=() _zrush_shown=() _zrush_spans=()
  _zrush_pos_rows=() _zrush_pos_gs=() _zrush_pos_ge=()
  _zrush_common_prefix=
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
  _zrush_cc_valid=0
  _zrush_cc_fp=
  _zrush_cc_krecs=() _zrush_cc_words=() _zrush_cc_match=() _zrush_cc_disp=()
  _zrush_cc_payload=
  return 0
}

_zrush_cc_check() {  # 0=usable hit; on a miss, log the reason and return nonzero
  emulate -L zsh
  if (( ! _zrush_cc_valid )); then
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
  _zlog "cache: hit (${#_zrush_cc_words} candidates)"
  return 0
}

_zrush_cc_save() {  # Copy parsed working arrays and payload into the cache.
  emulate -L zsh
  _zrush_cc_fingerprint
  _zrush_cc_fp=$REPLY
  _zrush_cc_time=$EPOCHSECONDS
  _zrush_cc_krecs=( "${(@)_zrush_krecs}" )
  _zrush_cc_words=( "${(@)_zrush_words}" )
  _zrush_cc_match=( "${(@)_zrush_match}" )
  _zrush_cc_disp=( "${(@)_zrush_disp}" )
  _zrush_cc_payload=$_zrush_payload
  _zrush_cc_valid=1
  _zlog "cache: saved ${#_zrush_cc_words} candidates"
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
  _zrush_keep=$REPLY_KEEP
  _zlog "request: widened=${(qqqq)_zrush_query} fuzzy=${(qqqq)_zrush_fuzzy}"

  # See behavior.md "空語収集キャッシュ". zle -F -w callers require explicit redraw.
  if [[ -z $_zrush_query ]] && _zrush_cc_check; then
    _zrush_recs=()
    _zrush_krecs=( "${(@)_zrush_cc_krecs}" )
    _zrush_words=( "${(@)_zrush_cc_words}" )
    _zrush_match=( "${(@)_zrush_cc_match}" )
    _zrush_disp=( "${(@)_zrush_cc_disp}" )
    _zrush_payload=$_zrush_cc_payload
    _zrush_apply_results
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

# ---------------------------------------------------------------- Receive, match, and render
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

_zrush_finalize() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify
  local payload=$_zrush_buf
  _zrush_buf=
  _zrush_parse_records "$payload"
  # Cache successful empty-word command-position results across prompts.
  if [[ -z $_zrush_query ]] && (( $#_zrush_words > 0 )); then
    _zrush_cc_save
  fi
  _zrush_apply_results
  return 0
}

# Collection payload -> local arrays (krecs/words/match/disp) and `_zrush_payload`
# for `zrush match`.
_zrush_parse_records() {  # $1=NUL-delimited collection payload ending in NUL
  emulate -L zsh
  setopt localoptions no_monitor no_notify
  local payload=$1
  _zrush_recs=() _zrush_krecs=() _zrush_words=() _zrush_match=() _zrush_disp=()
  _zrush_payload=

  if [[ -n $payload ]]; then
    if [[ $payload == *$'\0' ]]; then
      _zrush_recs=( "${(@0)${payload%$'\0'}}" )
    else
      _zlog "finalize: unterminated payload (${#payload} bytes); dropping"
      _zrush_recs=()
    fi
  fi
  _zlog "finalize: ${#_zrush_recs} records"

  # Parse insertion (w) and display (d) forms; match-text is the (Q)-decoded form.
  # Per-record zsh loops block for seconds on tens of thousands of candidates, so the
  # common no-d-field case uses bulk array operations (30k: measured ~1.6s -> ~35ms).
  local -i i n=0
  local -a words=() disps=() mts=()
  local NUL=$'\0'
  if [[ ${(pj::)_zrush_recs} != *$'\2'd$'\1'* ]]; then
    words=( "${(@)${(@)_zrush_recs#w$'\1'}%%$'\2'*}" )
    mts=( "${(@Q)words}" )
    if [[ -z ${(M)words:#(*$'\1'*|)} && -z ${(M)mts:#*$'\0'*} ]]; then
      # Fast path: no malformed or NUL-containing candidates, so records map 1:1.
      n=$#words
      _zrush_krecs=( "${(@)_zrush_recs}" )
      _zrush_words=( "${(@)words}" )
      _zrush_match=( "${(@)mts}" )
      _zrush_disp=( "${(@)words:/*/}" )         # all elements empty (no d field)
      if (( n > 0 )); then
        local -a _idxs=( {1..$n} )
        local -a _mts2=( "${(@)mts/%/$NUL}" )   # append an empty display field to each element
        local -a _zip=( "${(@)_idxs:^_mts2}" )
        _zrush_payload=${(pj:\0:)_zip}$'\0'
      fi
    else
      n=-1   # use the general path
    fi
  else
    n=-1
  fi

  if (( n < 0 )); then
    # General path for d fields or malformed records, normally a small set.
    local r w d
    local -a recs1=()
    words=() disps=()
    for r in "${(@)_zrush_recs}"; do
      [[ $r == w$'\1'* ]] || continue
      w=${${r#w$'\1'}%%$'\2'*}
      [[ -n $w ]] || continue
      if [[ $r == *$'\2'd$'\1'* ]]; then
        d=${${r#*$'\2'd$'\1'}%%$'\2'*}
      else
        d=
      fi
      words+=( "$w" )
      disps+=( "$d" )
      recs1+=( "$r" )
    done
    mts=( "${(@Q)words}" )
    # The sender drops NUL-containing candidates; indices use the filtered local arrays.
    n=0
    _zrush_krecs=() _zrush_words=() _zrush_match=() _zrush_disp=()
    for (( i = 1; i <= $#words; ++i )); do
      [[ $mts[i] == *$'\0'* || $disps[i] == *$'\0'* ]] && continue
      _zrush_krecs+=( "$recs1[i]" )
      _zrush_words+=( "$words[i]" )
      _zrush_match+=( "$mts[i]" )
      _zrush_disp+=( "$disps[i]" )
      (( ++n ))
      _zrush_payload+="$n"$'\0'"$mts[i]"$'\0'"$disps[i]"$'\0'
    done
  fi
  return 0
}

# Match, render, then apply a pending Tab. Inputs are the local arrays and
# `_zrush_payload`; called after parsing and on cache hits.
_zrush_apply_results() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify
  _zrush_ranked=() _zrush_spans=()
  _zrush_common_prefix=

  local -i n=$#_zrush_words
  if (( n == 0 )); then
    _zrush_render   # zero candidates clears the list
    return 0
  fi

  # `zrush match` is pure over snapshot arguments; suppress stderr to protect ZLE.
  local out
  # Fetch at most the grid capacity: max-lines rows times the maximum column count.
  out=$(print -rn -- "$_zrush_payload" | \
        "$ZRUSH_BIN" match --query "$_zrush_fuzzy" --mode "$ZRUSH_CFG_MODE" \
                           --smart-case "$ZRUSH_CFG_SMART_CASE" \
                           --max-lines $(( ${ZRUSH_CFG_MAX_LINES:-10} * _ZRUSH_MAX_COLS )) 2>/dev/null)
  local -i rc=$?
  if (( rc != 0 )); then
    if (( ! _zrush_match_warned )); then
      _zrush_warn "zrush match failed (exit $rc); suppressing further warnings this session"
      _zrush_match_warned=1
    fi
    _zlog "finalize: zrush match exit $rc; discarding"
    _zrush_recs=() _zrush_words=() _zrush_match=() _zrush_disp=()
    _zrush_render
    return 0
  fi

  # See cli-protocol.md "stdout(結果)" for common-prefix and index/span pairs.
  local -a fields=( "${(@0)${out%$'\0'}}" )
  _zrush_common_prefix=${fields[1]:-}
  _zrush_ranked=()
  local -i fi
  for (( fi = 2; fi + 1 <= $#fields; fi += 2 )); do
    _zrush_ranked+=( "${fields[fi]}" )
    [[ -n ${fields[fi+1]} ]] && _zrush_spans[${fields[fi]}]=${fields[fi+1]}
  done
  _zlog "finalize: match ok, ${#_zrush_ranked} ranked, common-prefix=${(qqqq)_zrush_common_prefix}"
  _zrush_render
  # Apply a Tab recorded before arrival; zero candidates do nothing without sync fallback.
  if (( _zrush_tab_pending )); then
    _zrush_tab_pending=0
    (( $#_zrush_shown > 0 )) && _zrush_tab_with_results
  fi
  return 0
}

_zrush_render() {  # Call only from a ZLE widget context.
  emulate -L zsh
  # In zsh without TYPESET_SILENT, redeclaring a populated local without assignment
  # writes "name=value" to stdout. Keep declarations outside loops and enable
  # typesetsilent defensively because any widget output corrupts the ZLE display.
  setopt localoptions typesetsilent
  local -i maxl=${ZRUSH_CFG_MAX_LINES:-10}
  (( LINES > 1 && maxl > LINES - 1 )) && maxl=$(( LINES - 1 ))
  (( maxl < 1 )) && maxl=1
  local -i width=$(( COLUMNS - 1 ))
  (( width < 1 )) && width=1

  # Highlight specs from the configuration snapshot; empty means no decoration.
  local hl_sel=${ZRUSH_CFG_HL_SELECTED-standout}
  local hl_mat=${ZRUSH_CFG_HL_MATCH-underline}
  local hl_head=${ZRUSH_CFG_HL_HEADING-bold}

  # Build displayable items up to grid capacity. Prefer J for group identity and X
  # for headings. Apply spans only when displaying match-text directly.
  local -a items=() texts=() gkey=() ghd=() spanstr=()
  local idx text rec x j
  for idx in "${(@)_zrush_ranked}"; do
    [[ $idx == <-> ]] || continue
    if [[ -n ${_zrush_disp[idx]:-} ]]; then
      text=${_zrush_disp[idx]}
      spanstr+=( '' )
    else
      text=${_zrush_match[idx]}
      spanstr+=( "${_zrush_spans[$idx]:-}" )
    fi
    text=${text//$'\n'/ }
    rec=${_zrush_krecs[idx]:-}
    x= j=
    [[ $rec == *$'\2'X$'\1'* ]] && x=${${rec#*$'\2'X$'\1'}%%$'\2'*}
    [[ $rec == *$'\2'J$'\1'* ]] && j=${${rec#*$'\2'J$'\1'}%%$'\2'*}
    [[ $j == -default- ]] && j=
    items+=( $idx )
    texts+=( "$text" )
    gkey+=( "${j:-$x}" )
    ghd+=( "${x:-$j}" )
    (( $#items >= maxl * _ZRUSH_MAX_COLS )) && break
  done
  if (( $#items == 0 )); then
    _zrush_clear_display
    return 0
  fi

  # Split groups by first appearance in rank order, retaining rank order within each group.
  local -A gord=()
  local -a gheads=() gmembers=()
  local -i ng=0 i
  local key
  for (( i = 1; i <= $#items; ++i )); do
    key="k:${gkey[i]}"
    if [[ -z ${gord[$key]:-} ]]; then
      gord[$key]=$(( ++ng ))
      gheads[ng]=${gkey[i]:+${ghd[i]}}   # no key means no group and no heading
    fi
    gmembers[${gord[$key]}]+=" $i"
  done

  # Pack a column-major grid per group within maxl. Width is uniform per group and
  # measured across all fetched members, conservatively preventing line overflow.
  local -a lines=() hl=()     # hl: "line-number line-offset character-count spec"
  _zrush_shown=()
  local -a pos_rows=() pos_gs=() pos_ge=() gi=()
  local -i gut=2 budget=maxl ord p r c w
  local -i sel=$_zrush_selected
  local -i gmaxw cols grows gcount gstart gend ii cello ms me kept
  local head cell line sp sel_hl=
  for (( ord = 1; ord <= ng; ++ord )); do
    (( budget < 1 )) && break
    gi=( ${=gmembers[ord]} )
    head=${gheads[ord]:-}
    if [[ -n $head ]]; then
      if (( budget >= 2 )); then
        if (( ${(m)#head} > width )); then
          head=${(mr:$width:)head}
          # (mr) rounds up at a wide-character boundary; drop one character if it overshoots.
          (( ${(m)#head} > width )) && head=${(mr:$width:)head[1,-2]}
        fi
        lines+=( "$head" )
        [[ -n $hl_head ]] && hl+=( "$#lines 0 ${#head} $hl_head" )
        (( budget -= 1 ))
      elif (( $#lines )); then
        break   # stop when a later group's heading does not fit the row budget
      fi        # for the first group, omit the heading and still show candidates
    fi
    gmaxw=1
    for i in $gi; do
      w=${(m)#texts[i]}
      (( w > gmaxw )) && gmaxw=w
    done
    (( gmaxw > width )) && gmaxw=width
    cols=$(( (width + gut) / (gmaxw + gut) ))
    (( cols < 1 )) && cols=1
    (( cols > _ZRUSH_MAX_COLS )) && cols=_ZRUSH_MAX_COLS
    grows=$(( ($#gi + cols - 1) / cols ))
    (( grows > budget )) && grows=budget
    gcount=$(( cols * grows ))
    (( gcount > $#gi )) && gcount=$#gi
    cols=$(( (gcount + grows - 1) / grows ))   # compact columns left over after rounding
    gstart=$(( $#_zrush_shown + 1 ))
    gend=$(( gstart + gcount - 1 ))
    for (( r = 1; r <= grows; ++r )); do
      line=
      for (( c = 1; c <= cols; ++c )); do
        p=$(( (c - 1) * grows + r ))
        (( p > gcount )) && break
        (( c > 1 )) && line+='  '
        ii=$gi[p]
        cell=${(mr:$gmaxw:)texts[ii]}
        # Wide-boundary rounding may exceed cell width; drop one character and repad.
        (( ${(m)#cell} > gmaxw )) && cell=${(mr:$gmaxw:)cell[1,-2]}
        cello=${#line}
        if (( gstart + p - 1 == sel )); then
          # Track the selected entry under -sel so input can remove it alone.
          [[ -n $hl_sel ]] && sel_hl="$(( $#lines + 1 )) $cello ${#cell}"
        elif [[ -n $hl_mat && -n ${spanstr[ii]} ]]; then
          # Clip character-offset match spans to the truncated text.
          # Do not apply them to the selected cell; selection decoration wins.
          kept=${#texts[ii]}
          (( ${(m)#texts[ii]} > gmaxw )) && kept=${#cell}
          for sp in ${(s:,:)spanstr[ii]}; do
            [[ $sp == <->-<-> ]] || continue
            ms=${sp%%-*}
            me=${sp#*-}
            (( me > kept )) && me=kept
            (( ms >= me )) && continue
            hl+=( "$(( $#lines + 1 )) $(( cello + ms )) $(( me - ms )) $hl_mat" )
          done
        fi
        line+=$cell
      done
      lines+=( "$line" )
    done
    for (( p = 1; p <= gcount; ++p )); do
      _zrush_shown+=( ${items[$gi[p]]} )
      pos_rows+=( $grows )
      pos_gs+=( $gstart )
      pos_ge+=( $gend )
    done
    (( budget -= grows ))
  done

  # Defensive no-list fallback; normally the first group yields at least one candidate row.
  if (( $#lines == 0 )); then
    _zrush_clear_display
    return 0
  fi

  # If row-budget clipping hides the selection, clamp and rebuild once. Normal selection
  # operations already clamp against the previous display.
  if (( _zrush_selected > $#_zrush_shown )); then
    _zrush_selected=$#_zrush_shown
    if (( ! _zrush_render_retry )); then
      _zrush_render_retry=1
      _zrush_render
      _zrush_render_retry=0
      return 0
    fi
  fi
  _zrush_pos_rows=( "${(@)pos_rows}" )
  _zrush_pos_gs=( "${(@)pos_gs}" )
  _zrush_pos_ge=( "${(@)pos_ge}" )

  # Replace POSTDISPLAY atomically to avoid a visible blank between clear and redraw.
  POSTDISPLAY=$'\n'${(pj:\n:)lines}
  # Apply selection and heading decoration through region_highlight without changing layout.
  _zrush_rh_clear
  local -a lstart=()
  local -i off=$(( $#BUFFER + 1 ))   # account for the leading newline
  for (( r = 1; r <= $#lines; ++r )); do
    lstart[r]=$off
    (( off += ${#lines[r]} + 1 ))
  done
  local e
  local -a f
  for e in "${(@)hl}"; do
    f=( ${=e} )
    # The spec starts at word four so user-configured specs may contain spaces.
    _zrush_rh_add $(( lstart[$f[1]] + f[2] )) $(( lstart[$f[1]] + f[2] + f[3] )) "${(j: :)f[4,-1]}"
  done
  if [[ -n $sel_hl ]]; then
    f=( ${=sel_hl} )
    _zrush_rh_add $(( lstart[$f[1]] + f[2] )) $(( lstart[$f[1]] + f[2] + f[3] )) "$hl_sel" -sel
  fi
  _zrush_listing=1
  _zlog "render: $#lines lines shown=$#_zrush_shown selected=$_zrush_selected"
  return 0
}

# ---------------------------------------------------------------- Debounce timer
_zrush_arm_timer() {  # ZLE widget context
  emulate -L zsh
  _zrush_disarm_timer
  local -i delay=${ZRUSH_CFG_DELAY_MS:-30}
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
    _zrush_clear_display
    return 0
  fi

  # Apply min-input to the current word; blank buffers were handled above.
  _zrush_widen "$LBUFFER"
  if (( ${#REPLY_WORD} < ${ZRUSH_CFG_MIN_INPUT:-0} )); then
    _zrush_disarm_timer
    _zrush_cancel_collection
    _zrush_clear_display
    return 0
  fi

  _zrush_arm_timer
  return 0
}

_zrush_line_init() {
  emulate -L zsh
  _zrush_last_buffer=
  _zrush_last_cursor=-1
  # Unlike zle -M, POSTDISPLAY requires explicit cleanup. Remove stale output left by
  # exits such as send-break that bypass line-finish.
  if (( _zrush_listing )); then
    POSTDISPLAY=
    _zrush_rh_clear
    _zrush_listing=0
  fi
  _zrush_selected=0
  _zrush_tab_pending=0
  return 0
}

_zrush_line_finish() {
  emulate -L zsh
  (( _zrush_enabled )) || return 0
  _zrush_disarm_timer
  _zrush_cancel_collection
  _zrush_clear_display
  _zrush_tab_pending=0
  _zlog "line-finish: cleared"
  return 0
}

# ---------------------------------------------------------------- Reconstruct insertion text
# See docs/internal/specs/behavior.md "確定(挿入)".
# <IPREFIX><ipre(-i)><apre(-P)><hpre(-p)><word><hsuf(-s)><asuf(-S)><isuf(-I)>
# Add a synthetic '/' when an -f candidate resolves to a real directory.
_zrush_reconstruct() {  # $1=record -> REPLY=insertion text
                        #   _zrush_rec_prefix=captured prefix (IPREFIX+hpre)
                        #   _zrush_rec_nospace=1 suppresses trailing-space
  emulate -L zsh
  local rec=$1 f t
  local -A g=()
  for f in "${(@ps:\2:)rec}"; do
    t=${f%%$'\1'*}
    g[$t]=${f#*$'\1'}
  done
  local composed=${g[ip]}${g[i]}${g[P]}${g[p]}${g[w]}${g[s]}${g[S]}${g[I]}
  local -i nospace=0
  [[ -n ${g[S]}${g[s]}${g[I]} ]] && nospace=1     # candidate has a -S-family suffix
  if [[ ${g[f]} == 1 && $composed != */ ]] && [[ -d ${g[rd]}${(Q)g[w]} ]]; then
    composed+=/
    nospace=1                                      # synthetic directory slash
  fi
  typeset -g  REPLY=$composed
  typeset -g  _zrush_rec_prefix=${g[ip]}${g[p]}
  typeset -gi _zrush_rec_nospace=$nospace
  return 0
}

# ---------------------------------------------------------------- Confirmation
# See docs/internal/specs/behavior.md "確定(挿入)".
_zrush_confirm_index() {  # $1=index into local krecs/words/... arrays
  emulate -L zsh
  local -i idx=$1
  local rec=${_zrush_krecs[idx]:-}
  [[ -n $rec ]] || return 1
  _zrush_reconstruct "$rec"
  local composed=$REPLY prefix=$_zrush_rec_prefix
  local -i nospace=$_zrush_rec_nospace

  # See docs/internal/specs/behavior.md "確定(挿入)" for replacement boundaries.
  # `composed` retains a matching prefix byte-for-byte, which also preserves '~'.
  _zrush_widen "$LBUFFER"
  local word=$REPLY_WORD keep=$REPLY_KEEP
  local pre=${LBUFFER[1,$#LBUFFER-$#word]}
  if [[ $prefix == "$keep" ]]; then
    _zlog "confirm: tail-replace keep=${(qqqq)keep} insert=${(qqqq)composed}"
  else
    _zlog "confirm: whole-word-replace (prefix=${(qqqq)prefix} != keep=${(qqqq)keep}) insert=${(qqqq)composed}"
  fi
  local newl=$pre$composed
  if [[ ${ZRUSH_CFG_TRAILING_SPACE:-true} == true ]] && (( ! nospace )); then
    newl+=' '
  fi
  LBUFFER=$newl        # leave text after the cursor (RBUFFER) unchanged

  # After confirmation, clear selection/list and align last_buffer to avoid recollection.
  _zrush_disarm_timer
  _zrush_cancel_collection
  _zrush_clear_display
  _zrush_tab_pending=0
  _zrush_last_buffer=$BUFFER
  _zrush_last_cursor=$CURSOR
  return 0
}

# ---------------------------------------------------------------- Selection
_zrush_select_start() {
  _zrush_selected=1
  _zrush_render
  _zlog "select: start"
}

_zrush_select_move() {  # $1=+1|-1
  emulate -L zsh
  local -i new=$(( _zrush_selected + $1 ))
  if (( new < 1 )); then
    # select-prev on the first candidate returns to normal state, preserving access to history.
    _zrush_selected=0
    _zrush_render
    _zlog "select: released-at-top"
    return 0
  fi
  (( new > $#_zrush_shown )) && new=$#_zrush_shown
  _zrush_selected=$new
  _zrush_render
  _zlog "select: pos=$_zrush_selected"
  return 0
}

_zrush_select_hmove() {  # $1=+1|-1 (column stride = grid rows; clamp within group)
  emulate -L zsh
  local -i p=$_zrush_selected
  local -i rows=${_zrush_pos_rows[p]:-1}
  local -i lo=${_zrush_pos_gs[p]:-1}
  local -i hi=${_zrush_pos_ge[p]:-$#_zrush_shown}
  local -i new=$(( p + $1 * rows ))
  (( new < lo )) && new=lo
  (( new > hi )) && new=hi
  (( new == p )) && return 0
  _zrush_selected=$new
  _zrush_render
  _zlog "select: pos=$_zrush_selected"
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
    _zrush_select_move 1
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
  if (( _zrush_listing && $#_zrush_shown > 0 )); then
    _zrush_select_start; return 0         # 3. visible list -> start selection
  fi
  _zrush_call_prev                        # 4. otherwise -> predecessor
  return 0
}

_zrush_action_prev() {
  if (( _zrush_selected > 0 )); then
    _zrush_select_move -1
    return 0
  fi
  _zrush_call_prev
  return 0
}

# select-left/right jump columns only while selected; otherwise fall back to the
# predecessor (cursor movement for the default arrow bindings).
_zrush_action_left() {
  if (( _zrush_selected > 0 )); then
    _zrush_select_hmove -1
    return 0
  fi
  _zrush_call_prev
  return 0
}

_zrush_action_right() {
  if (( _zrush_selected > 0 )); then
    _zrush_select_hmove 1
    return 0
  fi
  _zrush_call_prev
  return 0
}

_zrush_action_confirm() {
  if (( _zrush_selected > 0 )); then
    _zrush_confirm_index ${_zrush_shown[_zrush_selected]}
    return 0
  fi
  _zrush_call_prev
  return 0
}

_zrush_action_dismiss() {
  if (( _zrush_selected > 0 || _zrush_listing )); then
    _zlog "dismiss: closing list"
    _zrush_clear_display     # leave the buffer unchanged
    _zrush_tab_pending=0
    return 0
  fi
  _zrush_call_prev
  return 0
}

# Tab follows [insert].tab rather than acting as an independent action.
_zrush_tab_with_results() {  # Tab behavior when results are available
  emulate -L zsh
  case ${ZRUSH_CFG_TAB:-menu} in
    menu)
      _zrush_select_start
      ;;
    insert)
      (( $#_zrush_shown > 0 )) && _zrush_confirm_index ${_zrush_shown[1]}
      ;;
    common-prefix)
      # See cli-protocol.md "stdout(結果)" and behavior.md "Tab".
      local cp=$_zrush_common_prefix q=$_zrush_fuzzy
      if [[ -n $cp && $cp != "$q" && $cp == "$q"* ]]; then
        _zrush_widen "$LBUFFER"
        local word=$REPLY_WORD keep=$REPLY_KEEP
        local pre=${LBUFFER[1,$#LBUFFER-$#word]}
        LBUFFER=$pre$keep${(q)cp}
        _zlog "tab: common-prefix inserted ${(qqqq)cp}"
        # Partial insertion is not confirmation; leave last_buffer stale to trigger recollection.
      else
        _zlog "tab: common-prefix fallback -> insert top (cp=${(qqqq)cp} q=${(qqqq)q})"
        (( $#_zrush_shown > 0 )) && _zrush_confirm_index ${_zrush_shown[1]}
      fi
      ;;
  esac
  return 0
}

_zrush_action_tab() {
  emulate -L zsh
  if (( _zrush_selected > 0 )); then
    _zrush_confirm_index ${_zrush_shown[_zrush_selected]}   # Tab confirms the selection
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
  if (( _zrush_listing && $#_zrush_shown > 0 )); then
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
  _zrush_dsp_action[$wname]=$action
  # Embed action and predecessor in the function body to tolerate widget wrappers; see above.
  functions[$wname]="_zrush_dispatch ${(q)action} ${(q)prev}"
  zle -N $wname
  builtin bindkey -M main -- "$seq" $wname
  _zrush_new_bound[$seq]=$wname
  return 0
}

_zrush_apply_keybinds() {
  emulate -L zsh
  local -a kb=( "${(@)ZRUSH_CFG_KEYBINDS}" )
  local -a kb_default=(
    select-next  key:down  select-next  'seq:^N'
    select-prev  key:up    select-prev  'seq:^P'
    select-left  key:left  select-left  'seq:^B'
    select-right key:right select-right 'seq:^F'
    confirm 'seq:^M' dismiss 'seq:^G'
  )
  if (( $#kb % 2 != 0 )); then
    # The protocol requires an odd-length array to fall back wholesale and warn.
    _zrush_warn "keybinds: malformed ZRUSH_CFG_KEYBINDS (odd length $#kb); using default keybinds"
    kb=( "${(@)kb_default}" )
  elif (( ! ${+ZRUSH_CFG_KEYBINDS} )); then
    kb=( "${(@)kb_default}" )
  fi
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

_zrush_init
