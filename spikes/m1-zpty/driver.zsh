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
