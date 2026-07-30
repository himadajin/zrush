#!/bin/zsh -f
# Headless coexistence and real-environment checks for zrush.
#
# Usage:
#   zsh -f tests/zsh/driver-coexist.zsh <playground-dir>
# Prerequisites:
#   - cargo build --release completed
#   - /opt/homebrew/share/zsh-abbr, /opt/homebrew/share/zsh-syntax-highlighting
#   - /opt/homebrew/bin/tmux (started with a dedicated -L socket; no real sessions touched)
#
# Covers zsh-abbr, z-sy-h, all three together, tmux with resizing, concurrent
# shells, PS2 continuation, and recorded full-width rendering.
# All tests isolate ZDOTDIR, HOME, XDG, and ABBR files in temporary storage.
emulate -L zsh
setopt extended_glob
zmodload zsh/zpty    || { print -u2 FATAL: zpty; exit 1 }
zmodload zsh/zselect || { print -u2 FATAL: zselect; exit 1 }
zmodload zsh/system  || { print -u2 FATAL: system; exit 1 }

typeset -F SECONDS
typeset -g HERE=${${(%):-%N}:A:h}
typeset -g REPO=${HERE:h:h}
typeset -g PLAYGROUND=${1:?usage: driver-coexist.zsh <playground-dir>}
typeset -g ABBR_SRC=/opt/homebrew/share/zsh-abbr/zsh-abbr.zsh
typeset -g ZSYH_SRC=/opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
typeset -g TMUX_BIN=/opt/homebrew/bin/tmux
[[ -d $PLAYGROUND/docs ]] || { print -u2 "FATAL: invalid playground"; exit 1 }
[[ -r $ABBR_SRC && -r $ZSYH_SRC && -x $TMUX_BIN ]] || { print -u2 "FATAL: dependencies not found"; exit 1 }
[[ -x $REPO/target/release/zrush ]] || { print -u2 "FATAL: zrush binary not found"; exit 1 }

typeset -gi PASS=0 FAIL=0
out() { print -r -u2 -- "$@" }
ok()  { out "PASS: $1"; (( ++PASS )) }
ng()  { out "FAIL: $1"; (( ++FAIL )) }

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-coex.XXXXXX)
export TERM=xterm-256color
# POSTDISPLAY passes through ZLE rendering, which escapes UTF-8 bytes as unprintable
# under the C locale. Explicitly match the UTF-8 locale used in practice.
export LC_ALL=en_US.UTF-8
export HOME=$PLAYGROUND
export XDG_CONFIG_HOME=$WORK/xdg
export ZRUSH_REPO=$REPO
mkdir -p $WORK/xdg

# Idempotent fixtures for full-width and resize checks
mkdir -p $PLAYGROUND/wide
: >| $PLAYGROUND/wide/"longname-${(l:110::x:)}.txt"
: >| $PLAYGROUND/wide/"jp-日本語の長い名前のファイルで表示崩れを確認する.txt"
: >| $PLAYGROUND/wide/"jp-これは二つ目の全角ファイル名です.txt"

# ---------------------------------------------------------------- Generate rc files
# ^Xb dumps BUFFER to ZRUSH_LOG, matching the driver.zsh test helper.
typeset -g DUMPW='
_zrt_dump_buffer() { _zlog "TESTBUF=${(qqqq)BUFFER}" }
zle -N _zrt-dump-buffer _zrt_dump_buffer
bindkey "^Xb" _zrt-dump-buffer'

mk_zdot() {  # $1=name $2=rc body
  local d=$WORK/zdot-$1
  mkdir -p $d
  print -r -- "$2" > $d/.zshrc
  print -r -- $d
}

typeset -g RC_COMMON="PS1='HP> '
autoload -Uz compinit
compinit -u -d \$ZRUSH_TEST_TMP/zcompdump
"

