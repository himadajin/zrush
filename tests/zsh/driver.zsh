#!/bin/zsh -f
# Headless zle-integration smoke driver for zrush.zsh.
#
# Usage:
#   zsh -f tests/zsh/driver.zsh <playground-dir> [section ...]
#     The playground only needs to exist and be writable; it is used as an
#     isolated $HOME. Every fixture this driver needs (a small file/directory
#     tree and a large generated one) is created under $PLAYGROUND/fx by this
#     script -- no pre-populated docs tree or external "huge" directory is
#     required.
#     With no section arguments every section runs. Naming sections runs just
#     those, always in the canonical order of the SECTIONS array below (host
#     startup and its baseline checks run regardless). Each section owns its
#     prerequisites and starts from a clean prompt, so any subset is valid.
#   Prerequisite: the zrush binary has been built with cargo build --release.
#
# Failure evidence: when any check fails or is skipped (or ZRUSH_DRIVER_KEEP
# is set), $WORK is kept and its path plus a tail of the active ZRUSH_LOG are
# printed, instead of the silent cleanup a green run performs.
#
# Scope (docs/internal/contracts/cli-protocol.md and behavior.md are the
# source of truth for everything below): matching, ranking, grid layout,
# highlight/nav-table computation, and insertion-text construction all live
# in Rust and are covered by `cargo test`. This driver only smoke-tests what
# Rust cannot verify: that the real zle/compsys integration captures
# candidates, ships them to the persistent Rust worker, and applies its plan to
# POSTDISPLAY/region_highlight/BUFFER correctly under real key input.
#
# Harness (shared with driver-coexist.zsh/driver-latency.zsh):
#   - Start an interactive host zsh with nonblocking zpty -b, send keys, and inspect
#     both pty output and the ZRUSH_LOG file (including the ^Xw/^Xj/^Xg/^Xf
#     test-only dump widgets registered by rc/minimal.zshrc).
#   - Always drain the pty in wait loops to prevent tcsetattr TCSADRAIN blocking.
#     Draining never hides output from a later expect: EXPECT_BUF holds
#     everything the host has emitted since the last input we sent it.
#   - Listing renders are synchronized on ZRUSH_LOG "plan: applied" lines
#     (send_keys_wait_plan), never on candidate text reaching the pty: the pty
#     byte stream is zle's own encoding (diff redraw, highlight splitting,
#     terminfo padding), so a listing word is not guaranteed to survive in it
#     contiguously (#64). The few expect calls that do assert listing text
#     assert exactly terminal delivery, with SGR sequences and their padding
#     normalized away (buf_has).
#   - After executing a command, synchronize on the HP> prompt before sending more keys.
emulate -L zsh
setopt extended_glob
zmodload zsh/zpty    || { print -u2 FATAL: zpty; exit 1 }
zmodload zsh/zselect || { print -u2 FATAL: zselect; exit 1 }
zmodload zsh/system  || { print -u2 FATAL: system; exit 1 }

typeset -F SECONDS
typeset -g HERE=${${(%):-%N}:A:h}
typeset -g REPO=${HERE:h:h}
typeset -g PLAYGROUND=${1:?usage: driver.zsh <playground-dir> [section ...]}
[[ -d $PLAYGROUND ]] || { print -u2 "FATAL: invalid playground: $PLAYGROUND"; exit 1 }

# Canonical execution order of the test sections. Any sections named on the
# command line run in this order, never in argument order; an empty selection
# means every section.
typeset -ga SECTIONS=( jobtable inflight )
typeset -gA PICKED=()
for SECTION_ARG in "${@[2,-1]}"; do
  (( ${SECTIONS[(I)$SECTION_ARG]} )) || { print -u2 "FATAL: unknown section '$SECTION_ARG' (valid: $SECTIONS)"; exit 1 }
  PICKED[$SECTION_ARG]=1
done
unset SECTION_ARG

[[ -x $REPO/target/release/zrush ]] || { print -u2 "FATAL: zrush binary not found (cargo build --release)"; exit 1 }
[[ $REPO/zsh/zrush.zsh -nt $REPO/target/release/zrush ]] && { print -u2 "FATAL: zsh/zrush.zsh is newer than the built binary; run cargo build --release"; exit 1 }

