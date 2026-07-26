#!/bin/zsh -f
# ヘッドレス検証ドライバ。
# zpty で「ホストとなる対話 zsh(zsh -d -i + rc/minimal.zshrc)」を起動し、
# フェイクキーで zrush-test ウィジェットを発火させ、pty 出力から結果を読んで PASS/FAIL を印字する。
#
# 使い方: zsh -f driver.zsh <playground-dir>
#   playground には docs/{internal,user}, src, README.md, Cargo.toml,
#   'space name.txt', $'weird\nname.txt' がある前提(Step B/C の検証クエリ用)。
#
# 注意: ホスト pty は zpty -b(非ブロッキング)で開く。ブロッキングの zpty -r は
# ホストが無出力のとき永遠に返らない(Step A で踏んだ罠)。
# 進捗の可視性のため、結果はすべて stderr に印字する(stdout はバッファされて
# kill 時に失われるため)。
emulate -L zsh
setopt extended_glob
zmodload zsh/zpty    || { print -u2 FATAL: zpty; exit 1 }
zmodload zsh/zselect || { print -u2 FATAL: zselect; exit 1 }
zmodload zsh/system  || { print -u2 FATAL: system; exit 1 }

typeset -F SECONDS
typeset -g SPIKE=${0:A:h}
typeset -g PLAYGROUND=${1:?usage: driver.zsh <playground-dir>}
[[ -d $PLAYGROUND ]] || { print -u2 "FATAL: playground not found: $PLAYGROUND"; exit 1 }

typeset -gi PASS=0 FAIL=0
out() { print -r -u2 -- "$@" }
ok()  { out "PASS: $1"; (( ++PASS )) }
ng()  { out "FAIL: $1"; (( ++FAIL )) }
dbg() { [[ -n $ZRUSH_DEBUG ]] && out "DBG: $1"; return 0 }

# ---- 隔離環境(ユーザーの実環境に触れない) ----
typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-driver.XXXXXX)
export ZRUSH_SPIKE_DIR=$SPIKE
export ZRUSH_TEST_TMP=$WORK
export ZDOTDIR=$WORK/zdot
mkdir -p $ZDOTDIR
print 'source $ZRUSH_SPIKE_DIR/rc/minimal.zshrc' > $ZDOTDIR/.zshrc
export TERM=vt100

typeset -gi HOSTFD=-1
typeset -g TRANSCRIPT= EXPECT_BUF=

start_host() {
  cd $PLAYGROUND || return 1
  local REPLY=
  zpty -b host zsh -d -i || return 1
  HOSTFD=$REPLY
}

send_line() { zpty -w  host $1 }
send_keys() { zpty -wn host $1 }

# パターンが現れるまで pty を読み集める。EXPECT_BUF に今回分を蓄積。
expect() {  # $1=glob $2=timeout(s)
  local pat=$1
  local -F deadline=$(( SECONDS + ${2:-10} ))
  EXPECT_BUF=
  local chunk
  dbg "expect: pat=$pat"
  while (( SECONDS < deadline )); do
    if zselect -t 20 -r $HOSTFD 2>/dev/null; then
      chunk=
      if zpty -r host chunk; then
        EXPECT_BUF+=$chunk
        TRANSCRIPT+=$chunk
        if [[ $EXPECT_BUF == ${~pat} ]]; then
          dbg "expect: matched"
          return 0
        fi
      elif ! zpty -t host 2>/dev/null; then
        out "expect: host died"
        return 2
      fi
    fi
  done
  dbg "expect: timeout. buf=${(qqqq)EXPECT_BUF}"
  return 1
}

