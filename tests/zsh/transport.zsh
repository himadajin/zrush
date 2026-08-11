#!/bin/zsh -f
# Headless regression tests for the PID-free zsh worker transport.
# The real Rust worker is used for control-byte/EOF and healthy lifecycle
# checks; deterministic FIFO seams cover writer backpressure and quarantine.
emulate -L zsh
setopt extended_glob nomultibyte
export LC_ALL=C
zmodload zsh/system zsh/zselect zsh/datetime zsh/stat || {
  print -u2 FATAL: required zsh modules
  exit 1
}

typeset -g HERE=${${(%):-%N}:A:h}
typeset -g REPO=${HERE:h:h}
typeset -g REAL_BIN=$REPO/target/release/zrush
# The raw-drain case below runs the failure-injection launcher as $ZRUSH_BIN.
# It is a [[bin]] of the same crate, so one release build produces both.
typeset -g FAKE_BIN=$REPO/target/release/zrush-fake-worker
[[ -x $REAL_BIN && -x $FAKE_BIN ]] || {
  print -u2 "FATAL: build first: cargo build --release (needs zrush and zrush-fake-worker)"
  exit 1
}

typeset -gi PASS=0 FAIL=0 WAIT_CS=500 IDLE_CS=10
out() { print -r -u2 -- "$@" }
ok() { out "PASS: $1"; (( ++PASS )) }
ng() { out "FAIL: $1"; (( ++FAIL )) }
typeset -ga WHY=()
eq() { [[ $2 == "$3" ]] || WHY+=( "$1: got ${(qqq)2}, want ${(qqq)3}" ) }
note() { WHY+=( "$1" ) }
verdict() {
  if (( $#WHY == 0 )); then
    ok "$1"
  else
    ng "$1"
    local why
    for why in "${(@)WHY}"; do out "      - $why"; done
  fi
  WHY=()
}

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-transport.XXXXXX)
export HOME=$WORK/home XDG_CONFIG_HOME=$WORK/xdg HISTFILE=$WORK/history
mkdir -p $HOME $XDG_CONFIG_HOME
unset ZDOTDIR

{
  typeset -g ZRUSH_BIN=$REAL_BIN ZRUSH_NO_INIT=1
  eval "$("$REAL_BIN" config)" || { out "FATAL: cannot read build stamp"; exit 1 }
  typeset -g _ZRUSH_EXPECTED_BUILD_STAMP=$ZRUSH_BUILD_STAMP
  source $REPO/zsh/zrush.zsh || { out "FATAL: cannot source zrush.zsh"; exit 1 }
  unset ZRUSH_NO_INIT
  typeset -g LOGFILE=$WORK/zrush.log ZRUSH_LOG=$WORK/zrush.log
  : >| $LOGFILE
  typeset -ga WARNINGS=()
  _zrush_warn() { WARNINGS+=( "$1" ) }

  readable() { zselect -t ${2:-$WAIT_CS} -r $1 >/dev/null 2>&1 }
  fd_open() { [[ $1 == <-> && $1 -gt 2 && -e /dev/fd/$1 ]] }
  watcher_for_fd() {
    emulate -L zsh
    local listing=$(builtin zle -F 2>/dev/null) line
    local -a lines=( ${(f)listing} ) words
    for line in "${(@)lines}"; do
      words=( ${(z)line} )
      (( $#words >= 2 )) && [[ $words[-2] == $1 ]] && return 0
    done
    return 1
  }
  mode_of() {
    local value
    value=$(command stat -f %Lp "$1" 2>/dev/null) ||
      value=$(command stat -c %a "$1" 2>/dev/null) || return 1
    typeset -g REPLY=$value
  }

  reset_transport() {
    emulate -L zsh
    local kind fd
    for kind in data ack drain; do
      case $kind in
        data) fd=${_zrush_worker_rfd:--1} ;;
        ack) fd=${_zrush_worker_ack_fd:--1} ;;
        drain) fd=${_zrush_worker_drain_fd:--1} ;;
      esac
      (( $+functions[_zrush_worker_invalidate_callback] )) &&
        _zrush_worker_invalidate_callback $kind $fd
    done
    for fd in ${_zrush_worker_ack_fd:--1} ${_zrush_worker_drain_fd:--1} \
              ${_zrush_worker_rfd:--1} ${_zrush_worker_wfd:--1} \
              ${_zrush_worker_control_wfd:--1}; do
      (( fd > 2 )) && _zrush_close_internal_fd $fd
    done
    _zrush_worker_runtime_destroy
    _zrush_worker_rfd=-1 _zrush_worker_wfd=-1 _zrush_worker_control_wfd=-1
    _zrush_worker_ack_fd=-1 _zrush_worker_drain_fd=-1
    _zrush_worker_ready=0
    _zrush_worker_stopping=0 _zrush_worker_rx=
    _zrush_worker_runtime_tainted=0
    _zrush_worker_txq=() _zrush_worker_pending=() _zrush_cc_staged=()
    _zrush_cc_fp= _zrush_cc_time=0 _zrush_cc_cand_gen=0
    _zrush_current_request=0 _zrush_sync_target=0 _zrush_sync_done=0 _zrush_sync_ok=0
    _zrush_worker_failures=0 _zrush_worker_warned=0 _zrush_build_warned=0
    _zrush_build_following=0 _zrush_build_verifying=0 _zrush_stale_disabled=0
    _zrush_disabled=0 _zrush_disable_reason= _zrush_notice= _zrush_enabled=0
    _zrush_worker_callback_generation=( data 0 ack 0 drain 0 )
    _zrush_worker_callback_handler=()
    WARNINGS=()
  }

  drain_exact() {  # fd path byte-count
    emulate -L zsh
    local -i fd=$1 want=$3 total=0 count st outfd=-1
    exec {outfd}>| $2 || return 1
    while (( total < want )); do
      readable $fd || { exec {outfd}>&-; return 1 }
      count=0
      sysread -c count -i $fd -o $outfd -s 65536; st=$?
      (( st == 0 )) || { exec {outfd}>&-; return 1 }
      (( total += count ))
    done
    exec {outfd}>&-
  }

  start_ready() {
    emulate -L zsh
    local -F deadline=$(( EPOCHREALTIME + 5.0 ))
    _zrush_worker_runtime_prepare || return 1
    _zrush_worker_start || return 1
    while (( _zrush_worker_ack_fd >= 0 && EPOCHREALTIME < deadline )); do
      readable $_zrush_worker_ack_fd 20 && _zrush_worker_consume_ack
    done
    (( _zrush_worker_ack_fd < 0 )) || return 1
    while (( !_zrush_worker_ready && EPOCHREALTIME < deadline )); do
      readable $_zrush_worker_rfd 20 && _zrush_worker_read async
    done
    (( _zrush_worker_ready ))
  }

  stop_until_done() {
    emulate -L zsh
    local -F deadline=$(( EPOCHREALTIME + ${1:-5.0} ))
    while (( _zrush_worker_stopping && EPOCHREALTIME < deadline )); do
      _zrush_worker_stop_progress async
      (( _zrush_worker_stopping )) || break
      _zrush_worker_wait $(( EPOCHREALTIME + 0.05 )) \
        $_zrush_worker_ack_fd $_zrush_worker_rfd
    done
    (( !_zrush_worker_stopping ))
  }

  # ------------------------------------------------ secure runtime topology
  reset_transport
  typeset -gi saved0 saved1 saved2
  exec {saved0}<&0 {saved1}>&1 {saved2}>&2
  _zrush_worker_runtime_prepare || note "runtime preparation failed"
  typeset -g runtime=$_zrush_worker_runtime_dir req=$_zrush_worker_request_path
  typeset -g resp=$_zrush_worker_response_path ctl=$_zrush_worker_control_path
  [[ -d $runtime && -p $req && -p $resp && -p $ctl ]] || note "runtime topology is incomplete"
  mode_of $runtime && eq "runtime mode" $REPLY 700
  local endpoint
  for endpoint in $req $resp $ctl; do
    mode_of $endpoint && eq "FIFO mode $endpoint" $REPLY 600
  done
  [[ /dev/fd/0 -ef /dev/fd/$saved0 && /dev/fd/1 -ef /dev/fd/$saved1 \
     && /dev/fd/2 -ef /dev/fd/$saved2 ]] || note "runtime setup changed shell stdio"
  _zrush_worker_runtime_destroy
  [[ ! -e $runtime && -z $_zrush_worker_runtime_dir ]] || note "exact runtime paths survived destroy"
  exec {saved0}>&- {saved1}>&- {saved2}>&-
  verdict "runtime: private 0700 directory and three 0600 FIFOs are exact-owned"

  # Lazy worker start consumes only a source-prepared runtime. It cannot hide
  # a synchronous mkfifo/mkdir operation behind the first input event.
  reset_transport
  _zrush_worker_start >/dev/null 2>&1
  typeset -gi no_runtime_st=$?
  (( no_runtime_st != 0 )) || note "start without source-prepared runtime succeeded"
  [[ -z $_zrush_worker_runtime_dir && -z $_zrush_worker_request_path \
     && -z $_zrush_worker_response_path && -z $_zrush_worker_control_path ]] ||
    note "lazy start created a runtime"
  eq "lazy start response fd" $_zrush_worker_rfd -1
  eq "lazy start request fd" $_zrush_worker_wfd -1
  eq "lazy start control fd" $_zrush_worker_control_wfd -1
  verdict "startup: lazy start never creates the source-generation runtime"

  # -------------------------------- transactional descriptor acquisition
  reset_transport
  _zrush_worker_runtime_prepare || note "transaction fixture runtime failed"
  runtime=$_zrush_worker_runtime_dir
  typeset -gi txn0 txn1 txn2
  exec {txn0}<&0 {txn1}>&1 {txn2}>&2
  typeset -gi SYSOPEN_CALLS=0
  sysopen() {
    (( ++SYSOPEN_CALLS == 4 )) && return 1
    builtin sysopen "$@"
  }
  _zrush_worker_start >/dev/null 2>&1
  typeset -gi transaction_st=$?
  unfunction sysopen
  (( transaction_st != 0 )) || note "injected endpoint failure reported success"
  eq "unpublished response fd" $_zrush_worker_rfd -1
  eq "unpublished request fd" $_zrush_worker_wfd -1
  eq "unpublished control fd" $_zrush_worker_control_wfd -1
  eq "unpublished ack fd" $_zrush_worker_ack_fd -1
  eq "stopping gate finalized" $_zrush_worker_stopping 0
  [[ -d $runtime ]] || note "generation runtime was incorrectly destroyed by session start rollback"
  [[ /dev/fd/0 -ef /dev/fd/$txn0 && /dev/fd/1 -ef /dev/fd/$txn1 \
     && /dev/fd/2 -ef /dev/fd/$txn2 ]] || note "failed endpoint acquisition changed shell stdio"
  exec {txn0}>&- {txn1}>&- {txn2}>&-
  verdict "startup: endpoint allocation failure publishes no partial fd or active session"

  # A watcher failure reported after the worker has spawned cannot use the
  # pre-spawn rollback path. Keep the response fd as the sole completion
  # oracle, unlink the generation's names, and refuse overlap even after EOF.
  reset_transport
  ZRUSH_BIN=$REAL_BIN
  _zrush_worker_runtime_prepare || note "post-spawn worker fixture runtime failed"
  typeset -g worker_failed_runtime=$_zrush_worker_runtime_dir
  typeset -g worker_failed_req=$_zrush_worker_request_path
  typeset -g worker_failed_resp=$_zrush_worker_response_path
  typeset -g worker_failed_ctl=$_zrush_worker_control_path
  typeset -gi worker0 worker1 worker2
  exec {worker0}<&0 {worker1}>&1 {worker2}>&2
  functions[_zrt_poll_eof]=$functions[_zrush_worker_poll_eof]
  functions[_zrt_wait]=$functions[_zrush_worker_wait]
  typeset -g worker_failed_handler=_zrush-worker-data-$(( _zrush_worker_callback_seq + 1 ))
  zle() {
    if [[ $1 == -F && $2 == -w && $4 == $worker_failed_handler ]]; then
      return 1
    fi
    builtin zle "$@"
  }
  _zrush_worker_poll_eof() { return 1 }
  _zrush_worker_wait() { return 1 }
  _zrush_worker_start >/dev/null 2>&1
  typeset -gi post_worker_st=$?
  unfunction zle
  functions[_zrush_worker_poll_eof]=$functions[_zrt_poll_eof]
  functions[_zrush_worker_wait]=$functions[_zrt_wait]
  unfunction _zrt_poll_eof _zrt_wait
  (( post_worker_st != 0 )) || note "post-spawn worker watcher failure reported success"
  eq "post-spawn worker quarantine" $_zrush_worker_stopping 1
  eq "post-spawn worker taint" $_zrush_worker_runtime_tainted 1
  fd_open $_zrush_worker_rfd || note "post-spawn worker response oracle was discarded"
  eq "failed response callback generation cleared" ${_zrush_worker_callback_generation[data]} 0
  [[ -z ${_zrush_worker_callback_handler[data]} ]] || note "failed response callback handler remained published"
  (( !$+functions[$worker_failed_handler] && !$+widgets[$worker_failed_handler] )) ||
    note "failed response callback left a generated function/widget"
  watcher_for_fd $_zrush_worker_rfd && note "failed response callback left a live fd watcher"
  [[ ! -e $worker_failed_req && ! -e $worker_failed_resp && ! -e $worker_failed_ctl ]] ||
    note "tainted worker FIFO names remained published"
  [[ -d $worker_failed_runtime ]] || note "tainted worker ownership ledger directory was lost"
  _zrush_worker_start; eq "post-spawn worker overlap rejected" $? 1
  [[ /dev/fd/0 -ef /dev/fd/$worker0 && /dev/fd/1 -ef /dev/fd/$worker1 \
     && /dev/fd/2 -ef /dev/fd/$worker2 ]] || note "post-spawn worker rollback changed shell stdio"
  stop_until_done || note "explicit worker rollback cleanup did not observe response EOF"
  eq "worker rollback finalized" $_zrush_worker_stopping 0
  eq "worker taint survives EOF" $_zrush_worker_runtime_tainted 1
  _zrush_worker_start; eq "tainted worker runtime remains unavailable" $? 1
  _zrush_worker_runtime_destroy
  _zrush_worker_runtime_tainted=0
  _zrush_worker_runtime_prepare || note "fresh worker source-generation setup failed"
  [[ $_zrush_worker_runtime_dir != $worker_failed_runtime ]] || note "fresh source reused the tainted runtime directory"
  [[ -p $_zrush_worker_request_path && -p $_zrush_worker_response_path \
     && -p $_zrush_worker_control_path ]] || note "fresh source did not publish new FIFO inodes"
  exec {worker0}>&- {worker1}>&- {worker2}>&-
  verdict "startup: post-spawn response-watcher failure quarantines the worker and taints the runtime"

  # macOS readiness may report a response EOF only once. The normal parser
  # must record that already-observed EOF as worker completion before entering
  # abort; correctness cannot depend on polling the same EOF a second time.
  reset_transport
  exec {_zrush_worker_rfd}< /dev/null
  exec {_zrush_worker_wfd}> /dev/null
  exec {_zrush_worker_control_wfd}> /dev/null
  _zrush_worker_ready=1
  typeset -gi EOF_REPOLLS=0
  functions[_zrt_poll_eof]=$functions[_zrush_worker_poll_eof]
  _zrush_worker_poll_eof() { (( ++EOF_REPOLLS )); return 1 }
  _zrush_worker_read async >/dev/null 2>&1
  typeset -gi unexpected_eof_st=$?
  functions[_zrush_worker_poll_eof]=$functions[_zrt_poll_eof]
  unfunction _zrt_poll_eof
  eq "unexpected EOF read status" $unexpected_eof_st 1
  eq "unexpected EOF is not re-polled" $EOF_REPOLLS 0
  eq "observed EOF closes response gate" $_zrush_worker_rfd -1
  eq "observed EOF closes request" $_zrush_worker_wfd -1
  eq "observed EOF closes control" $_zrush_worker_control_wfd -1
  eq "observed EOF finalizes stop" $_zrush_worker_stopping 0
  eq "unexpected EOF records one failure" $_zrush_worker_failures 1
  verdict "response EOF: one normal-read observation completes the gate before abort"

  # ------------------------------------------------ real watchdog control byte
  reset_transport
  ZRUSH_BIN=$REAL_BIN
  start_ready || note "real worker did not reach build-stamp ready"
  typeset -gi byte_rfd=$_zrush_worker_rfd
  _zrush_worker_abort $(( EPOCHREALTIME + 2.0 )); typeset -gi byte_st=$?
  eq "abort byte status" $byte_st 0
  eq "abort byte response EOF" $_zrush_worker_rfd -1
  eq "abort byte control closed" $_zrush_worker_control_wfd -1
  eq "abort byte gate finalized" $_zrush_worker_stopping 0
  [[ ! -e /dev/fd/$byte_rfd ]] || note "response fd remained after watchdog byte"
  verdict "control: real worker exits on abort byte and response EOF finalizes"

  # ------------------------------------------------ real watchdog control EOF
  reset_transport
  start_ready || note "real worker did not reach ready for EOF case"
  functions[_zrt_signal_abort]=$functions[_zrush_worker_signal_abort]
  _zrush_worker_signal_abort() { return 0 }
  _zrush_worker_abort $(( EPOCHREALTIME + 2.0 )); typeset -gi eof_st=$?
  functions[_zrush_worker_signal_abort]=$functions[_zrt_signal_abort]
  unfunction _zrt_signal_abort
  eq "control EOF abort status" $eof_st 0
  eq "control EOF response finalized" $_zrush_worker_rfd -1
  eq "control EOF gate finalized" $_zrush_worker_stopping 0
  verdict "control: real worker exits when the sole control writer closes"

  # ------------------------------------------ normal writer ordering + ack slot
  reset_transport
  typeset -g REQ_FIFO=$WORK/request.fifo HOLD_FIFO=$WORK/hold.fifo
  command mkfifo $REQ_FIFO $HOLD_FIFO
  typeset -gi REQ_ANCHOR REQ_R HOLD_ANCHOR HOLD_R HOLD_W
  sysopen -rw -o cloexec -u REQ_ANCHOR $REQ_FIFO
  sysopen -r -o cloexec -u REQ_R $REQ_FIFO
  sysopen -w -o cloexec -u _zrush_worker_wfd $REQ_FIFO
  sysopen -rw -o cloexec -u HOLD_ANCHOR $HOLD_FIFO
  sysopen -r -o cloexec -u HOLD_R $HOLD_FIFO
  sysopen -w -o cloexec -u HOLD_W $HOLD_FIFO
  # The pipelined pair a finished collection sends: the store that fills a slot
  # under a fresh generation, then the plan reading that generation back
  # (cli-protocol.md "要求と応答").
  _zrush_encode_message store 1 live 1 $'b\1\0'; typeset -g FRAME_A=$REPLY
  _zrush_encode_message plan 2 1 / compsys q prefix false 1 1 false; typeset -g FRAME_B=$REPLY
  print -rn -- "$FRAME_A" >| $WORK/a.expected
  print -rn -- "$FRAME_B" >| $WORK/b.expected
  print() {
    if (( $# == 3 )) && [[ $1 == -rn && $2 == -- && $3 == 1 ]]; then
      builtin print "$@"
      exec {HOLD_W}>&- {HOLD_ANCHOR}>&-
      local release
      sysread -i $HOLD_R release
      return 0
    fi
    builtin print "$@"
  }
  _zrush_worker_txq=( "$FRAME_A" "$FRAME_B" )
  _zrush_worker_flush; typeset -gi order_st=$?
  unfunction print
  exec {HOLD_R}>&- {HOLD_ANCHOR}>&-
  eq "first flush status" $order_st 0
  eq "B remains queued under sole slot" $#_zrush_worker_txq 1
  drain_exact $REQ_R $WORK/a.actual ${#FRAME_A} || note "frame A did not arrive"
  command cmp -s $WORK/a.expected $WORK/a.actual || note "frame A bytes differ"
  readable $_zrush_worker_ack_fd || note "frame A ack did not arrive"
  typeset -gi ACK_A=$_zrush_worker_ack_fd
  _zrush_worker_consume_ack
  eq "A ack releases and delegates B" $#_zrush_worker_txq 0
  (( _zrush_worker_ack_fd > 2 && _zrush_worker_ack_fd != ACK_A )) || note "B did not acquire a new sole slot"
  drain_exact $REQ_R $WORK/b.actual ${#FRAME_B} || note "frame B did not arrive"
  command cmp -s $WORK/b.expected $WORK/b.actual || note "frame B bytes differ"
  readable $_zrush_worker_ack_fd || note "frame B ack did not arrive"
  _zrush_worker_consume_ack
  eq "B slot released" $_zrush_worker_ack_fd -1
  syswrite -o $HOLD_W -- x 2>/dev/null
  exec {HOLD_W}>&- {REQ_R}>&- {REQ_ANCHOR}>&-
  _zrush_worker_close_request
  command rm -f $REQ_FIFO $HOLD_FIFO
  verdict "writer: ack releases the slot and preserves serial ordering without process EOF"

  # Report an ack watcher failure only after its watcher was installed. The
  # already-spawned writer may have touched its frame, so its notification fd
  # remains the writer gate and the entire FIFO generation becomes unusable.
  reset_transport
  ZRUSH_BIN=$REAL_BIN
  start_ready || note "post-spawn writer fixture did not reach ready"
  typeset -g writer_failed_runtime=$_zrush_worker_runtime_dir
  typeset -g writer_failed_req=$_zrush_worker_request_path
  typeset -g writer_failed_resp=$_zrush_worker_response_path
  typeset -g writer_failed_ctl=$_zrush_worker_control_path
  typeset -gi writer0 writer1 writer2
  exec {writer0}<&0 {writer1}>&1 {writer2}>&2
  _zrush_encode_message plan 77 5 / compsys q prefix false 1 1 false
  _zrush_worker_txq=( "$REPLY" never-replayed )
  functions[_zrt_poll_writer]=$functions[_zrush_worker_poll_writer]
  functions[_zrt_poll_eof]=$functions[_zrush_worker_poll_eof]
  functions[_zrt_wait]=$functions[_zrush_worker_wait]
  typeset -g writer_failed_handler=_zrush-worker-ack-$(( _zrush_worker_callback_seq + 1 ))
  zle() {
    if [[ $1 == -F && $2 == -w && $4 == $writer_failed_handler ]]; then
      return 1
    fi
    builtin zle "$@"
  }
  _zrush_worker_poll_writer() { return 1 }
  _zrush_worker_poll_eof() { return 1 }
  _zrush_worker_wait() { return 1 }
  _zrush_worker_flush >/dev/null 2>&1
  typeset -gi post_writer_st=$?
  unfunction zle
  functions[_zrush_worker_poll_writer]=$functions[_zrt_poll_writer]
  functions[_zrush_worker_poll_eof]=$functions[_zrt_poll_eof]
  functions[_zrush_worker_wait]=$functions[_zrt_wait]
  unfunction _zrt_poll_writer _zrt_poll_eof _zrt_wait
  (( post_writer_st != 0 )) || note "post-spawn writer watcher failure reported success"
  eq "post-spawn writer quarantine" $_zrush_worker_stopping 1
  eq "post-spawn writer taint" $_zrush_worker_runtime_tainted 1
  fd_open $_zrush_worker_ack_fd || note "post-spawn writer notification gate was discarded"
  fd_open $_zrush_worker_rfd || note "post-spawn writer response oracle was discarded"
  eq "failed ack callback generation cleared" ${_zrush_worker_callback_generation[ack]} 0
  [[ -z ${_zrush_worker_callback_handler[ack]} ]] || note "failed ack callback handler remained published"
  (( !$+functions[$writer_failed_handler] && !$+widgets[$writer_failed_handler] )) ||
    note "failed ack callback left a generated function/widget"
  watcher_for_fd $_zrush_worker_ack_fd && note "failed ack callback left a live fd watcher"
  eq "post-spawn writer drops unsent frames" $#_zrush_worker_txq 0
  [[ ! -e $writer_failed_req && ! -e $writer_failed_resp && ! -e $writer_failed_ctl ]] ||
    note "tainted writer FIFO names remained published"
  _zrush_worker_start; eq "post-spawn writer overlap rejected" $? 1
  [[ /dev/fd/0 -ef /dev/fd/$writer0 && /dev/fd/1 -ef /dev/fd/$writer1 \
     && /dev/fd/2 -ef /dev/fd/$writer2 ]] || note "post-spawn writer rollback changed shell stdio"
  stop_until_done || note "explicit writer rollback cleanup did not resolve both gates"
  eq "writer rollback finalized" $_zrush_worker_stopping 0
  eq "writer taint survives cleanup" $_zrush_worker_runtime_tainted 1
  _zrush_worker_start; eq "tainted writer runtime remains unavailable" $? 1
  [[ -d $writer_failed_runtime ]] || note "writer ownership ledger directory was lost before source cleanup"
  _zrush_worker_runtime_destroy
  _zrush_worker_runtime_tainted=0
  _zrush_worker_runtime_prepare || note "fresh writer source-generation setup failed"
  [[ $_zrush_worker_runtime_dir != $writer_failed_runtime ]] || note "fresh source reused writer-tainted runtime"
  exec {writer0}>&- {writer1}>&- {writer2}>&-
  verdict "writer: post-spawn ack-watcher failure aborts without replay and forbids runtime reuse"

  # ---------------- one deadline, unacked EPIPE gate, response-EOF quarantine
  reset_transport
  REQ_FIFO=$WORK/blocked-request.fifo
  typeset -g RESP_FIFO=$WORK/blocked-response.fifo GATE_FIFO=$WORK/writer-gate.fifo
  command mkfifo $REQ_FIFO $RESP_FIFO $GATE_FIFO
  typeset -gi RESP_ANCHOR RESP_W GATE_ANCHOR GATE_R GATE_W
  sysopen -rw -o cloexec -u REQ_ANCHOR $REQ_FIFO
  sysopen -r -o cloexec -u REQ_R $REQ_FIFO
  sysopen -w -o cloexec -u _zrush_worker_wfd $REQ_FIFO
  sysopen -rw -o cloexec -u RESP_ANCHOR $RESP_FIFO
  sysopen -r -o cloexec -u _zrush_worker_rfd $RESP_FIFO
  sysopen -w -o cloexec -u RESP_W $RESP_FIFO
  sysopen -rw -o cloexec -u GATE_ANCHOR $GATE_FIFO
  sysopen -r -o cloexec -u GATE_R $GATE_FIFO
  sysopen -w -o cloexec -u GATE_W $GATE_FIFO
  _zrush_worker_ready=1
  _zrush_worker_register_callback data $_zrush_worker_rfd || note "response callback setup failed"
  watcher_for_fd $_zrush_worker_rfd || note "response watcher was not observable before stopping"
  typeset -gi stop_data_generation=$_zrush_worker_callback_generation[data]
  typeset -g BIG=${(l:262144::x:)}
  syswrite() {
    if (( $# >= 2 )) && [[ $1 == -o && $2 == $_zrush_worker_wfd ]]; then
      exec {REQ_R}>&- {REQ_ANCHOR}>&- {RESP_W}>&- {RESP_ANCHOR}>&-
      exec {GATE_W}>&- {GATE_ANCHOR}>&-
      local release
      builtin sysread -i $GATE_R release
      builtin syswrite "$@"
      return $?
    fi
    builtin syswrite "$@"
  }
  _zrush_worker_txq=( "$BIG" queued-never-handed )
  _zrush_worker_flush
  watcher_for_fd $_zrush_worker_ack_fd || note "ack watcher was not observable before stopping"
  typeset -gi stop_ack_generation=$_zrush_worker_callback_generation[ack]
  unfunction syswrite
  exec {GATE_R}>&- {GATE_ANCHOR}>&-
  typeset -ga STOP_DEADLINES=()
  typeset -g ABORT_DEADLINE=
  functions[_zrt_wait]=$functions[_zrush_worker_wait]
  functions[_zrt_abort]=$functions[_zrush_worker_abort]
  _zrush_worker_wait() { STOP_DEADLINES+=( "$1" ); return 1 }
  _zrush_worker_abort() { ABORT_DEADLINE=$1; _zrt_abort "$@" }
  typeset -gF stopped_at=$EPOCHREALTIME
  _zrush_worker_shutdown; typeset -gi quarantine_st=$?
  typeset -gF stop_elapsed=$(( EPOCHREALTIME - stopped_at ))
  functions[_zrush_worker_wait]=$functions[_zrt_wait]
  functions[_zrush_worker_abort]=$functions[_zrt_abort]
  unfunction _zrt_wait _zrt_abort
  (( quarantine_st != 0 )) || note "unresolved stop did not enter quarantine"
  (( stop_elapsed < 0.35 )) || note "synchronous stop exceeded one bounded budget: $stop_elapsed"
  (( $#STOP_DEADLINES >= 1 )) || note "healthy phase did not receive an absolute deadline"
  [[ -n $ABORT_DEADLINE && $ABORT_DEADLINE == ${STOP_DEADLINES[1]:-missing} ]] ||
    note "healthy-to-abort transition reset the deadline"
  eq "quarantine gate" $_zrush_worker_stopping 1
  eq "unhanded frame dropped" $#_zrush_worker_txq 0
  (( _zrush_worker_ack_fd > 2 && _zrush_worker_rfd > 2 )) || note "completion predicates were not retained"
  eq "response callback retained" ${_zrush_worker_callback_generation[data]} $stop_data_generation
  eq "ack callback retained" ${_zrush_worker_callback_generation[ack]} $stop_ack_generation
  _zrush_worker_start; eq "replacement rejected in quarantine" $? 1
  exec {REQ_R}>&- {REQ_ANCHOR}>&-
  syswrite -o $GATE_W -- x 2>/dev/null
  exec {GATE_W}>&-
  readable $_zrush_worker_ack_fd || note "failed writer notification never reached EOF"
  _zrush_worker_stop_progress async
  eq "EPIPE resolves writer gate" $_zrush_worker_ack_fd -1
  eq "response EOF still gates replacement" $_zrush_worker_stopping 1
  _zrush_worker_start; eq "replacement rejected before response EOF" $? 1
  exec {RESP_W}>&- {RESP_ANCHOR}>&-
  readable $_zrush_worker_rfd || note "response EOF did not become readable"
  stop_until_done || note "readiness cleanup did not finalize after both predicates"
  eq "quarantine finalized" $_zrush_worker_stopping 0
  eq "response fd finalized" $_zrush_worker_rfd -1
  command rm -f $REQ_FIFO $RESP_FIFO $GATE_FIFO
  verdict "quarantine: one deadline, unacked EPIPE gate, and response EOF prevent replay/replacement"

  # ------------------------------------ healthy request EOF + 8 MiB raw drain
  reset_transport
  export ZRUSH_REAL_BIN=$REAL_BIN
  export ZRUSH_FAKE_CONTROL=$WORK/fake-control ZRUSH_FAKE_STATE=$WORK/fake-state
  : >| $ZRUSH_FAKE_STATE
  print -r -- drain >| $ZRUSH_FAKE_CONTROL
  ZRUSH_BIN=$FAKE_BIN
  start_ready || note "fake drain worker did not reach ready"
  typeset -gi old_shutdown_ms=$_ZRUSH_WORKER_SHUTDOWN_MS
  # Isolate the successful raw-drain path from scheduler/disk variance. The
  # preceding quarantine case separately pins the one-deadline behavior.
  _ZRUSH_WORKER_SHUTDOWN_MS=5000
  _zrush_worker_shutdown; typeset -gi drain_st=$?
  _ZRUSH_WORKER_SHUTDOWN_MS=$old_shutdown_ms
  typeset -g fake_state=$(<$ZRUSH_FAKE_STATE)
  eq "healthy raw-drain status" $drain_st 0
  [[ $fake_state == *$'eof 1\ntail 1 8388608\nexit 1'* ]] || note "fake worker did not observe EOF/tail/exit order"
  eq "raw-drain response EOF" $_zrush_worker_rfd -1
  eq "healthy control retained until completion then closed" $_zrush_worker_control_wfd -1
  eq "healthy gate finalized" $_zrush_worker_stopping 0
  verdict "healthy: request EOF drains 8 MiB raw stdout through response EOF"

  # ----------------------------------------------------- SIGPIPE-safe abort
  reset_transport
  typeset -g PIPE_FIFO=$WORK/sigpipe.fifo
  command mkfifo $PIPE_FIFO
  typeset -gi PIPE_ANCHOR PIPE_R
  sysopen -rw -o cloexec -u PIPE_ANCHOR $PIPE_FIFO
  sysopen -r -o cloexec -u PIPE_R $PIPE_FIFO
  sysopen -w -o cloexec -u _zrush_worker_control_wfd $PIPE_FIFO
  exec {PIPE_R}>&- {PIPE_ANCHOR}>&-
  exec {_zrush_worker_rfd}< /dev/null
  exec {_zrush_worker_wfd}> /dev/null
  _zrush_worker_abort $(( EPOCHREALTIME + 0.5 )); typeset -gi sigpipe_st=$?
  eq "SIGPIPE abort status" $sigpipe_st 0
  eq "SIGPIPE control closed" $_zrush_worker_control_wfd -1
  eq "SIGPIPE gate finalized" $_zrush_worker_stopping 0
  command rm -f $PIPE_FIFO
  verdict "abort: closed control reader cannot terminate the interactive shell"

  # ---------------------------- stopping branches + stale generation/fd reuse
  reset_transport
  typeset -gi STALE_FD STALE_READS=0 STALE_ACKS=0 STALE_STOPS=0
  exec {STALE_FD}< /dev/null
  _zrush_worker_rfd=$STALE_FD _zrush_worker_ack_fd=$STALE_FD _zrush_worker_drain_fd=$STALE_FD
  _zrush_worker_callback_generation=( data 201 ack 202 drain 203 )
  functions[_zrt_read]=$functions[_zrush_worker_read]
  functions[_zrt_ack]=$functions[_zrush_worker_consume_ack]
  functions[_zrt_progress]=$functions[_zrush_worker_stop_progress]
  _zrush_worker_read() { (( ++STALE_READS )); return 0 }
  _zrush_worker_consume_ack() { (( ++STALE_ACKS )); return 0 }
  _zrush_worker_stop_progress() { (( ++STALE_STOPS )); return 0 }
  _zrush_worker_stopping=1
  _zrush_worker_on_data $STALE_FD 201
  _zrush_worker_on_ack $STALE_FD 202
  eq "current stopping callbacks avoid normal reads" $STALE_READS 0
  eq "current stopping callbacks avoid normal ack consumption" $STALE_ACKS 0
  eq "current stopping callbacks enter stop progress" $STALE_STOPS 2
  STALE_STOPS=0
  _zrush_worker_stopping=0
  _zrush_worker_on_data $STALE_FD 200
  _zrush_worker_on_ack $STALE_FD 200
  _zrush_worker_on_drain $STALE_FD 200
  _zrush_worker_stopping=1
  _zrush_worker_on_data $STALE_FD 200
  _zrush_worker_on_ack $STALE_FD 200
  functions[_zrush_worker_read]=$functions[_zrt_read]
  functions[_zrush_worker_consume_ack]=$functions[_zrt_ack]
  functions[_zrush_worker_stop_progress]=$functions[_zrt_progress]
  unfunction _zrt_read _zrt_ack _zrt_progress
  eq "stale data/drain reads" $STALE_READS 0
  eq "stale ack consumes" $STALE_ACKS 0
  eq "stale stop progress" $STALE_STOPS 0
  [[ -e /dev/fd/$STALE_FD ]] || note "stale callback closed reused fd"
  _zrush_worker_rfd=-1 _zrush_worker_ack_fd=-1 _zrush_worker_drain_fd=-1
  exec {STALE_FD}>&-
  _zrush_worker_stopping=0
  verdict "callbacks: retained data/ack watchers branch on stopping and stale dispatch is inert"

  # ----------------------------------------- build-follow guard and reset split
  reset_transport
  ZRUSH_BIN=/definitely/not/invoked
  _zrush_enabled=1
  _zrush_follow_build test; typeset -gi follow_fail_st=$?
  eq "failed build follow status" $follow_fail_st 1
  eq "failed build follow stale disable" $_zrush_stale_disabled 1
  eq "failed build follow fault disable" $_zrush_disabled 0
  eq "failed build follow warning latch" $_zrush_build_warned 1
  eq "failed build follow warning count" $#WARNINGS 1
  _zrush_build_following=0
  typeset -g ZRUSH_NO_INIT=1
  source $REPO/zsh/zrush.zsh; typeset -gi stale_resource_st=$?
  unset ZRUSH_NO_INIT
  eq "explicit re-source after stale failure" $stale_resource_st 0
  eq "explicit re-source clears stale disable" $_zrush_stale_disabled 0
  _zrush_disabled=1 _zrush_disable_reason=session-failure _zrush_worker_failures=2 _zrush_build_following=1
  typeset -g ZRUSH_NO_INIT=1
  source $REPO/zsh/zrush.zsh; typeset -gi auto_fault_resource_st=$?
  unset ZRUSH_NO_INIT
  eq "automatic re-source with fault disable status" $auto_fault_resource_st 0
  eq "automatic re-source preserves fault disable" $_zrush_disabled 1
  eq "automatic re-source preserves fault counter" $_zrush_worker_failures 2
  _zrush_build_following=0
  _zrush_disabled=1 _zrush_disable_reason=session-failure
  typeset -g ZRUSH_NO_INIT=1
  source $REPO/zsh/zrush.zsh; typeset -gi fault_resource_st=$?
  unset ZRUSH_NO_INIT
  eq "fault-state test re-source status" $fault_resource_st 0
  eq "explicit re-source clears session-failure disable" $_zrush_disabled 0
  eq "explicit re-source clears session-failure reason" $_zrush_disable_reason ""
  eq "explicit re-source clears session-failure counter" $_zrush_worker_failures 0
  _zrush_disabled=1 _zrush_disable_reason=policy
  typeset -g ZRUSH_NO_INIT=1
  source $REPO/zsh/zrush.zsh; typeset -gi policy_resource_st=$?
  unset ZRUSH_NO_INIT
  eq "policy-state re-source status" $policy_resource_st 0
  eq "explicit re-source preserves policy disable" $_zrush_disabled 1
  eq "explicit re-source preserves policy reason" $_zrush_disable_reason policy
  _zrush_disabled=0 _zrush_disable_reason=
  verdict "build follow: explicit source clears only session-failure disable"

  # -------------------------------- config/re-source fail-fast during quarantine
  reset_transport
  _zrush_worker_runtime_prepare
  runtime=$_zrush_worker_runtime_dir
  _zrush_worker_stopping=1 _zrush_installed=1
  _zrush_worker_failures=7 _zrush_disabled=1 _zrush_disable_reason=session-failure _zrush_enabled=0
  typeset -g old_read_body=$functions[_zrush_worker_read]
  typeset -g old_runtime=$runtime
  ZRUSH_BIN=/definitely/not/invoked
  _zrush_load_config reload; typeset -gi config_st=$?
  typeset -g ZRUSH_NO_INIT=1
  source $REPO/zsh/zrush.zsh; typeset -gi resource_st=$?
  unset ZRUSH_NO_INIT
  eq "quarantined config status" $config_st 1
  eq "quarantined re-source status" $resource_st 1
  eq "stopping state preserved" $_zrush_worker_stopping 1
  eq "runtime preserved" $_zrush_worker_runtime_dir $old_runtime
  eq "functions preserved" "$functions[_zrush_worker_read]" "$old_read_body"
  eq "failure state preserved" $_zrush_worker_failures 7
  _zrush_worker_stopping=0 _zrush_installed=0
  _zrush_worker_runtime_destroy
  verdict "reload: config and re-source fail fast without retrying quarantine"

  # ----------------------------------------------------- exit + fd 0/1/2
  reset_transport
  ZRUSH_BIN=$REAL_BIN
  _zrush_worker_runtime_prepare
  runtime=$_zrush_worker_runtime_dir
  exec {saved0}<&0 {saved1}>&1 {saved2}>&2
  exec {_zrush_worker_rfd}< /dev/null
  exec {_zrush_worker_wfd}> /dev/null
  exec {_zrush_worker_control_wfd}> /dev/null
  typeset -gi exit_rfd=$_zrush_worker_rfd exit_wfd=$_zrush_worker_wfd exit_ctl=$_zrush_worker_control_wfd
  _zrush_zshexit
  [[ ! -e $runtime ]] || note "zshexit retained runtime paths"
  [[ ! -e /dev/fd/$exit_rfd && ! -e /dev/fd/$exit_wfd && ! -e /dev/fd/$exit_ctl ]] ||
    note "zshexit retained owned session fds"
  [[ /dev/fd/0 -ef /dev/fd/$saved0 && /dev/fd/1 -ef /dev/fd/$saved1 \
     && /dev/fd/2 -ef /dev/fd/$saved2 ]] || note "zshexit changed shell stdio"
  exec {saved0}>&- {saved1}>&- {saved2}>&-
  verdict "exit: owned endpoints/runtime close without touching fd 0/1/2"

  # ------------------------------------------------------------ job table
  reset_transport
  ZRUSH_BIN=$REAL_BIN
  start_ready || note "job-table worker did not reach ready"
  typeset -a job_ids=( ${(f)"$(jobs -p 2>/dev/null)"} )
  eq "interactive job table" $#job_ids 0
  _zrush_worker_shutdown || note "job-table worker did not stop cleanly"
  eq "job-table stop gate" $_zrush_worker_stopping 0
  verdict "job table: worker and delegated writers remain invisible"

  # ------------------------------------------- synchronous history read seam
  # The history exchange sends store + plan and ends on the plan's terminal
  # response; the store's is consumed on the way there (behavior.md "履歴メニュー").
  reset_transport
  _zrush_worker_ready=1
  _zrush_worker_pending=( 1 'store live 1' 2 'plan history 0' 3 'plan compsys 0' )
  _zrush_sync_target=2 _zrush_sync_done=0 _zrush_sync_ok=0
  _zrush_encode_message ok 1 ''; typeset -g STORE_OK=$REPLY
  _zrush_encode_message ok 2 $'\0'"0"$'\0'"0"$'\0'"0"$'\0'; typeset -g TARGET=$REPLY
  _zrush_encode_message error 3 invalid-request; typeset -g TRAILING=$REPLY
  _zrush_worker_rx=$STORE_OK$TARGET$TRAILING
  _zrush_worker_read sync $(( EPOCHREALTIME + 1.0 )); typeset -gi sync_st=$?
  eq "sync target status" $sync_st 0
  eq "store response consumed en route" ${+_zrush_worker_pending[1]} 0
  eq "sync target committed" "$_zrush_sync_done:$_zrush_sync_ok" 1:1
  eq "trailing response retained" "$_zrush_worker_rx" "$TRAILING"
  verdict "sync read: the store is consumed and the plan commits while trailing responses remain asynchronous"

  # A store whose ok carries a body does not satisfy the contract; the plan it
  # backs must never be applied on such a session.
  reset_transport
  _zrush_worker_ready=1
  _zrush_worker_pending=( 4 'store live 4' )
  typeset -g STORE_FAILURE=
  functions[_zrt_session_fail]=$functions[_zrush_worker_session_fail]
  _zrush_worker_session_fail() { STORE_FAILURE=$1; return 1 }
  _zrush_encode_message ok 4 'unexpected'
  _zrush_netstring_take "$REPLY"
  _zrush_worker_handle_message "$REPLY"; typeset -gi store_body_st=$?
  functions[_zrush_worker_session_fail]=$functions[_zrt_session_fail]
  unfunction _zrt_session_fail
  eq "store body status" $store_body_st 1
  [[ $STORE_FAILURE == 'store ok carries a body request_id=4' ]] ||
    note "unexpected store-body failure reason: ${STORE_FAILURE:-<none>}"
  eq "store body leaves the request pending" ${+_zrush_worker_pending[4]} 1
  verdict "sync read: a store ok with a body ends the session"

  reset_transport
  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  (( $+functions[reset_transport] )) && reset_transport
  [[ -n $WORK && $WORK == */zrush-transport.* ]] && command rm -rf $WORK
}
(( FAIL == 0 ))