typeset -gi PASS=0 FAIL=0
# Report through a private duplicate of stderr, not fd 2 itself: the final
# `zpty -d host 2>/dev/null` in the always block below does not get its fd 2
# restored (the zpty module closes the descriptor zsh stashed the real stderr
# in), so anything printed to fd 2 after it -- exactly this driver's failure
# evidence -- would silently go to /dev/null.
typeset -gi ERRFD=-1
exec {ERRFD}>&2
out() { print -r -u $ERRFD -- "$@" }
ok()  { out "PASS: $1"; (( ++PASS )) }
ng()  { out "FAIL: $1"; (( ++FAIL )) }
# SKIP: a check this environment could not run; OBSV: a non-failing observation.
typeset -gi SKIP=0 OBSV=0
obsv() { out "OBSV: $1"; (( ++OBSV )) }

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-test.XXXXXX)
export TERM=vt100
# zsh links the vi keymap to main when $VISUAL/$EDITOR contains "vi"; the host
# keys this driver sends (^U, ^P, ^V, ...) are emacs-keymap bindings, so the
# invoking environment must not decide which keymap the host gets.
unset EDITOR VISUAL
# Match POSTDISPLAY printability checks to real UTF-8 use. Minimal Linux
# images commonly provide only C.UTF-8/C.utf8, while macOS provides
# en_US.UTF-8; select the first locale this host actually accepts.
typeset -g DRIVER_UTF8_LOCALE=
for DRIVER_UTF8_LOCALE in en_US.UTF-8 C.UTF-8 C.utf8; do
  LC_ALL=$DRIVER_UTF8_LOCALE command locale charmap >/dev/null 2>&1 && break
done
LC_ALL=$DRIVER_UTF8_LOCALE command locale charmap >/dev/null 2>&1 || DRIVER_UTF8_LOCALE=C
export LC_ALL=$DRIVER_UTF8_LOCALE
export HOME=$PLAYGROUND     # isolated; never the real home
export ZRUSH_TEST_TMP=$WORK
export ZDOTDIR=$WORK/zdot
export XDG_CONFIG_HOME=$WORK/xdg   # no config.toml is written: every test runs on defaults
export ZRUSH_LOG=$WORK/host.log
mkdir -p $ZDOTDIR $XDG_CONFIG_HOME/zrush

# A test launcher delegates to the real binary unless its isolated control
# file requests an active-session failure mode.
mkdir -p $WORK/bin
cp $REPO/tests/zsh/fake-worker.py $WORK/bin/zrush
chmod +x $WORK/bin/zrush
export ZRUSH_BIN=$WORK/bin/zrush
export ZRUSH_REAL_BIN=$REPO/target/release/zrush
export ZRUSH_FAKE_CONTROL=$WORK/fake-control
export ZRUSH_FAKE_STATE=$WORK/fake-state

print "source $REPO/tests/zsh/rc/minimal.zshrc" > $ZDOTDIR/.zshrc

# ---------------------------------------------------------------- Fixtures
# fx/basic: two candidates sharing a prefix (for match-highlight/selection
# tests) plus a subdirectory (for '/' synthesis on confirm).
mkdir -p $PLAYGROUND/fx/basic/subdir
: >| $PLAYGROUND/fx/basic/alpha.txt
: >| $PLAYGROUND/fx/basic/alsoalpha.txt
: >| $PLAYGROUND/fx/basic/subdir/inner.txt

# fx/overflow: enough entries that a single compsys capture's candidate_payload
# comfortably exceeds the request-FIFO buffer on either platform this driver
# runs on -- 8192 bytes on macOS, 65536 on Linux (behavior.md worker-lifecycle
# "フレームは不可分な送信単位") -- regardless of what this playground happens to
# already contain. 0000-marker.txt sorts before every item-*.txt entry (macOS
# default glob order), so it is always the first candidate and lands in the
# rendered listing no matter how the grid clips. This many entries put the
# frame around 112 KB, i.e. ~1.7x the larger of the two capacities. The entries
# are created in a loop rather than one touch(1) call: that many absolute paths
# can outgrow ARG_MAX for a deeply nested playground.
mkdir -p $PLAYGROUND/fx/overflow
: >| $PLAYGROUND/fx/overflow/0000-marker.txt
for OVERFLOW_ITEM in $PLAYGROUND/fx/overflow/item-{0001..7000}.txt; do : >| $OVERFLOW_ITEM; done
unset OVERFLOW_ITEM

typeset -gi HOSTFD=-1
typeset -g TRANSCRIPT= EXPECT_BUF= STDIO_BASELINE=

