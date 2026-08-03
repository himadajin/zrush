#!/bin/zsh -f
# Non-pty unit tests for the zsh-side worker transport write path: the outbound
# frame queue, the short-lived writer child that _zrush_worker_flush forks, and
# the ack/EOF notification fd that _zrush_worker_consume_ack reads.
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
# section "worker ライフサイクル".
#
# Test seams used here, none of which touch zsh/zrush.zsh:
#   - _zrush_warn is replaced by a recorder, so warnings are asserted instead of
#     printed into the runner's output.
#   - The ZLE callback never runs headless, so the shared consume path
#     (_zrush_worker_consume_ack) is called directly, exactly as the synchronous
#     history loop calls it.
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

  # A representative encoded plan request. Fields carry the bytes the transport
  # must ship verbatim: option-like values ("-f", "-cvar"), and NUL / SOH / STX,
  # which cli-protocol.md allows anywhere in a payload. $1 pads the frame past
  # the FIFO's 8192-byte capacity so the writer child blocks inside syswrite.
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
    (( pad > 0 )) && fields+=( "w"$'\1'"${${(l:40000::x:)}[1,pad]}" )
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
  _zrush_worker_flush; typeset -gi st=$?
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
  build_frame 40000; typeset -g FRAME_A=$REPLY
  build_frame;       typeset -g FRAME_B=$REPLY
  print -rn -- "$FRAME_A" >| $WORK/order.a.expected
  print -rn -- "$FRAME_B" >| $WORK/order.b.expected
  _zrush_worker_txq=( "$FRAME_A" "$FRAME_B" )
  _zrush_worker_flush; st=$?
  typeset -gi ACK_A=$_zrush_worker_ack_fd PID_A=$_zrush_worker_writer_pid
  eq "flush status" $st 0
  eq "second frame still queued" $#_zrush_worker_txq 1
  eq "queued frame is B" "$_zrush_worker_txq[1]" "$FRAME_B"
  (( PID_A > 1 )) || note "no writer child for frame A"
  # A is larger than the FIFO's 8192-byte capacity and nothing drains yet, so A
  # is still in flight here. A second flush must not hand B to another child.
  _zrush_worker_flush; st=$?
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
  build_frame 40000; typeset -g FRAME_BIG=$REPLY
  _zrush_worker_txq=( "$FRAME_BIG" )
  _zrush_worker_flush; st=$?
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
  _zrush_worker_flush; st=$?
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
  # Teardown drops the unsent queue and lets go of the in-flight child.
  fifo_setup drop
  build_frame 40000; FRAME_A=$REPLY
  build_frame;       FRAME_B=$REPLY
  _zrush_worker_txq=( "$FRAME_A" "$FRAME_B" )
  _zrush_worker_flush; st=$?
  eq "flush status" $st 0
  if peek_open; then
    _zrush_worker_transport_teardown failure
    eq "queued frames dropped" $#_zrush_worker_txq 0
    eq "notification fd released" $_zrush_worker_ack_fd -1
    eq "writer pid released" $_zrush_worker_writer_pid -1
    eq "request fd closed" $_zrush_worker_wfd -1
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
  verdict "teardown: unsent frames are dropped and the in-flight child is released"

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  [[ -n $WORK && $WORK == */zrush-transport.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
