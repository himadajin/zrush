#!/bin/zsh -f
# Non-pty unit tests for the zsh-side worker transport. The write path: the
# outbound frame queue, the short-lived writer child that _zrush_worker_flush
# forks, and the ack/EOF notification fd that _zrush_worker_consume_ack reads.
# The read path: how _zrush_worker_read walks the receive buffer, in the
# synchronous mode the history menu drives it in.
#
# Usage:
#   zsh -f tests/zsh/transport.zsh
#     No arguments, no pty, no terminal. The zrush binary is NOT needed and no
#     worker process is started: this runner only sources zsh/zrush.zsh with
#     ZRUSH_NO_INIT=1 (the test seam at the end of that file) and drives the
#     transport functions directly against a FIFO it owns, standing in for the
#     worker's request FIFO.
#     $HOME and $XDG_CONFIG_HOME are redirected to a fresh mktemp directory,
#     so the real ~/.zshrc, shell history and ~/.config/zrush are untouched.
#
# Scope: vectors.zsh covers the capture encoder and the plan decoder; this file
# is the home for non-pty unit tests of the zsh-side worker transport instead.
# The behavior under test is specified in docs/internal/specs/behavior.md,
# sections "worker ライフサイクル" and "履歴メニュー".
#
# Test seams used here, none of which touch zsh/zrush.zsh:
#   - _zrush_warn is replaced by a recorder, so warnings are asserted instead of
#     printed into the runner's output.
#   - _zrush_worker_deadline_expired is replaced, for one case, by an oracle
#     that reports expiry from the state of the exchange rather than from the
#     clock, so the moment a deadline trips is fixed instead of measured.
#   - The ZLE callback never runs headless, so the shared consume path
#     (_zrush_worker_consume_ack) is called directly, exactly as the synchronous
#     history loop calls it.
#   - ZRUSH_LOG points at a file under the temp directory, so that teardown's
#     classification of the writer child (signal it, or leave its pid alone)
#     can be read back.
#   - The notification fd is duplicated before consuming, so that "exactly one
#     ack byte" and "EOF without an ack byte" can be observed independently of
#     the code under test. The writer child is never `wait`ed on and its exit
#     status is never used as an oracle.
emulate -L zsh
setopt extended_glob nomultibyte
export LC_ALL=C
zmodload zsh/system || { print -u2 FATAL: system; exit 1 }
zmodload zsh/zselect || { print -u2 FATAL: zselect; exit 1 }

typeset -g HERE=${${(%):-%N}:A:h}
typeset -g REPO=${HERE:h:h}

typeset -gi PASS=0 FAIL=0
out() { print -r -u2 -- "$@" }
ok()  { out "PASS: $1"; (( ++PASS )) }
ng()  { out "FAIL: $1"; (( ++FAIL )) }

# Bounded waits: WAIT_CS for "this must happen", IDLE_CS for "this must not
# happen". Both are centiseconds (zselect's unit); no sleep is ever used for
# synchronization.
typeset -gi WAIT_CS=300 IDLE_CS=20

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-transport.XXXXXX)
export HOME=$WORK/home             # isolated; never the real home
export XDG_CONFIG_HOME=$WORK/xdg   # isolated; never the real ~/.config/zrush
export HISTFILE=$WORK/histfile     # nothing writes history, but never the real one either
unset ZDOTDIR
mkdir -p $HOME $XDG_CONFIG_HOME

