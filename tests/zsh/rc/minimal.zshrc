# Host rc for headless regression tests, loaded through ZDOTDIR by the Rust pty harness (tests/driver/) and by tests/zsh/driver.zsh
# Required environment: ZRUSH_REAL_BIN (built zrush binary), ZRUSH_TEST_TMP (isolated tmp)
PS1='HP> '
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-test
source <($ZRUSH_REAL_BIN init zsh)

# Test-only dump widgets that write internal state to ZRUSH_LOG so drivers can
# assert on it precisely. Not production code.
_zrt_dump_buffer() { _zlog "TESTBUF=${(qqqq)BUFFER}" }
zle -N _zrt-dump-buffer _zrt_dump_buffer
bindkey '^Xb' _zrt-dump-buffer

# ^Xp: POSTDISPLAY, quoted (cli-protocol.md "適用": leading \n + listing text).
_zrt_dump_postdisplay() { _zlog "TESTPOST=${(qqqq)POSTDISPLAY}" }
zle -N _zrt-dump-postdisplay _zrt_dump_postdisplay
bindkey '^Xp' _zrt-dump-postdisplay

# ^Xh: this plugin's region_highlight entries only (_zrush_rh ledger), space-joined
# so a single ZRUSH_LOG line carries every entry (role spec + memo=zrush suffix).
_zrt_dump_rh() { _zlog "TESTRH=${(pj: | :)_zrush_rh}" }
zle -N _zrt-dump-rh _zrt_dump_rh
bindkey '^Xh' _zrt-dump-rh

# ^Xw: persistent-worker lifecycle state. This exposes only stable invariants
# needed by driver.zsh (lazy start, reuse, monotonic ids, and clean teardown).
_zrt_dump_worker() {
  _zlog "TESTWORKER=ready=$_zrush_worker_ready seq=$_zrush_request_seq failures=$_zrush_worker_failures disabled=$_zrush_disabled reason=$_zrush_disable_reason stale=$_zrush_stale_disabled warned=$_zrush_worker_warned buildwarned=$_zrush_build_warned following=$_zrush_build_following verifying=$_zrush_build_verifying stopping=$_zrush_worker_stopping tainted=$_zrush_worker_runtime_tainted rfd=$_zrush_worker_rfd wfd=$_zrush_worker_wfd control=$_zrush_worker_control_wfd ack=$_zrush_worker_ack_fd pending=$#_zrush_worker_pending runtime=${_zrush_worker_runtime_dir:-<none>}"
}
zle -N _zrt-dump-worker _zrt_dump_worker
bindkey '^Xw' _zrt-dump-worker

_zrt_teardown_worker() { _zrush_worker_shutdown }
zle -N _zrt-teardown-worker _zrt_teardown_worker
bindkey '^Xq' _zrt-teardown-worker

# ^Xf: record the exact stdio targets and emit one marker through stdout and
# stderr. The driver compares the signature across lifecycle transitions; the
# markers prove that both output streams still reach the host pty.
typeset -gi _zrt_stdio_seq=0
_zrt_probe_stdio() {
  emulate -L zsh
  local signature= dev= ino=
  local -a stat
  local -i fd
  for fd in 0 1 2; do
    stat=()
    if zstat -A stat +device /dev/fd/$fd 2>/dev/null; then
      dev=$stat[1]
      stat=()
      zstat -A stat +inode /dev/fd/$fd 2>/dev/null || stat=( unknown )
      ino=$stat[1]
      signature+="$fd:$dev:$ino;"
    else
      signature+="$fd:closed;"
    fi
  done
  _zlog "TESTSTDIO=seq=$(( ++_zrt_stdio_seq )) fds=$signature"
  print -r -- ZRUSH-STDOUT-SENTINEL
  print -ru2 -- ZRUSH-STDERR-SENTINEL
  zle -R
}
zle -N _zrt-probe-stdio _zrt_probe_stdio
bindkey '^Xf' _zrt-probe-stdio

# ^Xj: synthesize the timer/ack/drain descriptors and exercise their shared
# teardown paths without depending on timing or kernel backpressure.
_zrt_close_aux_fds() {
  emulate -L zsh
  local -i ack_fd drain_fd timer_fd closed=1
  exec {ack_fd}< <( print )
  exec {drain_fd}< <( print )
  exec {timer_fd}< <( print )
  _zrush_worker_ack_fd=$ack_fd
  _zrush_worker_drain_fd=$drain_fd
  _zrush_timer_fd=$timer_fd
  _zrush_worker_release_writer
  _zrush_worker_disarm_drain
  _zrush_disarm_timer
  [[ -e /dev/fd/$ack_fd || -e /dev/fd/$drain_fd || -e /dev/fd/$timer_fd ]] && closed=0
  _zlog "TESTAUX=closed=$closed ack=$_zrush_worker_ack_fd drain=$_zrush_worker_drain_fd timer=$_zrush_timer_fd"
}
zle -N _zrt-close-aux-fds _zrt_close_aux_fds
bindkey '^Xj' _zrt-close-aux-fds

# ^Xg: arm the production generated drain handler. The readiness event occurs
# only after this widget returns to the real ZLE loop; the generated handler
# invalidates itself, closes its fd, then reaches this temporary read seam.
typeset -g _zrt_generated_handler= _zrt_generated_generation=
_zrt_generated_callback_cleanup() {
  _zrush_worker_disarm_drain
  if (( $+functions[_zrt_generated_read_saved] )); then
    functions[_zrush_worker_read]=$functions[_zrt_generated_read_saved]
    unfunction _zrt_generated_read_saved
  fi
}
_zrt_generated_callback_probe() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify no_bg_nice
  _zrt_generated_callback_cleanup
  functions[_zrt_generated_read_saved]=$functions[_zrush_worker_read]
  _zrush_worker_read() {
    emulate -L zsh
    local handler=$_zrt_generated_handler generation=$_zrt_generated_generation
    functions[_zrush_worker_read]=$functions[_zrt_generated_read_saved]
    unfunction _zrt_generated_read_saved
    _zlog "TESTGENERATED=dispatched kind=drain generation=$generation current=${_zrush_worker_callback_generation[drain]:-0} drain=$_zrush_worker_drain_fd handler_live=${+functions[$handler]} widget_live=${+widgets[$handler]}"
    return 0
  }
  if _zrush_worker_arm_drain; then
    _zrt_generated_handler=$_zrush_worker_callback_handler[drain]
    _zrt_generated_generation=$_zrush_worker_callback_generation[drain]
    _zlog "TESTGENERATED=armed kind=drain generation=$_zrt_generated_generation fd=$_zrush_worker_drain_fd handler=$_zrt_generated_handler"
  else
    _zrt_generated_callback_cleanup
    _zlog "TESTGENERATED=arm-failed kind=drain"
  fi
}
zle -N _zrt-generated-callback-probe _zrt_generated_callback_probe
bindkey '^Xg' _zrt-generated-callback-probe
zle -N _zrt-generated-callback-cleanup _zrt_generated_callback_cleanup
bindkey '^XG' _zrt-generated-callback-cleanup

_zrt_cursor_left_three() { (( CURSOR >= 3 )) && (( CURSOR -= 3 )) }
zle -N _zrt-cursor-left-three _zrt_cursor_left_three
bindkey '^Xv' _zrt-cursor-left-three

print MARK-RC-DONE
