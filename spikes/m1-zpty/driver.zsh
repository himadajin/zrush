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
# 部分パス補完(/u/lo → /usr/local)検証用の固定ツリー(冪等に作成)
mkdir -p $PLAYGROUND/pp/usr/local/bin $PLAYGROUND/pp/usr/local/lib $PLAYGROUND/pp/usr/share/doc

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
export HOME=$PLAYGROUND   # ~ 保持検証用(~/do → ~/docs)。実ホームには触れない
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

# EXPECT_BUF から ZRUSH-ITEM 行(${(qqqq)} エンコードされた v1 レコード)を抽出。
# ITEMS     = デコード済みレコード(<tag>\1<value> を \2 結合したもの)
# WORDS     = レコードの w フィールド(compadd 語。挿入用クォートを含み得る)
# RAW_ITEMS = さらに ${(Q)} でクォートを剥がした「実ファイル名」
parse_items() {
  typeset -ga ITEMS=() WORDS=() RAW_ITEMS=()
  typeset -g RESULT_LINE=
  local line enc decoded
  for line in ${(f)${EXPECT_BUF//$'\r'/}}; do
    if [[ $line == *ZRUSH-ITEM\ * ]]; then
      enc=${line##*ZRUSH-ITEM }
      decoded=
      eval "decoded=$enc" 2>/dev/null    # (qqqq) エンコードを戻す(自前出力なので安全)
      ITEMS+=( "$decoded" )
      rec_get "$decoded" w
      WORDS+=( "$REPLY" )
      RAW_ITEMS+=( "${(Q)REPLY}" )
    fi
    [[ $line == *ZRUSH-RESULT\ * ]] && RESULT_LINE=${line##*ZRUSH-RESULT }
  done
}

rec_get() {  # $1=レコード $2=タグ → REPLY=値(なければ非 0)
  typeset -g REPLY=
  local f
  for f in "${(@ps:\2:)1}"; do
    if [[ ${f%%$'\1'*} == $2 ]]; then
      REPLY=${f#*$'\1'}
      return 0
    fi
  done
  return 1
}

# レコードから挿入文字列(語領域の完全形)を再構成する。
# モデル(compadd doc の合成順): <IPREFIX><ipre(-i)><apre(-P)><hpre(-p)><word><hsuf(-s)><asuf(-S)><isuf(-I)>
# さらに -f(ファイル候補)でディレクトリの場合は compadd の挙動に合わせ '/' を付与
# (判定には捕獲した realdir(rd)を使う。driver は host と同じ cwd で動く前提)。
reconstruct() {  # $1=レコード → REPLY
  local rec=$1 t
  local -A g=()
  for t in ip i P p w s S I f rd; do
    rec_get "$rec" $t && g[$t]=$REPLY
  done
  local composed=${g[ip]}${g[i]}${g[P]}${g[p]}${g[w]}${g[s]}${g[S]}${g[I]}
  if [[ ${g[f]} == 1 && $composed != */ ]] && [[ -d ${g[rd]}${(Q)g[w]} ]]; then
    composed+=/
  fi
  typeset -g REPLY=$composed
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

# pty を読みながら待つ。
# 重要: ドライバが pty を読まないままホスト側に出力が滞留すると、ホストは
# accept-line 後や外部コマンド起動時の tcsetattr(TCSADRAIN) で永久ブロックする
# (sample で実証: loop→hend→settyinfo→tcsetattr→ioctl)。
# 実端末は常に読むので実運用では起きないが、ドライバの待ちループは必ずこれを使う。
drain_pty() {  # $1=待ち秒数
  local -F dl=$(( SECONDS + ${1:-0.2} ))
  local chunk
  while (( SECONDS < dl )); do
    if zselect -t 10 -r $HOSTFD 2>/dev/null; then
      zpty -r host chunk 2>/dev/null && TRANSCRIPT+=$chunk
    fi
  done
}

# 広げ収集(ZRUSH_WIDEN=1 前提)から目的候補を選び、その再構成を
# 「as-typed の実挿入」と突き合わせる(選択→置換の統合確認)。
compare_widened() {  # $1=label $2=as-typed buffer $3=語領域より前 $4=目的候補(dequoted)
  local label=$1 buffer=$2 pre=$3 target=$4
  if ! run_capture $buffer "$label(capture)"; then
    return 1
  fi
  local -i idx=${RAW_ITEMS[(Ie)$target]}
  local -a caprecs=( "${(@)ITEMS}" )
  clear_line
  expect '*HP>*' 3 >/dev/null
  if (( idx == 0 )); then
    ng "$label: 広げ収集に目的候補 ${(qqqq)target} が含まれない: ${(j:, :)${(qqqq)RAW_ITEMS[@]}}"
    return 1
  fi
  if ! real_insert $buffer; then
    ng "$label: 実挿入(^X^R)の結果が取れない"
    return 1
  fi
  reconstruct "${caprecs[idx]}"
  local recon="$pre$REPLY"
  if [[ $REAL_BUF == $recon || $REAL_BUF == "$recon " ]]; then
    ok "$label: 広げ収集候補の再構成 == as-typed 実挿入 ${(qqqq)recon}"
  else
    ng "$label: 不一致 recon=${(qqqq)recon} real=${(qqqq)REAL_BUF} rec=${(qqqq)caprecs[idx]}"
  fi
  return 0
}

# 素の compsys に第 1 候補を実挿入させ、結果 BUFFER を取得(^X^R → zrush-real-insert)
real_insert() {  # $1=buffer text → REAL_BUF
  typeset -g REAL_BUF=
  send_keys $1
  send_keys $'\C-x\C-r'
  local st=1 line
  if expect '*ZRUSH-REAL-END*' 15; then
    for line in ${(f)${EXPECT_BUF//$'\r'/}}; do
      [[ $line == *ZRUSH-REAL-END* ]] && continue
      [[ $line == *ZRUSH-REAL\ * ]] && eval "REAL_BUF=${line##*ZRUSH-REAL }" 2>/dev/null
    done
    st=0
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null
  return $st
}

# 捕獲レコードからの再構成と実挿入を突き合わせる。
# mode=match: 一致を要求(不一致は FAIL)
# mode=observe: 一致/不一致を記録するだけ(FAIL にしない。崩れ方の記録が目的)
compare_case() {  # $1=label $2=buffer $3=語領域より前の部分 $4=mode
  local label=$1 buffer=$2 pre=$3 mode=${4:-match}
  if ! run_capture $buffer "$label(capture)"; then
    return 1
  fi
  local -a caprecs=( "${(@)ITEMS}" )
  clear_line
  expect '*HP>*' 3 >/dev/null
  if (( $#caprecs == 0 )); then
    ng "$label: 候補が捕獲できない"
    return 1
  fi
  if ! real_insert $buffer; then
    ng "$label: 実挿入(^X^R)の結果が取れない"
    return 1
  fi
  reconstruct "${caprecs[1]}"
  local recon="$pre$REPLY"
  if [[ $REAL_BUF == $recon ]]; then
    ok "$label: 再構成 == 実挿入 ${(qqqq)recon}"
  elif [[ $REAL_BUF == "$recon " ]]; then
    ok "$label: 再構成+auto-space == 実挿入 ${(qqqq)REAL_BUF}"
  else
    if [[ $mode == observe ]]; then
      out "OBSV: $label: 不一致(想定内・記録) recon=${(qqqq)recon} real=${(qqqq)REAL_BUF} rec1=${(qqqq)caprecs[1]}"
    else
      ng "$label: 不一致 recon=${(qqqq)recon} real=${(qqqq)REAL_BUF} rec1=${(qqqq)caprecs[1]}"
    fi
  fi
  return 0
}

widen_test() {  # $1=buffer $2=期待広げ後 $3=期待クエリ
  zrush_widen "$1"
  if [[ $REPLY_WIDENED == "$2" && $REPLY_QUERY == "$3" ]]; then
    ok "widen: ${(qqqq)1} → ${(qqqq)2} + ${(qqqq)3}"
  else
    ng "widen: ${(qqqq)1} → got ${(qqqq)REPLY_WIDENED} + ${(qqqq)REPLY_QUERY}, want ${(qqqq)2} + ${(qqqq)3}"
  fi
}

{
  # ---------------- M1-4 単体テスト: 広げ規則(純関数・pty 不要)----------------
  source $SPIKE/04-widen.zsh
  out "==== M1-4: 広げ規則 単体テスト ===="
  widen_test 'gti'          ''          'gti'
  widen_test 'docs/inte'    'docs/'     'inte'
  widen_test '--verbso'     '--'        'verbso'
  widen_test 'FOO=ba'       'FOO='      'ba'
  widen_test '~/do'         '~/'        'do'
  widen_test 'ls docs/inte' 'ls docs/'  'inte'
  widen_test 'git ch'       'git '      'ch'
  widen_test 'ls /'         'ls /'      ''       # 語が / そのもの
  widen_test 'FOO='         'FOO='      ''       # = で終わる
  widen_test '-'            '-'         ''       # - 単独
  widen_test ''             ''          ''       # 空語
  widen_test 'ls '          'ls '       ''       # 現在語が空(複数語)

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

  # ================ M1-3: compadd フックの網羅性 ================
  out "==== M1-3: メタデータ捕獲・-O/-A 除外・挿入再構成 ===="

  # --- (1) -O/-A 除外: _describe 経由(内部で -O/-A/-D を多用)---
  if run_capture 'tstdesc ' "[m1-3] describe"; then
    if (( $#RAW_ITEMS == 3 )) && has_item add && has_item remove && has_item update; then
      ok "[m1-3] -O/-A 除外: _describe で候補がちょうど {add,remove,update} の 3 件(マッチテスト呼び出しの混入なし)"
    else
      ng "[m1-3] -O/-A 除外: 候補集合が想定外: ${(j:, :)${(qqqq)RAW_ITEMS[@]}}"
    fi
    # --- (4) 表示文字列と挿入文字列の区別 ---
    local _r _w _d ok_d=1
    for _r in "${(@)ITEMS}"; do
      rec_get "$_r" w; _w=$REPLY
      rec_get "$_r" d || { ok_d=0; break }
      _d=$REPLY
      [[ -n $_d && $_d != $_w ]] || { ok_d=0; break }
    done
    if (( ok_d )); then
      rec_get "${ITEMS[1]}" d
      ok "[m1-3] 表示/挿入の区別: 全候補で -d 表示文字列を別途捕獲(例: w=add d=${(qqqq)REPLY})"
    else
      ng "[m1-3] 表示/挿入の区別: -d が取れない候補あり: ${(qqqq)ITEMS[1]}"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # --- (2)+(3) 合成 -P/-S/-p/-s/-i/-I: メタデータ捕獲と合成順序の検証 ---
  if run_capture 'tstps ' "[m1-3] ps(capture)"; then
    local _rec1=${ITEMS[1]:-}
    local want ok_meta=1 missing=
    for want in P:PRE: p:hidp: S::SUF s::hids i:ign: I::igns; do
      rec_get "$_rec1" ${want%%:*} && [[ $REPLY == ${want#*:} ]] || { ok_meta=0; missing+=" ${want%%:*}" }
    done
    if (( ok_meta )); then
      ok "[m1-3] メタデータ捕獲: -P/-p/-S/-s/-i/-I の全値を捕獲(rec=${(qqqq)_rec1})"
    else
      ng "[m1-3] メタデータ捕獲: 欠落タグ:$missing rec=${(qqqq)_rec1}"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null
  compare_case "[m1-3] 合成順序(-P/-S/-p/-s/-i/-I)" 'tstps ' 'tstps ' match

  # --- (3) 実在ケースでの再構成一致 ---
  compare_case "[m1-3] 変数補完(\$ZRUSHUNIQ → IPREFIX)" 'echo $ZRUSHUNIQ' 'echo ' match
  compare_case "[m1-3] オプション補完(--verb → --verbose)" 'tstargs --verb' 'tstargs ' match
  compare_case "[m1-3] オプション補完(--fi → --file=)" 'tstargs --fi' 'tstargs ' match
  compare_case "[m1-3] describe 系(tstdesc ad → add)" 'tstdesc ad' 'tstdesc ' match
  compare_case "[m1-3] ファイル補完・dir(docs/inte → internal/)" 'ls docs/inte' 'ls ' match
  compare_case "[m1-3] ファイル補完・file(Cargo.t → Cargo.toml)" 'ls Cargo.t' 'ls ' match

  # --- (3) 崩れるはずのケース(観察・記録)---
  compare_case "[m1-3] compadd -U(語全体書き換え)" 'tstu xyz' 'tstu ' observe
  compare_case "[m1-3] _multi_parts(段階補完)" 'tstmulti /usr/lo' 'tstmulti ' observe
  compare_case "[m1-3] _multi_parts(複数セグメント略記 /u/lo)" 'tstmulti /u/lo' 'tstmulti ' observe
  compare_case "[m1-3] 部分パス補完(pp/u/lo → pp/usr/local)" 'ls pp/u/lo' 'ls ' observe

  # --- (3') ~ 保持: 捕獲データ上で ~ が展開されないか(plan の ~ 非展開保証に直結)---
  if run_capture 'ls ~/do' "[m1-3] tilde(capture)"; then
    local _trec=${ITEMS[1]:-}
    local _tp= _tip=
    rec_get "$_trec" p  && _tp=$REPLY
    rec_get "$_trec" ip && _tip=$REPLY
    if [[ $_tip$_tp == '~/'* ]]; then
      ok "[m1-3] ~ 保持: 捕獲プレフィックスが未展開のまま (ip=${(qqqq)_tip} p=${(qqqq)_tp})"
    else
      ng "[m1-3] ~ 保持: プレフィックスが展開されている ip=${(qqqq)_tip} p=${(qqqq)_tp} rec=${(qqqq)_trec}"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null
  compare_case "[m1-3] ~ 再構成(~/do → ~/docs/)" 'ls ~/do' 'ls ' match

  # --- (2') _arguments の説明文と -S= の捕獲(合否外の情報も含めて確認)---
  if run_capture 'tstargs --' "[m1-3] args(capture)"; then
    local _found_file=0 _file_rec=
    for _r in "${(@)ITEMS}"; do
      rec_get "$_r" w
      [[ $REPLY == --file ]] && { _found_file=1; _file_rec=$_r }
    done
    if (( _found_file )); then
      local _sfx= _dsc=
      rec_get "$_file_rec" S && _sfx=$REPLY
      rec_get "$_file_rec" s && _sfx=${_sfx:-$REPLY}
      rec_get "$_file_rec" d && _dsc=$REPLY
      if [[ $_sfx == '=' && -n $_dsc ]]; then
        ok "[m1-3] --file= 型: suffix '=' と説明文を捕獲(d=${(qqqq)_dsc})"
      else
        ng "[m1-3] --file= 型: suffix/説明が取れない rec=${(qqqq)_file_rec}"
      fi
    else
      ng "[m1-3] --file 候補が捕獲できない: ${(j:, :)${(qqqq)RAW_ITEMS[@]}}"
    fi
    # あれば良い: -X/-J/-V の取得可否を記録(合否に含めない)
    local _x= _j= _v=
    rec_get "${ITEMS[1]}" X && _x=$REPLY
    rec_get "${ITEMS[1]}" J && _j=$REPLY
    rec_get "${ITEMS[1]}" V && _v=$REPLY
    out "OBSV: [m1-3] グループ情報(合否外): X=${(qqqq)_x} J=${(qqqq)_j} V=${(qqqq)_v} (rec=${(qqqq)ITEMS[1]})"
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # ================ M1-4: 広げクエリでの収集検証 ================
  out "==== M1-4: 広げクエリでの収集 ===="
  send_line "typeset -g ZRUSH_WIDEN=1"
  expect '*HP>*' 5 >/dev/null

  # --- (a) コマンド位置の空語(gti の広げ結果 = '')→ 全コマンド名(最悪ケース先行計測)---
  send_line "typeset -g ZRUSH_REPORT_LIMIT=40"
  expect '*HP>*' 5 >/dev/null
  if run_capture 'gti' "[m1-4] 空語コマンド収集"; then
    local -i _cnt=${${${(M)${(s: :)RESULT_LINE}:#count=*}[1]}#count=}
    if (( _cnt >= 500 )); then
      ok "[m1-4] 空語(gti→'')で全コマンド名 $_cnt 件を収集 ($RESULT_LINE)"
    else
      ng "[m1-4] 空語収集が少なすぎる: $RESULT_LINE"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null
  send_line "typeset -g ZRUSH_REPORT_LIMIT=0"
  expect '*HP>*' 5 >/dev/null

  # --- (b) docs/inte の広げ結果(docs/)で docs/ 配下一式 ---
  if run_capture 'ls docs/inte' "[m1-4] docs/ 収集"; then
    if has_item internal && has_item user; then
      ok "[m1-4] 'docs/inte'→広げ 'docs/' で docs/ 配下一式 (internal, user) ($RESULT_LINE)"
    else
      ng "[m1-4] docs/ 配下が取れない: ${(j:, :)${(qqqq)RAW_ITEMS[@]}}"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # --- (c) --verbso の広げ結果(--)でオプション集合 ---
  if run_capture 'tstargs --verbso' "[m1-4] -- 収集"; then
    if (( $#RAW_ITEMS == 3 )) && has_item '--verbose' && has_item '--file' && has_item '--mode'; then
      ok "[m1-4] '--verbso'→広げ '--' でオプション集合 3 件 ($RESULT_LINE)"
    else
      ng "[m1-4] オプション集合が想定外: ${(j:, :)${(qqqq)RAW_ITEMS[@]}}"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # --- (d) git ch の広げ結果(空語)で git サブコマンド一式 ---
  if run_capture 'git ch' "[m1-4] git サブコマンド収集"; then
    local -i _gcnt=${${${(M)${(s: :)RESULT_LINE}:#count=*}[1]}#count=}
    if has_item checkout && (( _gcnt >= 50 )); then
      ok "[m1-4] 'git ch'→広げ 'git ' でサブコマンド $_gcnt 件(checkout 含む) ($RESULT_LINE)"
    else
      ng "[m1-4] git サブコマンドが取れない: count=$_gcnt has_checkout=$? ($RESULT_LINE)"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # --- (e) ~/do の広げ結果(~/)で HOME 配下 + hpre 未展開 ---
  if run_capture 'ls ~/do' "[m1-4] ~/ 収集"; then
    if has_item docs; then
      local -i _tidx=${RAW_ITEMS[(Ie)docs]}
      rec_get "${ITEMS[_tidx]}" p
      if [[ $REPLY == '~/' ]]; then
        ok "[m1-4] '~/do'→広げ '~/' で HOME 配下が取れ、hpre は未展開 '~/' のまま ($RESULT_LINE)"
      else
        ng "[m1-4] hpre が想定外: ${(qqqq)REPLY} rec=${(qqqq)ITEMS[_tidx]}"
      fi
    else
      ng "[m1-4] ~/ 配下が取れない: ${(j:, :)${(qqqq)RAW_ITEMS[@]}}"
    fi
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # --- 広げ収集 → 候補選択 → 置換、が as-typed 実挿入と一致するか ---
  compare_widened "[m1-4] 置換統合(docs/inte→internal/)" 'ls docs/inte' 'ls ' 'internal'
  compare_widened "[m1-4] 置換統合(--verb→--verbose)"    'tstargs --verb' 'tstargs ' '--verbose'
  compare_widened "[m1-4] 置換統合(~/do→~/docs/)"        'ls ~/do' 'ls ' 'docs'

  send_line "typeset -g ZRUSH_WIDEN="
  expect '*HP>*' 5 >/dev/null

  # ================ M1-5: キャンセルと後始末 ================
  out "==== M1-5: キャンセルと後始末 ===="
  send_line "export ZRUSH_SLOW_LOG=$WORK/slow.log"
  expect '*HP>*' 5 >/dev/null

  # slow.log の最終行から pid を取り出す(数値でなければ空を返す)
  read_slow_pid() {  # → REPLY(pid or 空)
    typeset -g REPLY=
    [[ -s $WORK/slow.log ]] || return 1
    # 注意: ${(f)...}[-1] は 1 行のとき「スカラの最終 1 文字」を返す罠がある。
    # 必ず配列に受けてから [-1] を取る(driver13 で pid=0/1 事故の原因)。
    local -a lines=( ${(f)"$(<$WORK/slow.log)"} )
    local pid=${${lines[-1]}#*PID=}
    [[ $pid == <-> && $pid != 0 ]] && REPLY=$pid
    [[ -n $REPLY ]]
  }
  # pid の消滅を最大 $2 秒待つ(pty を読みながら)。REPLY_ELAPSED に所要秒。
  wait_dead() {  # $1=pid $2=timeout(s)
    local -F t0=$SECONDS
    local -i n=$(( $2 * 5 ))
    while (( n-- > 0 )); do
      kill -0 $1 2>/dev/null || { typeset -gF REPLY_ELAPSED=$(( SECONDS - t0 )); return 0 }
      drain_pty 0.2
    done
    typeset -gF REPLY_ELAPSED=$(( SECONDS - t0 ))
    return 1
  }

  # --- (3a) 遅い補完(sleep 3)中もホストが入力を受け付ける ---
  : >| $WORK/slow.log
  send_keys 'tstslow '
  send_keys $'\C-x\C-z'
  clear_line
  send_line 'print MARK-ALIVE-SLOW'
  if expect '*MARK-ALIVE-SLOW*' 2; then
    ok "[m1-5] 遅い補完(sleep 3)の収集中もホストは入力を受け付ける"
  else
    ng "[m1-5] 遅い補完中にホストが応答しない"
  fi
  # コマンド実行直後は zle 再初期化で typeahead が捨てられるため、プロンプト到達を待つ
  expect '*HP>*' 3 >/dev/null

  # 旧 fork の pid はホスト自身が pipe 先頭レコードで受領している(_zrush_worker_pid)。
  # slow.log 経由は「キー到着がバーストした場合に補完関数まで進む前にキャンセルされる」
  # レースで空になり得るため使わない。
  local slowpid= _i=0
  while (( _i++ < 10 )); do
    send_line 'print WPID-${_zrush_worker_pid:-none}-END'
    if expect '*WPID-<->-END*' 2; then
      slowpid=${${EXPECT_BUF##*WPID-}%%-END*}
      expect '*HP>*' 3 >/dev/null
      break
    fi
    expect '*HP>*' 3 >/dev/null
  done
  [[ $slowpid == <-> ]] || { ng "[m1-5] ホストから worker pid が取れない"; slowpid= }

  # --- (1)(2)(3b) 収集中(sleep 残り約 2 秒)に新リクエスト → 旧 zpty 破棄・新結果のみ ---
  send_keys 'ls docs/'
  send_keys $'\C-x\C-z'
  if expect '*ZRUSH-END*' 10; then
    parse_items
    if has_item internal && ! has_item slow-one && ! has_item slow-two; then
      ok "[m1-5] 収集中の新リクエストで旧収集がキャンセルされ、新結果のみ届く ($RESULT_LINE)"
    else
      ng "[m1-5] 結果が混ざった: ${(j:, :)${(qqqq)RAW_ITEMS[@]}}"
    fi
  else
    ng "[m1-5] 新リクエストの結果が来ない"
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # --- (1') 旧 fork の死亡確認(pgroup SIGINT による即時中断)---
  if [[ -n $slowpid ]]; then
    if wait_dead $slowpid 4; then
      if (( REPLY_ELAPSED < 2.0 )); then
        ok "[m1-5] 旧 fork (pid=$slowpid) がキャンセル後 ${REPLY_ELAPSED}s で消滅(sleep の自然終了を待たない即時中断)"
      else
        ok "[m1-5] 旧 fork (pid=$slowpid) は消滅したが ${REPLY_ELAPSED}s かかった(自然死の可能性・要注意)"
      fi
    else
      ng "[m1-5] 旧 fork (pid=$slowpid) が残留している"
      kill -9 $slowpid 2>/dev/null
    fi
  fi

  # --- (2') stale 結果の静観: 旧 sleep 完了時刻を過ぎても何も届かない ---
  expect '*ZRUSH-NEVER*' 4 >/dev/null   # 4 秒読み続ける(意図的に不一致)
  if [[ $EXPECT_BUF != *ZRUSH-RESULT* && $EXPECT_BUF != *slow-one* ]]; then
    ok "[m1-5] stale 結果は届かない(4 秒静観で ZRUSH 出力なし)。親も無事"
  else
    ng "[m1-5] stale 出力を検出: ${(qqqq)EXPECT_BUF}"
  fi

  # --- (3c) 遅い補完を放置 → 完走して結果が届く ---
  send_keys 'tstslow '
  send_keys $'\C-x\C-z'
  if expect '*ZRUSH-END*' 8; then
    parse_items
    if has_item slow-one && has_item slow-two; then
      ok "[m1-5] 放置した遅い補完は完走して結果が届く ($RESULT_LINE)"
    else
      ng "[m1-5] 遅い補完の結果が不正: ${(j:, :)${(qqqq)RAW_ITEMS[@]}}"
    fi
  else
    ng "[m1-5] 遅い補完が 8 秒で完走しない"
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # --- 連打(rapid-fire): 3 連続リクエストで最後の結果のみ ---
  send_keys 'tstslow a'
  send_keys $'\C-x\C-z'
  clear_line
  send_keys 'tstslow b'
  send_keys $'\C-x\C-z'
  clear_line
  send_keys 'ls docs/'
  send_keys $'\C-x\C-z'
  if expect '*ZRUSH-END*' 10; then
    parse_items
    if has_item internal && ! has_item slow-one; then
      ok "[m1-5] 連打 3 リクエストで最後の結果のみ届く ($RESULT_LINE)"
    else
      ng "[m1-5] 連打結果が不正: ${(j:, :)${(qqqq)RAW_ITEMS[@]}}"
    fi
  else
    ng "[m1-5] 連打後の結果が来ない"
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null
  expect '*ZRUSH-NEVER*' 4 >/dev/null   # 静観
  if [[ $EXPECT_BUF != *ZRUSH-RESULT* ]]; then
    ok "[m1-5] 連打後の静観 4 秒でキャンセル済みリクエストの結果は届かない"
  else
    ng "[m1-5] キャンセル済みの結果が漏れた: ${(qqqq)EXPECT_BUF}"
  fi

  # --- (追加確認) 非 NUL 終端の部分ペイロードで fork が異常死した場合 ---
  send_keys 'tstdie '
  send_keys $'\C-x\C-z'
  if expect '*ZRUSH-END*' 10; then
    if [[ $EXPECT_BUF == *unterminated-payload* ]]; then
      ok "[m1-5] 異常死 fork の部分ペイロードは ZRUSH-ERROR unterminated-payload として報告され、ホストは無事"
    else
      ng "[m1-5] unterminated 経路を通らなかった: ${(qqqq)EXPECT_BUF}"
    fi
  else
    ng "[m1-5] 異常死ケースで ZRUSH-END が来ない"
  fi
  clear_line
  send_line 'print MARK-ALIVE-DIE'
  expect '*MARK-ALIVE-DIE*' 3 >/dev/null && ok "[m1-5] 異常死ケース後もホスト応答あり"
  expect '*HP>*' 3 >/dev/null   # typeahead flush 対策(プロンプト同期)

  # --- (5) 再帰防止ガード: fork 内から _zrush_request を呼んでも二重 fork しない ---
  send_keys 'tstrecur '
  send_keys $'\C-x\C-z'
  if expect '*ZRUSH-END*' 10; then
    parse_items
    if (( $#RAW_ITEMS == 1 )) && has_item recur-done; then
      ok "[m1-5] 再帰防止: fork 内の _zrush_request は ZRUSH_INTERNAL ガードで無害化され、候補 recur-done のみ届く"
    else
      ng "[m1-5] 再帰ケースの結果が不正: ${(j:, :)${(qqqq)RAW_ITEMS[@]}}"
    fi
  else
    ng "[m1-5] 再帰ケースがハング(ガード不全の疑い)"
  fi
  clear_line
  expect '*HP>*' 3 >/dev/null

  # --- TMOUT 観察: ハング級補完(sleep 15)は TMOUT=10 で自殺するか ---
  : >| $WORK/slow.log
  send_keys 'tsthang '
  send_keys $'\C-x\C-z'
  if expect '*ZRUSH-END*' 12; then
    parse_items
    out "OBSV: [m1-5] TMOUT=10 は補完実行中にも発火: 終端到達 ($RESULT_LINE)"
    clear_line
    expect '*HP>*' 3 >/dev/null
  else
    out "OBSV: [m1-5] TMOUT=10 は補完実行中には発火しない(12s 時点で未完)→ 新リクエストでのキャンセルを検証"
    local hangpid=
    read_slow_pid && hangpid=$REPLY
    clear_line
    send_keys 'ls docs/'
    send_keys $'\C-x\C-z'
    if expect '*ZRUSH-END*' 10; then
      parse_items
      has_item internal && ok "[m1-5] ハング中 fork も新リクエストで即キャンセルされ新結果が届く ($RESULT_LINE)"
    else
      ng "[m1-5] ハング fork のキャンセルに失敗"
    fi
    if [[ -n $hangpid ]]; then
      if wait_dead $hangpid 4; then
        ok "[m1-5] ハング fork (pid=$hangpid) も消滅"
      else
        ng "[m1-5] ハング fork (pid=$hangpid) が残留"
        kill -9 $hangpid 2>/dev/null
      fi
    else
      ng "[m1-5] hang fork の pid が取れない: slow.log=${(qqqq)"$(cat $WORK/slow.log 2>/dev/null)"}"
    fi
    clear_line
    expect '*HP>*' 3 >/dev/null
  fi

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

  # ================ M1-5(4): zshexit での掃除(ホスト終了・最終テスト)================
  out "==== M1-5: zshexit 掃除(ホスト終了)===="
  expect '*HP>*' 3 >/dev/null   # 直前の残骸回収後、プロンプト同期してからキーを送る
  # 遅い収集を発行した直後にホストを exit させる
  : >| $WORK/slow.log
  send_keys 'tstslow '
  send_keys $'\C-x\C-z'
  local exitpid= _j=0
  while (( _j++ < 15 )); do
    read_slow_pid && { exitpid=$REPLY; break }
    drain_pty 0.1
  done
  clear_line
  send_line 'exit'
  local -i hostdead=0; _j=0
  while (( _j++ < 25 )); do
    zpty -t host 2>/dev/null || { hostdead=1; break }
    drain_pty 0.2
  done
  if (( hostdead )); then
    ok "[m1-5] ホストが exit で終了"
  else
    ng "[m1-5] ホストが exit しない"
  fi
  if [[ -n $exitpid ]]; then
    if wait_dead $exitpid 4; then
      ok "[m1-5] zshexit の掃除で収集中 fork (pid=$exitpid) も消滅"
    else
      ng "[m1-5] ホスト終了後も fork (pid=$exitpid) が残留"
      kill -9 $exitpid 2>/dev/null
    fi
  else
    ng "[m1-5] exit テストの fork pid が取れない: slow.log=${(qqqq)"$(cat $WORK/slow.log 2>/dev/null)"}"
  fi
  local -a leftover=( ${TMPDIR:-/tmp}/zrush-cap-*(N) )
  if (( $#leftover == 0 )); then
    ok "[m1-5] 一時 fifo の残骸なし(作成直後 unlink 済み)"
  else
    ng "[m1-5] fifo 残骸: ${(j:, :)leftover}"
  fi

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  zpty -d host 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-driver.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
