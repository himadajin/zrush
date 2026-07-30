#!/bin/zsh -f
# Headless regression driver for zrush.zsh.
#
# Usage:
#   zsh -f tests/zsh/driver.zsh <playground-dir>
#     The playground must contain docs/{internal,user}, with a large-file directory
#     at ../huge, matching the spike fixture layout.
#   Prerequisite: the zrush binary has been built with cargo build --release.
#
# Harness:
#   - Start an interactive host zsh with nonblocking zpty -b, send keys, and inspect
#     both pty output and the ZRUSH_LOG file.
#   - Always drain the pty in wait loops to prevent tcsetattr TCSADRAIN blocking.
#   - After executing a command, synchronize on the HP> prompt before sending more keys.
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
export LC_ALL=en_US.UTF-8   # match POSTDISPLAY printability checks to real UTF-8 use
export HOME=$PLAYGROUND    # test '~' preservation without touching the real home
# Fixed tree for abbreviated partial-path replacement tests
mkdir -p $PLAYGROUND/pp/usr/local/bin $PLAYGROUND/pp/usr/share/doc
# Thirty short names for an a01..a30 grid that fits eight columns by four rows
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
      # Match again after stripping SGR that may split words for highlighting.
      # Raw escape-sequence patterns already had the first chance to match above.
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

log_count() {  # $1=fixed string -> REPLY: occurrence count in ZRUSH_LOG
  typeset -g REPLY=0
  [[ -r $ZRUSH_LOG ]] && REPLY=$(grep -cF -- $1 $ZRUSH_LOG 2>/dev/null)
  return 0
}

