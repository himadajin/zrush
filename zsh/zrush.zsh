# zrush.zsh — zle 統合本体(M3: リアルタイム候補一覧まで)
#
# 前提・導入(plan.md「導入形態」):
#   - compinit 実行済みであること(未初期化なら警告のみ表示し、収集は空になり得る)
#   - source 順: zsh-abbr より後、zsh-syntax-highlighting より前
#   - バイナリは $ZRUSH_BIN 優先、なければ <this>/../target/release/zrush
#
# 構造(plan.md「zle 統合の設計上の要点」/ spikes/m1-zpty の実証結果の移植):
#   zle-line-pre-redraw で BUFFER/CURSOR 差分検知
#     → fd タイマー(zselect)でデバウンス
#     → zpty fork(現在シェルの fork)内で compsys を駆動し、compadd フックが
#       候補レコードを「継承 pipe fd」へ NUL 区切りバッチ搬出(終端 = EOF)
#     → zle -F -w ハンドラが部分読み・再組み立て
#     → `zrush match` にスナップショット引数で渡し、返却 index 順に zle -M 描画
#   キャンセル = worker 自己申告 pid のプロセスグループへ SIGINT → zpty -d
#   (zpty -d の HUP は外部コマンド待ち中の fork に遅延される。zpty -t は使用禁止。
#    いずれも M1-5 で実測済み)
#
# デバッグ: ZRUSH_LOG=<file> を設定するとタイムスタンプ付きトレースを追記する(既定 no-op)。

# 多重 source ガード(再 source は許可: 状態を初期化し直す)
typeset -g _zrush_source_dir=${${(%):-%N}:A:h}

# ---------------------------------------------------------------- グローバル状態
typeset -g  ZRUSH_BIN=${ZRUSH_BIN:-$_zrush_source_dir/../target/release/zrush}
typeset -gi _zrush_enabled=0
typeset -gi _ZRUSH_EXPECTED_PROTO=1
typeset -g  _zrush_cfg_path= _zrush_cfg_mtime= _zrush_cfg_warn_shown=
typeset -gi _zrush_match_warned=0 _zrush_proto_warned=0

# 収集リクエスト状態
typeset -g  _zrush_query= _zrush_fuzzy= _zrush_keep= _zrush_buf= _zrush_pty= _zrush_worker_pid=
typeset -gi _zrush_rfd=-1 _zrush_wfd=-1 _zrush_gen=0 _zrush_timer_fd=-1
typeset -g  _zrush_pending_buffer=
typeset -g  _zrush_last_buffer=
typeset -gi _zrush_last_cursor=-1

# 受信結果(M4 でも使う: レコード原本と挿入形を保持する)
typeset -ga _zrush_recs=() _zrush_words=() _zrush_match=() _zrush_disp=()
typeset -g  _zrush_common_prefix=
typeset -gi _zrush_listing=0

# ---------------------------------------------------------------- ユーティリティ
_zlog() { [[ -n $ZRUSH_LOG ]] && print -r -- "[$$ ${EPOCHREALTIME:-0}] $1" >>| $ZRUSH_LOG; return 0 }

_zrush_warn() { print -ru2 -- "zrush: $1" }

