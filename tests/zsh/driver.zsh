#!/bin/zsh -f
# Headless zle-integration smoke driver for zrush.zsh.
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

# A send-break reset for scenarios that can leave a multiline BUFFER: ^U
# (backward-kill-line) only clears the current physical line of a multiline
# buffer, so those scenarios need a real line abandon + resync instead.
reset_line() { send_keys $'\C-c'; drain 0.3; sync_prompt 5 }

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
  expect '*MARK-RC-DONE*' 20 || return 1
  drain 0.3
  return 0
}

{
  # ---------------- Host startup ----------------
  cd $PLAYGROUND || exit 1
  local REPLY=
  zpty -b host zsh -d -i || { ng "host failed to start"; exit 1 }
  HOSTFD=$REPLY
  if expect '*MARK-RC-DONE*' 20; then
    ok "host started + compinit + zrush.zsh sourced (config loaded)"
  else
    ng "unable to confirm host startup: ${(qqqq)EXPECT_BUF[-300,-1]}"
    exit 1
  fi
  sync_prompt

  # ================================================================ (1) Capture fork -> candidate records
  # (cap-1a) A real compsys fork collects candidates, ships candidate records
  # (b header + w/d), and the round trip through `zrush plan` renders a list.
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

  # Regression (cap-2): a compadd call with zero hits must still tail-call the
  # real builtin (_zrush_compadd), or compsys internal state can desync and
  # break the *next* completion. A prefix with no real match yields at least
  # one zero-hit compadd call inside compsys; a normal completion right after
  # must still work cleanly.
  send_keys 'ls fx/basic/ZZZNOMATCH'
  drain 0.8   # let debounce + collection + the (zero-result) plan settle
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

  # Regression (dis-2): dismiss must cancel any still-armed debounce timer /
  # in-flight collection for a newer keystroke, or a late-arriving result can
  # silently reopen the list right after the user closed it. Reproduced with
  # git's naturally slow (~150ms+) subcommand completion -- no extra fixture
  # needed. The buffer edit below never goes through a blank state, so the
  # first (broader) list stays visible (no-flash design) while the narrowing
  # 'git chec' collection is armed/in flight; dismissing at that instant must
  # win the race even though the narrower collection is still pending.
  send_keys 'git c'
  expect '*checkout*' 10 >/dev/null   # first list showing; _zrush_listing=1
  send_keys 'hec'                     # -> 'git chec': re-arms debounce/collection
  send_keys $'\C-g'                   # dismiss immediately, no drain in between
  drain 1.0                           # comfortably longer than 'git chec' compsys (~150-200ms)
  if dump_get $'\C-xp' TESTPOST; then
    local post_dis2=${(Q)REPLY}
    if [[ -z $post_dis2 ]]; then
      ok "(dis-2) dismiss cancels the in-flight collection; no late result reopens the list"
    else
      ng "(dis-2) list reappeared after dismiss (stale collection not cancelled): ${(qqqq)post_dis2}"
    fi
  else
    ng "(dis-2) POSTDISPLAY dump did not run"
  fi
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

  # ================================================================ Regression: send-break leaves a clean new prompt (fix 3)
  # An exit that bypasses _zrush_line_finish (send-break and similar) must
  # not leak the previous session's plan state into the next one. A
  # test-only widget dumps _zrush_plan_npos/_zrush_listing directly, since
  # neither is observable through POSTDISPLAY/BUFFER alone once the new
  # prompt's line-init has already cleared the display.
  send_line '_zrt_dump_plan() { _zlog "TESTPLAN=npos=$_zrush_plan_npos listing=$_zrush_listing" }; zle -N _zrt-dump-plan _zrt_dump_plan; bindkey "^Xy" _zrt-dump-plan'
  sync_prompt
  send_keys 'ls fx/basic/al'
  expect '*alpha.txt*' 10 >/dev/null   # real, non-empty _zrush_plan_* now populated
  send_keys $'\C-c'                    # send-break: abandon the line, bypassing line-finish
  if sync_prompt 5; then
    ok "(sb-1a) a new prompt appears after send-break"
    if dump_get $'\C-xy' TESTPLAN; then
      if [[ $REPLY == *'npos=0'* && $REPLY == *'listing=0'* ]]; then
        ok "(sb-1b) plan state is reset after send-break (npos=0, listing=0); no stale candidates leak into the new prompt"
      else
        ng "(sb-1b) stale plan state survived send-break: ${REPLY:-<none>}"
      fi
    else
      ng "(sb-1b) plan-state dump did not run"
    fi
  else
    out "SKIP: (sb-1) send-break did not produce a new prompt in this environment; skipping the plan-state check"
  fi
  clear_line
  drain 0.3
  send_line 'bindkey -r "^Xy"; zle -D _zrt-dump-plan; unfunction _zrt_dump_plan'
  sync_prompt

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

  # Regression (err-2): a pending Tab resolved against a *failed* plan must
  # never insert anything (_zrush_settle_plan's failure branch discards the
  # pending Tab outright rather than resolving it, possibly against stale
  # _zrush_plan_* from an earlier successful query). ZRUSH_BIN is still the
  # broken copy from the block above.
  send_keys 'ls fx/basic/al'$'\t'   # Tab races the debounce; the plan fetch will fail
  drain 1.0
  assert_buffer 'ls fx/basic/al' "(err-2) pending Tab resolved against a failed plan inserts nothing"
  clear_line
  drain 0.3

  # ================================================================ (10) History menu (issue #9)
  # docs/internal/specs/behavior.md "履歴メニュー" and cli-protocol.md
  # "history profile" are the source of truth. This section runs on its own
  # host(s) with fixture history (tests/zsh/rc/history.zshrc and friends)
  # instead of the "host" pty used above, so it starts by restoring the
  # shared private ZRUSH_BIN copy the (err-1/err-2) section just corrupted.
  # The fixture history is isolated (HISTFILE under $WORK, SAVEHIST=0) and
  # never touches the real ~/.zsh_history (AGENTS.md guardrail).
  cp $REPO/target/release/zrush $WORK/bin/zrush
  chmod +x $WORK/bin/zrush

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
  log_count 'plan: ok producer=compsys'; local -i cc0=$REPLY
  press $'\r'
  if wait_log 'plan: ok producer=compsys' $cc0 3; then
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
  log_count 'plan: ok producer=compsys'; local -i cc1=$REPLY
  press $'\t'
  if wait_log 'plan: ok producer=compsys' $cc1 3; then
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

  # ---- (h24) audit A2: a synchronous history-producer plan failure (same
  # broken-binary technique as err-1/err-2, which only exercise the async
  # compsys path) must leave no menu, no residual kind/listing, the buffer
  # untouched, and the shell responsive (cli-protocol.md "エラー時の zsh 側
  # 挙動" applies to `zrush plan --producer history`'s synchronous invocation
  # exactly as it does to the async compsys one).
  # An empty buffer (rather than a typed query) avoids a confound: typing
  # anything here would also arm its own compsys collection, which (via the
  # already-warm empty-word cache from earlier scenarios on this host) would
  # hit the broken binary synchronously and consume the session's one-time
  # warning before the history-menu attempt below even runs.
  print -r -- $'#!/bin/sh\nexit 7' > $WORK/bin/zrush
  chmod +x $WORK/bin/zrush
  TRANSCRIPT=
  send_keys $'\e[A'   # raw send, not press: press's own drain would already
                       # consume the one-shot warning before expect looks for it
  if expect '*zrush: zrush plan failed*' 10; then
    ok "(h24a) a broken zrush binary triggers a warning when opening the history menu"
  else
    ng "(h24a) no warning shown for a broken binary on the history-menu path"
  fi
  if dump_get $'\C-xk' TESTKIND; then
    [[ $REPLY == 'kind=none sel=0 listing=0 npos=0' ]] && ok "(h24b) no menu/kind/listing survives the failed sync plan" || ng "(h24b) $REPLY"
  fi
  assert_buffer '' "(h24c) buffer is unchanged after the failed sync plan"
  cp $REPO/target/release/zrush $WORK/bin/zrush
  chmod +x $WORK/bin/zrush
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
  [[ $REPLY == 'kind=history'* ]] || ng "(h26-setup) history menu did not open: $REPLY"
  send_keys $'\C-c'   # send-break: abandon the line, bypassing confirm/dismiss/line-finish
  if sync_prompt 5; then
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
  if sync_prompt 5; then
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
    if sync_prompt 5; then
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

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  zpty -d host 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-test.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