{
  typeset -g ZRUSH_NO_INIT=1
  source $REPO/zsh/zrush.zsh || { out "FATAL: cannot source zrush.zsh"; exit 1 }
  unset ZRUSH_NO_INIT
  for fn in _zrush_worker_flush _zrush_worker_consume_ack _zrush_worker_release_writer \
            _zrush_worker_transport_teardown _zrush_encode_message; do
    (( $+functions[$fn] )) || { out "FATAL: $fn undefined after source"; exit 1 }
  done
  (( _zrush_enabled )) && { out "FATAL: ZRUSH_NO_INIT did not suppress initialization"; exit 1 }

  typeset -ga WARNINGS=()
  _zrush_warn() { WARNINGS+=( "$1" ) }   # test seam: record instead of printing

  # _zlog appends only when ZRUSH_LOG is set (zsh/zrush.zsh); point it at the
  # temp directory so teardown's writer classification is observable.
  typeset -g LOGFILE=$WORK/zrush.log
  typeset -g ZRUSH_LOG=$LOGFILE
  : >| $LOGFILE
  log_reset() { : >| $LOGFILE }
  log_has() { command grep -qF -- "$1" $LOGFILE }
  log_lines() {  # append the whole log to the failure reasons, for diagnosis
    local l
    for l in ${(f)"$(command cat $LOGFILE 2>/dev/null)"}; do WHY+=( "log| $l" ); done
  }

  # ------------------------------------------------------------- assertions
  typeset -ga WHY=()
  eq() {  # $1=what $2=actual $3=expected
    [[ $2 == "$3" ]] || WHY+=( "$1: got ${(qqq)2}, want ${(qqq)3}" )
  }
  note() { WHY+=( "$1" ) }
  verdict() {  # $1=case label
    if (( $#WHY == 0 )); then
      ok "$1"
    else
      ng "$1"
      local w
      for w in "${(@)WHY}"; do out "      - $w"; done
    fi
    WHY=()
  }

  # ------------------------------------------------------------- fixtures
  typeset -gi RFD=-1 ANCHOR=-1
  typeset -g FIFO=

  # A writer child forked by _zrush_worker_flush inherits this runner's reader
  # fds on the FIFO, so a child left blocked inside syswrite by a failing
  # implementation would never see EPIPE and would outlive the run holding the
  # runner's stdout. Remember the pids and reap the survivors at exit; never an
  # oracle, only a safety net for failing runs.
  typeset -ga SPAWNED=()
  remember_writer() { (( _zrush_worker_writer_pid > 1 )) && SPAWNED+=( $_zrush_worker_writer_pid ); return 0 }
  flush_now() {
    _zrush_worker_flush
    local -i s=$?
    remember_writer
    return $s
  }
  reap_spawned() {
    local -i p
    local pp
    for p in ${(@)SPAWNED}; do
      kill -0 $p 2>/dev/null || continue
      # Only ever signal a pid that is still one of this runner's own children,
      # so a recycled pid cannot be hit.
      pp=${${(f)"$(command ps -o ppid= -p $p 2>/dev/null)"}//[[:space:]]/}
      [[ $pp == $$ ]] && kill -KILL $p 2>/dev/null
    done
    SPAWNED=()
  }

  # Reset every transport global the write path reads, so each case starts from
  # a clean session with no worker process behind it.
  transport_reset() {
    typeset -g  _zrush_worker_txq=() _zrush_worker_rx= _zrush_worker_setup_req=
    typeset -gi _zrush_worker_ack_fd=-1 _zrush_worker_writer_pid=-1
    typeset -gi _zrush_worker_rfd=-1 _zrush_worker_wfd=-1
    typeset -gi _zrush_worker_drain_fd=-1 _zrush_worker_setup_fd=-1 _zrush_worker_setup_pid=-1
    typeset -gi _zrush_worker_pid=-1 _zrush_worker_ready=0
    typeset -gi _zrush_worker_failures=0 _zrush_worker_warned=0 _zrush_disabled=0
    typeset -gA _zrush_worker_pending=()
    WARNINGS=()
  }

  # A FIFO standing in for the worker's request FIFO. The anchor is opened
  # read-write so neither the reader nor the writer open blocks, and the write
  # fd is blocking + cloexec exactly as _zrush_worker_finish_start opens it: the
  # forked writer child keeps it because cloexec acts at exec, not at fork.
  fifo_setup() {  # $1=case name
    emulate -L zsh
    FIFO=$WORK/$1.fifo
    command mkfifo $FIFO || { out "FATAL: mkfifo $FIFO"; exit 1 }
    sysopen -rw -o cloexec -u ANCHOR $FIFO || { out "FATAL: anchor open"; exit 1 }
    sysopen -r -u RFD $FIFO || { out "FATAL: read open"; exit 1 }
    transport_reset
    sysopen -w -o cloexec -u _zrush_worker_wfd $FIFO || { out "FATAL: write open"; exit 1 }
  }

  fifo_teardown() {
    emulate -L zsh
    local -i fd
    for fd in $_zrush_worker_wfd $RFD $ANCHOR; do
      (( fd > 2 )) && { exec {fd}>&- } 2>/dev/null
    done
    _zrush_worker_wfd=-1 RFD=-1 ANCHOR=-1
    [[ -n $FIFO ]] && command rm -f $FIFO
    FIFO=
  }

  # Padding that leaves the writer child blocked inside its single syswrite.
  # A FIFO's buffer is 8192 bytes on macOS but 65536 on Linux, so a frame only
  # blocks on both platforms if it exceeds the larger figure with margin; the
  # cases below never hard-code a capacity, they pad by this amount.
  typeset -gi BLOCK_PAD=131072

  # A representative encoded plan request. Fields carry the bytes the transport
  # must ship verbatim: option-like values ("-f", "-cvar"), and NUL / SOH / STX,
  # which cli-protocol.md allows anywhere in a payload. $1 pads the frame; pass
  # $BLOCK_PAD when the case needs a writer child blocked inside syswrite.
  build_frame() {  # $1=pad bytes (default 0) -> REPLY
    emulate -L zsh
    setopt localoptions nomultibyte
    local LC_ALL=C
    local -i pad=${1:-0}
    local -a fields=(
      plan 1 /some/path compsys somequery fuzzy 0 1 24 80
      "w"$'\1'"-f"
      "w"$'\1'"-cvar"
      "w"$'\2'"README.md"$'\0'"after-nul"
    )
    (( pad > 0 )) && fields+=( "w"$'\1'"${(l:pad::x:)}" )
    _zrush_encode_message "${(@)fields}"
  }

  # ------------------------------------------------------------- fd helpers
  readable() {  # $1=fd $2=centiseconds -> 0 if readable within the budget
    emulate -L zsh
    zselect -t $2 -r $1 >/dev/null 2>&1
  }

  # Copy exactly $3 bytes off $1 into the file $2, never blocking unbounded.
  drain_bytes() {  # $1=fd $2=outfile $3=byte count
    emulate -L zsh
    setopt localoptions nomultibyte
    local LC_ALL=C
    local -i fd=$1 want=$3 got=0 cnt=0 st=0 outfd=-1
    exec {outfd}>| $2 || return 1
    while (( got < want )); do
      if ! readable $fd $WAIT_CS; then
        { exec {outfd}>&- } 2>/dev/null
        return 1
      fi
      cnt=0
      sysread -c cnt -i $fd -o $outfd -s 65536; st=$?
      (( st == 0 )) || { { exec {outfd}>&- } 2>/dev/null; return 1 }
      (( got += cnt ))
    done
    { exec {outfd}>&- } 2>/dev/null
    return 0
  }

  # Duplicate the notification fd so the ack byte / EOF can be observed without
  # racing the code under test for it.
  peek_open() {  # -> PEEK
    typeset -gi PEEK=-1
    (( _zrush_worker_ack_fd >= 0 )) || return 1
    exec {PEEK}<&$_zrush_worker_ack_fd
  }
  peek_close() {
    (( PEEK > 2 )) && { exec {PEEK}>&- } 2>/dev/null
    PEEK=-1
  }
  # Reads whatever the notification pipe still holds. status 4 = nothing yet,
  # 0 = bytes available (in PEEK_BYTES), 5 = EOF.
  peek_read() {  # -> PEEK_ST / PEEK_BYTES
    typeset -g PEEK_BYTES=
    sysread -t 0 -i $PEEK PEEK_BYTES
    typeset -gi PEEK_ST=$?
  }

  # ============================================================ case 1
  # One frame: the child ships it whole and acks exactly once.
  fifo_setup one
  build_frame; typeset -g FRAME=$REPLY
  print -rn -- "$FRAME" >| $WORK/one.expected
  _zrush_worker_txq=( "$FRAME" )
  flush_now; typeset -gi st=$?
  eq "flush status" $st 0
  eq "queue drained into the child" $#_zrush_worker_txq 0
  (( _zrush_worker_ack_fd >= 0 )) || note "no notification fd after flush"
  (( _zrush_worker_writer_pid > 1 )) || note "no writer child pid after flush"
  if peek_open; then
    if drain_bytes $RFD $WORK/one.actual ${#FRAME}; then
      cmp -s $WORK/one.expected $WORK/one.actual || note "frame bytes differ from what was queued"
    else
      note "reader did not observe ${#FRAME} bytes within ${WAIT_CS}cs"
    fi
    readable $RFD $IDLE_CS && note "extra bytes followed the frame"
    if readable $_zrush_worker_ack_fd $WAIT_CS; then
      _zrush_worker_consume_ack; typeset -gi cst=$?
      eq "consume_ack status" $cst 0
      # consume_ack read the whole ack byte string: any second byte would have
      # made it "11" and failed the session. The dup then shows EOF, so exactly
      # one ack byte was ever written.
      peek_read
      eq "notification fd after the ack" $PEEK_ST 5
      eq "bytes after the ack" ${#PEEK_BYTES} 0
      eq "in-flight notification fd released" $_zrush_worker_ack_fd -1
      eq "in-flight writer pid released" $_zrush_worker_writer_pid -1
      eq "session failures" $_zrush_worker_failures 0
      eq "warnings" $#WARNINGS 0
    else
      note "no ack within ${WAIT_CS}cs"
    fi
  else
    note "cannot duplicate the notification fd"
  fi
  peek_close
  fifo_teardown
  verdict "frame: shipped byte-for-byte and acked exactly once"

  # ============================================================ case 2
  # Two frames: the second waits for the first frame's ack, and the reader sees
  # the first frame complete before any byte of the second.
  fifo_setup order
  build_frame $BLOCK_PAD; typeset -g FRAME_A=$REPLY
  build_frame;       typeset -g FRAME_B=$REPLY
  print -rn -- "$FRAME_A" >| $WORK/order.a.expected
  print -rn -- "$FRAME_B" >| $WORK/order.b.expected
  _zrush_worker_txq=( "$FRAME_A" "$FRAME_B" )
  flush_now; st=$?
  typeset -gi ACK_A=$_zrush_worker_ack_fd PID_A=$_zrush_worker_writer_pid
  eq "flush status" $st 0
  eq "second frame still queued" $#_zrush_worker_txq 1
  eq "queued frame is B" "$_zrush_worker_txq[1]" "$FRAME_B"
  (( PID_A > 1 )) || note "no writer child for frame A"
  # A outgrows the FIFO's buffer on either platform and nothing drains yet, so
  # A is still in flight here. A second flush must not hand B to another child.
  flush_now; st=$?
  eq "flush while a child is in flight" $st 0
  eq "notification fd unchanged" $_zrush_worker_ack_fd $ACK_A
  eq "writer pid unchanged" $_zrush_worker_writer_pid $PID_A
  eq "B still queued while A is in flight" $#_zrush_worker_txq 1
  if drain_bytes $RFD $WORK/order.a.actual ${#FRAME_A}; then
    cmp -s $WORK/order.a.expected $WORK/order.a.actual || note "frame A bytes differ"
  else
    note "reader did not observe frame A within ${WAIT_CS}cs"
  fi
  # Nothing of B may be in the FIFO before A is acked.
  readable $RFD $IDLE_CS && note "bytes of B reached the FIFO before A was acked"
  eq "B still queued before A's ack" $#_zrush_worker_txq 1
  if readable $_zrush_worker_ack_fd $WAIT_CS; then
    _zrush_worker_consume_ack; cst=$?
    remember_writer   # consume_ack flushed B itself
    eq "consume_ack status for A" $cst 0
    eq "B handed to a child on A's ack" $#_zrush_worker_txq 0
    (( _zrush_worker_ack_fd >= 0 )) || note "no notification fd for frame B"
    (( _zrush_worker_writer_pid > 1 && _zrush_worker_writer_pid != PID_A )) ||
      note "frame B did not get its own writer child"
    if drain_bytes $RFD $WORK/order.b.actual ${#FRAME_B}; then
      cmp -s $WORK/order.b.expected $WORK/order.b.actual || note "frame B bytes differ"
    else
      note "reader did not observe frame B within ${WAIT_CS}cs"
    fi
    if readable $_zrush_worker_ack_fd $WAIT_CS; then
      _zrush_worker_consume_ack; cst=$?
      eq "consume_ack status for B" $cst 0
      eq "notification fd released after B" $_zrush_worker_ack_fd -1
      eq "writer pid released after B" $_zrush_worker_writer_pid -1
      eq "session failures" $_zrush_worker_failures 0
      eq "warnings" $#WARNINGS 0
    else
      note "no ack for frame B within ${WAIT_CS}cs"
    fi
  else
    note "no ack for frame A within ${WAIT_CS}cs"
  fi
  fifo_teardown
  verdict "queue: the next frame is sent only on the previous frame's ack, in order"

  # ============================================================ case 3
  # A child killed mid-frame: EOF without an ack byte is a worker session
  # failure, never a silently truncated success.
  fifo_setup killed
  build_frame $BLOCK_PAD; typeset -g FRAME_BIG=$REPLY
  _zrush_worker_txq=( "$FRAME_BIG" )
  flush_now; st=$?
  eq "flush status" $st 0
  typeset -gi VICTIM=$_zrush_worker_writer_pid
  if (( VICTIM > 1 )) && kill -0 $VICTIM 2>/dev/null && peek_open; then
    # Nothing drains the FIFO, so the child is blocked inside its single
    # syswrite with the frame only partly written.
    readable $_zrush_worker_ack_fd $IDLE_CS && note "acked before the frame could have been written"
    kill -KILL $VICTIM 2>/dev/null || note "cannot kill the writer child"
    if readable $PEEK $WAIT_CS; then
      peek_read
      eq "notification fd reached EOF" $PEEK_ST 5
      eq "ack bytes before EOF" ${#PEEK_BYTES} 0
      typeset -gi BEFORE=$_zrush_worker_failures
      _zrush_worker_consume_ack; cst=$?
      eq "consume_ack reports failure" $cst 1
      eq "session failure counted" $_zrush_worker_failures $(( BEFORE + 1 ))
      eq "warned once" $#WARNINGS 1
      eq "no in-flight notification fd left" $_zrush_worker_ack_fd -1
      eq "no in-flight writer pid left" $_zrush_worker_writer_pid -1
      eq "queue discarded" $#_zrush_worker_txq 0
      eq "request fd closed by the teardown" $_zrush_worker_wfd -1
    else
      note "notification fd did not reach EOF within ${WAIT_CS}cs after the kill"
    fi
  else
    note "no live writer child to kill"
  fi
  peek_close
  fifo_teardown
  verdict "kill: a child killed mid-frame fails the session instead of truncating silently"

  # ============================================================ case 4
  # Frames are opaque byte units: whatever leading bytes a frame has, syswrite
  # never parses them as its own options.
  fifo_setup opaque
  typeset -g ODD=$'-cvar\1-f\0--\2 -s 1'
  print -rn -- "$ODD" >| $WORK/opaque.expected
  _zrush_worker_txq=( "$ODD" )
  flush_now; st=$?
  eq "flush status" $st 0
  if drain_bytes $RFD $WORK/opaque.actual ${#ODD}; then
    cmp -s $WORK/opaque.expected $WORK/opaque.actual || note "option-like frame bytes differ"
  else
    note "reader did not observe the frame within ${WAIT_CS}cs"
  fi
  if readable $_zrush_worker_ack_fd $WAIT_CS; then
    _zrush_worker_consume_ack; cst=$?
    eq "consume_ack status" $cst 0
    eq "session failures" $_zrush_worker_failures 0
  else
    note "no ack within ${WAIT_CS}cs"
  fi
  fifo_teardown
  verdict "frame: option-like leading bytes are written verbatim, not parsed by syswrite"

  # ============================================================ case 5
  # Teardown drops the unsent queue and signals the child that is still inside
  # its blocking syswrite: nothing readable on the notification fd is the only
  # state in which the recorded pid is still the writer child's.
  fifo_setup drop
  build_frame $BLOCK_PAD; FRAME_A=$REPLY
  build_frame;       FRAME_B=$REPLY
  _zrush_worker_txq=( "$FRAME_A" "$FRAME_B" )
  flush_now; st=$?
  eq "flush status" $st 0
  typeset -gi PID_BLOCKED=$_zrush_worker_writer_pid
  if peek_open; then
    log_reset
    _zrush_worker_transport_teardown failure
    eq "queued frames dropped" $#_zrush_worker_txq 0
    eq "notification fd released" $_zrush_worker_ack_fd -1
    eq "writer pid released" $_zrush_worker_writer_pid -1
    eq "request fd closed" $_zrush_worker_wfd -1
    if ! log_has "worker: teardown terminating writer pid=$PID_BLOCKED"; then
      note "teardown did not signal the child blocked in syswrite"
      log_lines
    fi
    log_has "teardown writer done" && note "teardown classified a blocked child as done"
    if readable $PEEK $WAIT_CS; then
      peek_read
      eq "in-flight child gone without an ack" $PEEK_ST 5
      eq "ack bytes" ${#PEEK_BYTES} 0
    else
      note "in-flight child outlived the teardown"
    fi
  else
    note "cannot duplicate the notification fd"
  fi
  peek_close
  fifo_teardown
  verdict "teardown: unsent frames are dropped and the blocked child is signalled"

  # ============================================================ case 6
  # A child that already acked owns nothing any more, even when the ack byte has
  # not been consumed yet: teardown must not signal that pid, which by then may
  # belong to an unrelated process.
  fifo_setup acked
  build_frame; FRAME=$REPLY
  _zrush_worker_txq=( "$FRAME" )
  flush_now; st=$?
  eq "flush status" $st 0
  typeset -gi PID_DONE=$_zrush_worker_writer_pid
  if drain_bytes $RFD $WORK/acked.actual ${#FRAME}; then
    if readable $_zrush_worker_ack_fd $WAIT_CS; then
      # The ack byte is deliberately left unconsumed: teardown, not
      # _zrush_worker_consume_ack, has to classify it.
      log_reset
      _zrush_worker_transport_teardown failure
      if ! log_has "worker: teardown writer done pid=$PID_DONE status=0"; then
        note "teardown did not classify the acked child as done"
        log_lines
      fi
      log_has "teardown terminating writer" && note "teardown signalled a child that had already acked"
      eq "notification fd released" $_zrush_worker_ack_fd -1
      eq "writer pid released" $_zrush_worker_writer_pid -1
      eq "queue emptied" $#_zrush_worker_txq 0
    else
      note "no ack within ${WAIT_CS}cs"
    fi
  else
    note "reader did not observe the frame within ${WAIT_CS}cs"
  fi
  fifo_teardown
  verdict "teardown: a child that already acked is never signalled"

  # ============================================================ case 7
  # Same classification at the other end: a child that died mid-frame leaves the
  # notification fd at EOF, and a dead pid must not be signalled either.
  fifo_setup gone
  build_frame $BLOCK_PAD; FRAME_BIG=$REPLY
  _zrush_worker_txq=( "$FRAME_BIG" )
  flush_now; st=$?
  eq "flush status" $st 0
  VICTIM=$_zrush_worker_writer_pid
  if (( VICTIM > 1 )) && kill -0 $VICTIM 2>/dev/null && peek_open; then
    kill -KILL $VICTIM 2>/dev/null || note "cannot kill the writer child"
    if readable $PEEK $WAIT_CS; then
      log_reset
      _zrush_worker_transport_teardown failure
      if ! log_has "worker: teardown writer done pid=$VICTIM status=5"; then
        note "teardown did not classify the EOF as a finished child"
        log_lines
      fi
      log_has "teardown terminating writer" && note "teardown signalled a child that had already died"
      eq "notification fd released" $_zrush_worker_ack_fd -1
      eq "writer pid released" $_zrush_worker_writer_pid -1
    else
      note "notification fd did not reach EOF within ${WAIT_CS}cs after the kill"
    fi
  else
    note "no live writer child to kill"
  fi
  peek_close
  fifo_teardown
  verdict "teardown: a child already at EOF is never signalled"

  # ------------------------------------------------------ read-path fixtures
  # A read fd that never carries data: sysread -t 0 on it always reports EAGAIN,
  # so _zrush_worker_read can only make progress from what the case put into
  # _zrush_worker_rx, and no worker process is needed behind it.
  typeset -g RFIFO=
  sync_setup() {  # $1=case name; a session waiting synchronously for request 1
    emulate -L zsh
    transport_reset
    RFIFO=$WORK/rx-$1.fifo
    command mkfifo $RFIFO || { out "FATAL: mkfifo $RFIFO"; exit 1 }
    sysopen -rw -o cloexec -u _zrush_worker_rfd $RFIFO || { out "FATAL: rx open"; exit 1 }
    _zrush_worker_ready=1
    typeset -gi _zrush_current_request=0
    _zrush_worker_pending=( 1 history 2 compsys 3 compsys )
    typeset -gi _zrush_sync_target=1 _zrush_sync_done=0 _zrush_sync_ok=0
  }
  sync_teardown() {
    emulate -L zsh
    (( _zrush_worker_rfd > 2 )) && { exec {_zrush_worker_rfd}>&- } 2>/dev/null
    _zrush_worker_rfd=-1
    [[ -n $RFIFO ]] && command rm -f $RFIFO
    RFIFO=
  }

  # An outer frame carrying an `ok` response whose render plan is the smallest
  # one _zrush_parse_plan accepts: no rows, no highlights, no positions.
  msg_ok() {  # $1=request_id -> REPLY
    emulate -L zsh
    setopt localoptions nomultibyte
    local LC_ALL=C
    _zrush_encode_message ok "$1" $'\0'"0"$'\0'"0"$'\0'"0"$'\0'
  }

  # ============================================================ case 8
  # The target's terminal response ends the synchronous exchange.
  sync_setup lone
  msg_ok 1; _zrush_worker_rx=$REPLY
  typeset -gF DEADLINE=$(( EPOCHREALTIME + 5 ))
  _zrush_worker_read sync $DEADLINE; st=$?
  eq "read status" $st 0
  eq "exchange finished" $_zrush_sync_done 1
  eq "exchange succeeded" $_zrush_sync_ok 1
  eq "target no longer pending" ${+_zrush_worker_pending[1]} 0
  eq "receive buffer consumed" ${#_zrush_worker_rx} 0
  eq "session failures" $_zrush_worker_failures 0
  eq "warnings" $#WARNINGS 0
  sync_teardown
  verdict "sync read: the target's terminal response commits the exchange"

  # ============================================================ case 9
  # Same response, now followed by responses for other request_ids that arrived
  # in the same read. The exchange ends at the target; the rest stays buffered
  # for the asynchronous path instead of being processed inside the sync window.
  sync_setup trailing
  msg_ok 1; typeset -g TARGET=$REPLY
  msg_ok 2; typeset -g TRAILING=$REPLY
  msg_ok 3; TRAILING+=$REPLY
  _zrush_worker_rx=$TARGET$TRAILING
  DEADLINE=$(( EPOCHREALTIME + 5 ))
  _zrush_worker_read sync $DEADLINE; st=$?
  eq "read status" $st 0
  eq "exchange finished" $_zrush_sync_done 1
  eq "exchange succeeded" $_zrush_sync_ok 1
  eq "trailing bytes left buffered" ${#_zrush_worker_rx} ${#TRAILING}
  eq "trailing bytes left untouched" "$_zrush_worker_rx" "$TRAILING"
  eq "trailing requests still pending" $#_zrush_worker_pending 2
  eq "session failures" $_zrush_worker_failures 0
  eq "warnings" $#WARNINGS 0
  sync_teardown
  verdict "sync read: trailing responses are left to the asynchronous path"

  # ============================================================ case 10
  # The same buffer under a deadline that trips the instant the target's
  # response is committed -- the worst moment there is, and the one a clock
  # cannot be aimed at. A success already committed is never withdrawn.
  sync_setup expiring
  msg_ok 1; TARGET=$REPLY
  msg_ok 2; TRAILING=$REPLY
  msg_ok 3; TRAILING+=$REPLY
  _zrush_worker_rx=$TARGET$TRAILING
  typeset -g DEADLINE_FN=$functions[_zrush_worker_deadline_expired]
  _zrush_worker_deadline_expired() { [[ -n $1 ]] && (( _zrush_sync_done )) }
  DEADLINE=$(( EPOCHREALTIME + 5 ))   # the oracle, not this value, decides expiry
  _zrush_worker_read sync $DEADLINE; st=$?
  functions[_zrush_worker_deadline_expired]=$DEADLINE_FN
  eq "read status" $st 0
  eq "exchange finished" $_zrush_sync_done 1
  eq "exchange succeeded" $_zrush_sync_ok 1
  eq "trailing bytes left buffered" ${#_zrush_worker_rx} ${#TRAILING}
  eq "session failures" $_zrush_worker_failures 0
  eq "warnings" $#WARNINGS 0
  sync_teardown
  verdict "sync read: a deadline expiring after the commit cannot undo it"

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  (( $+functions[reap_spawned] )) && reap_spawned
  [[ -n $WORK && $WORK == */zrush-transport.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
