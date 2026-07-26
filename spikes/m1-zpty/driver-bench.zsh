#!/bin/zsh -f
# M1-6: 計測ドライバ(実環境条件)
#
# 2 種類のホストで捕獲 v1 の端到端レイテンシ等を計測する:
#   minimal … zsh -d -i + rc/minimal.zshrc(従来の隔離ホスト)
#   real    … zsh -i + ユーザーの実 ~/.zshrc + 実履歴(fork コストの実測条件)
#
# 安全策(real ホスト):
#   - 起動直後に unset HISTFILE / SAVEHIST=0(ユーザー履歴ファイルへの書き込み禁止。
#     fork にも継承される)。ユーザーのファイルは一切変更しない。
#   - プラグイン(zsh-autocomplete / z-sy-h / zsh-abbr)はメモリ上でのみ無効化:
#     bindkey -d でキーマップを既定へ戻し、zle-* フックウィジェットを削除、
#     precmd/preexec 等のフック配列を空にする。メモリフットプリントは維持される。
#
# 判定・計測は ZRUSH-RESULT 行ベース(プロンプト文字列に依存しない)。
# コマンド実行の同期は「クォート分割マーカー」で行う(エコーとの誤マッチ防止):
#   print -r -- MARK-'S1' → エコーは MARK-'S1'、出力は MARK-S1。
#
# 使い方: zsh -f driver-bench.zsh <fixtures-dir>   (playground/ と huge/ を含む親)
emulate -L zsh
setopt extended_glob
zmodload zsh/zpty    || { print -u2 FATAL: zpty; exit 1 }
zmodload zsh/zselect || { print -u2 FATAL: zselect; exit 1 }
zmodload zsh/system  || { print -u2 FATAL: system; exit 1 }
zmodload zsh/datetime

typeset -F SECONDS
typeset -g SPIKE=${0:A:h}
typeset -g FIXTURES=${1:?usage: driver-bench.zsh <fixtures-dir>}
[[ -d $FIXTURES/playground && -d $FIXTURES/huge ]] || { print -u2 "FATAL: fixtures 不備: $FIXTURES"; exit 1 }

typeset -gi PASS=0 FAIL=0 SYNCN=0
out() { print -r -u2 -- "$@" }
ok()  { out "PASS: $1"; (( ++PASS )) }
ng()  { out "FAIL: $1"; (( ++FAIL )) }

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-bench.XXXXXX)
# 注意: TERM=vt100 だと zsh-autocomplete が初期化をスキップし、
# 実環境ホストで compsys ごと不在になる(mc=0 を実測)。実端末相当の値を使う。
export TERM=xterm-256color

typeset -g HOST= HOSTFD=-1 HOSTLOG= TRANSCRIPT= EXPECT_BUF= RESULT_LINE=

# 注意: コマンド行は必ず先頭スペース付きで送る。real ホストは share_history が
# 有効で、`unset HISTFILE` が効く前の最初のコマンドがユーザーの実履歴に追記されて
# しまう事故が起きた(hist_ignore_space が rc で有効なため先頭スペースで防げる)。
send_line() { zpty -w  $HOST " $1" }
send_keys() { zpty -wn $HOST $1 }

expect() {  # $1=glob $2=timeout(s)
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
    fi
  done
  return 1
}

drain() {  # $1=秒: pty を読みながら待つ(tcsetattr TCSADRAIN ブロック防止)
  local -F dl=$(( SECONDS + ${1:-0.2} ))
  local chunk
  while (( SECONDS < dl )); do
    if zselect -t 10 -r $HOSTFD 2>/dev/null; then
      zpty -r $HOST chunk 2>/dev/null && TRANSCRIPT+=$chunk
    fi
  done
}

sync_host() {  # コマンド実行完了を 1 往復で確認 + プロンプト猶予
  local m=S$(( ++SYNCN ))
  send_line "print -r -- MARK-'$m'"
  expect "*MARK-$m*" ${1:-20} || return 1
  drain 0.3
  return 0
}

run_cmd() {  # $1=コマンド行(同期付き)
  send_line $1
  sync_host ${2:-20}
}

clear_line() { send_keys $'\C-u'; drain 0.15 }

