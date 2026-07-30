#!/bin/zsh -f
# Headless zle-integration smoke driver for zrush.zsh (protocol v2).
#
# Usage:
#   zsh -f tests/zsh/driver.zsh <playground-dir>
#     The playground only needs to exist and be writable; it is used as an
#     isolated $HOME. Every fixture this driver needs (small file/directory
#     trees, a filename containing a space, a slow fake completion) is
#     created under $PLAYGROUND/fx by this script -- no pre-populated docs
#     tree or external "huge" directory is required.
#   Prerequisite: the zrush binary has been built with cargo build --release.
#
# Scope (docs/internal/contracts/cli-protocol.md and behavior.md are the
# source of truth for everything below): matching, ranking, grid layout,
# highlight/nav-table computation, and insertion-text construction all live
# in Rust and are covered by `cargo test`. This driver only smoke-tests what
# Rust cannot verify: that the real zle/compsys integration captures
# candidates, ships them to `zrush plan`, and applies the returned plan to
# POSTDISPLAY/region_highlight/BUFFER correctly under real key input.
#
# Harness (shared with driver-coexist.zsh/driver-latency.zsh):
#   - Start an interactive host zsh with nonblocking zpty -b, send keys, and inspect
#     both pty output and the ZRUSH_LOG file (including the ^Xb/^Xp/^Xh test-only
#     dump widgets registered by rc/minimal.zshrc).
#   - Always drain the pty in wait loops to prevent tcsetattr TCSADRAIN blocking.
#   - After executing a command, synchronize on the HP> prompt before sending more keys.
emulate -L zsh
setopt extended_glob
zmodload zsh/zpty    || { print -u2 FATAL: zpty; exit 1 }
zmodload zsh/zselect || { print -u2 FATAL: zselect; exit 1 }
zmodload zsh/system  || { print -u2 FATAL: system; exit 1 }
autoload -Uz is-at-least

typeset -F SECONDS
typeset -g HERE=${${(%):-%N}:A:h}
typeset -g REPO=${HERE:h:h}
typeset -g PLAYGROUND=${1:?usage: driver.zsh <playground-dir>}
[[ -d $PLAYGROUND ]] || { print -u2 "FATAL: invalid playground: $PLAYGROUND"; exit 1 }
[[ -x $REPO/target/release/zrush ]] || { print -u2 "FATAL: zrush binary not found (cargo build --release)"; exit 1 }

typeset -gi PASS=0 FAIL=0
out() { print -r -u2 -- "$@" }
ok()  { out "PASS: $1"; (( ++PASS )) }
ng()  { out "FAIL: $1"; (( ++FAIL )) }

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-test.XXXXXX)
export TERM=vt100
export LC_ALL=en_US.UTF-8   # match POSTDISPLAY printability checks to real UTF-8 use
export HOME=$PLAYGROUND     # isolated; never the real home
export ZRUSH_REPO=$REPO
export ZRUSH_TEST_TMP=$WORK
export ZDOTDIR=$WORK/zdot
export XDG_CONFIG_HOME=$WORK/xdg   # no config.toml is written: every test runs on defaults
export ZRUSH_LOG=$WORK/host.log
mkdir -p $ZDOTDIR $XDG_CONFIG_HOME/zrush

# A private copy of the binary, so the error-path test (err-1/2) can corrupt it
# in place without ever touching the real build artifact under target/release.
mkdir -p $WORK/bin
cp $REPO/target/release/zrush $WORK/bin/zrush
chmod +x $WORK/bin/zrush
export ZRUSH_BIN=$WORK/bin/zrush

print "source $REPO/tests/zsh/rc/minimal.zshrc" > $ZDOTDIR/.zshrc

# Whether this zsh build can tag region_highlight entries with memo=zrush
# (cli-protocol.md / behavior.md "region_highlight の自エントリ"); on 5.8 the
# ^Xh dump still lists this plugin's own entries (via the internal _zrush_rh
# ledger, not memo filtering), so only the memo-suffix assertion is gated.
typeset -gi HAVE_MEMO=0
is-at-least 5.9 $ZSH_VERSION && HAVE_MEMO=1

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

