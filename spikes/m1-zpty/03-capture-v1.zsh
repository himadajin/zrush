# Step M1-3: 捕獲 v1 — メタデータ込みレコード + 実挿入比較
#
# v0(02-capture-v0.zsh)からの拡張:
#   - compadd フックが候補語だけでなくメタデータを捕獲してレコード化する
#       -P(apre) -p(hpre) -S(asuf) -s(hsuf) -i(ipre) -I(isuf) -d(表示文字列)
#       -X 見出し / -J / -V グループ / -x メッセージ / -U / -f
#       compadd 呼び出し時点の IPREFIX / ISUFFIX / PREFIX / SUFFIX
#   - レコード形式: フィールド = <tag>$'\1'<value>、フィールド結合 = $'\2'、
#     レコード終端 = NUL。搬出路は v0 と同じ継承 pipe + EOF 終端。
#     (注: 値に \1/\2 が含まれると壊れる。FTB と同じ制限。M2 プロトコルで要解決)
#   - 実挿入比較用ウィジェット zrush-real-insert(^X^R):
#     素の compsys に compstate[insert]=1 で第 1 候補を実挿入させ、結果 BUFFER を印字する
#     (ZAS comppostfuncs 方式)。フック捕獲からの再構成と突き合わせるための基準値。
#
# 駆動・搬出・受信の構造は v0 と同一(direct 方式のみ。vared は本構成では不可と実証済み)。

zmodload zsh/zpty    || return 1
zmodload zsh/system  || return 1
zmodload zsh/zutil   || return 1
zmodload zsh/parameter || return 1
zmodload zsh/datetime

typeset -g  ZRUSH_VARIANT=${ZRUSH_VARIANT:-direct}
typeset -g  _zrush_query= _zrush_fuzzy= _zrush_buf= _zrush_pty=
typeset -gi _zrush_rfd=-1 _zrush_wfd=-1 _zrush_gen=0 _zrush_nreads=0
typeset -gF _zrush_t0=0

# デバッグログ($ZRUSH_LOG が設定されていればファイル追記。fork 内でも使える)
_zlog() { [[ -n $ZRUSH_LOG ]] && print -r -- "[$$] $1" >>| $ZRUSH_LOG; return 0 }

