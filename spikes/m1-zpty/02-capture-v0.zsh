# Step B: 捕獲 v0 — zpty fork で compsys を走らせ、候補語を pipe で吸い出す
#
# 対話ホストシェル(compinit 済み)で source して使う。
#   - ウィジェット zrush-test(^X^Z)が現在の $BUFFER をクエリとして非同期収集を開始
#   - zpty で現在シェルを fork し、fork 内で list-choices 型補完ウィジェットを駆動
#   - compadd フックが生き残った候補語を NUL 区切りで pipe(継承 fd)へ書く
#   - 終端は pipe の EOF(fork の exit)。pty にはデータを流さない
#   - ホストは zle -F -w ハンドラで部分読み・再組み立てし、結果を印字する
#
# 駆動方式は $ZRUSH_VARIANT で切替:
#   direct (既定) … fork 内で zle <widget> を直接呼ぶ(ZAS sync 方式)
#   vared          … fork 内で vared を開き、親が ^@ フェイクキーを送る(ZAC 方式)

zmodload zsh/zpty    || return 1
zmodload zsh/system  || return 1
zmodload zsh/zutil   || return 1
zmodload zsh/parameter || return 1

typeset -g  ZRUSH_VARIANT=${ZRUSH_VARIANT:-direct}
typeset -g  _zrush_query= _zrush_buf= _zrush_pty=
typeset -gi _zrush_rfd=-1 _zrush_wfd=-1 _zrush_gen=0
typeset -gF _zrush_t0=0

# デバッグログ($ZRUSH_LOG が設定されていればファイル追記。fork 内でも使える)
_zlog() { [[ -n $ZRUSH_LOG ]] && print -r -- "[$$] $1" >>| $ZRUSH_LOG; return 0 }

