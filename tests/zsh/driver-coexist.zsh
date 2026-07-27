#!/bin/zsh -f
# zrush の共存・実機系ヘッドレス検証(plan.md M5 チェックリストの事前検証)。
#
# 実行方法:
#   zsh -f tests/zsh/driver-coexist.zsh <playground-dir>
# 前提:
#   - cargo build --release 済み
#   - /opt/homebrew/share/zsh-abbr, /opt/homebrew/share/zsh-syntax-highlighting
#   - /opt/homebrew/bin/tmux(専用ソケット -L で起動。実セッションに触れない)
#
# 検証対象: zsh-abbr 共存 / z-sy-h 共存 / 三者共存 / tmux 内 + リサイズ /
#           シェル多重起動 / PS2 複数行 / 全角幅(記録のみ)。
# すべて隔離環境(ZDOTDIR/HOME/XDG/ABBR ファイルを一時領域へ)。
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
[[ -d $PLAYGROUND/docs ]] || { print -u2 "FATAL: playground 不備"; exit 1 }
[[ -r $ABBR_SRC && -r $ZSYH_SRC && -x $TMUX_BIN ]] || { print -u2 "FATAL: 依存物が見つからない"; exit 1 }
[[ -x $REPO/target/release/zrush ]] || { print -u2 "FATAL: zrush バイナリがない"; exit 1 }

typeset -gi PASS=0 FAIL=0
out() { print -r -u2 -- "$@" }
ok()  { out "PASS: $1"; (( ++PASS )) }
ng()  { out "FAIL: $1"; (( ++FAIL )) }

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-coex.XXXXXX)
export TERM=xterm-256color
# POSTDISPLAY は zle の表示ロジックを通るため、C ロケールだと UTF-8 バイトが
# 印字不能文字としてエスケープ表示される。実利用環境と同じ UTF-8 を明示する。
export LC_ALL=en_US.UTF-8
export HOME=$PLAYGROUND
export XDG_CONFIG_HOME=$WORK/xdg
export ZRUSH_REPO=$REPO
mkdir -p $WORK/xdg

# 全角幅・リサイズ検証用 fixtures(冪等)
mkdir -p $PLAYGROUND/wide
: >| $PLAYGROUND/wide/"longname-${(l:110::x:)}.txt"
: >| $PLAYGROUND/wide/"jp-日本語の長い名前のファイルで表示崩れを確認する.txt"
: >| $PLAYGROUND/wide/"jp-これは二つ目の全角ファイル名です.txt"

# ---------------------------------------------------------------- rc 生成
# ^Xb = BUFFER を ZRUSH_LOG にダンプ(driver.zsh と同じテスト支援)
typeset -g DUMPW='
_zrt_dump_buffer() { _zlog "TESTBUF=${(qqqq)BUFFER}" }
zle -N _zrt-dump-buffer _zrt_dump_buffer
bindkey "^Xb" _zrt-dump-buffer'