# EXPECT_BUF is the observation window: everything the host has emitted since
# the last input we sent it. Sending input (and adopting a new host's fd) is
# the only thing that opens a fresh window, so output that an intervening
# drain happened to read is still there for a later expect to match.
send_line() { EXPECT_BUF=; zpty -w  host $1 }
send_keys() { EXPECT_BUF=; zpty -wn host $1 }

buf_has() {  # $1=glob -> 0 when EXPECT_BUF already satisfies it
  # Match the raw bytes, then again with SGR sequences stripped: highlighting
  # can split a word the pattern expects to be contiguous. Each SGR is
  # stripped together with the NUL run some platforms emit after it (terminfo
  # padding, #64); unrelated literal NULs are left alone.
  [[ $EXPECT_BUF == ${~1} || ${EXPECT_BUF//$'\e['[0-9;]#m$'\0'#/} == ${~1} ]]
}

expect() {  # $1=glob $2=timeout(s)
  local pat=$1
  local -F deadline=$(( SECONDS + ${2:-10} ))
  buf_has "$pat" && return 0
  local chunk
  while (( SECONDS < deadline )); do
    if zselect -t 20 -r $HOSTFD 2>/dev/null; then
      zpty -r host chunk 2>/dev/null || return 2
      EXPECT_BUF+=$chunk
      TRANSCRIPT+=$chunk
      buf_has "$pat" && return 0
    fi
  done
  return 1
}

drain() {  # $1=seconds to wait while reading the pty
  local -F dl=$(( SECONDS + ${1:-0.2} ))
  local chunk
  while (( SECONDS < dl )); do
    if zselect -t 10 -r $HOSTFD 2>/dev/null; then
      zpty -r host chunk 2>/dev/null && { TRANSCRIPT+=$chunk; EXPECT_BUF+=$chunk }
    fi
  done
}

clear_line() { send_keys $'\C-u'; drain 0.2 }
sync_prompt() {  # $1=timeout(s); returns expect's status (drain still always runs)
  expect '*HP>*' ${1:-5} >/dev/null
  local -i st=$?
  drain 0.1
  return st
}

log_count() {  # $1=fixed string -> REPLY: occurrence count in ZRUSH_LOG
  typeset -g REPLY=0
  [[ -r $ZRUSH_LOG ]] && REPLY=$(grep -cF -- $1 $ZRUSH_LOG 2>/dev/null)
  return 0
}

wait_log() {  # $1=fixed string $2=baseline $3=timeout(s) -> 0 when count increases
  local -F dl=$(( SECONDS + ${3:-5} ))
  while (( SECONDS < dl )); do
    drain 0.15
    log_count $1
    (( REPLY > $2 )) && return 0
  done
  return 1
}

# Send keys and wait for the render plan they provoke to be applied: a NEW
# "plan: applied" ZRUSH_LOG line (written by _zrush_apply_plan right after the
# plan reaches POSTDISPLAY/region_highlight state) of the required shape --
# "zero" for the empty plan (its log line is always the fixed "L=0 P=0"),
# "nonempty" for a listing with selectable positions. This is the only
# listing-render synchronization: candidate text reaching the pty is not
# waited on (see the header note and #64). A timeout is reported immediately;
# a silent one would be exactly the do-nothing wait this helper replaces.
send_keys_wait_plan() {  # $1=zero|nonempty $2=keys $3=timeout(s)
  local shape=$1 keys=$2 caller=${funcfiletrace[1]}
  [[ $shape == (zero|nonempty) ]] || { ng "send_keys_wait_plan: bad shape ${(qqqq)shape} ($caller)"; return 2 }
  local -i base_all=$(grep -cF 'plan: applied' $ZRUSH_LOG 2>/dev/null)
  local -i base_zero=$(grep -cF 'plan: applied L=0 P=0' $ZRUSH_LOG 2>/dev/null)
  send_keys $keys
  local -F dl=$(( SECONDS + ${3:-10} ))
  local -i all zero
  while (( SECONDS < dl )); do
    drain 0.15
    all=$(grep -cF 'plan: applied' $ZRUSH_LOG 2>/dev/null)
    zero=$(grep -cF 'plan: applied L=0 P=0' $ZRUSH_LOG 2>/dev/null)
    case $shape in
      zero)     (( zero > base_zero )) && return 0 ;;
      nonempty) (( all - zero > base_all - base_zero )) && return 0 ;;
    esac
  done
  ng "send_keys_wait_plan: no $shape plan after ${(qqqq)keys} ($caller)"
  return 1
}

fake_count() {  # $1=fixed state line -> REPLY=count
  typeset -g REPLY=0
  [[ -r $ZRUSH_FAKE_STATE ]] && REPLY=$(grep -cF -- "$1" $ZRUSH_FAKE_STATE 2>/dev/null)
  return 0
}

fake_session_count() {  # -> REPLY=number of fake worker sessions created
  typeset -g REPLY=0
  [[ -r $ZRUSH_FAKE_STATE.count ]] &&
    REPLY=$(command cat $ZRUSH_FAKE_STATE.count 2>/dev/null)
  [[ $REPLY == <-> ]] || REPLY=0
}

worker_state_has() {  # $1=TESTWORKER value, remaining args=exact fields
  local state=$1 field
  shift
  for field in "$@"; do
    [[ " $state " == *" $field "* ]] || return 1
  done
  return 0
}

wait_fake() {  # $1=fixed state line $2=baseline $3=timeout
  local -F dl=$(( SECONDS + ${3:-5} ))
  while (( SECONDS < dl )); do
    drain 0.1
    fake_count "$1"
    (( REPLY > $2 )) && return 0
  done
  return 1
}

# Trigger a ^X* dump widget and return the freshest matching ZRUSH_LOG line's
# value (post-tag text) in REPLY. $1=dump key-sequence $2=log tag.
# Waits for the tag's occurrence count to grow past its pre-press value, so a
# line left behind by an earlier dump of the same tag can never satisfy the
# wait. The key is re-sent once per second within the deadline: a keystroke
# that lands while the host is still unwinding a pty-level interrupt
# (send-break) can be consumed without running its widget (#47), and every
# dump widget is a pure observer, so an extra press is harmless.
dump_get() {
  local key=$1 tag=$2
  log_count "$tag="; local -i base=$REPLY
  typeset -g REPLY=
  local -a tl
  local -F dl=$(( SECONDS + 8 ))
  while (( SECONDS < dl )); do
    send_keys $key
    if wait_log "$tag=" $base 1; then
      tl=( ${(f)"$(grep -F "$tag=" $ZRUSH_LOG 2>/dev/null)"} )
      typeset -g REPLY=${tl[-1]#*$tag=}
      return 0
    fi
  done
  typeset -g REPLY=   # wait_log left its counter here; failure means "no value"
  return 1
}

assert_host_stdio() {  # $1=label; compare fd targets and stdout/stderr delivery
  local label=$1
  log_count 'TESTSTDIO='; local -i baseline=$REPLY
  send_keys $'\C-xf'
  if ! wait_log 'TESTSTDIO=' $baseline 5; then
    ng "$label: stdio probe did not run"
    return 1
  fi
  drain 0.2
  local -a lines=( "${(@f)"$(grep -F 'TESTSTDIO=' $ZRUSH_LOG 2>/dev/null)"}" )
  local latest=${lines[-1]#*TESTSTDIO=}
  local signature=${latest#*fds=}
  local visible=${EXPECT_BUF//$'\e['[0-9;]#m/}
  [[ -n $STDIO_BASELINE ]] || STDIO_BASELINE=$signature
  if [[ $signature == "$STDIO_BASELINE" \
        && $visible == *ZRUSH-STDOUT-SENTINEL* \
        && $visible == *ZRUSH-STDERR-SENTINEL* ]]; then
    ok "$label"
    return 0
  fi
  ng "$label: fds=${signature:-<none>} baseline=${STDIO_BASELINE:-<none>} output=${(qqqq)visible}"
  return 1
}

# Stop whatever is running as the "host" pty and start a fresh one under a
# given ZDOTDIR/XDG_CONFIG_HOME/log file. sec_jobtable and sec_inflight each
# need a host of their own, because each lets its host exit for real.
start_host() {  # $1=zdotdir $2=xdg-config-home $3=logfile
  zpty -d host 2>/dev/null
  export ZDOTDIR=$1 XDG_CONFIG_HOME=$2 ZRUSH_LOG=$3
  cd $PLAYGROUND || return 1
  local REPLY=
  zpty -b host zsh -d -i || return 1
  HOSTFD=$REPLY
  EXPECT_BUF=
  expect '*MARK-RC-DONE*' 20 || return 1
  drain 0.3
  return 0
}

sec_boot() {
  # ---------------- Host startup ----------------
  cd $PLAYGROUND || exit 1
  local REPLY=
  zpty -b host zsh -d -i || { ng "host failed to start"; exit 1 }
  HOSTFD=$REPLY
  EXPECT_BUF=
  if expect '*MARK-RC-DONE*' 20; then
    ok "host started + compinit + zrush.zsh sourced (config loaded)"
  else
    ng "unable to confirm host startup: ${(qqqq)EXPECT_BUF[-300,-1]}"
    exit 1
  fi
  sync_prompt

  # The Rust worker is lazy: sourcing/config validation alone must not start it.
  if dump_get $'\C-xw' TESTWORKER \
     && worker_state_has "$REPLY" ready=0 seq=0 stopping=0 tainted=0 rfd=-1 wfd=-1 control=-1 ack=-1; then
    ok "(worker-1a) source/config leaves the persistent worker stopped"
  else
    ng "(worker-1a) worker was not lazy: ${REPLY:-<none>}"
  fi
  assert_host_stdio "(fd-1a) source leaves host fd 0/1/2 attached and writable"

  if dump_get $'\C-xj' TESTAUX \
     && [[ $REPLY == 'closed=1 ack=-1 drain=-1 timer=-1' ]]; then
    ok "(fd-1b) timer/ack/drain descriptors close through shared teardown"
  else
    ng "(fd-1b) auxiliary fd teardown mismatch: ${REPLY:-<none>}"
  fi
  assert_host_stdio "(fd-1c) timer/ack/drain teardown preserves host fd 0/1/2"

  # Register a production-generated drain wrapper from a widget, then return
  # to the real ZLE event loop. Only readiness dispatch through zle -F can
  # reach the temporary read seam and emit TESTGENERATED=dispatched.
  log_count 'TESTGENERATED=dispatched'; local -i generated0=$REPLY
  send_keys $'\C-xg'
  local -i generated_ok=1
  wait_log 'TESTGENERATED=dispatched' $generated0 5 || generated_ok=0
  local generated_line=$(grep -F 'TESTGENERATED=dispatched' $ZRUSH_LOG 2>/dev/null | tail -1)
  local generated_value=${${generated_line#*generation=}%% *}
  if (( generated_ok )) && [[ $generated_value == <-> ]] \
     && worker_state_has "$generated_line" kind=drain current=0 drain=-1 handler_live=0 widget_live=0 \
     && dump_get $'\C-xw' TESTWORKER \
     && worker_state_has "$REPLY" ready=0 stopping=0 tainted=0 rfd=-1 wfd=-1 control=-1 ack=-1; then
    ok "(worker-callback) generated zle -F handler dispatches readiness and self-invalidates"
  else
    ng "(worker-callback) generated handler did not progress/clean up: line=${generated_line:-<none>} state=${REPLY:-<none>}"
    send_keys $'\C-xG'
    drain 0.2
  fi
  assert_host_stdio "(fd-1d) generated callback dispatch preserves host fd 0/1/2"
}

sec_jobtable() {
  # ================================================================ Worker job-table isolation
  # This host must exit during the assertion, so give it dedicated rc/config/log
  # state rather than reusing any host needed by the preceding cases.
  mkdir -p $WORK/zdot-exit $WORK/xdg-exit/zrush
  print "source $REPO/tests/zsh/rc/minimal.zshrc" > $WORK/zdot-exit/.zshrc
  if start_host $WORK/zdot-exit $WORK/xdg-exit $WORK/host-exit.log; then
    send_line '[[ -o checkjobs && -o checkrunningjobs ]] && print CHECK-JOBS-ENABLED'
    if expect '*CHECK-JOBS-ENABLED*HP>*' 5; then
      fake_session_count; local -i exit_session=$(( REPLY + 1 ))
      # Job-table behavior does not require the separate 8 MiB raw-drain
      # stressor. A small terminal response keeps this case focused on one
      # `exit`, while zshexit remains free to stop waiting at its fixed deadline.
      print -r -- error > $ZRUSH_FAKE_CONTROL
      fake_count "error $exit_session "; local -i exit_request0=$REPLY
      log_count 'worker: error request_id='; local -i exit_error0=$REPLY
      send_keys 'ls fx/basic/al'
      if wait_fake "error $exit_session " $exit_request0 10 \
         && wait_log 'worker: error request_id=' $exit_error0 10 \
         && dump_get $'\C-xw' TESTWORKER \
         && worker_state_has "$REPLY" ready=1 stopping=0; then
        clear_line
        drain 0.3
        local -F exit_deadline=$(( SECONDS + 5 ))
        local -i exit_eof=0 exit_read_status=0
        local exit_output= exit_chunk=
        send_line exit
        while (( SECONDS < exit_deadline )); do
          if zselect -t 20 -r $HOSTFD 2>/dev/null; then
            exit_chunk=
            zpty -r host exit_chunk 2>/dev/null; exit_read_status=$?
            (( exit_read_status == 0 )) && exit_output+=$exit_chunk
            if (( exit_read_status == 2 )); then
              exit_eof=1
              break
            fi
          fi
        done
        local visible_exit_output=${exit_output//$'\e['[0-9;]#m/}
        if (( exit_eof )) \
           && [[ $visible_exit_output != *'zsh: you have running jobs.'* \
                 && $visible_exit_output != *'Terminated'* \
                 && $visible_exit_output != *'Done'* ]]; then
          ok "(worker-job-table) one exit terminates without job-control output"
        else
          ng "(worker-job-table) exit did not terminate cleanly: eof=$exit_eof output=${(qqqq)visible_exit_output}"
        fi
      else
        ng "(worker-job-table) dedicated host did not start its worker: ${REPLY:-<none>}"
      fi
    else
      ng "(worker-job-table) dedicated host did not enable CHECK_JOBS and CHECK_RUNNING_JOBS"
    fi
  else
    ng "(worker-job-table) dedicated exit host failed to start"
  fi
  print -r -- proxy > $ZRUSH_FAKE_CONTROL
}

sec_inflight() {
  # ================================================================ Teardown while a frame is in flight
  # Dedicated host (same exit pattern as "Worker job-table isolation" above)
  # so exiting mid-request doesn't disturb any other case. fx/overflow (added
  # above for (fifo-1a/b)) makes the writer child's single syswrite take long
  # enough to plausibly still be delegated -- unacked, possibly still writing
  # -- when we tear down; (inflight-1c) reports (OBSV, non-failing) whether
  # this run actually won that race, since the exact window isn't guaranteed.
  #
  # The previous case just let its own dedicated "host" pty session exit for
  # real (as opposed to every other transition in this driver, which deletes
  # a still-live session via `zpty -d host`). start_host always issues
  # its own `zpty -d host 2>/dev/null` before spawning anew; issuing that
  # exact call -- with stderr redirected -- as the *first* deletion of an
  # already-dead real-worker session reproducibly kills this outer zsh
  # process outright (a zpty/job-control interaction, not a zrush bug).
  # Reaping it here first, without redirecting stderr, avoids the crash;
  # start_host's own redundant delete of the now-already-gone session
  # is then a harmless no-op.
  print -r -- proxy > $ZRUSH_FAKE_CONTROL
  zpty -d host
  mkdir -p $WORK/zdot-inflight $WORK/xdg-inflight/zrush
  print "source $REPO/tests/zsh/rc/minimal.zshrc" > $WORK/zdot-inflight/.zshrc
  if start_host $WORK/zdot-inflight $WORK/xdg-inflight $WORK/host-inflight.log; then
    send_line '[[ -o checkjobs && -o checkrunningjobs ]] && print CHECK-JOBS-ENABLED'
    if expect '*CHECK-JOBS-ENABLED*HP>*' 5; then
      # Warm the persistent worker up on a small request first so handshake/
      # startup latency cannot masquerade as "frame in flight" below.
      send_keys_wait_plan nonempty 'ls fx/basic/al'
      clear_line
      drain 0.3
      log_count 'worker: sending frame'; local -i inflight_sending_before=$REPLY
      log_count 'worker: frame sent'; local -i inflight_sent_before=$REPLY
      send_keys 'ls fx/overflow/'
      if wait_log 'worker: sending frame' $inflight_sending_before 15; then
        local inflight_sending_line=$(grep -F 'worker: sending frame' $ZRUSH_LOG 2>/dev/null | tail -1)
        local -i inflight_ack_fd=${${inflight_sending_line##*ackfd=}%% *}
        log_count 'worker: frame sent'; local -i inflight_sent_at_dispatch=$REPLY
        # No drain here: the whole point is to tear down as close as possible
        # to the writer-child spawn, before its ack can land. ^U
        # (kill-whole-line) only discards the still-uncommitted
        # 'ls fx/overflow/' buffer text so that `exit` runs on an empty line;
        # the capture already finished -- that's how the frame got queued --
        # and an empty buffer collects nothing (behavior.md 候補収集), so no
        # new request races the exit. The transport is untouched until the
        # zshexit hook begins healthy shutdown.
        #
        # ^C would clear the buffer just as well but must not be used here:
        # zsh 5.9 defers a SIGINT that arrives while a `zle -F` watcher
        # callback is running -- precisely the window this case aims at --
        # until the next input byte, and the deferred send-break then swallows
        # that byte, eating the 'e' of the following `exit`. kill-whole-line
        # is a plain widget keystroke with no such hazard.
        send_keys $'\C-u'
        send_line exit
        local -F inflight_exit_deadline=$(( SECONDS + 5 ))
        local -i inflight_exit_eof=0 inflight_exit_status=0
        local inflight_exit_output= inflight_exit_chunk=
        while (( SECONDS < inflight_exit_deadline )); do
          if zselect -t 20 -r $HOSTFD 2>/dev/null; then
            inflight_exit_chunk=
            zpty -r host inflight_exit_chunk 2>/dev/null; inflight_exit_status=$?
            (( inflight_exit_status == 0 )) && inflight_exit_output+=$inflight_exit_chunk
            if (( inflight_exit_status == 2 )); then
              inflight_exit_eof=1
              break
            fi
          fi
        done
        local inflight_visible_output=${inflight_exit_output//$'\e['[0-9;]#m/}
        if (( inflight_exit_eof )) \
           && [[ $inflight_visible_output != *'zsh: you have running jobs.'* ]] \
           && [[ $inflight_visible_output != *'Terminated'* && $inflight_visible_output != *'Done'* ]]; then
          ok "(inflight-1a) exit while the writer child is still delegated produces no job-control output"
        else
          ng "(inflight-1a) job-control output leaked during in-flight teardown: eof=$inflight_exit_eof output=${(qqqq)inflight_visible_output}"
        fi
        if (( inflight_ack_fd > 2 )) && [[ $inflight_sending_line != *'writer_pid='* ]]; then
          ok "(inflight-1b) delegated writer is tracked only by its ack transport slot"
        else
          ng "(inflight-1b) missing PID-free ack slot in: ${inflight_sending_line:-<none>}"
        fi
        if (( inflight_sent_at_dispatch == inflight_sent_before )); then
          obsv "(inflight-1c) teardown was dispatched before this frame's ack was consumed (writer child genuinely still delegated)"
        else
          obsv "(inflight-1c) this frame's ack had already landed before teardown; (inflight-1a/b) still ran but not against a strictly unacked frame"
        fi
      else
        ng "(inflight-1) dedicated host never delegated a writer child for the overflow request"
      fi
    else
      ng "(inflight-1) dedicated host did not enable CHECK_JOBS and CHECK_RUNNING_JOBS"
    fi
  else
    ng "(inflight-1) dedicated in-flight-teardown host failed to start"
  fi
}

# Host startup always runs; every other section runs only when it was named
# on the command line (or when nothing was named), in canonical order.
{
  sec_boot
  local s
  for s in $SECTIONS; do
    (( $#PICKED == 0 || ${+PICKED[$s]} )) && sec_$s
  done
  out "SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP OBSV=$OBSV"
} always {
  zpty -d host 2>/dev/null
  # Anything short of a fully green run keeps its evidence: the work directory
  # (host logs, fake-worker state) and a tail of the log the run ended on.
  if (( FAIL || SKIP )) || [[ -n $ZRUSH_DRIVER_KEEP ]]; then
    out "kept: $WORK"
    typeset -a KEPT_LOGS=( $WORK/host*.log(N) )
    (( $#KEPT_LOGS )) && out "logs: $KEPT_LOGS"
    if [[ -r $ZRUSH_LOG ]]; then
      out "---- tail -80 $ZRUSH_LOG ----"
      tail -n 80 -- $ZRUSH_LOG >&$ERRFD
      out "---- end of $ZRUSH_LOG ----"
    fi
  else
    [[ -n $WORK && $WORK == */zrush-test.* ]] && rm -rf $WORK
  fi
}
(( FAIL == 0 ))
