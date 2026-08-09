#!/bin/zsh -f
# Headless zle-integration smoke driver for zrush.zsh.
#
# Usage:
#   zsh -f tests/zsh/driver.zsh <playground-dir> [section ...]
#     The playground only needs to exist and be writable; it is used as an
#     isolated $HOME. Every fixture this driver needs (small file/directory
#     trees, a filename containing a space, a slow fake completion) is
#     created under $PLAYGROUND/fx by this script -- no pre-populated docs
#     tree or external "huge" directory is required.
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
#     both pty output and the ZRUSH_LOG file (including the ^Xb/^Xp/^Xh test-only
#     dump widgets registered by rc/minimal.zshrc).
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
typeset -ga SECTIONS=( capture death hist jobtable inflight )
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
typeset -gi FAKE_DRAIN_TAIL_BYTES=8388608
# Test seam: 5000 ms matches the driver's other bounded waits.
export ZRUSH_HISTORY_DEADLINE_MS=5000

print "source $REPO/tests/zsh/rc/minimal.zshrc" > $ZDOTDIR/.zshrc

# ---------------------------------------------------------------- Fixtures
# fx/basic: two candidates sharing a prefix (for match-highlight/selection
# tests) plus a subdirectory (for '/' synthesis on confirm).
mkdir -p $PLAYGROUND/fx/basic/subdir
: >| $PLAYGROUND/fx/basic/alpha.txt
: >| $PLAYGROUND/fx/basic/alsoalpha.txt
: >| $PLAYGROUND/fx/basic/subdir/inner.txt

# fx/spacey: a filename whose quoted (w) and raw (m) forms differ.
mkdir -p $PLAYGROUND/fx/spacey
: >| $PLAYGROUND/fx/spacey/"has space.txt"

# fx/hidden: dot-prefixed entries next to a visible one. The names share the
# "dotted" stem so a dotless listing can be checked for their absence.
mkdir -p $PLAYGROUND/fx/hidden
: >| $PLAYGROUND/fx/hidden/.dotted-alpha.txt
: >| $PLAYGROUND/fx/hidden/.dotted-beta.txt
: >| $PLAYGROUND/fx/hidden/visible.txt

# fx/headed: a plain file so _files' "file" tag heading appears in the plan.
mkdir -p $PLAYGROUND/fx/headed
: >| $PLAYGROUND/fx/headed/plainfile.txt

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
press() { send_keys $1; drain 0.3 }

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