mk_zdot() {  # $1=名前 $2=rc 本文
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

# ---------------------------------------------------------------- ホスト操作(複数ホスト対応)
typeset -gA HFD=()
typeset -g HOST= CURLOG=
typeset -gi HOSTFD=-1
typeset -g TRANSCRIPT= EXPECT_BUF=

start_host() {  # $1=ホスト名 $2=ZDOTDIR $3=ログファイル $4=作業tmp
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
      # マッチ箇所ハイライト等の SGR が語の途中に挟まるため、SGR を
      # 剥がした形でも照合する(生パターン指定のテストは上で先に通る)
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

assert_buffer() {  # $1=期待バッファ $2=ラベル(^Xb ダンプ比較)
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

clog_count() {  # $1=固定文字列 → REPLY: CURLOG 内の出現回数
  typeset -g REPLY=0
  [[ -r $CURLOG ]] && REPLY=$(grep -cF -- $1 $CURLOG 2>/dev/null)
  return 0
}
wait_clog() {  # $1=固定文字列 $2=基準値 $3=timeout(s) → 増えたら 0
  local -F dl=$(( SECONDS + ${3:-5} ))
  while (( SECONDS < dl )); do
    drain 0.15
    clog_count $1
    (( REPLY > $2 )) && return 0
  done
  return 1
}

# zrush の基本フロー(一覧→選択→確定)を現在のホストで検証する共通手順
basic_flow() {  # $1=ラベル接頭辞
  send_keys 'ls docs/inte'
  if expect '*internal*' 10; then
    ok "$1: 一覧の自動表示"
  else
    ng "$1: 一覧が出ない"
    return 1
  fi
  clog_count 'selected=1'; local -i c_sel=$REPLY
  send_keys $DOWN
  if wait_clog 'selected=1' $c_sel 5; then
    ok "$1: ↓ で選択(selected=1 で描画)"
  else
    ng "$1: 選択できない"
  fi
  press $ENTER
  assert_buffer 'ls docs/internal/' "$1: 確定挿入 'ls docs/internal/'"
  clear_line
  drain 0.3
}

{
  # ================ (1) zsh-abbr 共存(abbr → zrush)================
  out "==== (1) zsh-abbr 共存 ===="
  if start_host h_abbr $ZDOT_ABBR $WORK/abbr.log $WORK/t-abbr; then
    ok "(1) abbr+zrush ホスト起動"
    send_keys 'zzz'
    drain 0.5
    send_keys $ENTER          # press() は drain が出力を先食いするため使わない
    if expect '*ABBR-EXPANDED-OK*' 8; then
      ok "(1a) 非選択時 Enter で略語展開が生きる(前任者チェーン経由)"
    else
      ng "(1a) 略語展開が動かない"
    fi
    sync_prompt
    basic_flow "(1b)"
  else
    ng "(1) abbr ホスト起動失敗"
  fi
  stop_host h_abbr

  # ================ (2) zsh-syntax-highlighting 共存(zrush → z-sy-h)================
  out "==== (2) z-sy-h 共存 ===="
  if start_host h_zsyh $ZDOT_ZSYH $WORK/zsyh.log $WORK/t-zsyh; then
    ok "(2) zrush+z-sy-h ホスト起動"
    send_keys 'qqqqxx'
    if expect '*'$'\e''\[31m*' 8; then
      ok "(2a) ハイライトが効いている(unknown-token の SGR 出力)"
    else
      ng "(2a) ハイライトの SGR が観測できない"
    fi
    clear_line
    drain 0.5
    basic_flow "(2c)"   # 一覧+選択+確定 = pre-redraw 共存とラップ後ディスパッチの実証
  else
    ng "(2) z-sy-h ホスト起動失敗"
  fi
  stop_host h_zsyh

  # ================ (3) 三者共存(abbr → zrush → z-sy-h)================
  out "==== (3) 三者共存 ===="
  if start_host h_all $ZDOT_ALL $WORK/all.log $WORK/t-all; then
    ok "(3) 三者ホスト起動"
    basic_flow "(3a)"
    send_keys 'zzz'
    drain 0.5
    send_keys $ENTER
    if expect '*ABBR-EXPANDED-OK*' 8; then
      ok "(3b) 三者共存でも Enter の略語展開が生きる"
    else
      ng "(3b) 三者共存で略語展開が壊れた"
    fi
    sync_prompt
    send_keys 'qqqqxx'
    expect '*'$'\e''\[31m*' 8 && ok "(3c) 三者共存でもハイライトが効く" || ng "(3c) ハイライト消失"
    clear_line
  else
    ng "(3) 三者ホスト起動失敗"
  fi
  stop_host h_all

  # ================ (5) シェル多重起動(同時収集)================
  out "==== (5) シェル多重起動 ===="
  if start_host h1 $ZDOT_MIN $WORK/h1.log $WORK/t1 && start_host h2 $ZDOT_MIN $WORK/h2.log $WORK/t2; then
    ok "(5) 2 ホスト同時起動"
    use_host h1 $WORK/h1.log; send_keys 'ls docs/inte'
    use_host h2 $WORK/h2.log; send_keys 'ls ../huge/file0000'
    use_host h1 $WORK/h1.log
    expect '*internal*' 10 && ok "(5a) host1 の一覧表示(同時収集)" || ng "(5a) host1 が壊れた"
    use_host h2 $WORK/h2.log
    expect '*file00000.txt*' 30 && ok "(5b) host2 の一覧表示(同時収集・huge)" || ng "(5b) host2 が壊れた"
    use_host h1 $WORK/h1.log; press $DOWN; press $ENTER
    assert_buffer 'ls docs/internal/' "(5c) 多重起動でも host1 の確定が正常"
    clear_line
  else
    ng "(5) 多重起動に失敗"
  fi
  stop_host h2

  # ================ (6) 複数行バッファ(PS2 継続)================
  out "==== (6) PS2 複数行 ===="
  use_host h1 $WORK/h1.log
  send_keys 'for i in 1 2'
  press $ENTER            # 未完コマンド → PS2 継続(同一 zle セッション)
  drain 0.5
  send_keys 'ls docs/inte'
  if expect '*internal*' 10; then
    ok "(6a) PS2 継続行でも一覧が表示される"
  else
    ng "(6a) PS2 で一覧が出ない"
  fi
  clog_count 'selected=1'; local -i c6sel=$REPLY
  send_keys $DOWN
  wait_clog 'selected=1' $c6sel 5 && ok "(6b) PS2 で選択開始(末尾行なので優先順位③)" || ng "(6b) PS2 で選択できない"
  press $ENTER
  # 注: PS2 継続は行ごとに独立した zle セッションで、BUFFER は継続行のみを持つ
  # (複数行 BUFFER になるのは ESC-Enter 等の自己挿入改行の場合)。
  # よって確定後の BUFFER は継続行のみで正しい。
  assert_buffer 'ls docs/internal/' "(6c) PS2 での確定挿入が継続行内で正常(表示崩れなし)"
  press $CTRLC            # 行を破棄
  drain 0.5

  # ================ (7) 全角幅(記録のみ)================
  out "==== (7) 全角幅(記録)===="
  sync_prompt 3
  send_keys 'ls wide/jp-'
  if expect '*日本語*' 10; then
    ok "(7) 全角ファイル名の一覧が表示される(クラッシュなし)"
    drain 0.5
    local seg=${TRANSCRIPT[-600,-1]}
    out "OBSV: (7) 全角描画の生出力(セル幅は \${(m)} 表示幅ベース): ${(qqqq)${(M)${(f)${seg//$'\r'/}}:#*jp-*}}"
  else
    ng "(7) 全角ファイル名の一覧が出ない"
  fi
  clear_line
  stop_host h1

  # ================ (4)(8) tmux 内 + リサイズ ================
  out "==== (4)(8) tmux ===="
  local TSOCK=zrush-m5-$$
  tm() { $TMUX_BIN -L $TSOCK -f /dev/null "$@" }
  tm_cap() { tm capture-pane -p -t m5 2>/dev/null }
  tm_wait() {  # $1=glob $2=timeout
    local -F dl=$(( SECONDS + ${2:-10} ))
    while (( SECONDS < dl )); do
      [[ "$(tm_cap)" == ${~1} ]] && return 0
      command sleep 0.2
    done
    return 1
  }
  local TLOG=$WORK/tmux.log
  tm new-session -d -s m5 -x 100 -y 30 \
    "ZDOTDIR=$ZDOT_MIN XDG_CONFIG_HOME=$WORK/xdg HOME=$PLAYGROUND ZRUSH_REPO=$REPO ZRUSH_TEST_TMP=$WORK/t-tmux ZRUSH_LOG=$TLOG exec zsh -d -i" 2>/dev/null
  if tm_wait '*HP>*' 15; then
    ok "(4) tmux 内ホスト起動(TERM=$(tm display-message -p -t m5 '#{client_termname}' 2>/dev/null || print '?'))"
    tm send-keys -t m5 -l ' print -r -- TERM-INSIDE-$TERM'
    tm send-keys -t m5 Enter
    tm_wait '*TERM-INSIDE-*' 5 && out "INFO: $(tm_cap | grep -o 'TERM-INSIDE-[a-z0-9-]*' | tail -1)"
    # リサイズ前: 長い候補行の幅(width=100 → 99 に切り詰め)
    tm send-keys -t m5 -l 'ls wide/lo'
    if tm_wait '*longname-*' 10; then
      local line1=$(tm_cap | grep -m1 -o 'longname-x*' )
      out "INFO: (8) width=100 での表示長=${#line1}"
      tm resize-window -t m5 -x 60 -y 20 2>/dev/null
      command sleep 0.5
      tm send-keys -t m5 -l 'n'      # 再描画トリガ('ls wide/lon')
      command sleep 1.5
      local line2=$(tm_cap | grep -m1 -o 'longname-x*')
      out "INFO: (8) width=60 での表示長=${#line2}"
      if (( ${#line2} > 0 && ${#line2} < 60 && ${#line2} < ${#line1} )); then
        ok "(8) リサイズ後の次描画で新しい COLUMNS が効く(${#line1} → ${#line2})"
      else
        ng "(8) リサイズ後の切り詰めが不正(${#line1} → ${#line2})"
      fi
    else
      ng "(8) tmux 内で一覧が出ない"
    fi
    tm send-keys -t m5 C-u
    command sleep 0.3
    # tmux 内の基本フロー(terminfo キー解決: Down は tmux が TERM 相当の列を送る)
    tm send-keys -t m5 -l 'ls docs/inte'
    if tm_wait '*internal*' 10; then
      ok "(4a) tmux 内で一覧表示"
      local -i c4sel=0
      [[ -r $TLOG ]] && c4sel=$(grep -cF 'selected=1' $TLOG 2>/dev/null)
      tm send-keys -t m5 Down
      local -F dl4=$(( SECONDS + 5 ))
      local -i c4now=0
      while (( SECONDS < dl4 )); do
        command sleep 0.2
        [[ -r $TLOG ]] && c4now=$(grep -cF 'selected=1' $TLOG 2>/dev/null)
        (( c4now > c4sel )) && break
      done
      if (( c4now > c4sel )); then
        ok "(4b) tmux 内で ↓ 選択(terminfo キー解決、selected=1 で描画)"
      else
        ng "(4b) tmux 内で選択できない"
      fi
      # 選択ハイライトの実描画(SGR 7)も観測記録として残す
      if [[ "$($TMUX_BIN -L $TSOCK -f /dev/null capture-pane -p -e -t m5 2>/dev/null)" == *$'\e[7m'* ]]; then
        out "OBSV: (4b) tmux ペインに standout(SGR 7)を確認"
      else
        out "OBSV: (4b) tmux ペインで standout を確認できず(要実機確認)"
      fi
      tm send-keys -t m5 Enter
      command sleep 0.5
      tm send-keys -t m5 C-x b
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
        ok "(4c) tmux 内で確定挿入が正常"
      else
        ng "(4c) tmux 内の確定が不正: ${tlast:-?}"
      fi
    else
      ng "(4a) tmux 内で一覧が出ない"
    fi
  else
    ng "(4) tmux 内ホストが起動しない: $(tm_cap | tail -3)"
  fi
  tm kill-server 2>/dev/null

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  local h
  for h in "${(@k)HFD}"; do zpty -d $h 2>/dev/null; done
  $TMUX_BIN -L zrush-m5-$$ kill-server 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-coex.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