{
  # ---------------- Host startup ----------------
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

  # ---------------- (a) List appears automatically after delay-ms ----------------
  send_keys 'ls docs/inte'
  if expect '*internal*' 10; then
    ok "(a) タイプ後に候補一覧が自動表示される(internal を確認)"
  else
    ng "(a) 一覧が表示されない"
  fi
  clear_line

  # ---------------- (b) Blank buffer shows nothing ----------------
  drain 0.5
  log_count 'request: widened'; local -i req_before=$REPLY
  send_keys '   '     # whitespace only
  drain 1.0
  clear_line
  drain 0.5
  log_count 'request: widened'; local -i req_after=$REPLY
  if (( req_after == req_before )); then
    ok "(b) 空バッファ(空白のみ)では収集リクエストが発生しない ($req_before → $req_after)"
  else
    ng "(b) 空バッファで収集が走った ($req_before → $req_after)"
  fi

  # ---------------- (f) Typo query yields candidates through Rust ----------------
  # (f1) At command position, gti collects all commands, round-trips through zrush
  # match, and renders. Because substring outranks typo matching, environments with
  # many g,t,i subsequences may rank commands such as gtimeout above git.
  # Assert successful matching and rendering rather than git appearing in the top ten.
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
  # (f2) In a constrained set, transposed docs/intre reaches internal.
  send_keys 'ls docs/intre'
  if expect '*internal*' 10; then
    ok "(f2) typo クエリ intre → internal が表示される(誤字許容マッチ)"
  else
    ng "(f2) typo 候補 internal が出ない"
  fi
  clear_line
  drain 0.3

  # ---------------- (d) Large candidate sets do not block input ----------------
  send_keys 'ls ../huge/'
  drain 0.4                     # wait for collection to start (default 30ms delay + fork)
  local -F t0=$SECONDS
  send_keys 'zzz'               # additional typing during collection
  # Decoration updates may insert escape sequences between echoed characters, so do not
  # require consecutive z characters.
  if expect '*z*z*z*' 2; then
    ok "(d) huge 収集中も追加タイプが即エコーされる($(( SECONDS - t0 ))s)"
  else
    ng "(d) huge 収集中に入力がブロックされた"
  fi
  clear_line
  drain 1.0                     # allow in-flight collection cancellation to settle

  # Also require the huge listing itself after clearing the zero-result zzz query.
  send_keys 'ls ../huge/file0000'
  if expect '*file00000.txt*' 20; then
    ok "(d') huge ディレクトリの候補一覧が表示される"
  else
    ng "(d') huge の一覧が出ない"
  fi
  clear_line
  drain 0.5

  # ---------------- (e) No list remains after accept-line ----------------
  log_count 'line-finish: cleared'; local -i fin_before=$REPLY
  send_keys 'ls docs/inte'
  expect '*internal*' 10 >/dev/null
  send_keys $'\r'               # accept-line executes ls docs/
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

  # ---------------- (c) min-input=2 suppresses one-character input ----------------
  command sleep 1.1   # accommodate one-second mtime granularity
  print -r -- $'[display]\nmin-input = 2\ndelay-ms = 10' > $XDG_CONFIG_HOME/zrush/config.toml
  send_line ': reload'          # new prompt -> precmd -> mtime detection -> reload
  sync_prompt
  log_count 'request: widened'; local -i mi_before=$REPLY
  send_keys 'l'                 # one character, below min-input
  drain 0.8
  log_count 'request: widened'; local -i mi_one=$REPLY
  send_keys 's'                 # second character makes 'ls', equal to min-input
  drain 0.8
  log_count 'request: widened'; local -i mi_two=$REPLY
  if (( mi_one == mi_before && mi_two > mi_one )); then
    ok "(c) min-input=2: 1 文字では収集せず、2 文字で収集する ($mi_before/$mi_one/$mi_two)"
  else
    ng "(c) min-input が効いていない ($mi_before/$mi_one/$mi_two)"
  fi
  clear_line
  drain 0.3

  # ---------------- (g) Invalid config value emits a warning ----------------
  command sleep 1.1
  print -r -- $'[display]\nmax-lines = "abc"' > $XDG_CONFIG_HOME/zrush/config.toml
  send_line ': reload2'
  if expect '*max-lines*' 10; then
    ok "(g) config 不正値の警告が stderr に表示される"
  else
    ng "(g) 不正値警告が出ない"
  fi
  sync_prompt
  # Verify that invalid values fall back to defaults and operation continues.
  send_keys 'ls docs/inte'
  if expect '*internal*' 10; then
    ok "(g') 不正 config でも既定値で動作継続する"
  else
    ng "(g') 不正 config 後に一覧が出ない"
  fi
  clear_line

  # ================================================================ Selection, confirmation, insertion
  local DOWN=$'\e[B' UP=$'\e[A' ENTER=$'\r' TAB=$'\t' CTRLG=$'\C-g'
  press() { send_keys $1; drain 0.3 }
  wait_log() {  # $1=fixed string $2=baseline $3=timeout(s) -> 0 when count increases
    local -F dl=$(( SECONDS + ${3:-5} ))
    while (( SECONDS < dl )); do
      drain 0.15
      log_count $1
      (( REPLY > $2 )) && return 0
    done
    return 1
  }
  assert_buffer() {  # $1=expected buffer $2=label; compare exact ^Xb dump
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

  # Restore default config after the invalid-config tests.
  command sleep 1.1
  rm -f $XDG_CONFIG_HOME/zrush/config.toml
  send_line ': m4-reset'
  sync_prompt

  # ---------------- (m4-1) Start, highlight, move, and release selection at top ----------------
  send_keys 'ls docs/'
  expect '*user*' 10 >/dev/null
  log_count 'select: start';           local -i c_start=$REPLY
  log_count 'select: pos=2';           local -i c_pos2=$REPLY
  log_count 'select: released-at-top'; local -i c_rel=$REPLY
  log_count 'selected=1';              local -i c_sel1=$REPLY
  TRANSCRIPT=            # isolate pre-selection output for the standout assertion
  send_keys $DOWN        # press() would consume the render while draining
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

  # ---------------- (m4-2) Unselected Enter executes; Up traverses history ----------------
  # Send ^M explicitly because send_line's zpty -w appends ^J, bypassing zrush's
  # Enter dispatch and predecessor fallback.
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

  # ---------------- (m4-3) Down moves toward newer history while browsing ----------------
  log_count 'next: hist-branch'; local -i c_hist=$REPLY
  press $DOWN
  wait_log 'next: hist-branch' $c_hist 3 && ok "(m4-3) 履歴移動中の ↓ は履歴戻り(優先順位②)" || ng "(m4-3) hist-branch を通らない"
  clear_line
  drain 0.3

  # ---------------- (m4-4/5a/6a) Insert-only confirmation, tail replacement, no space for dirs ----------------
  send_keys 'ls docs/inte'
  expect '*internal*' 10 >/dev/null
  press $DOWN
  press $ENTER
  assert_buffer 'ls docs/internal/' "(m4-4) 確定は挿入のみ(実行されず編集継続)+末尾置換で 'ls docs/internal/'+dir はスペースなし"
  clear_line
  drain 0.3

  # ---------------- (m4-6b) trailing-space applies to ordinary file candidates ----------------
  send_keys 'ls Cargo.t'
  expect '*Cargo.toml*' 10 >/dev/null
  press $DOWN
  press $ENTER
  assert_buffer 'ls Cargo.toml ' "(m4-6) trailing-space: ファイル候補の確定で末尾スペースが付く"
  clear_line
  drain 0.3

  # ---------------- (m4-5b) Preserve '~' ----------------
  send_keys 'ls ~/do'
  expect '*docs*' 10 >/dev/null
  press $DOWN
  press $ENTER
  assert_buffer 'ls ~/docs/' "(m4-5b) ~ 候補の確定でも ~ が展開されない('ls ~/docs/' のまま)"
  clear_line
  drain 0.3

  # ---------------- (m4-5c) Prefix mismatch replaces the whole word (pp/u/lo) ----------------
  log_count 'whole-word-replace'; local -i c_ww=$REPLY
  send_keys 'ls pp/u/lo'
  expect '*local*' 10 >/dev/null
  press $DOWN
  press $ENTER
  assert_buffer 'ls pp/usr/local/' "(m4-5c) 部分パス略記の確定は語全体置換で 'ls pp/usr/local/'"
  wait_log 'whole-word-replace' $c_ww 2 && ok "(m4-5c') 語全体置換の分岐を通った" || ng "(m4-5c') whole-word-replace 分岐が記録されない"
  clear_line
  drain 0.3

  # ---------------- (m4-11) dismiss closes the list without changing the buffer ----------------
  send_keys 'ls docs/'
  expect '*user*' 10 >/dev/null
  log_count 'dismiss: closing list'; local -i c_dis=$REPLY
  press $CTRLG
  wait_log 'dismiss: closing list' $c_dis 3 && ok "(m4-11a) dismiss で一覧が閉じる" || ng "(m4-11a) dismiss が効かない"
  assert_buffer 'ls docs/' "(m4-11b) dismiss 後もバッファは不変"
  clear_line
  drain 0.3

  # ---------------- (m4-7) Tab menu mode starts selection from a visible list ----------------
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
  # Non-extending case: gd/a1 has prefix-tier {a10..a19} with LCP "a1" equal to
  # the query, so fallback confirms the top candidate a10 including trailing-space.
  send_keys 'ls gd/a1'
  expect '*a10*' 10 >/dev/null
  log_count 'fallback -> insert top'; local -i c_fb=$REPLY
  press $TAB
  assert_buffer 'ls gd/a10 ' "(m4-8b) Tab(common-prefix): 伸びないときは先頭候補を確定挿入('ls gd/a10 ')"
  wait_log 'fallback -> insert top' $c_fb 2 && ok "(m4-8b') フォールバック経路を通った" || ng "(m4-8b') フォールバック経路が記録されない"
  clear_line
  drain 0.3

  # ---------------- (m4-9) Tab insert immediately inserts the top candidate ----------------
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

  # ---------------- (m4-10) Tab before arrival applies after candidates arrive ----------------
  log_count 'tab: pending'; local -i c_pend=$REPLY
  send_keys 'ls docs/inte'$'\t'    # Tab during debounce in the same input burst
  if expect '*ls docs/internal/*' 10; then
    ok "(m4-10a) 未着時 Tab: 収集前倒し→到着時に insert 適用"
  else
    ng "(m4-10a) 未着時 Tab が適用されない"
  fi
  wait_log 'tab: pending' $c_pend 2 && ok "(m4-10b) pending 経路を通った" || ng "(m4-10b) pending 経路が記録されない"
  clear_line
  drain 0.3

  # ---------------- (d2-1) Multicolumn grid and horizontal movement ----------------
  local RIGHT=$'\e[C' LEFT=$'\e[D'
  send_keys 'ls gd/'
  # a01..a30 use two-character words with width-three cells: eight columns by four
  # rows, column-major, so row one is a01 a05 a09 ...
  if expect '*a01  a05*' 10; then
    ok "(d2-1a) 列優先グリッドで複数候補が 1 行に並ぶ(a01  a05)"
  else
    ng "(d2-1a) グリッド行が確認できない"
  fi
  log_count 'render: 5 lines shown=30'
  if (( REPLY > 0 )); then
    ok "(d2-1b) 30 件が見出し 1 行 + 8 列 × 4 行に収まる"
  else
    ng "(d2-1b) グリッド形状が期待と違う(render: 5 lines shown=30 がログにない)"
  fi
  log_count 'select: pos=5'; local -i c_gp5=$REPLY
  send_keys $DOWN            # start selection at pos=1
  drain 0.3
  send_keys $RIGHT           # move right one column = +rows (4)
  wait_log 'select: pos=5' $c_gp5 3 && ok "(d2-1c) → で右の列へ(pos 1→5)" || ng "(d2-1c) 列ジャンプしない"
  log_count 'select: pos=1'; local -i c_gp1=$REPLY
  send_keys $LEFT
  wait_log 'select: pos=1' $c_gp1 3 && ok "(d2-1d) ← で左の列へ戻る(pos 5→1)" || ng "(d2-1d) 左ジャンプしない"
  press $CTRLG
  # When unselected, Left falls back through the predecessor chain to cursor movement.
  log_count 'dispatch: fallback'; local -i c_gfb=$REPLY
  send_keys $LEFT
  wait_log 'dispatch: fallback' $c_gfb 3 && ok "(d2-1e) 非選択時の ← は前任者へフォールバック" || ng "(d2-1e) 非選択 ← が奪われている"
  clear_line
  drain 0.3

  # ---------------- (kb-1) Default Emacs-family keys (ctrl-n/p/b/f) ----------------
  send_keys 'ls gd/'
  expect '*a01  a05*' 10 >/dev/null
  log_count 'select: start'; local -i c_kbs=$REPLY
  send_keys $'\C-n'
  wait_log 'select: start' $c_kbs 3 && ok "(kb-1a) ctrl-n で選択開始(↓ と同じ優先順位規則)" || ng "(kb-1a) ctrl-n で選択が始まらない"
  log_count 'select: pos=5'; local -i c_kb5=$REPLY
  send_keys $'\C-f'
  wait_log 'select: pos=5' $c_kb5 3 && ok "(kb-1b) ctrl-f で右の列へ(pos 1→5)" || ng "(kb-1b) ctrl-f が効かない"
  log_count 'select: pos=1'; local -i c_kb1=$REPLY
  send_keys $'\C-b'
  wait_log 'select: pos=1' $c_kb1 3 && ok "(kb-1c) ctrl-b で左の列へ(pos 5→1)" || ng "(kb-1c) ctrl-b が効かない"
  log_count 'select: released-at-top'; local -i c_kbr=$REPLY
  send_keys $'\C-p'
  wait_log 'select: released-at-top' $c_kbr 3 && ok "(kb-1d) 先頭で ctrl-p → 選択解除(↑ と同じ)" || ng "(kb-1d) ctrl-p で解除されない"
  # When unselected, ctrl-p falls back to the predecessor history widget.
  log_count 'dispatch: fallback'; local -i c_kbf=$REPLY
  send_keys $'\C-p'
  wait_log 'dispatch: fallback' $c_kbf 3 && ok "(kb-1e) 非選択時の ctrl-p は前任者へフォールバック" || ng "(kb-1e) 非選択 ctrl-p が奪われている"
  clear_line
  drain 0.3

  # ---------------- (d3-1) Group headings ----------------
  send_keys 'ls docs/inte'
  if expect '*file*internal*' 10; then
    ok "(d3-1a) ファイル候補にグループ見出し 'file' が付く"
  else
    ng "(d3-1a) 見出し 'file' が出ない"
  fi
  clear_line
  drain 0.3
  send_keys 'git chec'
  if expect '*main porcelain command*checkout*' 15; then
    ok "(d3-1b) git サブコマンドに見出し 'main porcelain command' が付く"
  else
    ng "(d3-1b) git サブコマンドの見出しが出ない"
  fi
  drain 0.3
  # (d3-1c) Rendering multiple groups with spans must not leak variable values.
  # In zsh, redeclaring a populated local without assignment may print it to stdout.
  if [[ $TRANSCRIPT != *sp=* && $TRANSCRIPT != *gcount=* ]]; then
    ok "(d3-1c) render の変数表示リーク(sp=/gcount=)がない"
  else
    ng "(d3-1c) render が変数を標準出力へ漏らしている(sp=/gcount= を検出)"
  fi
  clear_line
  drain 0.3

  # ---------------- (d4-1) Match highlighting and [display.highlight] ----------------
  TRANSCRIPT=
  send_keys 'ls docs/inte'
  expect '*internal*' 10 >/dev/null
  drain 0.3
  # With default match="underline", vt100 smul emits \e[4m at match positions.
  if [[ $TRANSCRIPT == *$'\e[4m'* ]]; then
    ok "(d4-1a) マッチ箇所の underline(SGR 4)が pty 出力に現れる"
  else
    ng "(d4-1a) underline 列が pty 出力に見えない"
  fi
  clear_line
  drain 0.3
  # Changing match to "" disables decoration; automatic reload removes underline.
  command sleep 1.1
  print -r -- $'[display.highlight]\nmatch = ""' > $XDG_CONFIG_HOME/zrush/config.toml
  send_line ': cfg-hl'
  sync_prompt
  TRANSCRIPT=
  send_keys 'ls docs/inte'
  expect '*internal*' 10 >/dev/null
  drain 0.3
  if [[ $TRANSCRIPT != *$'\e[4m'* ]]; then
    ok "(d4-1b) match=\"\" の自動反映で underline が消える"
  else
    ng "(d4-1b) match=\"\" 後も underline が出ている"
  fi
  clear_line
  drain 0.3

  # ---------------- (m4-12) Key-binding changes and odd-length arrays ----------------
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
  # Host-side unit check: odd-length KEYBINDS ignores the whole array, defaults, and warns.
  send_line 'ZRUSH_CFG_KEYBINDS=(a b c); _zrush_apply_keybinds'
  if expect '*odd length*' 5; then
    ok "(m4-12c) KEYBINDS 奇数長は無視して既定+警告"
  else
    ng "(m4-12c) 奇数長の警告が出ない"
  fi
  sync_prompt

  # ================================================================ Empty-word collection cache
  # (cc-1) The second command-position query hits and renders without a fork.
  clear_line
  drain 0.5
  log_count 'cache: saved'; local -i cc_sv=$REPLY
  send_keys 'whic'
  expect '*which*' 10 >/dev/null
  wait_log 'cache: saved' $cc_sv 5 || :   # the first query may hit; either way the cache is warm
  clear_line
  drain 0.5
  log_count 'cache: hit';          local -i cc_hit=$REPLY
  log_count 'request: collecting'; local -i cc_col=$REPLY
  TRANSCRIPT=
  send_keys 'whic'
  if wait_log 'cache: hit' $cc_hit 5; then
    ok "(cc-1a) 2 回目のコマンド位置クエリでキャッシュヒット"
  else
    ng "(cc-1a) キャッシュヒットが記録されない"
  fi
  drain 0.5
  # wait_log drains pty output first, so match the cumulative TRANSCRIPT after stripping
  # SGR instead of using expect, as in d4.
  if [[ ${TRANSCRIPT//$'\e['[0-9;]#m/} == *which* ]]; then
    ok "(cc-1b) ヒット経路でも一覧が描画される(which を確認)"
  else
    ng "(cc-1b) ヒット時に一覧が出ない"
  fi
  log_count 'request: collecting'; local -i cc_col2=$REPLY
  if (( cc_col2 == cc_col )); then
    ok "(cc-1c) ヒット時は収集 fork が起きない ($cc_col → $cc_col2)"
  else
    ng "(cc-1c) ヒットのはずが収集が走った ($cc_col → $cc_col2)"
  fi
  clear_line
  drain 0.3

  # (cc-2) Adding an alias invalidates the fingerprint, recollects, and lists it.
  log_count 'cache: miss (fingerprint)'; local -i cc_fp=$REPLY
  send_line 'alias zrushtestalias=ls'
  sync_prompt
  send_keys 'zrushtestali'
  if expect '*zrushtestalias*' 10; then
    ok "(cc-2a) alias 追加が次の一覧に反映される"
  else
    ng "(cc-2a) 追加した alias が一覧に出ない"
  fi
  wait_log 'cache: miss (fingerprint)' $cc_fp 3 && \
    ok "(cc-2b) alias 追加でフィンガープリントミス" || \
    ng "(cc-2b) fingerprint ミスが記録されない"
  clear_line
  drain 0.3

  # (cc-3) Adding a PATH directory invalidates the cache and lists its new binary.
  mkdir -p $WORK/xbin
  print -r -- '#!/bin/sh' > $WORK/xbin/zrushtestbin1
  chmod +x $WORK/xbin/zrushtestbin1
  log_count 'cache: miss (fingerprint)'; cc_fp=$REPLY
  send_line "path+=($WORK/xbin)"
  sync_prompt
  send_keys 'zrushtestbin'
  if expect '*zrushtestbin1*' 10; then
    ok "(cc-3a) PATH 追加ディレクトリのバイナリが一覧に反映される"
  else
    ng "(cc-3a) PATH 追加後のバイナリが一覧に出ない"
  fi
  wait_log 'cache: miss (fingerprint)' $cc_fp 3 && \
    ok "(cc-3b) PATH 変更でフィンガープリントミス" || \
    ng "(cc-3b) PATH 変更のミスが記録されない"
  clear_line
  drain 0.3

  # (cc-4) Adding an executable to an existing PATH directory invalidates via dir mtime.
  command sleep 1.1   # accommodate one-second mtime granularity
  print -r -- '#!/bin/sh' > $WORK/xbin/zrushtestbin2
  chmod +x $WORK/xbin/zrushtestbin2
  log_count 'cache: miss (fingerprint)'; cc_fp=$REPLY
  send_keys 'zrushtestbin'
  if expect '*zrushtestbin2*' 10; then
    ok "(cc-4a) PATH 上ディレクトリへのバイナリ追加が一覧に反映される"
  else
    ng "(cc-4a) 追加バイナリが一覧に出ない"
  fi
  wait_log 'cache: miss (fingerprint)' $cc_fp 3 && \
    ok "(cc-4b) ディレクトリ mtime 変化でフィンガープリントミス" || \
    ng "(cc-4b) mtime 変化のミスが記録されない"
  clear_line
  drain 0.3

  # (cc-5) TTL expiry misses; shorten the TTL to one second inside the host.
  send_line '_ZRUSH_CC_TTL=1'
  sync_prompt
  send_keys 'whic'                 # warm it; either a miss or hit leaves a saved cache
  expect '*which*' 10 >/dev/null
  clear_line
  drain 0.3
  command sleep 2.5                # exceed TTL=1s despite whole-second rounding
  log_count 'cache: miss (ttl)'; local -i cc_ttl=$REPLY
  send_keys 'whic'
  wait_log 'cache: miss (ttl)' $cc_ttl 5 && \
    ok "(cc-5) TTL 失効でミスし再収集する" || \
    ng "(cc-5) TTL ミスが記録されない"
  clear_line
  drain 0.3
  send_line '_ZRUSH_CC_TTL=300'
  sync_prompt

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  zpty -d host 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-test.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