# ------------------------------------------------------------------ compadd フック
# fork 内でのみ functions[compadd] に差し込まれる(FTB -ftb-compadd の拡張版)。
_zrush_compadd() {
  builtin setopt localoptions extendedglob norcexpandparam noshglob
  local -A apre hpre asuf hsuf ipre isuf dscrs _oad _mesg grpJ grpV
  local -a isfile _opts __ expl
  zparseopts -a _opts P:=apre p:=hpre S:=asuf s:=hsuf i:=ipre I:=isuf \
             d:=dscrs X+:=expl O:=_oad A:=_oad D:=_oad f=isfile x:=_mesg \
             r: R: W: F: M+: E: q e Q n U C \
             J:=grpJ V:=grpV a=__ l=__ k=__ o::=__ 1=__ 2=__
  # -O/-A/-D はマッチテスト・配列格納用の内部呼び出し。候補として数えず即委譲。
  if (( $#_oad != 0 )); then
    _zlog "compadd: delegate-only call (${(kv)_oad}) nargs=$#"
    builtin compadd "$@"
    return
  fi
  local -a __hits __dscr
  (( $#dscrs == 1 )) && __dscr=( "${(@P)${(v)dscrs}}" )
  builtin compadd -A __hits -D __dscr "$@"
  local -i ret=$?
  (( $#__hits == 0 )) && return ret

  # レコード化して搬出(pipe への書き込みは compadd 呼び出し単位でバッチする —
  # レコード毎 print だと大量候補時に読み側が 1 レコード 1 read になる: 実測 959 reads/4195 件)
  local _out=
  local -a _rec
  local -i j
  local _d
  for (( j = 1; j <= $#__hits; ++j )); do
    _rec=( "w"$'\1'"$__hits[j]" )
    _d=${__dscr[j]:-}
    [[ -n $_d ]]           && _rec+=( "d"$'\1'"$_d" )
    (( $#apre ))           && _rec+=( "P"$'\1'"${(v)apre}" )
    (( $#hpre ))           && _rec+=( "p"$'\1'"${(v)hpre}" )
    (( $#asuf ))           && _rec+=( "S"$'\1'"${(v)asuf}" )
    (( $#hsuf ))           && _rec+=( "s"$'\1'"${(v)hsuf}" )
    (( $#ipre ))           && _rec+=( "i"$'\1'"${(v)ipre}" )
    (( $#isuf ))           && _rec+=( "I"$'\1'"${(v)isuf}" )
    [[ -n $IPREFIX ]]      && _rec+=( "ip"$'\1'"$IPREFIX" )
    [[ -n $ISUFFIX ]]      && _rec+=( "is"$'\1'"$ISUFFIX" )
    [[ -n $PREFIX ]]       && _rec+=( "pr"$'\1'"$PREFIX" )
    [[ -n $SUFFIX ]]       && _rec+=( "su"$'\1'"$SUFFIX" )
    (( ${_opts[(I)-U]} ))  && _rec+=( "U"$'\1'"1" )
    if (( $#isfile )); then
      _rec+=( "f"$'\1'"1" )
      # -f 候補の実ディレクトリ(FTB :102-105)。挿入時のディレクトリ '/' 付与判定に必要。
      # 二重 ${} + 非クォートでないと ~ 展開が効かない(FTB :103 の NOTE。
      # クォートすると ~ が文字のまま残ることを実測済み)
      _rec+=( "rd"$'\1'${${(Qe)~${:-$IPREFIX${(v)hpre}}}} )
    fi
    (( $#expl >= 2 ))      && _rec+=( "X"$'\1'"$expl[2]" )
    (( $#grpJ ))           && _rec+=( "J"$'\1'"${(v)grpJ}" )
    (( $#grpV ))           && _rec+=( "V"$'\1'"${(v)grpV}" )
    (( $#_mesg ))          && _rec+=( "x"$'\1'"${(v)_mesg}" )
    _out+="${(pj:\2:)_rec}"$'\0'
  done
  print -rn -u $_zrush_wfd -- "$_out"
  _zlog "compadd: exported $#__hits records (P=${(v)apre} S=${(v)asuf} ip=$IPREFIX pr=$PREFIX)"
  # compsys の内部状態(compstate 等)の整合のため素の compadd も実行(FTB :127)
  builtin compadd "$@"
}

# ------------------------------------------------------------------ fork 内: 捕獲ウィジェット
_zrush_capture_complete() {
  _zlog "complete: invoked. vared=${compstate[vared]} context=${curcontext:-none}"
  unset 'compstate[vared]'
  unfunction compadd 2>/dev/null   # 他プラグインの compadd ラッパー除去
  functions[compadd]=$functions[_zrush_compadd]
  {
    _main_complete
    _zlog "complete: _main_complete returned st=$? nmatches=${compstate[nmatches]}"
  } always {
    unfunction compadd 2>/dev/null
  }
  compstate[insert]=
  compstate[list]=
  unset MENUSELECT MENUMODE
}

_zrush_capture_entry() {
  {
    _zlog "entry: setting buffer to ${(qqqq)_zrush_query}"
    LBUFFER=$_zrush_query
    RBUFFER=
    builtin zle _zrush-capture-c -w 2>>| ${ZRUSH_LOG:-/dev/null}
    _zlog "entry: completion widget returned st=$?"
  } always {
    exec {_zrush_wfd}>&-
    builtin exit 0
  }
}

# ------------------------------------------------------------------ fork 本体
_zrush_worker() {  # $1 = direct | vared
  typeset -gx ZRUSH_INTERNAL=1
  _zlog "worker: start variant=$1 wfd=$_zrush_wfd"
  local -a hooks=( chpwd periodic precmd preexec zshaddhistory zshexit )
  builtin unset ${^hooks}_functions 2>/dev/null
  $hooks[@] () { : }
  _zrush_noop() { : }
  local h
  for h in zle-isearch-exit zle-isearch-update zle-line-pre-redraw \
           zle-line-init zle-line-finish zle-history-line-set zle-keymap-select; do
    (( $+widgets[$h] )) && builtin zle -N $h _zrush_noop
  done
  TMOUT=10
  (( _zrush_rfd >= 0 )) && exec {_zrush_rfd}<&-

  if [[ $1 == vared ]]; then
    builtin bindkey $'\C-@' _zrush-capture-n
    builtin bindkey $'\r' undefined-key
    builtin bindkey $'\n' undefined-key
    local __tmp__=
    builtin vared __tmp__ 2>>| ${ZRUSH_LOG:-/dev/null}
    _zlog "worker: vared returned st=$?"
    builtin exit 0
  else
    builtin zle _zrush-capture-n 2>>| ${ZRUSH_LOG:-/dev/null}
    _zlog "worker: direct zle call returned st=$?"
    builtin exit 0
  fi
}

# ------------------------------------------------------------------ ホスト側
_zrush_cleanup() {
  if (( _zrush_rfd >= 0 )); then
    zle -F $_zrush_rfd 2>/dev/null
    exec {_zrush_rfd}<&-
    _zrush_rfd=-1
  fi
  if (( _zrush_wfd >= 0 )); then
    exec {_zrush_wfd}>&-
    _zrush_wfd=-1
  fi
  if [[ -n $_zrush_pty ]]; then
    zpty -d $_zrush_pty 2>/dev/null
    _zrush_pty=
  fi
  _zrush_buf=
}

zshexit() { _zrush_cleanup }

_zrush_request() {
  emulate -L zsh
  [[ -n $ZRUSH_INTERNAL ]] && return 0
  _zrush_cleanup
  # ZRUSH_WIDEN=1 なら広げ規則(04-widen.zsh)を適用して収集クエリを作る
  if [[ -n $ZRUSH_WIDEN ]] && (( $+functions[zrush_widen] )); then
    zrush_widen "$LBUFFER"
    _zrush_query=$REPLY_WIDENED
    _zrush_fuzzy=$REPLY_QUERY
    _zlog "request: widened=${(qqqq)_zrush_query} fuzzy=${(qqqq)_zrush_fuzzy}"
  else
    _zrush_query=$BUFFER
    _zrush_fuzzy=
  fi
  _zrush_t0=$EPOCHREALTIME
  _zrush_nreads=0
  _zlog "request: query=${(qqqq)_zrush_query} variant=$ZRUSH_VARIANT"

  local fifo=${TMPDIR:-/tmp}/zrush-cap-$$-$RANDOM.fifo
  mkfifo $fifo || return 1
  local rw
  exec {rw}<>$fifo
  exec {_zrush_rfd}<$fifo
  exec {_zrush_wfd}>$fifo
  exec {rw}>&-
  rm -f $fifo

  _zrush_pty=zrush-w$(( ++_zrush_gen ))
  _zlog "request: pipe rfd=$_zrush_rfd wfd=$_zrush_wfd"
  if ! zpty $_zrush_pty _zrush_worker $ZRUSH_VARIANT; then
    zle -M "zrush: zpty create failed"
    _zrush_cleanup
    return 1
  fi
  exec {_zrush_wfd}>&-
  _zrush_wfd=-1

  [[ $ZRUSH_VARIANT == vared ]] && zpty -wn $_zrush_pty $'\C-@'

  zle -F -w $_zrush_rfd _zrush-on-data
  _zlog "request: handler registered on fd $_zrush_rfd"
  return 0
}

_zrush_on_data() {
  emulate -L zsh
  local -i fd=$1
  local chunk= st=0
  sysread -i $fd chunk; st=$?
  _zlog "on-data: fd=$fd st=$st len=$#chunk err=${2:-}"
  if (( st == 0 )); then
    _zrush_buf+=$chunk
    (( ++_zrush_nreads ))
    return 0
  fi
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  _zrush_rfd=-1
  zpty -d $_zrush_pty 2>/dev/null
  _zrush_pty=
  if (( st == 5 )); then
    _zrush_report
  else
    zle -I
    print -r -- "ZRUSH-ERROR sysread=$st"
    print -r -- "ZRUSH-END"
  fi
  return 0
}

# 結果表示。各 ZRUSH-ITEM 行は「レコード全体」の ${(qqqq)} エンコード。
_zrush_report() {
  local -F elapsed=$(( EPOCHREALTIME - _zrush_t0 ))
  local -a recs=()
  local bad=
  local -i bytes=$#_zrush_buf
  if [[ -n $_zrush_buf ]]; then
    if [[ $_zrush_buf == *$'\0' ]]; then
      recs=( "${(@0)${_zrush_buf%$'\0'}}" )
    else
      bad=$_zrush_buf
    fi
  fi
  zle -I
  [[ -n $bad ]] && print -r -- "ZRUSH-ERROR unterminated-payload ${(qqqq)bad}"
  print -r -- "ZRUSH-RESULT count=$#recs bytes=$bytes reads=$_zrush_nreads elapsed-ms=$(( elapsed * 1000 ))"
  # 大量候補ケース用: ZRUSH_REPORT_LIMIT>0 なら先頭 N 件だけ印字(count は全件数のまま)
  local -i limit=${ZRUSH_REPORT_LIMIT:-0}
  local r
  local -i n=0
  for r in "${(@)recs}"; do
    print -r -- "ZRUSH-ITEM ${(qqqq)r}"
    (( ++n ))
    if (( limit > 0 && n >= limit )); then
      print -r -- "ZRUSH-TRUNC shown=$n of=$#recs"
      break
    fi
  done
  print -r -- "ZRUSH-END"
  _zrush_buf=
}

# ------------------------------------------------------------------ 実挿入比較(基準値の取得)
# 素の compsys に第 1 候補を実挿入させ、結果の BUFFER を印字する(ZAS 方式)。
# 検証ケースは単一候補になるよう設計し、「第 1 候補」の曖昧さを避けること。
_zrush_real_postfunc() {
  compstate[insert]=1
  unset 'compstate[list]'
}

_zrush_real_insert() {
  local -a +h comppostfuncs
  comppostfuncs=( _zrush_real_postfunc )
  builtin zle -- ${(k)widgets[(r)completion:.complete-word:_main_complete]}
  zle -I
  print -r -- "ZRUSH-REAL ${(qqqq)BUFFER}"
  print -r -- "ZRUSH-REAL-END"
}

# ------------------------------------------------------------------ fd タイマー起点(実運用形態)
_zrush_request_deferred() {
  emulate -L zsh
  [[ -n $ZRUSH_INTERNAL ]] && return 0
  local tfd
  exec {tfd}< <( exec sleep 0.05 )
  zle -F -w $tfd _zrush-timer-fire
  _zlog "deferred: timer armed on fd $tfd"
  return 0
}

_zrush_timer_fire() {
  emulate -L zsh
  local -i fd=$1
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  _zlog "timer: fired; starting request from zle -F -w handler context"
  _zrush_request
}

# ------------------------------------------------------------------ 登録
zle -N zrush-test _zrush_request
zle -N zrush-test-deferred _zrush_request_deferred
zle -N zrush-real-insert _zrush_real_insert
zle -N _zrush-timer-fire _zrush_timer_fire
zle -N _zrush-on-data _zrush_on_data
zle -N _zrush-capture-n _zrush_capture_entry
zle -C _zrush-capture-c list-choices _zrush_capture_complete
bindkey '^X^Z' zrush-test
bindkey '^X^Y' zrush-test-deferred
bindkey '^X^R' zrush-real-insert