typeset -g ZDOT_ABBR=$(mk_zdot abbr "$RC_COMMON
export ABBR_USER_ABBREVIATIONS_FILE=\$ZRUSH_TEST_TMP/abbr-user
touch \$ABBR_USER_ABBREVIATIONS_FILE
source $ABBR_SRC
abbr -S zzz='print ABBR-EXPANDED-OK' >/dev/null
source $REPO/zsh/zrush.zsh
$DUMPW
print MARK-RC-DONE")

typeset -g ZDOT_ZSYH=$(mk_zdot zsyh "$RC_COMMON
source $REPO/zsh/zrush.zsh
$DUMPW
source $ZSYH_SRC
print MARK-RC-DONE")

typeset -g ZDOT_ALL=$(mk_zdot all "$RC_COMMON
export ABBR_USER_ABBREVIATIONS_FILE=\$ZRUSH_TEST_TMP/abbr-user
touch \$ABBR_USER_ABBREVIATIONS_FILE
source $ABBR_SRC
abbr -S zzz='print ABBR-EXPANDED-OK' >/dev/null
source $REPO/zsh/zrush.zsh
$DUMPW
source $ZSYH_SRC
print MARK-RC-DONE")

typeset -g ZDOT_MIN=$(mk_zdot min "source $REPO/tests/zsh/rc/minimal.zshrc")

# ---------------------------------------------------------------- Host operations with multi-host support
typeset -gA HFD=()
typeset -g HOST= CURLOG=
typeset -gi HOSTFD=-1
typeset -g TRANSCRIPT= EXPECT_BUF=

start_host() {  # $1=host name $2=ZDOTDIR $3=log file $4=working tmp
  export ZDOTDIR=$2
  export ZRUSH_LOG=$3
  export ZRUSH_TEST_TMP=${4:-$WORK}
  mkdir -p $ZRUSH_TEST_TMP
  cd $PLAYGROUND || return 1
  local REPLY=
  zpty -b $1 zsh -d -i || return 1
  HFD[$1]=$REPLY
  use_host $1 $3
  expect '*MARK-RC-DONE*' 30 || return 1
  sync_prompt
  return 0
}

use_host() { HOST=$1; HOSTFD=${HFD[$1]}; CURLOG=${2:-$CURLOG} }
stop_host() { zpty -d $1 2>/dev/null; unset "HFD[$1]" }

send_line() { zpty -w  $HOST $1 }
send_keys() { zpty -wn $HOST $1 }

expect() {
  local pat=$1
  local -F deadline=$(( SECONDS + ${2:-10} ))
  EXPECT_BUF=
  local chunk
  while (( SECONDS < deadline )); do
    if zselect -t 20 -r $HOSTFD 2>/dev/null; then
      zpty -r $HOST chunk 2>/dev/null || return 2
      EXPECT_BUF+=$chunk
      TRANSCRIPT+=$chunk
      [[ $EXPECT_BUF == ${~pat} ]] && return 0
      # Match again after stripping SGR that may split words for highlighting.
      # Raw escape-sequence patterns already had the first chance to match above.
      [[ ${EXPECT_BUF//$'\e['[0-9;]#m/} == ${~pat} ]] && return 0
    fi
  done
  return 1
}

drain() {
  local -F dl=$(( SECONDS + ${1:-0.2} ))
  local chunk
  while (( SECONDS < dl )); do
    if zselect -t 10 -r $HOSTFD 2>/dev/null; then
      zpty -r $HOST chunk 2>/dev/null && TRANSCRIPT+=$chunk
    fi
  done
}

clear_line()  { send_keys $'\C-u'; drain 0.25 }
sync_prompt() { expect '*HP>*' ${1:-5} >/dev/null; drain 0.1 }

assert_buffer() {  # $1=expected buffer $2=label; compare ^Xb dump
  local want=${(qqqq)1}
  send_keys $'\C-xb'
  local -F dl=$(( SECONDS + 5 ))
  local last=
  local -a tl
  while (( SECONDS < dl )); do
    drain 0.15
    tl=( ${(f)"$(grep -F 'TESTBUF=' $CURLOG 2>/dev/null)"} )
    (( $#tl )) && last=${tl[-1]#*TESTBUF=}
    [[ $last == "$want" ]] && { ok "$2"; return 0 }
  done
  ng "$2: buffer=${last:-?} want=$want"
  return 1
}

typeset -g DOWN=$'\e[B' UP=$'\e[A' ENTER=$'\r' CTRLC=$'\C-c'
press() { send_keys $1; drain 0.3 }

clog_count() {  # $1=fixed string -> REPLY: occurrence count in CURLOG
  typeset -g REPLY=0
  [[ -r $CURLOG ]] && REPLY=$(grep -cF -- $1 $CURLOG 2>/dev/null)
  return 0
}
wait_clog() {  # $1=fixed string $2=baseline $3=timeout(s) -> 0 when count increases
  local -F dl=$(( SECONDS + ${3:-5} ))
  while (( SECONDS < dl )); do
    drain 0.15
    clog_count $1
    (( REPLY > $2 )) && return 0
  done
  return 1
}

# Shared flow that verifies listing, selection, and confirmation on the current host
basic_flow() {  # $1=label prefix
  send_keys 'ls docs/inte'
  if expect '*internal*' 10; then
    ok "$1: list displayed automatically"
  else
    ng "$1: list not displayed"
    return 1
  fi
  clog_count 'selected=1'; local -i c_sel=$REPLY
  send_keys $DOWN
  if wait_clog 'selected=1' $c_sel 5; then
    ok "$1: Down starts selection (rendered with selected=1)"
  else
    ng "$1: unable to select"
  fi
  press $ENTER
  assert_buffer 'ls docs/internal/' "$1: confirmed insertion of 'ls docs/internal/'"
  clear_line
  drain 0.3
}

{
  # ================ (1) zsh-abbr coexistence (abbr -> zrush) ================
  out "==== (1) zsh-abbr coexistence ===="
  if start_host h_abbr $ZDOT_ABBR $WORK/abbr.log $WORK/t-abbr; then
    ok "(1) abbr+zrush host started"
    send_keys 'zzz'
    drain 0.5
    send_keys $ENTER          # press() would consume output while draining
    if expect '*ABBR-EXPANDED-OK*' 8; then
      ok "(1a) abbreviation expansion works on Enter without selection (via predecessor chain)"
    else
      ng "(1a) abbreviation expansion does not work"
    fi
    sync_prompt
    basic_flow "(1b)"
  else
    ng "(1) abbr host failed to start"
  fi
  stop_host h_abbr

  # ================ (2) zsh-syntax-highlighting coexistence (zrush -> z-sy-h) ================
  out "==== (2) z-sy-h coexistence ===="
  if start_host h_zsyh $ZDOT_ZSYH $WORK/zsyh.log $WORK/t-zsyh; then
    ok "(2) zrush+z-sy-h host started"
    send_keys 'qqqqxx'
    if expect '*'$'\e''\[31m*' 8; then
      ok "(2a) highlighting works (SGR output for unknown-token)"
    else
      ng "(2a) highlighting SGR not observed"
    fi
    clear_line
    drain 0.5
    basic_flow "(2c)"   # listing + selection + confirmation exercises pre-redraw and wrapped dispatch
  else
    ng "(2) z-sy-h host failed to start"
  fi
  stop_host h_zsyh

  # ================ (3) Three-way coexistence (abbr -> zrush -> z-sy-h) ================
  out "==== (3) three-way coexistence ===="
  if start_host h_all $ZDOT_ALL $WORK/all.log $WORK/t-all; then
    ok "(3) three-way host started"
    basic_flow "(3a)"
    send_keys 'zzz'
    drain 0.5
    send_keys $ENTER
    if expect '*ABBR-EXPANDED-OK*' 8; then
      ok "(3b) Enter abbreviation expansion works with all three tools"
    else
      ng "(3b) abbreviation expansion is broken with all three tools"
    fi
    sync_prompt
    send_keys 'qqqqxx'
    expect '*'$'\e''\[31m*' 8 && ok "(3c) highlighting works with all three tools" || ng "(3c) highlighting lost"
    clear_line
  else
    ng "(3) three-way host failed to start"
  fi
  stop_host h_all

  # ================ (5) Concurrent shells and collection ================
  out "==== (5) multiple shell instances ===="
  if start_host h1 $ZDOT_MIN $WORK/h1.log $WORK/t1 && start_host h2 $ZDOT_MIN $WORK/h2.log $WORK/t2; then
    ok "(5) two hosts started concurrently"
    use_host h1 $WORK/h1.log; send_keys 'ls docs/inte'
    use_host h2 $WORK/h2.log; send_keys 'ls ../huge/file0000'
    use_host h1 $WORK/h1.log
    expect '*internal*' 10 && ok "(5a) host1 list displayed (concurrent collection)" || ng "(5a) host1 failed"
    use_host h2 $WORK/h2.log
    expect '*file00000.txt*' 30 && ok "(5b) host2 list displayed (concurrent huge collection)" || ng "(5b) host2 failed"
    use_host h1 $WORK/h1.log; press $DOWN; press $ENTER
    assert_buffer 'ls docs/internal/' "(5c) host1 confirms correctly with multiple instances"
    clear_line
  else
    ng "(5) failed to start multiple instances"
  fi
  stop_host h2

  # ================ (6) Multiline input through PS2 continuation ================
  out "==== (6) multiline PS2 ===="
  use_host h1 $WORK/h1.log
  send_keys 'for i in 1 2'
  press $ENTER            # incomplete command -> PS2 continuation in the same ZLE session
  drain 0.5
  send_keys 'ls docs/inte'
  if expect '*internal*' 10; then
    ok "(6a) list displayed on PS2 continuation line"
  else
    ng "(6a) list not displayed under PS2"
  fi
  clog_count 'selected=1'; local -i c6sel=$REPLY
  send_keys $DOWN
  wait_clog 'selected=1' $c6sel 5 && ok "(6b) selection starts under PS2 (priority 3 because this is the last line)" || ng "(6b) unable to select under PS2"
  press $ENTER
  # Each PS2 continuation line has its own ZLE session, so BUFFER contains only that
  # line. A multiline BUFFER instead requires a self-inserted newline such as ESC-Enter.
  # The confirmed BUFFER should therefore contain only the continuation line.
  assert_buffer 'ls docs/internal/' "(6c) confirmed insertion works within a PS2 continuation line (no display corruption)"
  press $CTRLC            # discard the line
  drain 0.5

  # ================ (7) Full-width rendering (record only) ================
  out "==== (7) full-width characters (observation) ===="
  sync_prompt 3
  send_keys 'ls wide/jp-'
  if expect '*日本語*' 10; then
    ok "(7) full-width filenames are listed (no crash)"
    drain 0.5
    local seg=${TRANSCRIPT[-600,-1]}
    out "OBSV: (7) raw full-width rendering output (cell width is based on \${(m)} display width): ${(qqqq)${(M)${(f)${seg//$'\r'/}}:#*jp-*}}"
  else
    ng "(7) full-width filename list not displayed"
  fi
  clear_line
  stop_host h1

  # ================ (4)(8) Inside tmux with resizing ================
  out "==== (4)(8) tmux ===="
  local TSOCK=zrush-coex-$$
  tm() { $TMUX_BIN -L $TSOCK -f /dev/null "$@" }
  tm_cap() { tm capture-pane -p -t coex 2>/dev/null }
  tm_wait() {  # $1=glob $2=timeout
    local -F dl=$(( SECONDS + ${2:-10} ))
    while (( SECONDS < dl )); do
      [[ "$(tm_cap)" == ${~1} ]] && return 0
      command sleep 0.2
    done
    return 1
  }
  local TLOG=$WORK/tmux.log
  tm new-session -d -s coex -x 100 -y 30 \
    "ZDOTDIR=$ZDOT_MIN XDG_CONFIG_HOME=$WORK/xdg HOME=$PLAYGROUND ZRUSH_REPO=$REPO ZRUSH_TEST_TMP=$WORK/t-tmux ZRUSH_LOG=$TLOG exec zsh -d -i" 2>/dev/null
  if tm_wait '*HP>*' 15; then
    ok "(4) host started inside tmux (TERM=$(tm display-message -p -t coex '#{client_termname}' 2>/dev/null || print '?'))"
    tm send-keys -t coex -l ' print -r -- TERM-INSIDE-$TERM'
    tm send-keys -t coex Enter
    tm_wait '*TERM-INSIDE-*' 5 && out "INFO: $(tm_cap | grep -o 'TERM-INSIDE-[a-z0-9-]*' | tail -1)"
    # Before resize, truncate a long candidate line from width 100 to 99.
    tm send-keys -t coex -l 'ls wide/lo'
    if tm_wait '*longname-*' 10; then
      local line1=$(tm_cap | grep -m1 -o 'longname-x*' )
      out "INFO: (8) rendered length at width=100: ${#line1}"
      tm resize-window -t coex -x 60 -y 20 2>/dev/null
      command sleep 0.5
      tm send-keys -t coex -l 'n'      # trigger redraw for 'ls wide/lon'
      command sleep 1.5
      local line2=$(tm_cap | grep -m1 -o 'longname-x*')
      out "INFO: (8) rendered length at width=60: ${#line2}"
      if (( ${#line2} > 0 && ${#line2} < 60 && ${#line2} < ${#line1} )); then
        ok "(8) new COLUMNS takes effect on the next render after resizing (${#line1} → ${#line2})"
      else
        ng "(8) incorrect truncation after resizing (${#line1} → ${#line2})"
      fi
    else
      ng "(8) list not displayed inside tmux"
    fi
    tm send-keys -t coex C-u
    command sleep 0.3
    # Basic tmux flow; tmux sends the TERM-equivalent Down sequence resolved by terminfo.
    tm send-keys -t coex -l 'ls docs/inte'
    if tm_wait '*internal*' 10; then
      ok "(4a) list displayed inside tmux"
      local -i c4sel=0
      [[ -r $TLOG ]] && c4sel=$(grep -cF 'selected=1' $TLOG 2>/dev/null)
      tm send-keys -t coex Down
      local -F dl4=$(( SECONDS + 5 ))
      local -i c4now=0
      while (( SECONDS < dl4 )); do
        command sleep 0.2
        [[ -r $TLOG ]] && c4now=$(grep -cF 'selected=1' $TLOG 2>/dev/null)
        (( c4now > c4sel )) && break
      done
      if (( c4now > c4sel )); then
        ok "(4b) Down selects inside tmux (terminfo key resolution, rendered with selected=1)"
      else
        ng "(4b) unable to select inside tmux"
      fi
      # Also record actual selection-highlight rendering (SGR 7).
      if [[ "$($TMUX_BIN -L $TSOCK -f /dev/null capture-pane -p -e -t coex 2>/dev/null)" == *$'\e[7m'* ]]; then
        out "OBSV: (4b) confirmed standout (SGR 7) in tmux pane"
      else
        out "OBSV: (4b) unable to confirm standout in tmux pane (manual verification required)"
      fi
      tm send-keys -t coex Enter
      command sleep 0.5
      tm send-keys -t coex C-x b
      local -F dl=$(( SECONDS + 5 ))
      local tlast=
      local -a ttl
      while (( SECONDS < dl )); do
        command sleep 0.2
        ttl=( ${(f)"$(grep -F 'TESTBUF=' $TLOG 2>/dev/null)"} )
        (( $#ttl )) && tlast=${ttl[-1]#*TESTBUF=}
        [[ $tlast == "${(qqqq):-ls docs/internal/}" ]] && break
      done
      if [[ $tlast == "${(qqqq):-ls docs/internal/}" ]]; then
        ok "(4c) confirmed insertion works inside tmux"
      else
        ng "(4c) incorrect confirmation inside tmux: ${tlast:-?}"
      fi
    else
      ng "(4a) list not displayed inside tmux"
    fi
  else
    ng "(4) host failed to start inside tmux: $(tm_cap | tail -3)"
  fi
  tm kill-server 2>/dev/null

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  local h
  for h in "${(@k)HFD}"; do zpty -d $h 2>/dev/null; done
  $TMUX_BIN -L zrush-coex-$$ kill-server 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-coex.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