# Wait until asynchronous worker-stop cleanup reaches an exact observable
# state. Session failure is logged before the fixed 100 ms lifecycle budget has
# necessarily reached response EOF, so a following request must not use that
# log line alone as evidence that replacement is allowed.
wait_worker_state() {  # $1=timeout(s), remaining args=exact TESTWORKER fields
  local -F dl=$(( SECONDS + $1 ))
  shift
  local state=
  while (( SECONDS < dl )); do
    if dump_get $'\C-xw' TESTWORKER; then
      state=$REPLY
      worker_state_has "$state" "$@" && return 0
    fi
    drain 0.1
  done
  typeset -g REPLY=$state
  return 1
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

# Compare an exact ^Xb BUFFER dump against an expected string.
assert_buffer() {  # $1=expected buffer $2=label
  local expected=$1 want=${(qqqq)1}
  send_keys $'\C-xb'
  local -F dl=$(( SECONDS + 5 ))
  local last=
  local -a tl
  while (( SECONDS < dl )); do
    drain 0.15
    tl=( ${(f)"$(grep -F 'TESTBUF=' $ZRUSH_LOG 2>/dev/null)"} )
    (( $#tl )) && last=${tl[-1]#*TESTBUF=}
    [[ ${(Q)last} == "$expected" ]] && { ok "$2"; return 0 }
  done
  ng "$2: buffer=${last:-?} want=$want"
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

# A send-break reset for scenarios that can leave a multiline BUFFER: ^U
# (backward-kill-line) only clears the current physical line of a multiline
# buffer, so those scenarios need a real line abandon + resync instead.
# The generous bound matches the other send-break sites: a loaded host has
# been observed to spend >5s inside pty-^C interrupt handling before the new
# prompt appears (#47). A resync that never happens leaves every following
# case running against a desynced host, so it is reported rather than dropped.
reset_line() {
  send_keys $'\C-c'
  drain 0.3
  sync_prompt 15 || ng "reset_line: no prompt after send-break"
}

# Stop whatever is running as the "host" pty and start a fresh one under a
# given ZDOTDIR/XDG_CONFIG_HOME/log file. Used by the history-menu section
# below, which needs several isolated hosts (a default-config one plus
# config-variant ones for limit/min-input/keybind) beyond the single host the
# rest of this driver uses.
start_hist_host() {  # $1=zdotdir $2=xdg-config-home $3=logfile
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

sec_capture() {
  # ================================================================ (1) Capture fork -> candidate records
  # (cap-1a) A real compsys fork collects candidates, ships candidate records
  # (b header + w/d), and the worker round trip renders a list.
  send_keys 'ls fx/basic/al'
  if expect '*alpha.txt*' 10; then
    ok "(cap-1a) fork capture -> persistent worker -> apply round trip renders a list"
  else
    ng "(cap-1a) list not displayed"
  fi
  dump_get $'\C-xw' TESTWORKER
  local worker_after_first=$REPLY
  local -i first_worker_rfd=${${worker_after_first#*rfd=}%% *}
  local first_runtime=${${worker_after_first#*runtime=}%% *}
  if (( first_worker_rfd > 2 )) \
     && worker_state_has "$worker_after_first" ready=1 seq=1 stopping=0 tainted=0 \
     && [[ $first_runtime != '<none>' ]]; then
    ok "(worker-1b) first real request starts and handshakes one worker"
  else
    ng "(worker-1b) unexpected first-request state: $worker_after_first"
  fi
  clear_line
  drain 0.3
  assert_host_stdio "(fd-2a) lazy worker start preserves host fd 0/1/2"

  # A config reload after the worker is live must still deliver its warning to
  # the host pty. The fixture is removed immediately so later cases use defaults.
  print -r -- $'[unknown]\nvalue = true' >| $XDG_CONFIG_HOME/zrush/config.toml
  send_line ':'
  if expect '*zrush: config:*unknown table*ignoring*HP>*' 5; then
    ok "(fd-2b) config warning reaches stderr after worker startup"
  else
    ng "(fd-2b) config warning missing after worker startup"
  fi
  rm -f $XDG_CONFIG_HOME/zrush/config.toml
  send_line ':'
  sync_prompt
  assert_host_stdio "(fd-2c) config reload preserves host fd 0/1/2"

  # (cap-1b) The batch header's shared X/J tags reach the worker and come back
  # as a heading line (_files' 'file' tag with group-name '').
  send_keys 'ls fx/headed/'
  if expect '*file*plainfile.txt*' 10; then
    ok "(cap-1b) batch header group/heading tags (X/J) round-trip into a heading"
  else
    ng "(cap-1b) 'file' heading not displayed"
  fi
  clear_line
  drain 0.3

  dump_get $'\C-xw' TESTWORKER
  local worker_after_successive=$REPLY
  local -i successive_rfd=${${worker_after_successive#*rfd=}%% *}
  local successive_runtime=${${worker_after_successive#*runtime=}%% *}
  if (( successive_rfd == first_worker_rfd \
        && ${${worker_after_successive#*seq=}%% *} > 1 )) \
     && [[ $successive_runtime == $first_runtime ]]; then
    ok "(worker-1c) successive completion requests reuse the same Rust worker"
  else
    ng "(worker-1c) worker was not reused: first=$worker_after_first now=$worker_after_successive"
  fi

  # A config process from a newer build causes the loaded generation to
  # re-source the current binary once. The replacement is silent, preserves
  # shell-session counters, and immediately restarts the previously-live worker.
  local -i seq_before_auto=${${worker_after_successive#*seq=}%% *}
  log_count 'build: automatic re-source completed'; local -i auto_config0=$REPLY
  # Exercise the successful handoff rather than scheduler variance in the
  # separately-covered 100 ms quarantine guard.
  send_line '_ZRUSH_WORKER_SHUTDOWN_MS=5000'
  sync_prompt
  send_line '_ZRUSH_EXPECTED_BUILD_STAMP=deadbeef'
  sync_prompt
  print -r -- $'[display]\nmax-lines = 10' >| $XDG_CONFIG_HOME/zrush/config.toml
  send_line ':'
  sync_prompt
  local -i auto_config_ready=1
  wait_worker_state 10 ready=1 disabled=0 stale=0 buildwarned=0 following=0 verifying=0 \
    stopping=0 tainted=0 pending=0 || auto_config_ready=0
  local auto_config_state= auto_config_runtime=
  dump_get $'\C-xw' TESTWORKER && auto_config_state=$REPLY
  auto_config_runtime=${${auto_config_state#*runtime=}%% *}
  local -i auto_config_rfd=${${auto_config_state#*rfd=}%% *}
  if (( auto_config_ready && auto_config_rfd > 2 )) \
     && wait_log 'build: automatic re-source completed' $auto_config0 5 \
     && worker_state_has "$auto_config_state" ready=1 seq=$seq_before_auto disabled=0 stale=0 \
          buildwarned=0 following=0 verifying=0 stopping=0 tainted=0 pending=0 \
     && [[ $auto_config_runtime != '<none>' && $auto_config_runtime != $successive_runtime \
           && ! -e $successive_runtime ]]; then
    ok "(build-1a) config stamp mismatch silently re-sources and restarts the live worker"
  else
    ng "(build-1a) automatic config follow failed: state=${auto_config_state:-<none>} old=$successive_runtime"
  fi
  rm -f $XDG_CONFIG_HOME/zrush/config.toml
  send_line ':'
  sync_prompt

  # The async worker-handshake path uses the same transition. Its pending
  # request is not replayed (one keystroke misses), then a later input starts
  # the replacement worker normally.
  send_line '_ZRUSH_WORKER_SHUTDOWN_MS=5000'
  sync_prompt
  send_keys $'\C-xq'
  wait_worker_state 10 ready=0 stopping=0 rfd=-1 wfd=-1 control=-1 ack=-1 pending=0 || \
    ng "(build-1b setup) could not stop the prior worker"
  print -r -- mismatch > $ZRUSH_FAKE_CONTROL
  log_count 'build: automatic re-source completed'; local -i auto_worker0=$REPLY
  send_keys 'ls fx/basic/al'
  local -i auto_worker_followed=1
  wait_log 'build: automatic re-source completed' $auto_worker0 10 || auto_worker_followed=0
  wait_worker_state 10 ready=1 disabled=0 stale=0 buildwarned=0 following=0 verifying=0 \
    stopping=0 tainted=0 pending=0 || auto_worker_followed=0
  local auto_worker_state= auto_worker_runtime=
  dump_get $'\C-xw' TESTWORKER && auto_worker_state=$REPLY
  auto_worker_runtime=${${auto_worker_state#*runtime=}%% *}
  if (( auto_worker_followed )) \
     && worker_state_has "$auto_worker_state" ready=1 disabled=0 stale=0 buildwarned=0 \
          following=0 verifying=0 stopping=0 tainted=0 pending=0 \
     && [[ $auto_worker_runtime != '<none>' && $auto_worker_runtime != $auto_config_runtime \
           && ! -e $auto_config_runtime ]]; then
    ok "(build-1b) incompatible worker silently re-sources, restarts, and discards the in-flight request"
  else
    ng "(build-1b) automatic worker follow failed: state=${auto_worker_state:-<none>} old=$auto_config_runtime"
  fi
  print -r -- proxy > $ZRUSH_FAKE_CONTROL
  if send_keys_wait_plan nonempty 'p' 10; then
    ok "(build-1c) input after the missed stroke is served by the compatible replacement worker"
  fi
  clear_line
  drain 0.3

  dump_get $'\C-xw' TESTWORKER && worker_after_successive=$REPLY
  successive_runtime=${${worker_after_successive#*runtime=}%% *}

  local -i seq_before_resource=${${worker_after_successive#*seq=}%% *}
  log_count 'worker: transport stopped'; local -i resource_stopped0=$REPLY
  # This case tests the completed handoff, not the separately-covered 100 ms
  # expiry/quarantine branch. Give the old definition an extended test-only
  # budget so scheduler variance cannot turn this source invocation into the
  # specified fail-fast result whose cleanup completes just after the prompt.
  send_line '_ZRUSH_WORKER_SHUTDOWN_MS=5000'
  sync_prompt
  send_line "source <($ZRUSH_REAL_BIN init zsh)"
  sync_prompt
  local post_resource_state= post_resource_runtime=
  dump_get $'\C-xw' TESTWORKER && post_resource_state=$REPLY
  post_resource_runtime=${${post_resource_state#*runtime=}%% *}
  if worker_state_has "$post_resource_state" ready=0 seq=$seq_before_resource stopping=0 tainted=0 \
       rfd=-1 wfd=-1 control=-1 ack=-1 pending=0 \
     && [[ $post_resource_runtime != '<none>' && $post_resource_runtime != $successive_runtime ]]; then
    ok "(worker-1d) re-source tears down transport while preserving the request counter"
  else
    ng "(worker-1d) bad post-resource state: ${post_resource_state:-<none>}"
  fi
  if wait_log 'worker: transport stopped' $resource_stopped0 5 \
     && [[ ! -e $successive_runtime ]]; then
    ok "(worker-1e) re-source observes response EOF before replacing the old runtime generation"
  else
    ng "(worker-1e) old completion/runtime cleanup missing: runtime=$successive_runtime"
  fi
  assert_host_stdio "(fd-3) re-source teardown preserves host fd 0/1/2"

  # Re-source a healthy fake session whose final stdout bytes are deliberately
  # not a protocol frame. The fake records stdin EOF, a successful raw tail
  # write, and clean return in that order. This makes the shutdown observation
  # deterministic without depending on whether a real worker happened to have
  # an outstanding response when the source command ran.
  fake_session_count; local -i drain_session=$(( REPLY + 1 ))
  print -r -- drain > $ZRUSH_FAKE_CONTROL
  fake_count "drain $drain_session "; local -i drain_request0=$REPLY
  log_count 'worker: error request_id='; local -i drain_error0=$REPLY
  send_keys 'ls fx/basic/al'
  if wait_fake "drain $drain_session " $drain_request0 10 \
     && wait_log 'worker: error request_id=' $drain_error0 10 \
     && dump_get $'\C-xw' TESTWORKER \
     && worker_state_has "$REPLY" ready=1 stopping=0 tainted=0; then
    local -i drain_seq=${${REPLY#*seq=}%% *}
    fake_count "eof $drain_session"; local -i drain_eof0=$REPLY
    fake_count "tail $drain_session $FAKE_DRAIN_TAIL_BYTES"; local -i drain_tail0=$REPLY
    fake_count "exit $drain_session"; local -i drain_exit0=$REPLY
    clear_line
    drain 0.2
    # The 8 MiB tail deliberately exceeds pipe capacity. Extend only this
    # successful-shutdown fixture; the bounded deadline and quarantine path are
    # asserted independently by transport.zsh.
    send_line '_ZRUSH_WORKER_SHUTDOWN_MS=5000'
    sync_prompt
    send_line "source <($ZRUSH_REAL_BIN init zsh)"
    local -i drain_resource_ok=1
    sync_prompt || drain_resource_ok=0
    wait_fake "eof $drain_session" $drain_eof0 5 || drain_resource_ok=0
    wait_fake "tail $drain_session $FAKE_DRAIN_TAIL_BYTES" $drain_tail0 5 || drain_resource_ok=0
    wait_fake "exit $drain_session" $drain_exit0 5 || drain_resource_ok=0
    local drain_resource_output=${EXPECT_BUF//$'\e['[0-9;]#m/}
    if (( drain_resource_ok )) \
       && [[ $drain_resource_output != *'Terminated'* \
             && $drain_resource_output != *'Done'* \
             && $drain_resource_output != *'zsh: you have running jobs.'* ]]; then
      ok "(worker-1f) healthy re-source closes stdin at EOF, drains raw stdout, and confirms clean worker disappearance"
    else
      ng "(worker-1f) healthy fake shutdown incomplete: output=${(qqqq)drain_resource_output}"
    fi
    if dump_get $'\C-xw' TESTWORKER \
       && worker_state_has "$REPLY" ready=0 seq=$drain_seq stopping=0 tainted=0 \
            rfd=-1 wfd=-1 control=-1 ack=-1 pending=0; then
      ok "(worker-1g) healthy re-source leaves no transport state and does not start a replacement"
    else
      ng "(worker-1g) bad post-resource fake-worker state: ${REPLY:-<none>}"
    fi
    assert_host_stdio "(fd-3b) healthy raw-drain re-source preserves host fd 0/1/2"
  else
    ng "(worker-1f/g) healthy fake session did not become ready: ${REPLY:-<none>}"
  fi
  print -r -- proxy > $ZRUSH_FAKE_CONTROL

  # (cap-1c) w vs m: a candidate whose quoted form differs from its raw text.
  # The listing must show the raw text (m, cli-protocol.md "候補レコード"), and
  # confirming must insert the quoted form (w) so the shell word stays valid.
  send_keys_wait_plan nonempty 'ls fx/spacey/has'
  if dump_get $'\C-xp' TESTPOST && [[ ${(Q)REPLY} == *'has space.txt'* ]]; then
    ok "(cap-1c) listing displays the raw (m) text 'has space.txt', not the quoted form"
  else
    ng "(cap-1c) raw text not found in POSTDISPLAY dump: ${REPLY:-<none>}"
  fi
  press $'\e[B'   # Down: select the (only) candidate
  press $'\r'     # confirm
  assert_buffer 'ls fx/spacey/has\ space.txt ' "(cap-1c') confirmation inserts the quoted (w) form 'has\\ space.txt'"
  clear_line
  drain 0.3

  # Regression (cap-2): a compadd call with zero hits must still tail-call the
  # real builtin (_zrush_compadd), or compsys internal state can desync and
  # break the *next* completion. A prefix with no real match yields at least
  # one zero-hit compadd call inside compsys; a normal completion right after
  # must still work cleanly.
  send_keys_wait_plan zero 'ls fx/basic/ZZZNOMATCH'
  if dump_get $'\C-xp' TESTPOST && [[ -z ${(Q)REPLY} ]]; then
    ok "(cap-2a) a prefix with zero real candidates shows no list"
  else
    ng "(cap-2a) unexpected listing for a zero-candidate prefix: ${REPLY:-<none>}"
  fi
  clear_line
  drain 0.3
  send_keys 'ls fx/basic/al'
  if expect '*alpha.txt*' 10; then
    ok "(cap-2b) a normal completion right after a zero-candidate one still works (compsys/tail-call state intact)"
  else
    ng "(cap-2b) completion broke after a zero-candidate collection"
  fi
  clear_line
  drain 0.3

  # (cap-3) Hidden files: the fork collects them unconditionally (globdots,
  # behavior.md "候補収集") and the matcher keeps them out until the query
  # starts with a dot (cli-protocol.md "隠し候補の除外").
  send_keys_wait_plan nonempty 'ls fx/hidden/'
  if dump_get $'\C-xp' TESTPOST && [[ ${(Q)REPLY} == *visible.txt* && ${(Q)REPLY} != *dotted* ]]; then
    ok "(cap-3a) a dotless query lists only the visible entry"
  else
    ng "(cap-3a) hidden entries leaked into a dotless listing: ${REPLY:-<none>}"
  fi
  clear_line
  drain 0.3
  send_keys_wait_plan nonempty 'ls fx/hidden/.'
  if dump_get $'\C-xp' TESTPOST \
     && [[ ${(Q)REPLY} == *.dotted-alpha.txt* && ${(Q)REPLY} == *.dotted-beta.txt* ]]; then
    ok "(cap-3b) typing the dot lists every hidden entry"
  else
    ng "(cap-3b) hidden entries missing after the dot: ${REPLY:-<none>}"
  fi
  clear_line
  drain 0.3
  send_keys_wait_plan nonempty 'ls fx/hidden/.dotted-be'
  if dump_get $'\C-xp' TESTPOST \
     && [[ ${(Q)REPLY} == *.dotted-beta.txt* && ${(Q)REPLY} != *alpha* ]]; then
    ok "(cap-3c) the dot-prefixed query filters the hidden entries"
  else
    ng "(cap-3c) hidden entries not filtered: ${REPLY:-<none>}"
  fi
  clear_line
  drain 0.3
}

sec_death() {
  # ================================================================ (9) Active persistent-worker death
  # Sanity: the delegated real worker behaves normally first.
  send_keys 'ls fx/basic/al'
  if expect '*alpha.txt*' 10; then
    ok "(err-0) sanity: the delegated real worker is ready and serving plans"
  else
    ng "(err-0) real-worker sanity check failed before death injection"
  fi
  clear_line
  drain 0.3

  # Switch only future sessions to the fake. It handshakes ready, records the
  # assigned request id, then exits without a terminal response.
  log_count 'worker: transport stopped'; local -i explicit_stop0=$REPLY
  send_keys $'\C-xq'
  drain 0.3
  dump_get $'\C-xw' TESTWORKER
  if worker_state_has "$REPLY" ready=0 stopping=0 rfd=-1 wfd=-1 control=-1 ack=-1 pending=0 \
     && wait_log 'worker: transport stopped' $explicit_stop0 5; then
    ok "(err-setup) explicit healthy teardown reaches response EOF and clears transport state"
  else
    ng "(err-setup) explicit teardown did not finalize: ${REPLY:-<none>}"
  fi
  assert_host_stdio "(fd-4) explicit worker teardown preserves host fd 0/1/2"
  fake_session_count; local -i death_session0=$REPLY
  local -i death_first_session=$(( death_session0 + 1 ))
  local -i death_second_session=$(( death_session0 + 2 ))
  local -i death_third_session=$(( death_session0 + 3 ))
  local -i death_starts0=$(grep -c '^start ' $ZRUSH_FAKE_STATE 2>/dev/null)
  print -r -- die > $ZRUSH_FAKE_CONTROL
  log_count 'worker: session failure:'; local -i err_fail0=$REPLY
  fake_count "die $death_first_session "; local -i fake_die0=$REPLY
  local -i err_log_line0=0
  [[ -r $ZRUSH_LOG ]] && err_log_line0=$(wc -l < $ZRUSH_LOG)
  send_keys 'ls fx/basic/al'
  local -i active_death_ok=1
  wait_fake "die $death_first_session " $fake_die0 10 || active_death_ok=0
  wait_log 'worker: session failure:' $err_fail0 10 || active_death_ok=0
  local worker_warning_output=${EXPECT_BUF//$'\e['[0-9;]#m/}
  if [[ $worker_warning_output == *'zrush: worker transport failed; retrying once'* ]]; then
    ok "(fd-5a) worker failure notice reaches the ZLE status line after worker startup"
  else
    ng "(fd-5a) worker failure notice missing from pty output: ${(qqqq)worker_warning_output}"
  fi
  local err_log_delta=$(sed -n "$(( err_log_line0 + 1 )),\$p" $ZRUSH_LOG 2>/dev/null)
  local -i fake_started_count=$(print -r -- "$err_log_delta" | grep -cF 'worker: started rfd=' 2>/dev/null)
  if (( active_death_ok && fake_started_count == 1 )) \
     && dump_get $'\C-xw' TESTWORKER \
     && worker_state_has "$REPLY" failures=1 disabled=0 warned=1 pending=0; then
    ok "(err-1a) ready worker dies with an assigned request; pending is discarded and failure is retryable"
  else
    ng "(err-1a) active-death state missing: state=${REPLY:-<none>} starts=$fake_started_count"
  fi
  local first_die=$(grep -F "die $death_first_session " $ZRUSH_FAKE_STATE 2>/dev/null | tail -1)
  local first_dead_id=${first_die##* }
  drain 0.5
  if dump_get $'\C-xp' TESTPOST; then
    local post2=${(Q)REPLY}
    if [[ -z $post2 ]]; then
      ok "(err-1b) no listing is shown when the plan cannot be fetched"
    else
      ng "(err-1b) a stale/unexpected listing was shown: ${(qqqq)post2}"
    fi
  else
    ng "(err-1b) POSTDISPLAY dump did not run"
  fi
  # The next real request lazily starts one replacement. Hold it after ready
  # and assignment so state can be inspected before its terminal response.
  clear_line; drain 0.3
  assert_host_stdio "(fd-5b) session failure teardown preserves host fd 0/1/2"
  local -i first_death_clean=0
  wait_worker_state 10 ready=0 stopping=0 rfd=-1 wfd=-1 control=-1 ack=-1 pending=0 \
    && first_death_clean=1
  print -r -- hold > $ZRUSH_FAKE_CONTROL
  fake_count "hold $death_second_session "; local -i fake_hold0=$REPLY
  send_keys 'ls fx/basic/'
  if (( first_death_clean )) \
     && wait_fake "hold $death_second_session " $fake_hold0 10 \
     && dump_get $'\C-xw' TESTWORKER \
     && worker_state_has "$REPLY" ready=1 failures=1 disabled=0 pending=1 \
     && (( $(grep -c '^start ' $ZRUSH_FAKE_STATE) == death_starts0 + 2 )); then
    ok "(err-1c) next request starts exactly one replacement; ready handshake does not reset failure streak"
  else
    ng "(err-1c) held replacement state missing: ${REPLY:-<none>}"
  fi
  if (( $(grep -cE "^request [0-9]+ $first_dead_id\$" $ZRUSH_FAKE_STATE 2>/dev/null) == 1 )); then
    ok "(err-1d) failed request_id=$first_dead_id is never replayed"
  else
    ng "(err-1d) failed request was replayed or fake-state accounting changed"
  fi

  log_count 'worker: error request_id='; local -i err_terminal0=$REPLY
  print -r -- error > $ZRUSH_FAKE_CONTROL
  if wait_log 'worker: error request_id=' $err_terminal0 10 \
     && dump_get $'\C-xw' TESTWORKER \
     && worker_state_has "$REPLY" failures=0 disabled=0 pending=0; then
    ok "(err-1e) well-formed terminal error resets the session-failure streak"
  else
    ng "(err-1e) terminal response did not reset streak: ${REPLY:-<none>}"
  fi

  # Kill that active session, then kill its one lazy replacement too. The
  # second consecutive active-session death opens the breaker. Pending Tab
  # must not resolve against a failed plan.
  print -r -- die > $ZRUSH_FAKE_CONTROL
  clear_line; drain 0.3
  fake_count "die $death_second_session "; local -i fake_die1=$REPLY
  log_count 'worker: session failure:'; local -i active_fail1=$REPLY
  send_keys 'ls fx/basic/al'
  wait_fake "die $death_second_session " $fake_die1 10 \
    && wait_log 'worker: session failure:' $active_fail1 10
  local -i second_death_clean=0
  wait_worker_state 10 ready=0 stopping=0 rfd=-1 wfd=-1 control=-1 ack=-1 pending=0 \
    && second_death_clean=1
  clear_line; drain 0.3
  fake_count "die $death_third_session "; local -i fake_die2=$REPLY
  log_count 'worker: session failure:'; local -i active_fail2=$REPLY
  send_keys 'ls fx/basic/al'$'\t'
  wait_fake "die $death_third_session " $fake_die2 10 \
    && wait_log 'worker: session failure:' $active_fail2 10
  local -i third_death_clean=0
  wait_worker_state 10 ready=0 stopping=0 rfd=-1 wfd=-1 control=-1 ack=-1 pending=0 \
    && third_death_clean=1
  drain 0.5
  assert_buffer 'ls fx/basic/al' "(err-2) pending Tab resolved against an actively-dead worker inserts nothing"
  if dump_get $'\C-xw' TESTWORKER \
     && (( second_death_clean && third_death_clean )) \
     && worker_state_has "$REPLY" failures=2 disabled=1 reason=session-failure warned=1 pending=0 \
     && (( $(grep -c '^start ' $ZRUSH_FAKE_STATE) == death_starts0 + 3 )); then
    ok "(err-3) two consecutive active-session deaths open the breaker after one lazy replacement"
  else
    ng "(err-3) active-death breaker state missing: second-clean=$second_death_clean third-clean=$third_death_clean state=${REPLY:-<none>}"
  fi
  local worker_disabled_output=${EXPECT_BUF//$'\e['[0-9;]#m/}
  if [[ $worker_disabled_output == *'zrush: worker disabled after repeated failures; source <(zrush init zsh) to retry'* ]]; then
    ok "(err-3a) disabled worker remains visible with an explicit recovery action"
  else
    ng "(err-3a) disabled worker status missing from pty output: ${(qqqq)worker_disabled_output}"
  fi

  clear_line
  drain 0.3
  assert_host_stdio "(fd-6) explicit disable preserves host fd 0/1/2"
  send_keys 'print HISTMARK-AFTER-ERROR'
  send_keys $'\r'
  if expect '*HISTMARK-AFTER-ERROR*HP>*' 5; then
    ok "(err-4) the shell keeps responding normally after worker failures"
  else
    ng "(err-4) shell did not respond after worker failures"
  fi
  # No sync_prompt here: the expect above already covers this command's prompt.
  drain 0.2

  # An explicit re-source starts a new recovery epoch for the session-failure
  # breaker. It must leave the monotonic request counter intact and make the
  # fake worker available again without starting it until the next request.
  print -r -- proxy > $ZRUSH_FAKE_CONTROL
  send_line 'source <($ZRUSH_REAL_BIN init zsh)'
  if sync_prompt 10 && dump_get $'\C-xw' TESTWORKER \
     && worker_state_has "$REPLY" ready=0 failures=0 disabled=0 reason= stale=0 stopping=0 \
          rfd=-1 wfd=-1 control=-1 ack=-1 pending=0; then
    ok "(err-5a) explicit re-source clears only the session-failure breaker"
  else
    ng "(err-5a) explicit re-source did not restore a lazy worker: ${REPLY:-<none>}"
  fi
  if send_keys_wait_plan nonempty 'ls fx/basic/al' 10; then
    ok "(err-5b) the recovered session serves the next completion request"
  else
    ng "(err-5b) recovered session did not serve a completion request"
  fi
  clear_line
  drain 0.3

  # Keep the fake worker in proxy mode for sections after this one even when
  # the death section is filtered out.
  print -r -- proxy > $ZRUSH_FAKE_CONTROL
}

sec_hist() {
  # ================================================================ (10) History menu (issue #9)
  # docs/internal/specs/behavior.md "履歴メニュー" and cli-protocol.md
  # "history profile" are the source of truth. This section runs on its own
  # host(s) with fixture history (tests/zsh/rc/history.zshrc and friends)
  # instead of the "host" pty used above. Reset the test launcher to proxy.
  # The fixture history is isolated (HISTFILE under $WORK, SAVEHIST=0) and
  # never touches the real ~/.zsh_history (AGENTS.md guardrail).
  print -r -- proxy > $ZRUSH_FAKE_CONTROL

  mkdir -p $WORK/zdot-hist $WORK/xdg-hist/zrush
  print "source $REPO/tests/zsh/rc/history.zshrc" > $WORK/zdot-hist/.zshrc
  if start_hist_host $WORK/zdot-hist $WORK/xdg-hist $WORK/host-hist.log; then
    ok "(hist-0) history-menu host started with fixture history loaded"
  else
    ng "(hist-0) history-menu host failed to start"
  fi

  # ---- (h1) mid-input Up opens the filtered menu at position 1; Up/Up/Down
  # walks the nav table; Enter replaces the whole line with the landed-on
  # entry's raw text (and, being a confirm rather than accept-line, never
  # executes it).
  send_keys 'echo'
  drain 0.5
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=history sel=1 listing=1 npos=6' ]] \
      && ok "(h1a) mid-input Up opens the history menu filtered to the buffer, position 1 selected" \
      || ng "(h1a) $REPLY"
  else
    ng "(h1a) kind dump did not run"
  fi
  if dump_get $'\C-xp' TESTPOST; then
    local post_h1=${(Q)REPLY}
    local listing_h1=${post_h1#$'\n'}
    local first_h1=${listing_h1%%$'\n'*}
    local last_h1=${listing_h1##*$'\n'}
    if [[ $first_h1 =~ '^[[:space:]]*[0-9]+  echo oldest' \
          && $last_h1 =~ '^[[:space:]]*[0-9]+  echo newest' ]]; then
      ok "(h1a') history is one column growing upward: oldest shown at top, position 1/newest at bottom"
    else
      ng "(h1a') unexpected history row order: ${(qqqq)post_h1}"
    fi
  else
    ng "(h1a') POSTDISPLAY dump did not run"
  fi
  press $'\e[A'
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=history sel=2 listing=1 npos=6' ]] && ok "(h1b) Up moves to the next-older entry (position 2)" || ng "(h1b) $REPLY"
  press $'\e[A'
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=history sel=3 listing=1 npos=6' ]] && ok "(h1c) a second Up moves to position 3" || ng "(h1c) $REPLY"
  press $'\e[B'
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=history sel=2 listing=1 npos=6' ]] && ok "(h1d) Down moves back toward newer (position 2)" || ng "(h1d) $REPLY"
  press $'\r'
  assert_buffer $'echo *.glob \'sq\' "dq" \\bs -dash 日本語' "(h1e) Enter replaces the whole line with the landed-on entry's raw text (buffer retains it, so it was not executed)"
  if dump_get $'\C-xk' TESTKIND; then
    # A same-buffer recollection triggered by the confirm can legitimately
    # already have settled by the time this dump runs; only a lingering
    # 'history' kind would mean the menu's state was left behind (h18 is the
    # dedicated, deterministic test for "recollection resumes normally").
    [[ $REPLY != 'kind=history'* ]] && ok "(h1f) confirm leaves no residual history-menu kind" || ng "(h1f) $REPLY"
  fi
  clear_line
  drain 0.3

  # ---- (h2) empty buffer + Up: the full (unfiltered) history menu, one
  # candidate per row with position 1 = the single newest entry at the bottom.
  # The fixture has 13 unique, non-excluded entries, so [display].max-lines=10
  # (the default) caps the single-column list at exactly 10 positions.
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=history sel=1 listing=1 npos=10' ]] \
      && ok "(h2a) empty-buffer Up opens a max-lines-bounded single-column history menu at position 1" \
      || ng "(h2a) $REPLY"
  else
    ng "(h2a) kind dump did not run"
  fi
  assert_buffer '' "(h2b) buffer stays empty while browsing"
  # ---- (h27) history rows carry their real `$history` event number in a
  # minimum-five-column right-aligned field followed by two spaces. Compare
  # against a lazy lookup inside the host rather than assuming fixture event
  # numbers are consecutive or start at a particular value.
  if dump_get $'\C-xe' TESTEVENT; then
    local newest_event=$REPLY
    if [[ $newest_event == <-> ]] && dump_get $'\C-xp' TESTPOST; then
      local post_numbered=${(Q)REPLY}
      local expected_numbered=${(l:5:: :)newest_event}'  echo newest'
      [[ $post_numbered == *$expected_numbered* ]] \
        && ok "(h27) the newest row starts with its real right-aligned history event number and two spaces" \
        || ng "(h27) numbered row missing: event=$newest_event post=${(qqqq)post_numbered}"
    else
      ng "(h27) newest fixture event number could not be resolved: $newest_event"
    fi
  fi
  press $'\r'
  assert_buffer 'echo newest' "(h2c) position 1 of the unfiltered menu is the single newest history entry"
  clear_line
  drain 0.3

  # ---- (h3) dismiss (ctrl-g) closes the menu; buffer is untouched.
  press $'\e[A'
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=history'* ]] || ng "(h3-setup) history menu did not open: $REPLY"
  press $'\C-g'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=none sel=0 listing=0 npos=0' ]] && ok "(h3a) dismiss closes the history menu" || ng "(h3a) $REPLY"
  fi
  assert_buffer '' "(h3b) buffer is unchanged after dismiss"

  # ---- (h4) typing while the menu is open erases the whole listing (unlike
  # a completion listing, which keeps its text until the next result arrives).
  # Uses an argument-position query (a real path prefix, then a suffix with
  # no real matches) rather than a bare command-position character: at
  # command position, typing hits the empty-word cache (behavior.md) and
  # renders a large real-system-command listing, which only obscures this
  # scenario's point without changing it.
  send_keys 'ls fx/basic/'
  drain 0.5
  press $'\e[A'
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=history sel=1 listing=1'* ]] || ng "(h4-setup) history menu did not open: $REPLY"
  send_keys 'ZZZNOMATCH'
  drain 0.6
  if dump_get $'\C-xk' TESTKIND; then
    # As in (h1f)/(h18a): a same-buffer recollection may have already
    # settled (here, to an empty compsys result -- 'fx/basic/ZZZNOMATCH'
    # matches no real file); only a lingering 'history' kind would be wrong.
    [[ $REPLY != 'kind=history'* ]] && ok "(h4a) typing erases the whole history menu (no residual history kind)" || ng "(h4a) $REPLY"
  fi
  if dump_get $'\C-xp' TESTPOST; then
    [[ -z ${(Q)REPLY} ]] && ok "(h4b) no history listing text is left behind" || ng "(h4b) post=${(qqqq)${(Q)REPLY}}"
  fi
  clear_line
  drain 0.3

  # ---- (h23) audit A2: a CURSOR-only external change (no BUFFER text edit)
  # must also erase the whole history menu; (h4) above only exercises a
  # BUFFER-changing edit. Uses the log line _zrush_line_pre_redraw always
  # emits on this exact transition, so the check is independent of whatever
  # a same-buffer recollection settles to afterward (same rationale as the
  # relaxed kind checks elsewhere in this file).
  send_keys 'echo'
  drain 0.5
  press $'\e[A'
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=history'* ]] || ng "(h23-setup) history menu did not open: $REPLY"
  log_count 'history: menu erased by an external buffer/cursor change'; local -i hc0=$REPLY
  press $'\C-xl'   # backward-char: moves CURSOR only, BUFFER text unchanged
  if wait_log 'history: menu erased by an external buffer/cursor change' $hc0 3; then
    ok "(h23a) a cursor-only external change (no BUFFER edit) erases the history menu"
  else
    ng "(h23a) cursor-only change did not erase the menu"
  fi
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY != 'kind=history'* ]] && ok "(h23b) kind is no longer 'history' after the cursor-only change" || ng "(h23b) $REPLY"
  fi
  assert_buffer 'echo' "(h23c) buffer text itself is unchanged (only the cursor moved)"
  clear_line
  drain 0.3

  # ---- (h5) Tab while a history entry is selected confirms it exactly like Enter.
  send_keys 'echo'
  drain 0.5
  press $'\e[A'
  press $'\t'
  assert_buffer 'echo newest' "(h5) Tab confirms the selected history entry (whole-line replacement)"
  clear_line
  drain 0.3

  # ---- (h6) ordering is fixed by recency, never re-sorted by match quality:
  # position 1 must be the newer substring-only match even though an older
  # prefix match also matches (cli-protocol.md "history profile" /
  # "マッチング・ランキングの意味論" -- the audit-flagged regression here).
  send_keys 'zqx'
  drain 0.5
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=history sel=1 listing=1 npos=2' ]] && ok "(h6a) query 'zqx' matches both fixture entries" || ng "(h6a) $REPLY"
  fi
  press $'\r'
  assert_buffer 'aa zqx bb' "(h6b) position 1 is the newer substring-only match, not the older (higher-tier) prefix match"
  clear_line
  drain 0.3

  # ---- (h7) an identical history line appearing twice yields exactly one candidate (the newest).
  send_keys 'dup'
  drain 0.5
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=history sel=1 listing=1 npos=1' ]] && ok "(h7) a duplicated history line is deduplicated to a single candidate" || ng "(h7) $REPLY"
  fi
  press $'\C-g'
  clear_line
  drain 0.3

  # ---- (h9) a history line carrying a framing byte (SOH here) is excluded
  # whole, not stripped-and-kept: querying its surviving text finds nothing.
  send_keys 'ctrlone'
  drain 0.5
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=none sel=0 listing=0 npos=0' ]] && ok "(h9) a history line containing a framing byte never becomes a candidate" || ng "(h9) $REPLY"
  fi
  assert_buffer 'ctrlone' "(h9b) buffer unchanged (no menu opened, the key was still consumed)"
  clear_line
  drain 0.3

  # ---- (h10) a history line that itself contains a newline: the listing
  # shows it flattened to one row (control-byte normalization), but
  # confirming inserts the raw multi-line text back into BUFFER.
  send_keys 'multi'
  drain 0.5
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=history sel=1 listing=1 npos=1' ]] && ok "(h10a) the multi-line fixture entry is the sole match" || ng "(h10a) $REPLY"
  fi
  if dump_get $'\C-xp' TESTPOST; then
    local post_ml=${(Q)REPLY}
    if [[ $post_ml == *'multi line2'* && $post_ml != *'multi'$'\n''line2'* ]]; then
      ok "(h10b) the listing shows the entry flattened to one row (embedded newline -> space)"
    else
      ng "(h10b) listing not flattened as expected: ${(qqqq)post_ml}"
    fi
  fi
  press $'\r'
  assert_buffer $'echo multi\nline2' "(h10c) confirming inserts the raw multi-line text, embedded newline included"
  reset_line   # BUFFER now spans two lines; ^U would only clear the current one

  # ---- (h11) glob characters, quotes, a backslash, a leading dash, and
  # Japanese text in a history line are shown and inserted byte-for-byte,
  # never interpreted (globbed, quote-parsed, or expanded).
  send_keys 'glob'
  drain 0.5
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=history sel=1 listing=1 npos=1' ]] && ok "(h11a) the meta-character fixture entry is the sole match" || ng "(h11a) $REPLY"
  fi
  if dump_get $'\C-xp' TESTPOST; then
    [[ ${(Q)REPLY} == *$'echo *.glob \'sq\' "dq" \\bs -dash 日本語'* ]] \
      && ok "(h11b) the listing displays the meta-character line verbatim" || ng "(h11b) post=${(qqqq)${(Q)REPLY}}"
  fi
  press $'\r'
  assert_buffer $'echo *.glob \'sq\' "dq" \\bs -dash 日本語' "(h11c) confirming inserts the meta-character line verbatim (no glob/quote interpretation)"
  clear_line
  drain 0.3

  # ---- (h12) a nonempty query with zero matches: no menu opens, the key is
  # consumed, and the buffer is left unchanged (no fallback to native history search).
  send_keys 'zzqqxx000'
  drain 0.5
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=none sel=0 listing=0 npos=0' ]] && ok "(h12a) zero matches: no menu opens" || ng "(h12a) $REPLY"
  fi
  assert_buffer 'zzqqxx000' "(h12b) buffer is unchanged (key consumed, no native fallback)"
  clear_line
  drain 0.3

  # ---- (h15) Down at position 1 erases the whole menu (unlike a completion
  # listing, where the analogous transition just deselects and keeps the text).
  send_keys 'echo'
  drain 0.5
  press $'\e[A'
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=history sel=1'* ]] || ng "(h15-setup) history menu did not open at position 1: $REPLY"
  press $'\e[B'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=none sel=0 listing=0 npos=0' ]] && ok "(h15a) Down at position 1 erases the whole menu" || ng "(h15a) $REPLY"
  fi
  assert_buffer 'echo' "(h15b) buffer is unchanged"
  clear_line
  drain 0.3

  # ---- (h16) select-prev at a completion listing's position 1 only
  # deselects (listing text stays); pressing it again, now unselected, opens
  # the history menu and replaces the completion listing outright.
  send_keys 'ls fx/basic/al'
  if expect '*alpha.txt*' 10; then
    ok "(h16a) a completion listing is showing"
  else
    ng "(h16a) completion listing did not render"
  fi
  press $'\e[B'   # Down: select-start at position 1
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=compsys sel=1'* ]] || ng "(h16b) selection did not start on the completion listing: $REPLY"
  press $'\e[A'   # Up: position 1's prev is 0 -> deselect only (compsys kind, not history)
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=compsys sel=0 listing=1'* ]] \
      && ok "(h16c) Up at the completion listing's position 1 only deselects (listing text remains)" \
      || ng "(h16c) $REPLY"
  fi
  press $'\e[A'   # Up again, now unselected: opens the history menu, replacing the completion listing
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=history sel=1 listing=1'* ]] \
      && ok "(h16d) a second Up (now unselected) opens the history menu, replacing the completion listing" \
      || ng "(h16d) $REPLY"
  fi
  if dump_get $'\C-xp' TESTPOST; then
    [[ ${(Q)REPLY} != *alpha.txt* ]] && ok "(h16e) the completion listing text is gone, not merely covered" || ng "(h16e) post=${(qqqq)${(Q)REPLY}}"
  fi
  clear_line
  drain 0.3

  # ---- (h25) audit A2: opening the history menu while only debounce-armed
  # (no collection started yet) disarms the pending timer; (h17) above only
  # covers cancelling a collection that has already started. The Up here is
  # sent in the same burst as the typed query, well inside the default 30ms
  # debounce, so the timer must still be pending when select-prev disarms it.
  log_count 'request: collecting'; local -i rc0=$REPLY
  send_keys 'echo'
  send_keys $'\e[A'
  drain 0.5
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=history sel=1 listing=1 npos=6' ]] \
      && ok "(h25a) Up sent within the debounce window still opens the history menu" \
      || ng "(h25a) $REPLY"
  fi
  drain 1.0   # comfortably longer than the original 30ms debounce + a real fork/collection round trip
  log_count 'request: collecting'; local -i rc1=$REPLY
  (( rc1 == rc0 )) \
    && ok "(h25b) the disarmed debounce timer never fires a compsys collection ($rc0 -> $rc1)" \
    || ng "(h25b) a compsys collection started despite the timer being disarmed ($rc0 -> $rc1)"
  clear_line
  drain 0.3

  # ---- (h17) opening the history menu cancels an in-flight completion
  # collection; the collection's late-arriving result must not overwrite the
  # menu once it (eventually) completes (behavior.md "候補収集": a cancelled
  # request's result is never applied, even if it arrives afterward). The
  # slow fixture completion (_zrushtestslow) is defined in
  # tests/zsh/rc/history.zshrc itself, not typed here, so it never becomes a
  # history entry that could confuse the query below.
  send_keys 'zrushtestslow '
  drain 0.2   # let debounce elapse and the fork start; it is still asleep
  press $'\e[A'   # open the history menu while the slow collection is in flight
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=history sel=1 listing=1'* ]] \
      && ok "(h17a) the history menu opens synchronously even with a slow collection in flight" \
      || ng "(h17a) $REPLY"
  fi
  drain 0.8   # comfortably longer than the fixture's 0.5s sleep
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=history sel=1 listing=1'* ]] \
      && ok "(h17b) the (cancelled) slow collection's late result did not overwrite the history menu" \
      || ng "(h17b) $REPLY"
  fi
  if dump_get $'\C-xp' TESTPOST; then
    [[ ${(Q)REPLY} != *slowcand* ]] && ok "(h17c) the slow completion's candidates never appear in the listing text" || ng "(h17c) post=${(qqqq)${(Q)REPLY}}"
  fi

  # ---- (h18) confirming a history entry leaves no residual history kind
  # behind; the very next completion request resumes the normal pipeline.
  press $'\r'   # confirm the still-open history menu from (h17)
  if dump_get $'\C-xk' TESTKIND; then
    # A same-buffer recollection can legitimately already have settled by the
    # time this dump runs (its own debounce is much shorter than the drain
    # above), so 'compsys' is an acceptable sighting here too; only a
    # lingering 'history' kind would mean confirm left the menu's state behind.
    [[ $REPLY != 'kind=history'* ]] && ok "(h18a) confirm leaves no residual history-menu state" || ng "(h18a) $REPLY"
  fi
  clear_line
  drain 0.3
  send_keys 'ls fx/basic/al'
  if expect '*alpha.txt*' 10; then
    ok "(h18b) a normal completion right after confirming a history entry still renders"
  else
    ng "(h18b) completion did not render after a history confirm"
  fi
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=compsys'* ]] && ok "(h18c) the resumed listing's kind is 'compsys', not a leftover 'history'" || ng "(h18c) $REPLY"
  fi
  clear_line
  drain 0.3

  # ---- (h22) regression (f6fcf2e, audit A2): confirming a history candidate
  # that is byte-identical to the current BUFFER must still trigger normal
  # recollection afterward. Opening the menu snapshots BUFFER/CURSOR as the
  # pre-redraw baseline (behavior.md "履歴メニュー"); if confirm left that
  # baseline untouched, an insertion identical to the pre-open buffer would
  # read as "no change" on the next pre-redraw and silently stall
  # recollection (behavior.md "確定(挿入)"). Checked via both confirm keys.
  send_keys 'echo newest'
  drain 0.5
  press $'\e[A'
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=history sel=1 listing=1 npos=1' ]] || ng "(h22-setup-enter) exact-match menu did not open as expected: $REPLY"
  log_count 'worker: ok request_id='; local -i cc0=$REPLY
  press $'\r'
  if wait_log 'worker: ok request_id=' $cc0 3; then
    ok "(h22a) confirming a history entry byte-identical to BUFFER (via Enter) still triggers a fresh compsys recollection"
  else
    ng "(h22a) no fresh compsys recollection observed after Enter confirmed an exact-BUFFER-match entry"
  fi
  clear_line
  drain 0.3

  send_keys 'echo newest'
  drain 0.5
  press $'\e[A'
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=history sel=1 listing=1 npos=1' ]] || ng "(h22-setup-tab) exact-match menu did not open as expected: $REPLY"
  log_count 'worker: ok request_id='; local -i cc1=$REPLY
  press $'\t'
  if wait_log 'worker: ok request_id=' $cc1 3; then
    ok "(h22b) confirming a history entry byte-identical to BUFFER (via Tab) still triggers a fresh compsys recollection"
  else
    ng "(h22b) no fresh compsys recollection observed after Tab confirmed an exact-BUFFER-match entry"
  fi
  clear_line
  drain 0.3

  # ---- (h21) the fixture-injection mechanism itself (print -s, run from
  # this host's rc file) never becomes a history candidate: a query matching
  # its own invocation text finds nothing.
  send_keys 'print'
  drain 0.5
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=none sel=0 listing=0 npos=0' ]] \
      && ok "(h21) the fixture's own 'print -s ...' injection commands never appear as history candidates" \
      || ng "(h21) $REPLY"
  fi
  clear_line
  drain 0.3

  # ---- (h24) A synchronous history request assigned to a ready worker which
  # then dies must leave no menu, no residual kind/listing, the buffer
  # untouched, and the shell responsive (cli-protocol.md "エラー時の zsh 側
  # 挙動" applies to the history producer's synchronous worker exchange
  # exactly as it does to the async compsys one).
  # An empty buffer (rather than a typed query) avoids a confound: typing
  # anything here would also arm its own compsys collection, which (via the
  # already-warm empty-word cache from earlier scenarios on this host) would
  # start an unrelated async request before the history-menu attempt.
  send_keys $'\C-xq'
  drain 0.3
  fake_session_count
  local -i hist_fake_session=$(( REPLY + 1 ))
  print -r -- die > $ZRUSH_FAKE_CONTROL
  fake_count "die $hist_fake_session "; local -i hist_die0=$REPLY
  log_count 'worker: session failure:'; local -i hist_fail0=$REPLY
  log_count 'worker: transport stopped'; local -i hist_stopped0=$REPLY
  send_keys $'\e[A'
  if wait_fake "die $hist_fake_session " $hist_die0 10 \
     && wait_log 'worker: session failure:' $hist_fail0 10; then
    ok "(h24a) active worker death is recorded on the synchronous history path"
  else
    ng "(h24a) no worker failure logged on the history-menu path"
  fi
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=none sel=0 listing=0 npos=0' ]] && ok "(h24b) no menu/kind/listing survives the failed sync plan" || ng "(h24b) $REPLY"
  fi
  assert_buffer '' "(h24c) buffer is unchanged after the failed sync plan"
  print -r -- proxy > $ZRUSH_FAKE_CONTROL
  clear_line
  drain 0.3
  send_keys 'print HISTMARK-AFTER-HIST-PLAN-ERROR'
  send_keys $'\r'
  if expect '*HISTMARK-AFTER-HIST-PLAN-ERROR*' 5; then
    ok "(h24d) the shell keeps responding normally after a failed history-menu plan"
  else
    ng "(h24d) shell did not respond after the failed history-menu plan"
  fi
  sync_prompt
  # The session-failure log can precede response EOF when abort exhausts its
  # synchronous budget. Do not make the next history request race the retained
  # stopping gate.
  local -i h26_worker_clean=0
  wait_log 'worker: transport stopped' $hist_stopped0 10 && h26_worker_clean=1

  # ---- (h26a/h26b) audit A2: send-break while the history menu is open must
  # not leak kind/listing state into the next line. The existing (sb-1)
  # regression elsewhere in this driver only checks _zrush_plan_npos/
  # _zrush_listing for a completion listing, not the history-menu path.
  # (No fd check here: opening the history menu already disarms the timer
  # and cancels any collection *before* it displays, so the fds are already
  # clear before ^C is even sent -- a check here would pass vacuously even
  # if _zrush_line_init's own disarm/cancel were broken. (h26c)/(h26d) below
  # cover the fd cleanup from states where the fds are provably non-empty
  # right before send-break.)
  send_keys 'echo'
  drain 0.5
  press $'\e[A'
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY == 'kind=history'* && $h26_worker_clean == 1 ]] ||
    ng "(h26-setup) history menu did not open after worker cleanup=$h26_worker_clean: $REPLY"
  send_keys $'\C-c'   # send-break: abandon the line, bypassing confirm/dismiss/line-finish
  if sync_prompt 15; then
    ok "(h26a) a new prompt appears after send-break with the history menu open"
    if dump_get $'\C-xk' TESTKIND; then
      [[ $REPLY == 'kind=none sel=0 listing=0 npos=0' ]] && ok "(h26b) no kind/listing state leaks into the new prompt" || ng "(h26b) $REPLY"
    fi
  else
    ng "(h26a) send-break did not produce a new prompt in this environment"
  fi
  clear_line
  drain 0.3

  # ---- (h26d) audit A2: send-break while a real collection is in flight
  # (rfd/pty alive, not merely debounce-armed) must clear those fds too.
  # Reuses the same slow fixture as (h17), but ends with ^C instead of Up.
  send_keys 'zrushtestslow '
  drain 0.2   # let debounce elapse and the fork start; it is still asleep (0.5s)
  if dump_get $'\C-xt' TESTFDS; then
    # Guard against a vacuous check: fail loudly here rather than silently
    # passing (h26d) below for the wrong reason if no collection is actually
    # in flight yet.
    [[ $REPLY != 'timer=-1 rfd=-1 wfd=-1 pty=<none>' ]] \
      && ok "(h26d-pre) a real collection is in flight (rfd/pty non -1) before send-break" \
      || ng "(h26d-pre) no in-flight collection detected before send-break: $REPLY"
  fi
  send_keys $'\C-c'
  if sync_prompt 15; then
    ok "(h26d-a) a new prompt appears after send-break during an in-flight collection"
    if dump_get $'\C-xt' TESTFDS; then
      [[ $REPLY == 'timer=-1 rfd=-1 wfd=-1 pty=<none>' ]] \
        && ok "(h26d) the cancelled collection's fds/pty are cleared after the following line-init" \
        || ng "(h26d) $REPLY"
    fi
    if dump_get $'\C-xk' TESTKIND; then
      [[ $REPLY == 'kind=none sel=0 listing=0 npos=0' ]] && ok "(h26d-kind) kind/listing is also clean" || ng "(h26d-kind) $REPLY"
    fi
  else
    ng "(h26d-a) send-break did not produce a new prompt in this environment"
  fi
  clear_line
  drain 0.3

  # ---- (h13) while browsing plain history (HISTNO != HISTCMD, entered here
  # via a raw ^Xu binding to up-line-or-history), select-prev/select-next
  # both delegate to the predecessor instead of opening/moving a history menu.
  # Each raw history step below changes BUFFER to a real history line, which
  # (like any buffer edit) can arm and settle an ordinary recollection before
  # the following dump runs; that legitimately shows up as 'compsys', so
  # every check here is "never 'history'", not "always 'none'".
  press $'\C-xu'
  press $'\C-xu'   # two raw history-back steps, so there is room for a further Down below
  dump_get $'\C-xk' TESTKIND
  [[ $REPLY != 'kind=history'* ]] || ng "(h13-setup) unexpected history-menu kind after raw history browsing: $REPLY"
  # audit A2: "kind != history" alone would also pass if the key were simply
  # swallowed as a no-op instead of actually delegated, so additionally pin
  # down the real transition via BUFFER content: Up must move one further
  # step back in plain history (a different line), and Down must land back
  # on exactly the line seen right before Up (a round trip), proving both
  # keys actually reached up-line-or-history/down-line-or-history.
  dump_get $'\C-xb' TESTBUF; local buf_base=${(Q)REPLY}
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY != 'kind=history'* ]] && ok "(h13a) Up while browsing plain history delegates (no history menu opens)" || ng "(h13a) $REPLY"
  fi
  dump_get $'\C-xb' TESTBUF; local buf_after_up=${(Q)REPLY}
  [[ $buf_after_up != "$buf_base" ]] \
    && ok "(h13a') the delegated Up actually moved one step further back in plain history (buffer changed: ${(qqqq)buf_base} -> ${(qqqq)buf_after_up})" \
    || ng "(h13a') buffer did not change; Up may have been silently swallowed instead of delegated"
  press $'\e[B'
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY != 'kind=history'* ]] && ok "(h13b) Down while browsing plain history delegates (no history menu opens)" || ng "(h13b) $REPLY"
  fi
  dump_get $'\C-xb' TESTBUF; local buf_after_down=${(Q)REPLY}
  [[ $buf_after_down == "$buf_base" ]] \
    && ok "(h13b') the delegated Down actually moved one step forward, back to the same plain-history line as before Up" \
    || ng "(h13b') buffer=${(qqqq)buf_after_down} want=${(qqqq)buf_base}"
  reset_line

  # ---- (h14) a multiline buffer with the cursor off the first line: Up is
  # cursor movement, not a history-menu open (behavior.md priority rule 1,
  # symmetric with select-next's own multiline rule).
  send_keys 'echo a'
  send_keys $'\C-v\C-j'
  send_keys 'b'
  drain 0.5
  dump_get $'\C-xz' TESTCUR; local -i cur_before=$REPLY   # end of buffer: 8 ('echo a'=6 + \n + 'b')
  press $'\e[A'
  if dump_get $'\C-xk' TESTKIND; then
    # A same-buffer recollection for the "b" argument word may have already
    # settled (real or not, cli-protocol.md still records it as 'compsys');
    # only a 'history' kind would mean the menu wrongly opened.
    [[ $REPLY != 'kind=history'* ]] && ok "(h14a) Up with a newline in LBUFFER delegates (no history menu opens)" || ng "(h14a) $REPLY"
  fi
  assert_buffer $'echo a\nb' "(h14b) buffer content is unchanged (only the cursor moved)"
  # audit A2: "buffer unchanged" alone would also pass if Up were a pure
  # no-op, so additionally pin down that the cursor actually left line 2:
  # 'echo a' occupies positions 0..6 (the newline sits at 6), so landing
  # anywhere in 0..6 means "on line 1".
  dump_get $'\C-xz' TESTCUR; local -i cur_after=$REPLY
  [[ $cur_after -lt 7 && $cur_after -ne $cur_before ]] \
    && ok "(h14c) the cursor actually moved onto the first line (was $cur_before, now $cur_after; line 1 spans 0..6)" \
    || ng "(h14c) cursor did not move onto the first line (before=$cur_before after=$cur_after)"
  reset_line

  # ---- (h26c) audit A2: send-break while merely debounce-armed (timer fd
  # alive, no collection started yet) must clear the timer too. A dedicated
  # host with a generous delay-ms is used so the round trip to dump and
  # assert the armed timer via ^Xt comfortably fits before the debounce
  # would otherwise fire ((h25) already covers disarming via the history-menu
  # open path itself; this covers disarming via send-break/line-init instead).
  mkdir -p $WORK/xdg-hist-slowdebounce/zrush
  print -r -- $'[display]\ndelay-ms = 2000' > $WORK/xdg-hist-slowdebounce/zrush/config.toml
  if start_hist_host $WORK/zdot-hist $WORK/xdg-hist-slowdebounce $WORK/host-hist-slowdebounce.log; then
    ok "(h26c-0) delay-ms=2000 host started"
    send_keys 'x'
    drain 0.3   # comfortably within the 2s debounce window
    if dump_get $'\C-xt' TESTFDS; then
      # Guard against a vacuous check: fail loudly here rather than silently
      # passing (h26c) below for the wrong reason if the timer never armed.
      [[ $REPLY != 'timer=-1'* ]] \
        && ok "(h26c-pre) the debounce timer is armed (non -1) before send-break" \
        || ng "(h26c-pre) timer was not armed as expected before send-break: $REPLY"
    fi
    send_keys $'\C-c'
    if sync_prompt 15; then
      ok "(h26c-a) a new prompt appears after send-break during the debounce wait"
      if dump_get $'\C-xt' TESTFDS; then
        [[ $REPLY == 'timer=-1 rfd=-1 wfd=-1 pty=<none>' ]] \
          && ok "(h26c) the disarmed debounce timer's fd is cleared after the following line-init" \
          || ng "(h26c) $REPLY"
      fi
      if dump_get $'\C-xk' TESTKIND; then
        [[ $REPLY == 'kind=none sel=0 listing=0 npos=0' ]] && ok "(h26c-kind) kind/listing is also clean" || ng "(h26c-kind) $REPLY"
      fi
    else
      ng "(h26c-a) send-break did not produce a new prompt in this environment"
    fi
  else
    ng "(h26c-0) delay-ms=2000 host failed to start"
  fi

  # ---- (h8) [history].limit bounds the RAW scan window; entries that don't
  # survive the in-window dedup/exclusion are never backfilled from outside
  # that window (cli-protocol.md "history profile", config-schema.md "[history]").
  mkdir -p $WORK/zdot-hist-lim $WORK/xdg-hist-lim/zrush
  print "source $REPO/tests/zsh/rc/history-limit.zshrc" > $WORK/zdot-hist-lim/.zshrc
  print -r -- $'[history]\nlimit = 5' > $WORK/xdg-hist-lim/zrush/config.toml
  if start_hist_host $WORK/zdot-hist-lim $WORK/xdg-hist-lim $WORK/host-hist-limit.log; then
    ok "(h8-0) limit=5 host started with its own fixture history"
    press $'\e[A'
    if dump_get $'\C-xp' TESTPOST; then
      local post_lim=${(Q)REPLY}
      if [[ $post_lim == *dupA* && $post_lim == *keep3* && $post_lim == *keep4* \
            && $post_lim != *keep5-outside* && $post_lim != *oldest-outside* ]]; then
        ok "(h8a) the newest-5 scan window yields dupA/keep3/keep4 and never backfills keep5-outside/oldest-outside from beyond it"
      else
        ng "(h8a) unexpected listing for limit=5: ${(qqqq)post_lim}"
      fi
      local -a lim_rows=( "${(f)post_lim}" )
      local -i n_dupa=${#${(M)lim_rows:#*dupA*}}
      (( n_dupa == 1 )) && ok "(h8b) the duplicate within the scan window is deduplicated to exactly one row" || ng "(h8b) dupA appeared in $n_dupa rows: ${(qqqq)post_lim}"
    else
      ng "(h8a) POSTDISPLAY dump did not run"
    fi
  else
    ng "(h8-0) limit=5 host failed to start"
  fi

  # ---- (h19) min-input does not gate the history menu: even with min-input
  # raised well above any possible word length, an empty-buffer Up still
  # opens the full menu (behavior.md: min-input and the blank-buffer
  # suppression rule apply only to the input-following auto display, not to
  # the history menu).
  mkdir -p $WORK/xdg-hist-mininput/zrush
  print -r -- $'[display]\nmin-input = 50' > $WORK/xdg-hist-mininput/zrush/config.toml
  if start_hist_host $WORK/zdot-hist $WORK/xdg-hist-mininput $WORK/host-hist-mininput.log; then
    ok "(h19-0) min-input=50 host started"
    press $'\e[A'
    if dump_get $'\C-xk' TESTKIND; then
      [[ $REPLY == 'kind=history sel=1 listing=1'* ]] \
        && ok "(h19a) empty-buffer Up opens the history menu even with min-input=50" \
        || ng "(h19a) $REPLY"
    fi
  else
    ng "(h19-0) min-input=50 host failed to start"
  fi

  # ---- (h20) remapping select-prev to just ["up"] leaves ctrl-p bound to its
  # predecessor (plain history movement, config-schema.md "[keybind]"); Up
  # (still in the remapped list) still opens the history menu.
  mkdir -p $WORK/xdg-hist-keybind/zrush
  print -r -- $'[keybind]\nselect-prev = ["up"]' > $WORK/xdg-hist-keybind/zrush/config.toml
  if start_hist_host $WORK/zdot-hist $WORK/xdg-hist-keybind $WORK/host-hist-keybind.log; then
    ok "(h20-0) select-prev=[\"up\"] host started"
    # Up first, on the pristine just-started state: ctrl-p's own predecessor
    # (tested second, below) is real native history movement and would
    # otherwise leave HISTNO != HISTCMD behind it, which changes what a
    # *later* Up does (behavior.md priority rule 2) -- unrelated to what
    # this remap is actually about.
    press $'\e[A'
    if dump_get $'\C-xk' TESTKIND; then
      [[ $REPLY == 'kind=history sel=1 listing=1'* ]] \
        && ok "(h20b) Up (still in the remapped select-prev list) still opens the history menu" \
        || ng "(h20b) $REPLY"
    fi
    press $'\C-g'   # dismiss: back to an empty buffer, HISTNO still untouched
    dump_get $'\C-xb' TESTBUF; local buf_before_ctrlp=${(Q)REPLY}
    press $'\C-p'
    if dump_get $'\C-xk' TESTKIND; then
      # ctrl-p's predecessor may move BUFFER to a real history line, which
      # (like any buffer edit) can arm and settle an ordinary recollection
      # before this dump runs; only a 'history' kind would mean the menu
      # wrongly opened.
      [[ $REPLY != 'kind=history'* ]] && ok "(h20a) ctrl-p (excluded from select-prev) does not open the history menu" || ng "(h20a) $REPLY"
    fi
    # audit A2: "kind != history" alone would also pass if ctrl-p were
    # silently swallowed as a no-op; pin down that its predecessor actually
    # ran plain history movement by requiring a real, nonempty buffer change.
    dump_get $'\C-xb' TESTBUF; local buf_after_ctrlp=${(Q)REPLY}
    [[ -n $buf_after_ctrlp && $buf_after_ctrlp != "$buf_before_ctrlp" ]] \
      && ok "(h20a') ctrl-p's predecessor actually performed native history movement (buffer: ${(qqqq)buf_before_ctrlp} -> ${(qqqq)buf_after_ctrlp})" \
      || ng "(h20a') ctrl-p did not change the buffer; it may have been silently swallowed instead of delegated"
  else
    ng "(h20-0) select-prev=[\"up\"] host failed to start"
  fi
}

sec_jobtable() {
  # ================================================================ Worker job-table isolation
  # This host must exit during the assertion, so give it dedicated rc/config/log
  # state rather than reusing any host needed by the preceding cases.
  mkdir -p $WORK/zdot-exit $WORK/xdg-exit/zrush
  print "source $REPO/tests/zsh/rc/minimal.zshrc" > $WORK/zdot-exit/.zshrc
  if start_hist_host $WORK/zdot-exit $WORK/xdg-exit $WORK/host-exit.log; then
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
  # a still-live session via `zpty -d host`). start_hist_host always issues
  # its own `zpty -d host 2>/dev/null` before spawning anew; issuing that
  # exact call -- with stderr redirected -- as the *first* deletion of an
  # already-dead real-worker session reproducibly kills this outer zsh
  # process outright (a zpty/job-control interaction, not a zrush bug).
  # Reaping it here first, without redirecting stderr, avoids the crash;
  # start_hist_host's own redundant delete of the now-already-gone session
  # is then a harmless no-op.
  print -r -- proxy > $ZRUSH_FAKE_CONTROL
  zpty -d host
  mkdir -p $WORK/zdot-inflight $WORK/xdg-inflight/zrush
  print "source $REPO/tests/zsh/rc/minimal.zshrc" > $WORK/zdot-inflight/.zshrc
  if start_hist_host $WORK/zdot-inflight $WORK/xdg-inflight $WORK/host-inflight.log; then
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
