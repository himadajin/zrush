# Host rc for headless regression tests, loaded by tests/zsh/driver.zsh through ZDOTDIR
# Required environment: ZRUSH_REPO (repository root), ZRUSH_TEST_TMP (isolated tmp)
PS1='HP> '
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-test
source $ZRUSH_REPO/zsh/zrush.zsh

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
  _zlog "TESTWORKER=pid=$_zrush_worker_pid ready=$_zrush_worker_ready seq=$_zrush_request_seq failures=$_zrush_worker_failures disabled=$_zrush_disabled warned=$_zrush_worker_warned rfd=$_zrush_worker_rfd wfd=$_zrush_worker_wfd ack=$_zrush_worker_ack_fd pending=$#_zrush_worker_pending"
}
zle -N _zrt-dump-worker _zrt_dump_worker
bindkey '^Xw' _zrt-dump-worker

_zrt_teardown_worker() { _zrush_worker_transport_teardown test }
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

_zrt_cursor_left_three() { (( CURSOR >= 3 )) && (( CURSOR -= 3 )) }
zle -N _zrt-cursor-left-three _zrt_cursor_left_three
bindkey '^Xv' _zrt-cursor-left-three

print MARK-RC-DONE
