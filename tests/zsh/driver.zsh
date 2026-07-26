#!/bin/zsh -f
# zrush.zsh のヘッドレス回帰ドライバ。
#
# 実行方法:
#   zsh -f tests/zsh/driver.zsh <playground-dir>
#     playground には docs/{internal,user} があり、../huge に大量ファイル
#     ディレクトリがあること(spikes の fixtures と同じレイアウト)。
#   前提: cargo build --release 済み(zrush バイナリ)。
#
# 方式(spikes/m1-zpty/driver.zsh で実証済みのハーネス知見を踏襲):
#   - ホスト対話 zsh を zpty -b(非ブロッキング)で起動し、キーを送って
#     pty 出力と ZRUSH_LOG(ファイル)で判定する
#   - 待ちループは常に pty を drain する(tcsetattr TCSADRAIN ブロック防止)
#   - コマンド実行後はプロンプト(HP>)同期をしてから次のキーを送る
emulate -L zsh
setopt extended_glob
zmodload zsh/zpty    || { print -u2 FATAL: zpty; exit 1 }
zmodload zsh/zselect || { print -u2 FATAL: zselect; exit 1 }
zmodload zsh/system  || { print -u2 FATAL: system; exit 1 }

typeset -F SECONDS
typeset -g HERE=${${(%):-%N}:A:h}
typeset -g REPO=${HERE:h:h}
typeset -g PLAYGROUND=${1:?usage: driver.zsh <playground-dir>}
[[ -d $PLAYGROUND/docs ]] || { print -u2 "FATAL: playground 不備: $PLAYGROUND"; exit 1 }
[[ -x $REPO/target/release/zrush ]] || { print -u2 "FATAL: zrush バイナリがない(cargo build --release)"; exit 1 }

typeset -gi PASS=0 FAIL=0
out() { print -r -u2 -- "$@" }
ok()  { out "PASS: $1"; (( ++PASS )) }
ng()  { out "FAIL: $1"; (( ++FAIL )) }

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-test.XXXXXX)
export TERM=vt100
export ZRUSH_REPO=$REPO
export ZRUSH_TEST_TMP=$WORK
export ZDOTDIR=$WORK/zdot
export XDG_CONFIG_HOME=$WORK/xdg
export ZRUSH_LOG=$WORK/host.log
mkdir -p $ZDOTDIR $XDG_CONFIG_HOME/zrush
print "source $REPO/tests/zsh/rc/minimal.zshrc" > $ZDOTDIR/.zshrc

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
    fi
  done
  return 1
}