# ---------------------------------------------------------------- 広げ規則(M1-4 実証)
# 現在語(カーソルまで)のうち、最後の / または = より後ろを空にして収集する。
# 区切りがなく - で始まる語は先頭のダッシュ列を保持。それ以外は語全体を空にする。
# 制限: 現在語の特定は「最後の空白より後ろ」の素朴規則(クォート内空白は未対応)。
_zrush_widen() {  # $1=カーソルまでのバッファ
                  # → REPLY_WIDENED / REPLY_QUERY / REPLY_KEEP / REPLY_WORD
  emulate -L zsh
  setopt extendedglob
  local buf=$1
  local word=${buf##*[[:space:]]}
  local pre=${buf[1,$#buf-$#word]}
  local keep= query=
  if [[ $word == *[/=]* ]]; then
    query=${word##*[/=]}
    keep=${word[1,$#word-$#query]}
  elif [[ $word == -* ]]; then
    keep=${(M)word##-##}
    query=${word[$#keep+1,-1]}
  else
    query=$word
  fi
  typeset -g REPLY_WIDENED=$pre$keep REPLY_QUERY=$query REPLY_KEEP=$keep REPLY_WORD=$word
}

# ---------------------------------------------------------------- 設定
_zrush_config_path() {
  typeset -g _zrush_cfg_path=${XDG_CONFIG_HOME:-$HOME/.config}/zrush/config.toml
}

_zrush_config_mtime() {  # → REPLY(mtime 数値 or 'absent')
  emulate -L zsh
  typeset -g REPLY=absent
  local -a st
  zstat -A st +mtime $_zrush_cfg_path 2>/dev/null && REPLY=$st[1]
  return 0
}

# `zrush config` を実行して source する。$1=initial|reload
# 戻り値 0 = 成功(グローバル ZRUSH_CFG_* / ZRUSH_PROTOCOL_VERSION が更新される)
_zrush_load_config() {
  emulate -L zsh
  local out
  out=$("$ZRUSH_BIN" config 2>/dev/null) || return 1
  # 出力は typeset への静的代入のみ(cli-protocol.md)。統制文脈で評価する。
  eval "$out" 2>/dev/null || return 1
  [[ -n $ZRUSH_PROTOCOL_VERSION ]] || return 1
  # 版照合(不一致は警告 1 回・継続)
  if [[ $ZRUSH_PROTOCOL_VERSION != $_ZRUSH_EXPECTED_PROTO ]] && (( ! _zrush_proto_warned )); then
    _zrush_warn "protocol version mismatch: zsh expects $_ZRUSH_EXPECTED_PROTO, binary reports $ZRUSH_PROTOCOL_VERSION (rebuild zrush?)"
    _zrush_proto_warned=1
  fi
  _zrush_config_mtime
  _zrush_cfg_mtime=$REPLY
  _zrush_show_cfg_warnings
  return 0
}

# 警告表示: config 再読み込み時に 1 行ずつ stderr へ。
# 同一内容は config が変わるまで再表示しない(読み込みは mtime 変化時のみなので実質毎回表示)。
_zrush_show_cfg_warnings() {
  emulate -L zsh
  (( $#ZRUSH_CFG_WARNINGS )) || { _zrush_cfg_warn_shown=; return 0 }
  local joined=${(pj:\n:)ZRUSH_CFG_WARNINGS}
  [[ $joined == $_zrush_cfg_warn_shown ]] && return 0
  local w
  for w in "${(@)ZRUSH_CFG_WARNINGS}"; do
    print -ru2 -- "zrush: $w"
  done
  _zrush_cfg_warn_shown=$joined
  return 0
}

# プロンプト表示ごと: config.toml の mtime を確認し、変化していれば再読み込み
_zrush_precmd() {
  emulate -L zsh
  (( _zrush_enabled )) || return 0
  _zrush_config_mtime
  if [[ $REPLY != $_zrush_cfg_mtime ]]; then
    _zlog "precmd: config mtime changed ($_zrush_cfg_mtime -> $REPLY); reloading"
    _zrush_load_config reload || _zlog "precmd: config reload failed; keeping previous values"
    # 失敗時は前回の設定値を維持して継続(cli-protocol.md)
  fi
  return 0
}

# ---------------------------------------------------------------- fork 内: 捕獲(スパイク v1 移植)
# compadd フック。fork 内でのみ functions[compadd] に差し込まれる。
# 候補語+メタデータを <tag>\1<value> を \2 結合したレコードにし、NUL 終端で
# 継承 pipe fd へ「compadd 呼び出し単位でバッチ」書き込みする(M1-4: レコード毎だと
# 読み側が 1 レコード 1 read になり大量候補で劣化することを実測済み)。
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
    builtin compadd "$@"
    return
  fi
  local -a __hits __dscr
  (( $#dscrs == 1 )) && __dscr=( "${(@P)${(v)dscrs}}" )
  builtin compadd -A __hits -D __dscr "$@"
  local -i ret=$?
  (( $#__hits == 0 )) && return ret

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
      # 実ディレクトリ(挿入時の '/' 付与判定に使う)。非クォート二重 ${} でないと
      # ~ が展開されない(M1-3 実測。FTB :103 の NOTE と同じ)。
      _rec+=( "rd"$'\1'${${(Qe)~${:-$IPREFIX${(v)hpre}}}} )
    fi
    (( $#expl >= 2 ))      && _rec+=( "X"$'\1'"$expl[2]" )
    (( $#grpJ ))           && _rec+=( "J"$'\1'"${(v)grpJ}" )
    (( $#grpV ))           && _rec+=( "V"$'\1'"${(v)grpV}" )
    (( $#_mesg ))          && _rec+=( "x"$'\1'"${(v)_mesg}" )
    _out+="${(pj:\2:)_rec}"$'\0'
  done
  print -rn -u $_zrush_wfd -- "$_out" 2>/dev/null
  # compsys の内部状態整合のため素の compadd も実行する(fzf-tab と同じ)
  builtin compadd "$@"
}

# list-choices 型補完ウィジェット(挿入を伴わず複数候補向き)
_zrush_capture_complete() {
  _zlog "fork: completion widget invoked (context=${curcontext:-none})"
  unset 'compstate[vared]'
  unfunction compadd 2>/dev/null   # 他プラグインの compadd ラッパー除去
  functions[compadd]=$functions[_zrush_compadd]
  {
    _main_complete
    _zlog "fork: _main_complete st=$? nmatches=${compstate[nmatches]}"
  } always {
    unfunction compadd 2>/dev/null
  }
  # 挿入・一覧・メニューの副作用を殺す(pty への大量出力やメニュー突入の防止)
  compstate[insert]=
  compstate[list]=
  unset MENUSELECT MENUMODE
}

# 通常ウィジェット。広げクエリをバッファへ注入して補完ウィジェットを呼ぶ。
# always で write 側 fd を閉じて exit する = 親への完了通知(EOF)。
# 補完ウィジェットが関数を呼ばず戻るケースでも EOF は必ず出る。
_zrush_capture_entry() {
  {
    LBUFFER=$_zrush_query
    RBUFFER=
    builtin zle _zrush-capture-comp -w 2>>| ${ZRUSH_LOG:-/dev/null}
  } always {
    exec {_zrush_wfd}>&-
    builtin exit 0
  }
}

# fork 本体(zpty が現在シェルを fork してこれを実行する)
_zrush_worker() {
  # 再帰防止ガード
  typeset -gx ZRUSH_INTERNAL=1
  # fork 衛生: 継承フックの無効化・履歴書き込み禁止
  local -a hooks=( chpwd periodic precmd preexec zshaddhistory zshexit )
  builtin unset ${^hooks}_functions 2>/dev/null
  $hooks[@] () { : }
  _zrush_noop() { : }
  local h
  for h in zle-isearch-exit zle-isearch-update zle-line-pre-redraw \
           zle-line-init zle-line-finish zle-history-line-set zle-keymap-select; do
    (( $+widgets[$h] )) && builtin zle -N $h _zrush_noop
  done
  builtin unset HISTFILE 2>/dev/null
  SAVEHIST=0
  _zlog "fork: start wfd=$_zrush_wfd"
  # 継承した read 側 copy は不要
  (( _zrush_rfd >= 0 )) && exec {_zrush_rfd}<&-
  # 先頭レコードで実 pid を親へ申告(キャンセル時の pgroup SIGINT 用)
  print -rn -u $_zrush_wfd -- "pid"$'\1'"$sysparams[pid]"$'\0' 2>/dev/null
  # fork は zle 活性を継承しているため、ウィジェットを直接呼べる(M1 実証)
  builtin zle _zrush-capture-entry 2>>| ${ZRUSH_LOG:-/dev/null}
  builtin exit 0
}

# ---------------------------------------------------------------- 収集の開始・キャンセル
_zrush_cancel_collection() {
  emulate -L zsh
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
    # worker 実 pid のプロセスグループへ SIGINT(外部コマンド待ちごと即中断)。
    # pid 未着(fork 直後)のときは zpty -d の HUP + pipe クローズ後の EPIPE が保険。
    if [[ $_zrush_worker_pid == <-> ]] && (( _zrush_worker_pid > 1 )); then
      _zlog "cancel: SIGINT to worker pgid $_zrush_worker_pid"
      kill -INT -$_zrush_worker_pid 2>/dev/null || kill -INT $_zrush_worker_pid 2>/dev/null
    fi
    zpty -d $_zrush_pty 2>/dev/null
    _zrush_pty=
  fi
  _zrush_worker_pid=
  _zrush_buf=
}

_zrush_disarm_timer() {
  emulate -L zsh
  if (( _zrush_timer_fd >= 0 )); then
    zle -F $_zrush_timer_fd 2>/dev/null
    exec {_zrush_timer_fd}<&-
    _zrush_timer_fd=-1
  fi
}

_zrush_clear_display() {  # zle ウィジェット文脈からのみ呼ぶこと
  (( _zrush_listing )) || return 0
  zle -M ""
  _zrush_listing=0
  _zrush_recs=() _zrush_words=() _zrush_match=() _zrush_disp=()
  _zrush_common_prefix=
}

# 収集リクエスト開始(ウィジェット/ハンドラ文脈)
_zrush_start_request() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify
  [[ -n $ZRUSH_INTERNAL ]] && return 0
  _zrush_cancel_collection

  # 広げ規則は開始時点のバッファで再計算する(デバウンス中の変化は
  # pre-redraw がタイマーを作り直すため、通常ここは最新状態)
  _zrush_widen "$LBUFFER"
  _zrush_query=$REPLY_WIDENED
  _zrush_fuzzy=${REPLY_QUERY//$'\0'/}   # --query の NUL 除去は送信側責務
  _zrush_keep=$REPLY_KEEP
  _zlog "request: widened=${(qqqq)_zrush_query} fuzzy=${(qqqq)_zrush_fuzzy}"

  # 匿名 pipe(FIFO を両端 open して即 unlink。搬出路は pipe、終端は EOF)
  local fifo=${TMPDIR:-/tmp}/zrush-$$-$RANDOM.fifo
  mkfifo $fifo 2>/dev/null || return 1
  local rw
  exec {rw}<>$fifo
  exec {_zrush_rfd}<$fifo
  exec {_zrush_wfd}>$fifo
  exec {rw}>&-
  rm -f $fifo

  _zrush_pty=zrush-w$(( ++_zrush_gen ))
  if ! zpty $_zrush_pty _zrush_worker; then
    _zlog "request: zpty create failed"
    _zrush_cancel_collection
    return 1
  fi
  # EOF 検知のため、親の write 側 copy は fork 直後に閉じる
  exec {_zrush_wfd}>&-
  _zrush_wfd=-1

  zle -F -w $_zrush_rfd _zrush-on-data
  _zlog "request: collecting on fd $_zrush_rfd (pty $_zrush_pty)"
  return 0
}

# ---------------------------------------------------------------- 受信・マッチ・描画
_zrush_on_data() {  # zle -F -w ハンドラ($1=fd)
  emulate -L zsh
  local -i fd=$1
  local chunk= st=0
  sysread -i $fd chunk; st=$?
  if (( st == 0 )); then
    _zrush_buf+=$chunk
    # 先頭の pid 申告レコードを消費
    if [[ -z $_zrush_worker_pid && $_zrush_buf == *$'\0'* ]]; then
      local first=${_zrush_buf%%$'\0'*}
      if [[ $first == pid$'\1'<-> ]]; then
        _zrush_worker_pid=${first#pid$'\1'}
        _zrush_buf=${_zrush_buf#*$'\0'}
      fi
    fi
    return 0
  fi
  # EOF(5)または読み取りエラー: このリクエストの受信を終える
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  _zrush_rfd=-1
  zpty -d $_zrush_pty 2>/dev/null
  _zrush_pty=
  _zrush_worker_pid=
  if (( st == 5 )); then
    _zrush_finalize
  else
    _zlog "on-data: read error st=$st; dropping request"
    _zrush_buf=
  fi
  return 0
}

_zrush_finalize() {
  emulate -L zsh
  setopt localoptions no_monitor no_notify
  local payload=$_zrush_buf
  _zrush_buf=
  _zrush_recs=() _zrush_words=() _zrush_match=() _zrush_disp=() _zrush_ranked=()
  _zrush_common_prefix=

  if [[ -n $payload ]]; then
    if [[ $payload == *$'\0' ]]; then
      _zrush_recs=( "${(@0)${payload%$'\0'}}" )
    else
      _zlog "finalize: unterminated payload (${#payload} bytes); dropping"
      _zrush_recs=()
    fi
  fi
  _zlog "finalize: ${#_zrush_recs} records"

  # レコード → 挿入形(w)/表示(d)。match-text は (Q) 復元形(cli-protocol.md)。
  # 大量候補(数万件)では zsh のレコード毎ループが数秒級のブロックになるため、
  # d フィールドが無い典型ケースは配列一括演算の高速経路で処理する
  # (30k 件で ループ ~1.6s → ~35ms を実測)。
  local -i i n=0
  local stdin_payload=
  local -a words=() disps=() mts=()
  local NUL=$'\0'
  if [[ ${(pj::)_zrush_recs} != *$'\2'd$'\1'* ]]; then
    words=( "${(@)${(@)_zrush_recs#w$'\1'}%%$'\2'*}" )
    mts=( "${(@Q)words}" )
    if [[ -z ${(M)words:#(*$'\1'*|)} && -z ${(M)mts:#*$'\0'*} ]]; then
      # 高速経路: 不正レコード・NUL 入り候補なし
      n=$#words
      _zrush_words=( "${(@)words}" )
      _zrush_match=( "${(@)mts}" )
      _zrush_disp=( "${(@)words:/*/}" )         # 全要素空(d なし)
      if (( n > 0 )); then
        local -a _idxs=( {1..$n} )
        local -a _mts2=( "${(@)mts/%/$NUL}" )   # 各要素末尾に空 display フィールドを畳み込む
        local -a _zip=( "${(@)_idxs:^_mts2}" )
        stdin_payload=${(pj:\0:)_zip}$'\0'
      fi
    else
      n=-1   # 汎用経路へ
    fi
  else
    n=-1
  fi

  if (( n < 0 )); then
    # 汎用経路: d フィールドあり/異常レコードあり(通常は少数件)
    local r w d
    words=() disps=()
    for r in "${(@)_zrush_recs}"; do
      [[ $r == w$'\1'* ]] || continue
      w=${${r#w$'\1'}%%$'\2'*}
      [[ -n $w ]] || continue
      if [[ $r == *$'\2'd$'\1'* ]]; then
        d=${${r#*$'\2'd$'\1'}%%$'\2'*}
      else
        d=
      fi
      words+=( "$w" )
      disps+=( "$d" )
    done
    mts=( "${(@Q)words}" )
    # NUL を含む候補は送出前に除外(送信側責務)。index は除外後の自前配列基準。
    n=0
    _zrush_words=() _zrush_match=() _zrush_disp=()
    for (( i = 1; i <= $#words; ++i )); do
      [[ $mts[i] == *$'\0'* || $disps[i] == *$'\0'* ]] && continue
      _zrush_words+=( "$words[i]" )
      _zrush_match+=( "$mts[i]" )
      _zrush_disp+=( "$disps[i]" )
      (( ++n ))
      stdin_payload+="$n"$'\0'"$mts[i]"$'\0'"$disps[i]"$'\0'
    done
  fi

  if (( n == 0 )); then
    _zrush_render   # 0 件 → 一覧を消す
    return 0
  fi

  # zrush match(設定スナップショットを引数で渡す純関数。stderr は端末に流さない)
  local out
  out=$(print -rn -- "$stdin_payload" | \
        "$ZRUSH_BIN" match --query "$_zrush_fuzzy" --mode "$ZRUSH_CFG_MODE" \
                           --smart-case "$ZRUSH_CFG_SMART_CASE" \
                           --max-lines "$ZRUSH_CFG_MAX_LINES" 2>/dev/null)
  local -i rc=$?
  if (( rc != 0 )); then
    if (( ! _zrush_match_warned )); then
      _zrush_warn "zrush match failed (exit $rc); suppressing further warnings this session"
      _zrush_match_warned=1
    fi
    _zlog "finalize: zrush match exit $rc; discarding"
    _zrush_recs=() _zrush_words=() _zrush_match=() _zrush_disp=()
    _zrush_render
    return 0
  fi

  local -a fields=( "${(@0)${out%$'\0'}}" )
  _zrush_common_prefix=${fields[1]:-}
  typeset -ga _zrush_ranked=( "${(@)fields[2,-1]}" )
  _zlog "finalize: match ok, ${#_zrush_ranked} ranked, common-prefix=${(qqqq)_zrush_common_prefix}"
  _zrush_render
  return 0
}

_zrush_render() {  # zle ウィジェット文脈からのみ呼ぶこと
  emulate -L zsh
  local -a lines=()
  local -i maxl=${ZRUSH_CFG_MAX_LINES:-10}
  (( LINES > 1 && maxl > LINES - 1 )) && maxl=$(( LINES - 1 ))
  (( maxl < 1 )) && maxl=1
  local idx text
  for idx in "${(@)_zrush_ranked}"; do
    [[ $idx == <-> ]] || continue
    text=${_zrush_disp[idx]:-${_zrush_match[idx]}}
    text=${text//$'\n'/ }
    (( COLUMNS > 1 && ${#text} >= COLUMNS )) && text=${text[1,COLUMNS-1]}
    lines+=( "$text" )
    (( $#lines >= maxl )) && break
  done
  if (( $#lines == 0 )); then
    _zrush_clear_display
    return 0
  fi
  zle -M "${(pj:\n:)lines}"
  _zrush_listing=1
  _zlog "render: $#lines lines"
  return 0
}

typeset -ga _zrush_ranked=()

# ---------------------------------------------------------------- タイマー(デバウンス)
_zrush_arm_timer() {  # zle ウィジェット文脈
  emulate -L zsh
  _zrush_disarm_timer
  local -i delay=${ZRUSH_CFG_DELAY_MS:-50}
  if (( delay <= 0 )); then
    _zrush_start_request
    return 0
  fi
  local -i cs=$(( delay / 10 ))
  (( cs < 1 )) && cs=1
  _zrush_pending_buffer=$BUFFER
  local tfd
  exec {tfd}< <( zselect -t $cs; print )
  _zrush_timer_fd=$tfd
  zle -F -w $tfd _zrush-timer-fire
  return 0
}

_zrush_timer_fire() {  # zle -F -w ハンドラ($1=fd)
  emulate -L zsh
  local -i fd=$1
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  (( fd == _zrush_timer_fd )) && _zrush_timer_fd=-1
  # 発火時点でバッファが変わっていれば破棄(pre-redraw が新タイマーを張っている)
  [[ $BUFFER == "$_zrush_pending_buffer" ]] || return 0
  (( KEYS_QUEUED_COUNT || PENDING )) && return 0   # 入力圧があるときは見送る(次の変化で再アーム)
  _zrush_start_request
  return 0
}

# ---------------------------------------------------------------- zle フック
_zrush_line_pre_redraw() {
  emulate -L zsh
  (( _zrush_enabled )) || return 0
  [[ -n $ZRUSH_INTERNAL ]] && return 0
  [[ $BUFFER == "$_zrush_last_buffer" ]] && (( CURSOR == _zrush_last_cursor )) && return 0
  _zrush_last_buffer=$BUFFER
  _zrush_last_cursor=$CURSOR

  # 空バッファ(空白のみ含む)では収集も表示もしない(plan の固定挙動)
  if [[ -z ${BUFFER//[[:space:]]/} ]]; then
    _zrush_disarm_timer
    _zrush_cancel_collection
    _zrush_clear_display
    return 0
  fi

  # min-input: 現在語の長さで判定(空バッファは上で除外済み)
  _zrush_widen "$LBUFFER"
  if (( ${#REPLY_WORD} < ${ZRUSH_CFG_MIN_INPUT:-0} )); then
    _zrush_disarm_timer
    _zrush_cancel_collection
    _zrush_clear_display
    return 0
  fi

  _zrush_arm_timer
  return 0
}

_zrush_line_init() {
  emulate -L zsh
  _zrush_last_buffer=
  _zrush_last_cursor=-1
  _zrush_listing=0    # 新しい行では表示なしから始まる(zle -M は行を跨いで残らない)
  return 0
}

_zrush_line_finish() {
  emulate -L zsh
  (( _zrush_enabled )) || return 0
  _zrush_disarm_timer
  _zrush_cancel_collection
  _zrush_clear_display
  _zlog "line-finish: cleared"
  return 0
}

# ---------------------------------------------------------------- 終了時の掃除
_zrush_zshexit() {
  emulate -L zsh
  # zle 系は触らない(zle 非活性文脈)。fd と zpty だけ確実に畳む。
  (( _zrush_timer_fd >= 0 )) && { exec {_zrush_timer_fd}<&- 2>/dev/null; _zrush_timer_fd=-1 }
  if (( _zrush_rfd >= 0 )); then exec {_zrush_rfd}<&-; _zrush_rfd=-1; fi
  if (( _zrush_wfd >= 0 )); then exec {_zrush_wfd}>&-; _zrush_wfd=-1; fi
  if [[ -n $_zrush_pty ]]; then
    if [[ $_zrush_worker_pid == <-> ]] && (( _zrush_worker_pid > 1 )); then
      kill -INT -$_zrush_worker_pid 2>/dev/null || kill -INT $_zrush_worker_pid 2>/dev/null
    fi
    zpty -d $_zrush_pty 2>/dev/null
    _zrush_pty=
  fi
  return 0
}

# ---------------------------------------------------------------- 初期化
_zrush_init() {
  emulate -L zsh

  if [[ ! -x $ZRUSH_BIN ]]; then
    _zrush_warn "binary not found or not executable: $ZRUSH_BIN (set \$ZRUSH_BIN or run 'cargo build --release'); zrush disabled"
    return 1
  fi

  zmodload zsh/zpty zsh/system zsh/zutil zsh/parameter zsh/zselect zsh/datetime 2>/dev/null || {
    _zrush_warn "required zsh modules unavailable; zrush disabled"
    return 1
  }
  zmodload -F zsh/stat b:zstat 2>/dev/null || {
    _zrush_warn "zsh/stat unavailable; zrush disabled"
    return 1
  }
  autoload -Uz add-zsh-hook add-zle-hook-widget

  _zrush_config_path
  # source 時は無条件で config を 1 回実行(版照合の機会を保証。cli-protocol.md)
  if ! _zrush_load_config initial; then
    _zrush_warn "initial 'zrush config' failed; zrush disabled"
    return 1
  fi

  # compinit 検知($+functions[_main_complete] — zsh-autocomplete 委任構成も検出可能)
  if (( ! $+functions[_main_complete] )); then
    _zrush_warn "compsys not initialized (run compinit before sourcing zrush.zsh); completions will be empty"
  fi

  # ウィジェット登録(_zrush-capture-* は fork 内でのみ実際に呼ばれる)
  zle -N _zrush-on-data _zrush_on_data
  zle -N _zrush-timer-fire _zrush_timer_fire
  zle -N _zrush-capture-entry _zrush_capture_entry
  zle -C _zrush-capture-comp list-choices _zrush_capture_complete
  zle -N _zrush-line-pre-redraw _zrush_line_pre_redraw
  zle -N _zrush-line-init _zrush_line_init
  zle -N _zrush-line-finish _zrush_line_finish

  # フック登録(add-zle-hook-widget: zsh-syntax-highlighting との公式共存経路)
  add-zle-hook-widget line-pre-redraw _zrush-line-pre-redraw
  add-zle-hook-widget line-init _zrush-line-init
  add-zle-hook-widget line-finish _zrush-line-finish
  add-zsh-hook precmd _zrush_precmd
  add-zsh-hook zshexit _zrush_zshexit   # 既存の zshexit を壊さない(フック配列経由)

  _zrush_enabled=1
  _zlog "init: enabled (bin=$ZRUSH_BIN proto=$ZRUSH_PROTOCOL_VERSION)"
  return 0
}

_zrush_init