parse_result() {  # EXPECT_BUF から ZRUSH-RESULT 行を取り出す
  RESULT_LINE=
  local line
  for line in ${(f)${EXPECT_BUF//$'\r'/}}; do
    [[ $line == *ZRUSH-RESULT\ * ]] && RESULT_LINE=${line##*ZRUSH-RESULT }
  done
  [[ -n $RESULT_LINE ]]
}

res_field() {  # $1=フィールド名 → REPLY
  typeset -g REPLY=${${${(M)${(s: :)RESULT_LINE}:#$1=*}[1]}#$1=}
  [[ -n $REPLY ]]
}

fork_ms() {  # $1=hostlog → REPLY: 直近リクエストの zpty 作成〜worker 開始 (ms)
  typeset -g REPLY=NA
  local pre=$(grep -F 'request: pipe rfd=' $1 2>/dev/null | tail -1)
  local wst=$(grep -F 'worker: start' $1 2>/dev/null | tail -1)
  [[ -n $pre && -n $wst ]] || return 1
  local -F t1=${${${(z)pre}[2]}%\]} t2=${${${(z)wst}[2]}%\]}
  REPLY=$(( (t2 - t1) * 1000 ))
}

median() {  # $@ → REPLY
  local -a s=( ${(on)@} )
  typeset -g REPLY=${s[$(( ($#s + 1) / 2 ))]:-NA}
}

host_rss_kb() {  # → REPLY
  typeset -g REPLY=NA
  local m=R$(( ++SYNCN ))
  send_line "print -r -- RSS-'$m'-\$(ps -o rss= -p \$\$ | tr -d ' ')-END"
  if expect "*RSS-$m-<->-END*" 15; then
    REPLY=${${EXPECT_BUF##*RSS-$m-}%%-END*}
  fi
  drain 0.3
}

# 1 回の捕獲計測。成功時: REPLY_E(elapsed ms) REPLY_F(fork ms) を設定
bench_once() {  # $1=buffer $2=timeout
  send_keys $1
  send_keys $'\C-x\C-z'
  if ! expect '*ZRUSH-END*' ${2:-30}; then
    clear_line
    return 1
  fi
  parse_result || { clear_line; return 1 }
  res_field elapsed-ms; typeset -gF REPLY_E=$REPLY
  fork_ms $HOSTLOG;     typeset -g  REPLY_F=$REPLY
  clear_line
  return 0
}

# N 回計測して表 1 行を出力
bench_case() {  # $1=host-label $2=case-label $3=buffer $4=trials $5=timeout
  local hl=$1 cl=$2 buffer=$3
  local -i trials=${4:-5}
  local -a es=() fs=()
  local first= count= bytes= reads=
  local -i i
  for (( i = 1; i <= trials; ++i )); do
    if bench_once $buffer ${5:-30}; then
      es+=( $REPLY_E ); fs+=( $REPLY_F )
      [[ -z $first ]] && first=$REPLY_E
      res_field count && count=$REPLY
      res_field bytes && bytes=$REPLY
      res_field reads && reads=$REPLY
    else
      ng "[$hl/$cl] 試行 $i が失敗(ZRUSH-END 不達)"
      return 1
    fi
  done
  local emed= fmed= estr= fstr= firststr=
  median $es; emed=$REPLY
  median $fs; fmed=$REPLY
  estr=$(printf '%.1f' $emed 2>/dev/null)
  fstr=$(printf '%.1f' $fmed 2>/dev/null)
  firststr=$(printf '%.1f' $first 2>/dev/null)
  out "BENCH | ${(r:7:)hl} | ${(r:22:)cl} | count=${(l:5:)count} | bytes=${(l:7:)bytes} | reads=${(l:3:)reads} | elapsed-med=${estr}ms (first=${firststr}) | fork-med=${fstr}ms | trials=$trials"
  ok "[$hl/$cl] 計測完了"
  return 0
}

start_minimal_host() {
  export ZRUSH_SPIKE_DIR=$SPIKE
  export ZRUSH_TEST_TMP=$WORK
  export ZDOTDIR=$WORK/zdot
  mkdir -p $ZDOTDIR
  print 'source $ZRUSH_SPIKE_DIR/rc/minimal.zshrc' > $ZDOTDIR/.zshrc
  HOST=minhost HOSTLOG=$WORK/min-host.log
  cd $FIXTURES/playground || return 1
  local REPLY=
  zpty -b $HOST zsh -d -i || return 1
  HOSTFD=$REPLY
  expect '*MARK-RC-DONE*' 30 || return 1
  drain 0.5
  run_cmd "export ZRUSH_LOG=$HOSTLOG" || return 1
  run_cmd "typeset -g ZRUSH_WIDEN=1 ZRUSH_REPORT_LIMIT=10" || return 1
  return 0
}

start_real_host() {
  unset ZDOTDIR   # ユーザー既定($HOME)の rc を読ませる
  HOST=realhost HOSTLOG=$WORK/real-host.log
  cd $FIXTURES/playground || return 1
  local REPLY=
  zpty -b $HOST zsh -i || return 1
  HOSTFD=$REPLY
  # 起動完了を確認(実 rc は brew 等で遅い可能性 → 60s)
  local m=BOOT$(( ++SYNCN ))
  send_line "print -r -- MARK-'$m'"
  expect "*MARK-$m*" 60 || return 1
  drain 0.5
  # 安全策: ユーザー履歴ファイルへの書き込みを止める(メモリ上のみ)
  run_cmd 'unset HISTFILE; SAVEHIST=0' || return 1
  # プラグインのメモリ上無効化(ファイルは触らない)
  run_cmd 'bindkey -d' || return 1
  run_cmd 'zle -D zle-line-pre-redraw zle-line-init zle-line-finish zle-keymap-select zle-history-line-set 2>/dev/null; precmd_functions=(); preexec_functions=(); chpwd_functions=(); periodic_functions=(); print DISABLED' || return 1
  run_cmd 'zpty -d AUTOCOMPLETE 2>/dev/null; print ZAC-PTY-CLEANED' || return 1
  # スパイクの読み込み(bindkey -d 後に行い ^X^Z を確保)
  run_cmd "source $SPIKE/03-capture-v1.zsh && source $SPIKE/04-widen.zsh && print SPIKE-LOADED" 30 || return 1
  run_cmd "export ZRUSH_LOG=$HOSTLOG" || return 1
  run_cmd "typeset -g ZRUSH_WIDEN=1 ZRUSH_REPORT_LIMIT=10" || return 1
  run_cmd "cd $FIXTURES/playground" || return 1
  return 0
}

kids_count() {  # ホストの子プロセス数(コマンド置換の子 1 を含むベースライン込み)
  typeset -g REPLY=NA
  local m=K$(( ++SYNCN ))
  send_line "print -r -- KIDS-'$m'-\$(pgrep -P \$\$ | wc -l | tr -d ' ')-END"
  if expect "*KIDS-$m-<->-END*" 15; then
    REPLY=${${EXPECT_BUF##*KIDS-$m-}%%-END*}
  fi
  drain 0.3
}

bench_host() {  # $1=host-label(共通ベンチ)
  local hl=$1
  host_rss_kb; out "INFO: [$hl] RSS=${REPLY}KB"
  bench_case $hl "docs (ls docs/inte)"  'ls docs/inte' 5 30
  bench_case $hl "git-sub (git ch)"     'git ch'       5 60
  bench_case $hl "all-cmds (gti)"       'gti'          5 60
  bench_case $hl "huge-30k (ls ../huge/)" 'ls ../huge/' 3 60
}

{
  # ================ minimal ホスト ================
  out "==== bench: minimal ホスト(zsh -d -i + 最小 rc)===="
  if start_minimal_host; then
    ok "[min] ホスト起動"
    bench_host min
  else
    ng "[min] ホスト起動失敗"
  fi
  zpty -d minhost 2>/dev/null

  # ================ real ホスト ================
  out "==== bench: real ホスト(zsh -i + 実 ~/.zshrc + 実履歴)===="
  if start_real_host; then
    ok "[real] ホスト起動+プラグインのメモリ上無効化"
    bench_host real

    # ---- 非ブロック確認(huge 収集中に入力が通る)----
    send_keys 'ls ../huge/'
    send_keys $'\C-x\C-z'
    clear_line
    local m=NB$(( ++SYNCN ))
    send_line "print -r -- MARK-'$m'"
    if expect "*MARK-$m*" 5; then
      if [[ $EXPECT_BUF != *ZRUSH-END* ]]; then
        ok "[real] huge 収集中もホストは応答(収集完了前にコマンド実行)"
      else
        out "OBSV: [real] 収集がコマンド往復より先に完了(非ブロック判定は不能だが high-speed)"
      fi
    else
      ng "[real] huge 収集中にホストが応答しない"
    fi
    expect '*ZRUSH-END*' 60 >/dev/null   # 残骸回収
    clear_line

    # ---- 連打(100ms 間隔 ×10、huge クエリ)----
    kids_count; local kids_before=$REPLY
    send_keys 'ls ../huge/'
    local -i k
    for (( k = 1; k <= 10; ++k )); do
      send_keys $'\C-x\C-z'
      drain 0.1
    done
    local -F t0=$SECONDS
    local -i pos=$(( ${#TRANSCRIPT} + 1 ))
    if expect '*ZRUSH-END*' 60; then
      local -F tend=$(( SECONDS - t0 ))
      drain 3
      local seg=$TRANSCRIPT[pos,-1]   # expect/drain は TRANSCRIPT にも追記するのでこれだけで全量
      local -i nres=$(( ${#${(ps:ZRUSH-RESULT:)seg}} - 1 ))
      if (( nres == 1 )); then
        ok "[real] 連打 10 回: 結果はちょうど 1 回だけ届く(最終トリガから ${tend}s)"
      else
        ng "[real] 連打 10 回: 結果が $nres 回届いた"
      fi
    else
      ng "[real] 連打後の結果が来ない"
    fi
    clear_line
    kids_count; local kids_after=$REPLY
    if [[ $kids_before == <-> && $kids_after == <-> ]] && (( kids_after <= kids_before )); then
      ok "[real] 連打後のプロセス蓄積なし(children: $kids_before → $kids_after)"
    else
      ng "[real] プロセス数が増加: $kids_before → $kids_after"
    fi
  else
    ng "[real] ホスト起動/セットアップ失敗(実環境で capture 不成立の可能性 — 要調査)"
  fi

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  zpty -d minhost 2>/dev/null
  zpty -d realhost 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-bench.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