drain() {  # $1=秒: pty を読みながら待つ
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

log_count() {  # $1=固定文字列 → REPLY: ZRUSH_LOG 内の出現回数
  typeset -g REPLY=0
  [[ -r $ZRUSH_LOG ]] && REPLY=$(grep -cF -- $1 $ZRUSH_LOG 2>/dev/null)
  return 0
}

{
  # ---------------- ホスト起動 ----------------
  cd $PLAYGROUND || exit 1
  local REPLY=
  zpty -b host zsh -d -i || { ng "host 起動失敗"; exit 1 }
  HOSTFD=$REPLY
  if expect '*MARK-RC-DONE*' 20; then
    ok "host 起動 + compinit + zrush.zsh source(config 読み込み成功)"
  else
    ng "host 起動を確認できない: ${(qqqq)EXPECT_BUF[-300,-1]}"
    exit 1
  fi
  sync_prompt

  # ---------------- (a) タイプ後 delay-ms 経過で一覧が自動表示される ----------------
  send_keys 'ls docs/inte'
  if expect '*internal*' 10; then
    ok "(a) タイプ後に候補一覧が自動表示される(internal を確認)"
  else
    ng "(a) 一覧が表示されない"
  fi
  clear_line

  # ---------------- (b) 空バッファで何も出ない ----------------
  drain 0.5
  log_count 'request: widened'; local -i req_before=$REPLY
  send_keys '   '     # 空白のみ
  drain 1.0
  clear_line
  drain 0.5
  log_count 'request: widened'; local -i req_after=$REPLY
  if (( req_after == req_before )); then
    ok "(b) 空バッファ(空白のみ)では収集リクエストが発生しない ($req_before → $req_after)"
  else
    ng "(b) 空バッファで収集が走った ($req_before → $req_after)"
  fi

  # ---------------- (f) typo クエリで候補が出る(Rust 連携) ----------------
  # (f1) コマンド位置の gti: 全コマンド収集 → zrush match 往復 → 描画が起きること。
  #   注意: 契約のティア順(部分列 > 誤字許容)により、g,t,i を部分列に含む
  #   コマンドが多い環境では 'git' そのものは top-10 に入らない(gtimeout 等が上位)。
  #   ここでは Rust 連携の実証として「match 成功+描画発生」を判定する。
  log_count 'finalize: match ok'; local -i mok_before=$REPLY
  log_count 'render:';            local -i ren_before=$REPLY
  send_keys 'gti'
  local -i mok_after=0 ren_after=0 _w=0
  while (( _w++ < 100 )); do
    drain 0.15
    log_count 'finalize: match ok'; mok_after=$REPLY
    log_count 'render:';            ren_after=$REPLY
    (( mok_after > mok_before && ren_after > ren_before )) && break
  done
  if (( mok_after > mok_before && ren_after > ren_before )); then
    ok "(f1) gti: 全コマンド収集 → zrush match → 描画の往復が成立"
  else
    ng "(f1) gti の match/描画が確認できない (match $mok_before→$mok_after render $ren_before→$ren_after)"
  fi
  clear_line
  drain 0.3
  # (f2) 限定候補での typo 到達: docs/intre(転置)→ internal が表示される
  send_keys 'ls docs/intre'
  if expect '*internal*' 10; then
    ok "(f2) typo クエリ intre → internal が表示される(誤字許容マッチ)"
  else
    ng "(f2) typo 候補 internal が出ない"
  fi
  clear_line
  drain 0.3

  # ---------------- (d) 大量候補で入力非ブロック ----------------
  send_keys 'ls ../huge/'
  drain 0.4                     # 収集開始まで待つ(delay 50ms + fork)
  local -F t0=$SECONDS
  send_keys 'zzz'               # 収集中の追加タイプ
  if expect '*zzz*' 2; then
    ok "(d) huge 収集中も追加タイプが即エコーされる($(( SECONDS - t0 ))s)"
  else
    ng "(d) huge 収集中に入力がブロックされた"
  fi
  clear_line
  drain 1.0                     # 進行中の収集キャンセルを消化

  # huge の一覧自体も出ること(0 件クエリ zzz を消したので再タイプ)
  send_keys 'ls ../huge/file0000'
  if expect '*file00000.txt*' 20; then
    ok "(d') huge ディレクトリの候補一覧が表示される"
  else
    ng "(d') huge の一覧が出ない"
  fi
  clear_line
  drain 0.5

  # ---------------- (e) accept-line 後に一覧が残らない ----------------
  log_count 'line-finish: cleared'; local -i fin_before=$REPLY
  send_keys 'ls docs/inte'
  expect '*internal*' 10 >/dev/null
  send_keys $'\r'               # accept-line(ls docs/ 実行)
  sync_prompt 10
  log_count 'line-finish: cleared'; local -i fin_after=$REPLY
  if (( fin_after > fin_before )); then
    ok "(e) accept-line で一覧消去(line-finish cleared: $fin_before → $fin_after)"
  else
    ng "(e) line-finish の消去が確認できない"
  fi
  log_count 'render:'; local -i render_settled=$REPLY
  drain 1.0
  log_count 'render:'; local -i render_after=$REPLY
  if (( render_after == render_settled )); then
    ok "(e') accept-line 後に一覧の再描画が起きない"
  else
    ng "(e') accept-line 後に再描画が発生 ($render_settled → $render_after)"
  fi

  # ---------------- (c) min-input 2 設定時に 1 文字で出ない ----------------
  command sleep 1.1   # mtime 秒粒度対策
  print -r -- $'[display]\nmin-input = 2\ndelay-ms = 10' > $XDG_CONFIG_HOME/zrush/config.toml
  send_line ': reload'          # プロンプト再表示 → precmd → mtime 検知 → 再読み込み
  sync_prompt
  log_count 'request: widened'; local -i mi_before=$REPLY
  send_keys 'l'                 # 1 文字(< min-input)
  drain 0.8
  log_count 'request: widened'; local -i mi_one=$REPLY
  send_keys 's'                 # 2 文字目 → 'ls'(= min-input)
  drain 0.8
  log_count 'request: widened'; local -i mi_two=$REPLY
  if (( mi_one == mi_before && mi_two > mi_one )); then
    ok "(c) min-input=2: 1 文字では収集せず、2 文字で収集する ($mi_before/$mi_one/$mi_two)"
  else
    ng "(c) min-input が効いていない ($mi_before/$mi_one/$mi_two)"
  fi
  clear_line
  drain 0.3

  # ---------------- (g) config 不正値の警告が表示される ----------------
  command sleep 1.1
  print -r -- $'[display]\nmax-lines = "abc"' > $XDG_CONFIG_HOME/zrush/config.toml
  send_line ': reload2'
  if expect '*max-lines*' 10; then
    ok "(g) config 不正値の警告が stderr に表示される"
  else
    ng "(g) 不正値警告が出ない"
  fi
  sync_prompt
  # 不正値でも動作継続(既定値フォールバック)の確認
  send_keys 'ls docs/inte'
  if expect '*internal*' 10; then
    ok "(g') 不正 config でも既定値で動作継続する"
  else
    ng "(g') 不正 config 後に一覧が出ない"
  fi
  clear_line

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  zpty -d host 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-test.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
