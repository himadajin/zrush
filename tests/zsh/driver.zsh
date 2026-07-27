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
export LC_ALL=en_US.UTF-8   # POSTDISPLAY の印字可能判定を実利用と同じ UTF-8 にする
export HOME=$PLAYGROUND    # ~ 保持テスト用(実ホームに触れない)
# 部分パス略記(接頭辞不一致置換)テスト用の固定ツリー
mkdir -p $PLAYGROUND/pp/usr/local/bin $PLAYGROUND/pp/usr/share/doc
# グリッド表示テスト用の短名 30 件(a01..a30 → 8 列 × 4 行になる幅)
mkdir -p $PLAYGROUND/gd
for _gi in {01..30}; do : >| $PLAYGROUND/gd/a$_gi; done
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

  # ================================================================ M4: 選択・確定・挿入
  local DOWN=$'\e[B' UP=$'\e[A' ENTER=$'\r' TAB=$'\t' CTRLG=$'\C-g'
  press() { send_keys $1; drain 0.3 }
  wait_log() {  # $1=固定文字列 $2=基準値 $3=timeout(s) → 増えたら 0
    local -F dl=$(( SECONDS + ${3:-5} ))
    while (( SECONDS < dl )); do
      drain 0.15
      log_count $1
      (( REPLY > $2 )) && return 0
    done
    return 1
  }
  assert_buffer() {  # $1=期待するバッファ内容 $2=ラベル(^Xb ダンプで正確比較)
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

  # config を既定に戻す(M3 テストが不正 config を残している)
  command sleep 1.1
  rm -f $XDG_CONFIG_HOME/zrush/config.toml
  send_line ': m4-reset'
  sync_prompt

  # ---------------- (m4-1) 選択開始・ハイライト・移動・先頭 ↑ で解除 ----------------
  send_keys 'ls docs/'
  expect '*user*' 10 >/dev/null
  log_count 'select: start';           local -i c_start=$REPLY
  log_count 'select: pos=2';           local -i c_pos2=$REPLY
  log_count 'select: released-at-top'; local -i c_rel=$REPLY
  log_count 'selected=1';              local -i c_sel1=$REPLY
  TRANSCRIPT=            # standout 検査のため選択前の出力を切り離す
  send_keys $DOWN        # press() は drain で描画を先に消費するため使わない
  if wait_log 'selected=1' $c_sel1 5; then
    ok "(m4-1a) ↓ で選択開始(selected=1 で描画)"
  else
    ng "(m4-1a) 選択開始の描画が確認できない"
  fi
  if [[ $TRANSCRIPT == *$'\e[7m'* ]]; then
    ok "(m4-1a') 選択行の standout(SGR 7)が pty 出力に現れる"
  else
    ng "(m4-1a') standout 列が pty 出力に見えない"
  fi
  press $DOWN
  wait_log 'select: pos=2' $c_pos2 3 && ok "(m4-1b) ↓ で次候補へ移動" || ng "(m4-1b) 候補移動しない"
  press $UP
  press $UP
  wait_log 'select: released-at-top' $c_rel 3 && ok "(m4-1c) 先頭候補で ↑ → 選択解除" || ng "(m4-1c) 先頭 ↑ で解除されない"
  clear_line
  drain 0.3

  # ---------------- (m4-2) 非選択時: Enter=実行・↑=履歴(前任者チェーン) ----------------
  # ^M を明示送信する(send_line の zpty -w は ^J を付加するため zrush の
  # Enter ディスパッチ → 前任者フォールバックを経由しない。監査指摘)
  send_keys 'print HISTMARK-ALPHA'
  send_keys $'\r'
  if expect '*HISTMARK-ALPHA*' 5; then
    ok "(m4-2a) 非選択時の Enter は前任者(accept-line)経由でコマンド実行"
  else
    ng "(m4-2a) Enter でコマンドが実行されない"
  fi
  sync_prompt
  send_keys $UP
  if expect '*print HISTMARK-ALPHA*' 5; then
    ok "(m4-2b) 非選択時の ↑ は前任者経由で履歴移動"
  else
    ng "(m4-2b) ↑ で履歴が出ない"
  fi
  drain 0.3

  # ---------------- (m4-3) 履歴移動中の ↓ は履歴戻り ----------------
  log_count 'next: hist-branch'; local -i c_hist=$REPLY
  press $DOWN
  wait_log 'next: hist-branch' $c_hist 3 && ok "(m4-3) 履歴移動中の ↓ は履歴戻り(優先順位②)" || ng "(m4-3) hist-branch を通らない"
  clear_line
  drain 0.3

  # ---------------- (m4-4/5a/6a) 確定=挿入のみ・末尾置換・dir は space なし ----------------
  send_keys 'ls docs/inte'
  expect '*internal*' 10 >/dev/null
  press $DOWN
  press $ENTER
  assert_buffer 'ls docs/internal/' "(m4-4) 確定は挿入のみ(実行されず編集継続)+末尾置換で 'ls docs/internal/'+dir はスペースなし"
  clear_line
  drain 0.3

  # ---------------- (m4-6b) trailing-space: 通常ファイル候補に付く ----------------
  send_keys 'ls Cargo.t'
  expect '*Cargo.toml*' 10 >/dev/null
  press $DOWN
  press $ENTER
  assert_buffer 'ls Cargo.toml ' "(m4-6) trailing-space: ファイル候補の確定で末尾スペースが付く"
  clear_line
  drain 0.3

  # ---------------- (m4-5b) ~ 保持 ----------------
  send_keys 'ls ~/do'
  expect '*docs*' 10 >/dev/null
  press $DOWN
  press $ENTER
  assert_buffer 'ls ~/docs/' "(m4-5b) ~ 候補の確定でも ~ が展開されない('ls ~/docs/' のまま)"
  clear_line
  drain 0.3

  # ---------------- (m4-5c) 接頭辞不一致 → 語全体置換(pp/u/lo) ----------------
  log_count 'whole-word-replace'; local -i c_ww=$REPLY
  send_keys 'ls pp/u/lo'
  expect '*local*' 10 >/dev/null
  press $DOWN
  press $ENTER
  assert_buffer 'ls pp/usr/local/' "(m4-5c) 部分パス略記の確定は語全体置換で 'ls pp/usr/local/'"
  wait_log 'whole-word-replace' $c_ww 2 && ok "(m4-5c') 語全体置換の分岐を通った" || ng "(m4-5c') whole-word-replace 分岐が記録されない"
  clear_line
  drain 0.3

  # ---------------- (m4-11) dismiss: 一覧を閉じてバッファ不変 ----------------
  send_keys 'ls docs/'
  expect '*user*' 10 >/dev/null
  log_count 'dismiss: closing list'; local -i c_dis=$REPLY
  press $CTRLG
  wait_log 'dismiss: closing list' $c_dis 3 && ok "(m4-11a) dismiss で一覧が閉じる" || ng "(m4-11a) dismiss が効かない"
  assert_buffer 'ls docs/' "(m4-11b) dismiss 後もバッファは不変"
  clear_line
  drain 0.3

  # ---------------- (m4-7) Tab menu モード: 一覧中 Tab で選択開始 ----------------
  send_keys 'ls docs/'
  expect '*user*' 10 >/dev/null
  log_count 'select: start'; local -i c_tstart=$REPLY
  press $TAB
  wait_log 'select: start' $c_tstart 3 && ok "(m4-7) Tab(menu)で選択開始" || ng "(m4-7) Tab で選択が始まらない"
  press $CTRLG
  clear_line
  drain 0.3

  # ---------------- (m4-8) Tab common-prefix ----------------
  command sleep 1.1
  print -r -- $'[insert]\ntab = "common-prefix"' > $XDG_CONFIG_HOME/zrush/config.toml
  send_line ': cfg-cp'
  sync_prompt
  send_keys 'ls docs/inte'
  expect '*internal*' 10 >/dev/null
  press $TAB
  assert_buffer 'ls docs/internal' "(m4-8a) Tab(common-prefix): クエリが真の接頭辞のとき共通部を挿入"
  clear_line
  drain 0.3
  log_count 'finalize: match ok'; local -i c_mok=$REPLY
  send_keys 'gti'
  wait_log 'finalize: match ok' $c_mok 10 || ng "(m4-8b 前提) gti の match が来ない"
  log_count 'condition not met'; local -i c_ncp=$REPLY
  press $TAB
  wait_log 'condition not met' $c_ncp 3 && ok "(m4-8b) Tab(common-prefix): typo クエリでは何もしない" || ng "(m4-8b) 条件外で挿入された疑い"
  assert_buffer 'gti' "(m4-8b') バッファ不変を確認"
  clear_line
  drain 0.3

  # ---------------- (m4-9) Tab insert: 先頭候補即挿入 ----------------
  command sleep 1.1
  print -r -- $'[insert]\ntab = "insert"' > $XDG_CONFIG_HOME/zrush/config.toml
  send_line ': cfg-ins'
  sync_prompt
  send_keys 'ls docs/inte'
  expect '*internal*' 10 >/dev/null
  press $TAB
  assert_buffer 'ls docs/internal/' "(m4-9) Tab(insert)で先頭候補を即挿入"
  clear_line
  drain 0.3

  # ---------------- (m4-10) 候補未着時 Tab → 到着後に適用 ----------------
  log_count 'tab: pending'; local -i c_pend=$REPLY
  send_keys 'ls docs/inte'$'\t'    # デバウンス中に Tab(同一バースト送信)
  if expect '*ls docs/internal/*' 10; then
    ok "(m4-10a) 未着時 Tab: 収集前倒し→到着時に insert 適用"
  else
    ng "(m4-10a) 未着時 Tab が適用されない"
  fi
  wait_log 'tab: pending' $c_pend 2 && ok "(m4-10b) pending 経路を通った" || ng "(m4-10b) pending 経路が記録されない"
  clear_line
  drain 0.3

  # ---------------- (d2-1) 複数列グリッドと左右移動 ----------------
  local RIGHT=$'\e[C' LEFT=$'\e[D'
  send_keys 'ls gd/'
  # a01..a30(2 文字語 + セル幅 3)→ 8 列 × 4 行、列優先なので行 1 は a01 a05 a09 ...
  if expect '*a01  a05*' 10; then
    ok "(d2-1a) 列優先グリッドで複数候補が 1 行に並ぶ(a01  a05)"
  else
    ng "(d2-1a) グリッド行が確認できない"
  fi
  log_count 'render: 4 lines cols=8'
  if (( REPLY > 0 )); then
    ok "(d2-1b) 30 件が 8 列 × 4 行に収まる"
  else
    ng "(d2-1b) グリッド形状が期待と違う(render: 4 lines cols=8 がログにない)"
  fi
  log_count 'select: pos=5'; local -i c_gp5=$REPLY
  send_keys $DOWN            # 選択開始(pos=1)
  drain 0.3
  send_keys $RIGHT           # 右の列へ = +rows(4)
  wait_log 'select: pos=5' $c_gp5 3 && ok "(d2-1c) → で右の列へ(pos 1→5)" || ng "(d2-1c) 列ジャンプしない"
  log_count 'select: pos=1'; local -i c_gp1=$REPLY
  send_keys $LEFT
  wait_log 'select: pos=1' $c_gp1 3 && ok "(d2-1d) ← で左の列へ戻る(pos 5→1)" || ng "(d2-1d) 左ジャンプしない"
  press $CTRLG
  # 非選択時の ← は前任者チェーン(カーソル移動)へフォールバックする
  log_count 'dispatch: fallback'; local -i c_gfb=$REPLY
  send_keys $LEFT
  wait_log 'dispatch: fallback' $c_gfb 3 && ok "(d2-1e) 非選択時の ← は前任者へフォールバック" || ng "(d2-1e) 非選択 ← が奪われている"
  clear_line
  drain 0.3

  # ---------------- (m4-12) キーバインド変更・奇数配列 ----------------
  command sleep 1.1
  print -r -- $'[insert]\ntab = "menu"\n[keybind]\ndismiss = "ctrl-t"' > $XDG_CONFIG_HOME/zrush/config.toml
  send_line ': cfg-key'
  sync_prompt
  send_keys 'ls docs/'
  expect '*user*' 10 >/dev/null
  log_count 'dismiss: closing list'; local -i c_dis2=$REPLY
  press $'\C-t'
  wait_log 'dismiss: closing list' $c_dis2 3 && ok "(m4-12a) config で変更した dismiss キー(^T)が機能" || ng "(m4-12a) ^T dismiss が効かない"
  log_count 'keybinds: restored'
  (( REPLY > 0 )) && ok "(m4-12b) 外れた旧キー(^G)は前任者へ復元される" || ng "(m4-12b) 旧キーの復元記録がない"
  clear_line
  drain 0.3
  # 奇数長 KEYBINDS: 配列全体を無視して既定+警告(ホスト内ユニット)
  send_line 'ZRUSH_CFG_KEYBINDS=(a b c); _zrush_apply_keybinds'
  if expect '*odd length*' 5; then
    ok "(m4-12c) KEYBINDS 奇数長は無視して既定+警告"
  else
    ng "(m4-12c) 奇数長の警告が出ない"
  fi
  sync_prompt

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  zpty -d host 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-test.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