# EXPECT_BUF から ZRUSH-ITEM 行(${(qqqq)} エンコード)を抽出。
# ITEMS     = 捕獲された compadd 語そのもの(compsys の挿入用クォートを含み得る)
# RAW_ITEMS = さらに ${(Q)} でクォートを剥がした「実ファイル名」
parse_items() {
  typeset -ga ITEMS=() RAW_ITEMS=()
  typeset -g RESULT_LINE=
  local line enc decoded
  for line in ${(f)${EXPECT_BUF//$'\r'/}}; do
    if [[ $line == *ZRUSH-ITEM\ * ]]; then
      enc=${line##*ZRUSH-ITEM }
      decoded=
      eval "decoded=$enc" 2>/dev/null    # (qqqq) エンコードを戻す(自前出力なので安全)
      ITEMS+=( "$decoded" )
      RAW_ITEMS+=( "${(Q)decoded}" )
    fi
    [[ $line == *ZRUSH-RESULT\ * ]] && RESULT_LINE=${line##*ZRUSH-RESULT }
  done
}

has_item() {  # $1=実ファイル名(クォートなし)。RAW_ITEMS に一致があるか
  (( ${RAW_ITEMS[(Ie)$1]} ))
}

# 1 回の収集を実行: バッファへ $1 をタイプ → トリガキー → ZRUSH-END まで待つ
run_capture() {  # $1=buffer text  $2=label  $3=trigger key (省略時 ^X^Z)
  send_keys $1
  send_keys ${3:-$'\C-x\C-z'}
  if expect '*ZRUSH-END*' 15; then
    parse_items
    return 0
  else
    parse_items
    ng "$2: ZRUSH-END が 15s 以内に来ない(候補収集がハング/失敗)"
    return 1
  fi
}

clear_line() { send_keys $'\C-u' }   # kill-whole-line

{
  # ---------------- ホスト起動 ----------------
  start_host || { ng "host 起動失敗"; exit 1 }
  if expect '*MARK-RC-DONE*' 15; then
    ok "host 起動 + rc 読み込み(compinit + spike source)"
  else
    ng "host rc 読み込みを確認できない: ${(qqqq)EXPECT_BUF}"
    exit 1
  fi
  expect '*HP>*' 5 >/dev/null   # プロンプト描画まで待つ

  # ================ direct 方式(本命): Step B/C ================
  out "==== variant: direct(widget 起点)===="
  send_line "typeset -g ZRUSH_VARIANT=direct"
  expect '*HP>*' 5 >/dev/null

  # ---------------- Step B: ls docs/ ----------------
  if run_capture 'ls docs/' "[direct] Step B"; then
    if has_item internal && has_item user; then
      ok "[direct] Step B: 'ls docs/' で docs/ 配下の候補 (internal, user) を捕獲 ($RESULT_LINE)"
    else
      ng "[direct] Step B: 期待候補なし。items=${(j:, :)${(qqqq)ITEMS[@]}} ($RESULT_LINE)"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # ---------------- Step C: 改行・スペース入りファイル名 ----------------
  if run_capture 'ls ' "[direct] Step C"; then
    local ok_weird=0 ok_space=0
    has_item $'weird\nname.txt' && ok_weird=1
    has_item 'space name.txt'   && ok_space=1
    if (( ok_weird && ok_space )); then
      ok "[direct] Step C: 改行入り・スペース入りファイル名が無傷で往復 ($RESULT_LINE)"
    else
      ng "[direct] Step C: weird=$ok_weird space=$ok_space items=${(j:, :)${(qqqq)ITEMS[@]}}"
    fi
    if has_item docs && has_item src && has_item README.md; then
      ok "[direct] Step C: 通常候補 (docs, src, README.md) も捕獲"
    else
      ng "[direct] Step C: 通常候補が欠落。items=${(j:, :)${(qqqq)ITEMS[@]}}"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # ================ fd タイマー起点(実運用 M3 形態)================
  # zle -F -w ハンドラ文脈からの zpty fork でも direct 駆動が成立するか
  out "==== variant: direct(zle -F -w ハンドラ起点)===="
  if run_capture 'ls docs/' "[deferred] Step B" $'\C-x\C-y'; then
    if has_item internal && has_item user; then
      ok "[deferred] zle -F -w ハンドラ起点の fork でも候補捕獲が成立 ($RESULT_LINE)"
    else
      ng "[deferred] 候補が取れない。items=${(j:, :)${(qqqq)ITEMS[@]}} ($RESULT_LINE)"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # ================ vared 方式: 既知の制約の確認 ================
  # fork 元(widget 文脈)で zle が活性のため、fork 内の vared は
  # "ZLE cannot be used recursively" で開始できない(ホストログで確認済み)。
  # ここでは空結果+EOF で正常終了する(ハングしない)ことだけを確認する。
  out "==== variant: vared(既知の制約)===="
  send_line "typeset -g ZRUSH_VARIANT=vared"
  expect '*HP>*' 5 >/dev/null
  if run_capture 'ls docs/' "[vared] graceful-fail"; then
    if (( $#ITEMS == 0 )); then
      ok "[vared] 既知の制約: zle 活性文脈からの fork では vared は開始不可。空結果+EOF で正常終了(ハングなし)"
    else
      ok "[vared] 予想外に候補が取れた(要調査): items=${(j:, :)${(qqqq)ITEMS[@]}}"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # ---------------- 非ブロック性の素朴な確認 ----------------
  # 収集開始直後にコマンドを実行させ、結果到着前でも入力が生きていることを見る
  send_line "typeset -g ZRUSH_VARIANT=direct"
  expect '*HP>*' 5 >/dev/null
  send_keys 'ls docs/'
  send_keys $'\C-x\C-z'
  clear_line
  send_line 'print MARK-ALIVE'
  if expect '*MARK-ALIVE*' 5; then
    ok "収集開始直後もホストはコマンドを受け付ける(非ブロック)"
  else
    ng "収集開始直後にホストが応答しない"
  fi
  expect '*ZRUSH-END*' 10 >/dev/null   # 残骸を回収

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  zpty -d host 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-driver.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