# fx/headed: a plain file so _files' "file" tag heading appears in the plan.
mkdir -p $PLAYGROUND/fx/headed
: >| $PLAYGROUND/fx/headed/plainfile.txt

# fx/longcol: candidate names wide enough to force a single-column grid
# (gmaxw clamped to width => cols=1), so select-left/right jump deterministically
# to the group's first/last position regardless of terminal width.
mkdir -p $PLAYGROUND/fx/longcol
: >| $PLAYGROUND/fx/longcol/"item-${(l:90::x:)}-1.txt"
: >| $PLAYGROUND/fx/longcol/"item-${(l:90::x:)}-2.txt"
: >| $PLAYGROUND/fx/longcol/"item-${(l:90::x:)}-3.txt"

typeset -gi HOSTFD=-1
typeset -g TRANSCRIPT= EXPECT_BUF=

send_line() { zpty -w  host $1 }
send_keys() { zpty -wn host $1 }

expect() {  # $1=glob $2=timeout(s)
  local pat=$1
  local -F deadline=$(( SECONDS + ${2:-10} ))
  EXPECT_BUF=
  local chunk
  while (( SECONDS < deadline )); do
    if zselect -t 20 -r $HOSTFD 2>/dev/null; then
      zpty -r host chunk 2>/dev/null || return 2
      EXPECT_BUF+=$chunk
      TRANSCRIPT+=$chunk
      [[ $EXPECT_BUF == ${~pat} ]] && return 0
      # Match again after stripping SGR that may split words for highlighting.
      [[ ${EXPECT_BUF//$'\e['[0-9;]#m/} == ${~pat} ]] && return 0
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
sync_prompt() { expect '*HP>*' ${1:-5} >/dev/null; drain 0.1 }
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

# Compare an exact ^Xb BUFFER dump against an expected string.
assert_buffer() {  # $1=expected buffer $2=label
  local want=${(qqqq)1}
  send_keys $'\C-xb'
  local -F dl=$(( SECONDS + 5 ))
  local last=
  local -a tl
  while (( SECONDS < dl )); do
    drain 0.15
    tl=( ${(f)"$(grep -F 'TESTBUF=' $ZRUSH_LOG 2>/dev/null)"} )
    (( $#tl )) && last=${tl[-1]#*TESTBUF=}
    [[ $last == "$want" ]] && { ok "$2"; return 0 }
  done
  ng "$2: buffer=${last:-?} want=$want"
  return 1
}

# Trigger a ^Xp/^Xh dump and return the freshest matching ZRUSH_LOG line's value
# (post-tag text) in REPLY. $1=dump key-sequence $2=log tag (TESTPOST|TESTRH).
dump_get() {
  send_keys $1
  local -F dl=$(( SECONDS + 5 ))
  local -a tl
  typeset -g REPLY=
  while (( SECONDS < dl )); do
    drain 0.15
    tl=( ${(f)"$(grep -F "$2=" $ZRUSH_LOG 2>/dev/null)"} )
    if (( $#tl )); then
      typeset -g REPLY=${tl[-1]#*$2=}
      return 0
    fi
  done
  return 1
}

{
  # ---------------- Host startup ----------------
  cd $PLAYGROUND || exit 1
  local REPLY=
  zpty -b host zsh -d -i || { ng "host failed to start"; exit 1 }
  HOSTFD=$REPLY
  if expect '*MARK-RC-DONE*' 20; then
    ok "host started + compinit + zrush.zsh sourced (protocol v2, config loaded)"
  else
    ng "unable to confirm host startup: ${(qqqq)EXPECT_BUF[-300,-1]}"
    exit 1
  fi
  sync_prompt

  # ================================================================ (1) Capture fork -> v2 records
  # (cap-1a) A real compsys fork collects candidates, ships v2 records (b header +
  # w/d), and the round trip through `zrush plan` renders a list.
  send_keys 'ls fx/basic/al'
  if expect '*alpha.txt*' 10; then
    ok "(cap-1a) fork capture -> zrush plan -> apply round trip renders a list"
  else
    ng "(cap-1a) list not displayed"
  fi
  clear_line
  drain 0.3

  # (cap-1b) The batch header's shared X/J tags reach `zrush plan` and come back
  # as a heading line (_files' 'file' tag with group-name '').
  send_keys 'ls fx/headed/'
  if expect '*file*plainfile.txt*' 10; then
    ok "(cap-1b) batch header group/heading tags (X/J) round-trip into a heading"
  else
    ng "(cap-1b) 'file' heading not displayed"
  fi
  clear_line
  drain 0.3

  # (cap-1c) w vs m: a candidate whose quoted form differs from its raw text.
  # The listing must show the raw text (m, cli-protocol.md "候補レコード"), and
  # confirming must insert the quoted form (w) so the shell word stays valid.
  send_keys 'ls fx/spacey/has'
  # 'space' alone would already match the typed 'spacey' path segment; require
  # the full candidate text so this actually waits for the async render.
  expect '*has space.txt*' 10 >/dev/null
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

  # ================================================================ (2) Async plumbing does not block input
  # A fake completion function that sleeps inside the fork; the parent shell
  # must keep echoing keystrokes while it runs.
  send_line '_zrushtestslow() { local -a m=(slowcandA slowcandB slowcandC); sleep 0.5; compadd -a m }'
  send_line 'compdef _zrushtestslow zrushtestslow'
  sync_prompt
  send_keys 'zrushtestslow '
  drain 0.4                     # let debounce elapse and the fork start (still sleeping)
  local -F t0=$SECONDS
  send_keys 'zzz'                # typed while the fork is asleep
  if expect '*z*z*z*' 2; then
    ok "(async-1a) input keeps echoing while a slow fork collection is in flight ($(( SECONDS - t0 ))s)"
  else
    ng "(async-1a) input blocked during slow collection"
  fi
  clear_line
  drain 0.8                      # let the stale in-flight collection settle (cancelled)
  send_keys 'zrushtestslow '
  if expect '*slowcandA*' 5; then
    ok "(async-1b) the pipeline completes end-to-end once the slow fork finishes"
  else
    ng "(async-1b) slow-completion candidates never rendered"
  fi
  clear_line
  drain 0.3

  # ================================================================ (3) Plan application: POSTDISPLAY + region_highlight
  send_keys 'ls fx/basic/al'
  expect '*alpha.txt*' 10 >/dev/null
  if dump_get $'\C-xp' TESTPOST; then
    local post=${(Q)REPLY}
    if [[ $post == $'\n'* && $post == *alpha.txt* && $post == *alsoalpha.txt* ]]; then
      ok "(apl-1a) POSTDISPLAY = leading newline + listing text for both candidates"
    else
      ng "(apl-1a) POSTDISPLAY malformed: ${(qqqq)post}"
    fi
  else
    ng "(apl-1a) POSTDISPLAY dump did not run"
  fi
  if dump_get $'\C-xh' TESTRH; then
    if [[ $REPLY == *underline* ]]; then
      ok "(apl-1b) region_highlight carries a match-role entry mapped to the default 'underline' spec"
    else
      ng "(apl-1b) no match-role highlight found: ${REPLY:-<none>}"
    fi
    if (( ! HAVE_MEMO )) || [[ $REPLY == *memo=zrush* ]]; then
      ok "(apl-1c) region_highlight entries are memo-tagged (or zsh<5.9, where memo is unavailable)"
    else
      ng "(apl-1c) memo=zrush missing on zsh >=5.9: ${REPLY:-<none>}"
    fi
  else
    ng "(apl-1b/c) region_highlight dump did not run"
  fi
  clear_line
  drain 0.3

  # ================================================================ (4) Selection: nav table + highlight swap
  send_keys 'ls fx/basic/al'
  expect '*alpha.txt*' 10 >/dev/null
  press $'\e[B'   # Down: select-next with nothing selected -> select-start (pos=1)
  if wait_log 'select: start' -1 3; then
    ok "(sel-1a) Down with a visible list starts selection (pos=1)"
  else
    ng "(sel-1a) selection did not start"
  fi
  if dump_get $'\C-xh' TESTRH; then
    if [[ $REPLY == *'memo=zrush-sel'* || ( ! HAVE_MEMO && $REPLY == *standout* ) ]]; then
      ok "(sel-1b) pos=1's own decoration (standout/selected) replaces its match highlight"
    else
      ng "(sel-1b) selected-cell decoration not found: ${REPLY:-<none>}"
    fi
  else
    ng "(sel-1b) region_highlight dump did not run"
  fi
  log_count 'select: dir=next'; local -i c_next=$REPLY
  press $'\e[B'
  wait_log 'select: dir=next' $c_next 3 && ok "(sel-1c) Down again moves via the nav table (select-next)" || ng "(sel-1c) select-next did not fire"
  log_count 'select: dir=prev'; local -i c_prev=$REPLY
  press $'\e[A'
  press $'\e[A'   # second Up: pos 1's prev = 0 (deselect)
  wait_log 'select: dir=prev' $c_prev 3 && ok "(sel-1d) Up moves via the nav table (select-prev)" || ng "(sel-1d) select-prev did not fire"
  if dump_get $'\C-xh' TESTRH; then
    if [[ $REPLY != *'-sel'* && $REPLY != *standout* ]]; then
      ok "(sel-1e) Up at position 1 deselects (no selected-cell decoration remains)"
    else
      ng "(sel-1e) selection was not released: ${REPLY:-<none>}"
    fi
  else
    ng "(sel-1e) region_highlight dump did not run"
  fi
  clear_line
  drain 0.3

  # select-left/right on a forced single-column grid jump to the group's
  # first/last position (cli-protocol.md "ナビ": grows == member count when cols=1).
  send_keys 'ls fx/longcol/item'
  expect '*item-*' 10 >/dev/null
  press $'\e[B'   # select-start at pos=1
  log_count 'select: dir=right'; local -i c_right=$REPLY
  press $'\e[C'
  wait_log 'select: dir=right' $c_right 3 && ok "(sel-2a) Right jumps toward the group's last position" || ng "(sel-2a) select-right did not fire"
  log_count 'select: dir=left'; local -i c_left=$REPLY
  press $'\e[D'
  wait_log 'select: dir=left' $c_left 3 && ok "(sel-2b) Left jumps back toward the group's first position" || ng "(sel-2b) select-left did not fire"
  press $'\C-g'
  clear_line
  drain 0.3

  # ================================================================ (5) Confirm: insertion text + RBUFFER preserved
  send_keys 'ls fx/basic/subd'
  # Typed text stops at 'subd' so the full candidate 'subdir' (the render) is
  # distinguishable from the just-echoed input.
  expect '*subdir*' 10 >/dev/null
  press $'\e[B'
  press $'\r'
  assert_buffer 'ls fx/basic/subdir/' "(cfm-1) confirm inserts the plan's insertion text (directory '/' synthesis, no trailing space)"
  clear_line
  drain 0.3

  # RBUFFER must survive confirmation untouched: type a word, move the cursor
  # back inside it, and confirm what's before the cursor only.
  send_keys 'ls fx/basic/alpEND'
  send_keys $'\e[D\e[D\e[D'   # Left x3: cursor lands between 'alp' and 'END'
  expect '*alpha.txt*' 10 >/dev/null
  press $'\e[B'
  press $'\r'
  assert_buffer 'ls fx/basic/alpha.txt END' "(cfm-2) RBUFFER ('END') is preserved verbatim after confirming mid-word"
  clear_line
  drain 0.3

  # ================================================================ (6) dismiss / accept-line
  send_keys 'ls fx/basic/'
  expect '*alpha.txt*' 10 >/dev/null
  log_count 'dismiss: closing list'; local -i c_dis=$REPLY
  press $'\C-g'
  wait_log 'dismiss: closing list' $c_dis 3 && ok "(dis-1a) dismiss closes the list" || ng "(dis-1a) dismiss did not work"
  assert_buffer 'ls fx/basic/' "(dis-1b) buffer is unchanged after dismiss"
  clear_line
  drain 0.3

  log_count 'line-finish: cleared'; local -i c_fin=$REPLY
  send_keys 'print HISTMARK-ACCEPT'
  send_keys $'\r'
  if expect '*HISTMARK-ACCEPT*' 5; then
    ok "(acc-1a) Enter without a selection executes the command via the predecessor chain"
  else
    ng "(acc-1a) command did not execute"
  fi
  sync_prompt
  wait_log 'line-finish: cleared' $c_fin 3 && ok "(acc-1b) accept-line resets zrush state (line-finish)" || ng "(acc-1b) line-finish not logged after accept-line"

  # ================================================================ (7) Empty-word collection cache: no fork on hit
  clear_line
  drain 0.5
  send_keys 'whic'
  expect '*which*' 10 >/dev/null
  clear_line
  drain 0.5
  log_count 'cache: hit';          local -i cc_hit=$REPLY
  log_count 'request: collecting'; local -i cc_col=$REPLY
  send_keys 'whic'
  if wait_log 'cache: hit' $cc_hit 5; then
    ok "(cc-1a) second command-position query hits the empty-word cache"
  else
    ng "(cc-1a) cache hit not logged"
  fi
  drain 0.5
  log_count 'request: collecting'; local -i cc_col2=$REPLY
  if (( cc_col2 == cc_col )); then
    ok "(cc-1b) no new fork is started on a cache hit ($cc_col -> $cc_col2)"
  else
    ng "(cc-1b) a fork ran despite the expected cache hit ($cc_col -> $cc_col2)"
  fi
  clear_line
  drain 0.3

  # ================================================================ (8) Tab pending
  # Default [insert].tab=menu, so a Tab that lands before candidates arrive
  # must, once they arrive, start selection -- not change the buffer.
  log_count 'tab: pending'; local -i c_pend=$REPLY
  log_count 'select: start'; local -i c_tstart=$REPLY
  send_keys 'ls fx/basic/al'$'\t'   # Tab in the same burst, before debounce elapses
  wait_log 'tab: pending' $c_pend 3 && ok "(tab-1a) Tab pressed before candidates arrive is recorded (pending)" || ng "(tab-1a) pending path not logged"
  if wait_log 'select: start' $c_tstart 5; then
    ok "(tab-1b) once candidates arrive, the pending Tab applies (menu -> selection starts)"
  else
    ng "(tab-1b) pending Tab was not applied on arrival"
  fi
  press $'\C-g'
  clear_line
  drain 0.3

  # ================================================================ (9) Error path: a broken ZRUSH_BIN
  # Sanity: the (still-working) private binary copy behaves normally first.
  send_keys 'ls fx/basic/al'
  if expect '*alpha.txt*' 10; then
    ok "(err-0) sanity: the private ZRUSH_BIN copy still works before corruption"
  else
    ng "(err-0) sanity check failed before corrupting the binary; aborting error-path test"
  fi
  clear_line
  drain 0.3

  print -r -- $'#!/bin/sh\nexit 7' > $WORK/bin/zrush
  chmod +x $WORK/bin/zrush
  TRANSCRIPT=
  send_keys 'ls fx/basic/al'
  if expect '*zrush: zrush plan failed*' 10; then
    ok "(err-1a) a broken zrush binary triggers exactly one warning on the first collection"
  else
    ng "(err-1a) no warning shown for a broken binary"
  fi
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
  clear_line
  drain 0.5
  send_keys 'ls fx/basic/'
  drain 1.5
  local -i warn_count=${#${(M)${(f)TRANSCRIPT}:#*zrush: zrush plan failed*}}
  if (( warn_count == 1 )); then
    ok "(err-1c) the warning is not repeated on a second failing collection (session-once)"
  else
    ng "(err-1c) warning fired $warn_count times, expected exactly 1"
  fi
  clear_line
  drain 0.3
  send_keys 'print HISTMARK-AFTER-ERROR'
  send_keys $'\r'
  if expect '*HISTMARK-AFTER-ERROR*' 5; then
    ok "(err-1d) the shell keeps responding normally after zrush plan failures"
  else
    ng "(err-1d) shell did not respond after zrush plan failures"
  fi
  sync_prompt

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  zpty -d host 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-test.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