# ------------------------------------------------------------------ compadd フック
# fork 内でのみ functions[compadd] に差し込まれる(FTB -ftb-compadd の縮小版)。
# v0 は候補語のみ捕獲。-O/-A/-D は即委譲。マッチ判定は builtin compadd -A/-D に委譲。
_zrush_compadd() {
  builtin setopt localoptions extendedglob norcexpandparam noshglob
  local -A apre hpre dscrs _oad _mesg
  local -a isfile _opts __ expl
  zparseopts -a _opts P:=apre p:=hpre d:=dscrs X+:=expl O:=_oad A:=_oad D:=_oad f=isfile \
             i: S: s: I: x:=_mesg r: R: W: F: M+: E: q e Q n U C \
             J:=__ V:=__ a=__ l=__ k=__ o::=__ 1=__ 2=__
  if (( $#_oad != 0 )); then
    builtin compadd "$@"
    return
  fi
  local -a __hits __dscr
  (( $#dscrs == 1 )) && __dscr=( "${(@P)${(v)dscrs}}" )
  builtin compadd -A __hits -D __dscr "$@"
  local -i ret=$?
  (( $#__hits == 0 )) && return ret
  # 生き残った候補語を NUL 区切りで搬出
  _zlog "compadd: exporting $#__hits hits"
  print -rn -u $_zrush_wfd -- "${(pj:\0:)__hits}"$'\0'
  # compsys の内部状態(compstate 等)の整合のため素の compadd も実行(FTB :127)
  builtin compadd "$@"
}

# ------------------------------------------------------------------ fork 内: 捕獲ウィジェット
# list-choices 型補完ウィジェット。挿入を伴わないため複数候補向き(ZAC 方式)。
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
  # 挿入・一覧表示・メニューの副作用を殺す(pty への大量出力やハング防止)
  compstate[insert]=
  compstate[list]=
  unset MENUSELECT MENUMODE
}

# 通常ウィジェット。バッファへ広げクエリを注入してから補完ウィジェットを呼ぶ。
# always で write 側 fd を閉じて exit する — これが親への「完了」通知(EOF)。
# 補完ウィジェットが関数を呼ばず戻るケース(ZAC :302-305)でも EOF は必ず出る。
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
  # 再帰防止ガード
  typeset -gx ZRUSH_INTERNAL=1
  _zlog "worker: start variant=$1 wfd=$_zrush_wfd"
  # fork 衛生: 親から継承したフックの無効化(ダイジェスト §1.3 / 落とし穴 §6)
  local -a hooks=( chpwd periodic precmd preexec zshaddhistory zshexit )
  builtin unset ${^hooks}_functions 2>/dev/null
  $hooks[@] () { : }
  _zrush_noop() { : }
  local h
  for h in zle-isearch-exit zle-isearch-update zle-line-pre-redraw \
           zle-line-init zle-line-finish zle-history-line-set zle-keymap-select; do
    (( $+widgets[$h] )) && builtin zle -N $h _zrush_noop
  done
  # 暴走時の自殺タイマー(検証用の保険)
  TMOUT=10
  # 継承した read 側 copy は不要(EOF 検知にも無関係だが衛生上閉じる)
  (( _zrush_rfd >= 0 )) && exec {_zrush_rfd}<&-

  if [[ $1 == vared ]]; then
    # ZAC 方式: vared で zle セッションを開き、親からの ^@ でウィジェット起動
    builtin bindkey $'\C-@' _zrush-capture-n
    builtin bindkey $'\r' undefined-key   # 事故防止(ZCC :28-30)
    builtin bindkey $'\n' undefined-key
    local __tmp__=
    builtin vared __tmp__ 2>>| ${ZRUSH_LOG:-/dev/null}
    _zlog "worker: vared returned st=$?"
    builtin exit 0            # vared が ^@ を処理できなかった場合の保険
  else
    # ZAS sync 方式: fork した時点の zle 活性を利用してウィジェットを直接呼ぶ
    builtin zle _zrush-capture-n 2>>| ${ZRUSH_LOG:-/dev/null}
    _zlog "worker: direct zle call returned st=$?"
    builtin exit 0            # ウィジェットが呼べなかった場合の保険(EOF は exit で出る)
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

zshexit() { _zrush_cleanup }   # spike 用の簡易掃除

# 収集リクエスト開始(zle ウィジェット)
_zrush_request() {
  emulate -L zsh
  [[ -n $ZRUSH_INTERNAL ]] && return 0   # 再帰防止
  _zrush_cleanup
  _zrush_query=$BUFFER    # v0: 広げ規則は適用せず、バッファそのままをクエリにする
  _zrush_t0=$EPOCHREALTIME
  _zlog "request: query=${(qqqq)_zrush_query} variant=$ZRUSH_VARIANT"

  # 匿名 pipe(FIFO を両端 open して unlink)
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
  # EOF 検知のため、親の write 側 copy は fork 直後に閉じる
  exec {_zrush_wfd}>&-
  _zrush_wfd=-1

  [[ $ZRUSH_VARIANT == vared ]] && zpty -wn $_zrush_pty $'\C-@'

  zle -F -w $_zrush_rfd _zrush-on-data
  _zlog "request: handler registered on fd $_zrush_rfd"
  return 0
}

# pipe の受信ハンドラ(zle -F -w: ウィジェットとして実行される)
_zrush_on_data() {
  emulate -L zsh
  local -i fd=$1
  local chunk= st=0
  sysread -i $fd chunk; st=$?
  _zlog "on-data: fd=$fd st=$st len=$#chunk err=${2:-}"
  if (( st == 0 )); then
    _zrush_buf+=$chunk
    return 0
  fi
  # EOF(5) または読み取りエラー: 終端処理
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

# 結果表示(検証ドライバが読み取るためのテキストプロトコル)
# 各候補は ${(qqqq)} で 1 行にエンコード(改行入りファイル名も 1 行で表現される)
_zrush_report() {
  local -F elapsed=$(( EPOCHREALTIME - _zrush_t0 ))
  local -a words=()
  local bad=
  if [[ -n $_zrush_buf ]]; then
    if [[ $_zrush_buf == *$'\0' ]]; then
      words=( "${(@0)${_zrush_buf%$'\0'}}" )
    else
      bad=$_zrush_buf
    fi
  fi
  zle -I   # 表示を無効化してからの print で行を壊さない
  [[ -n $bad ]] && print -r -- "ZRUSH-ERROR unterminated-payload ${(qqqq)bad}"
  print -r -- "ZRUSH-RESULT count=$#words elapsed-ms=$(( elapsed * 1000 ))"
  local w
  for w in "${(@)words}"; do
    print -r -- "ZRUSH-ITEM ${(qqqq)w}"
  done
  print -r -- "ZRUSH-END"
  _zrush_buf=
}

zmodload zsh/datetime   # EPOCHREALTIME

# ------------------------------------------------------------------ fd タイマー起点(実運用形態の検証)
# 実際の zrush はキー入力パスではなく、デバウンス fd タイマーの zle -F -w ハンドラから
# 収集を開始する(plan.md M3)。その文脈からの zpty fork でも direct 駆動が成立するかを
# 検証するための第二の入口。^X^Y → 50ms タイマー → ハンドラ内で _zrush_request。
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
  _zrush_request   # この関数内の zpty fork が -Fw ハンドラ文脈から起こる
}

# ウィジェット登録(_zrush-capture-* は fork 内でのみ実際に呼ばれる)
zle -N zrush-test _zrush_request
zle -N zrush-test-deferred _zrush_request_deferred
zle -N _zrush-timer-fire _zrush_timer_fire
zle -N _zrush-on-data _zrush_on_data      # zle -F -w のハンドラはウィジェットとして必要
zle -N _zrush-capture-n _zrush_capture_entry
zle -C _zrush-capture-c list-choices _zrush_capture_complete
bindkey '^X^Z' zrush-test
bindkey '^X^Y' zrush-test-deferred
