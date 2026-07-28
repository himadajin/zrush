#!/bin/zsh -f
# 遅延計測ドライバ(notes-dogfooding 2026-07-28「一覧なし→初回表示までの間」の切り分け)
#
# 使い方: zsh -f tests/zsh/driver-latency.zsh <playground-dir>
#   前提: cargo build --release 済み。TERM は実端末相当(xterm-256color)を使う
#   (vt100 だと zsh-autocomplete が初期化をスキップする — M1 計測の知見)。
#
# ホスト:
#   min-zrush     zsh -d -i + minimal.zshrc(隔離)
#   min-zrush-d0  同上 + delay-ms = 0(デバウンス寄与の分離)
#   min-zac       zsh -d -i + zsh-autocomplete(min-delay 0.05 = zrush 旧既定 50ms と同条件)
#   real-zrush    zsh -i + 実 ~/.zshrc(実環境。履歴ガードレール付き)
#
# 計測:
#   first-paint: キー列送信 → 期待文字列が pty に現れるまでの実時間
#                (SGR を剥がして照合。分解能は zselect の ~10ms)
#   breakdown  : ZRUSH_LOG の区間分解
#                arm(最終打鍵)→ request → fork → compsys → records → match → render
#
# 実環境ホストのガードレール(M1 事故の再発防止):
#   - 送信コマンドは必ず先頭スペース付き(hist_ignore_space)
#   - 起動直後に unset HISTFILE / SAVEHIST=0
#   - 実行前後で ~/.zsh_history のハッシュ不変を検証
#   - ユーザーファイルへの書き込みは一切しない
emulate -L zsh
setopt extended_glob
zmodload zsh/zpty    || { print -u2 FATAL: zpty; exit 1 }
zmodload zsh/zselect || { print -u2 FATAL: zselect; exit 1 }
zmodload zsh/system  || { print -u2 FATAL: system; exit 1 }
zmodload zsh/datetime

typeset -F SECONDS
typeset -g HERE=${${(%):-%N}:A:h}
typeset -g REPO=${HERE:h:h}
typeset -g PLAYGROUND=${1:?usage: driver-latency.zsh <playground-dir>}
[[ -d $PLAYGROUND/docs ]] || { print -u2 "FATAL: playground 不備: $PLAYGROUND"; exit 1 }
[[ -x $REPO/target/release/zrush ]] || { print -u2 "FATAL: zrush バイナリがない"; exit 1 }
typeset -g ZAC_SRC=~/.zsh/zsh-autocomplete/zsh-autocomplete.plugin.zsh

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-lat.XXXXXX)
export TERM=xterm-256color
export LC_ALL=en_US.UTF-8

typeset -g HOST= HOSTLOG= CURXDG=
typeset -gi HOSTFD=-1 SYNCN=0
out() { print -r -u2 -- "$@" }

send_line() { zpty -w  $HOST " $1" }   # 先頭スペース必須(実環境ホスト対策)
send_keys() { zpty -wn $HOST $1 }

drain() {
  local -F dl=$(( SECONDS + ${1:-0.2} ))
  local chunk
  while (( SECONDS < dl )); do
    zselect -t 10 -r $HOSTFD 2>/dev/null && zpty -r $HOST chunk 2>/dev/null
  done
}

expect() {  # $1=glob $2=timeout(s)
  local pat=$1 buf= chunk
  local -F dl=$(( SECONDS + ${2:-15} ))
  while (( SECONDS < dl )); do
    if zselect -t 20 -r $HOSTFD 2>/dev/null; then
      zpty -r $HOST chunk 2>/dev/null || return 2
      buf+=$chunk
      [[ $buf == ${~pat} ]] && return 0
    fi
  done
  return 1
}

sync_host() {
  local m=S$(( ++SYNCN ))
  send_line "print -r -- MARK-'$m'"
  expect "*MARK-$m*" ${1:-30} || return 1
  drain 0.3
  return 0
}

run_cmd() { send_line $1; sync_host ${2:-30} }

clear_line() { send_keys $'\C-u'; drain 0.6 }

# ---------------------------------------------------------------- first-paint
# キー送信 → SGR 除去後の pty ストリームに期待文字列が現れるまでの ms
paint_once() {  # $1=keys $2=固定文字列 $3=timeout → REPLY=ms(NA=不達)
  typeset -g REPLY=NA
  local pat=$2 buf= chunk
  local -F t0=$EPOCHREALTIME
  local -F dl=$(( SECONDS + ${3:-20} ))
  send_keys $1
  while (( SECONDS < dl )); do
    if zselect -t 1 -r $HOSTFD 2>/dev/null; then
      if zpty -r $HOST chunk 2>/dev/null; then
        buf+=$chunk
        if [[ ${buf//$'\e['[0-9;]#m/} == *$pat* ]]; then
          REPLY=$(( (EPOCHREALTIME - t0) * 1000 ))
          clear_line
          return 0
        fi
      fi
    fi
  done
  clear_line
  return 1
}

median() {
  local -a s=( ${(on)@} )
  typeset -g REPLY=${s[$(( ($#s + 1) / 2 ))]:-NA}
}

fmt() { [[ $1 == NA ]] && print -rn NA || printf '%.0f' $1 }

paint_case() {  # $1=host-label $2=case-label $3=keys $4=pattern [$5=trials]
  local -i trials=${5:-4}
  local -a ms=()
  local -i i
  for (( i = 1; i <= trials; ++i )); do
    if paint_once $3 $4 20; then
      ms+=( $REPLY )
    else
      out "WARN: [$1/$2] 試行 $i 不達"
    fi
    drain 0.6
  done
  median $ms
  out "PAINT | ${(r:12:)1} | ${(r:18:)2} | med=$(fmt $REPLY)ms | trials=[${(j:, :)${(@)ms/(#m)*/$(fmt $MATCH)}}]"
  return 0
}

# ---------------------------------------------------------------- breakdown
# ZRUSH_LOG の末尾チェーンから区間 ms を出す(直近 render 起点で遡る)
ts_of() { typeset -g REPLY=${${${(z)1}[2]}%\]} }

breakdown_last() {  # $1=logfile $2=先頭スキップ行数 → 表 1 行
  local -a L=( ${(f)"$(<$1)"} )
  L=( "${(@)L[$(( $2 + 1 )),-1]}" )
  local -i i ir=0
  for (( i = $#L; i >= 1; --i )); do
    [[ $L[i] == *" render: "* ]] && { ir=i; break }
  done
  (( ir )) || { out "WARN: breakdown: render 行が見つからない"; return 1 }
  local -F t_render t_match t_rec t_comp t_fork t_req t_arm
  t_render=0; t_match=0; t_rec=0; t_comp=0; t_fork=0; t_req=0; t_arm=0
  ts_of $L[ir]; t_render=$REPLY
  for (( i = ir - 1; i >= 1; --i )); do
    case $L[i] in
      *" finalize: match ok"*)       (( t_match == 0 )) && { ts_of $L[i]; t_match=$REPLY } ;;
      *" finalize: "*" records"*)    (( t_rec == 0 ))   && { ts_of $L[i]; t_rec=$REPLY } ;;
      *" fork: _main_complete "*)    (( t_comp == 0 ))  && { ts_of $L[i]; t_comp=$REPLY } ;;
      *" fork: start "*)             (( t_fork == 0 ))  && { ts_of $L[i]; t_fork=$REPLY } ;;
      *" request: widened"*)         (( t_req == 0 ))   && { ts_of $L[i]; t_req=$REPLY } ;;
      *" MEAS-arm"*)                 (( t_req != 0 )) && { ts_of $L[i]; t_arm=$REPLY; break } ;;
    esac
  done
  (( t_arm && t_req && t_fork && t_comp && t_rec && t_match )) || { out "WARN: breakdown: チェーン不完全"; return 1 }
  printf 'BREAK | debounce=%4.0f | spawn=%4.0f | compsys=%5.0f | transport=%4.0f | match=%4.0f | render=%4.0f | total(arm→render)=%5.0f ms\n' \
    $(( (t_req - t_arm) * 1000 )) \
    $(( (t_fork - t_req) * 1000 )) \
    $(( (t_comp - t_fork) * 1000 )) \
    $(( (t_rec - t_comp) * 1000 )) \
    $(( (t_match - t_rec) * 1000 )) \
    $(( (t_render - t_match) * 1000 )) \
    $(( (t_render - t_arm) * 1000 )) >&2
  return 0
}

paint_break_case() {  # $1=host-label $2=case-label $3=keys $4=pattern
  local -i skip=0
  [[ -r $HOSTLOG ]] && skip=$(wc -l < $HOSTLOG)
  paint_once $3 $4 20 || { out "WARN: [$1/$2] 不達"; return 1 }
  out "CASE  | ${(r:12:)1} | ${(r:18:)2} | first-paint=$(fmt $REPLY)ms"
  breakdown_last $HOSTLOG $skip
  drain 0.6
  return 0
}

# キャッシュヒット経路の区間分解(004): arm → request → cache hit → match → render
breakdown_hit_last() {  # $1=logfile $2=先頭スキップ行数
  local -a L=( ${(f)"$(<$1)"} )
  L=( "${(@)L[$(( $2 + 1 )),-1]}" )
  local -i i ir=0
  for (( i = $#L; i >= 1; --i )); do
    [[ $L[i] == *" render: "* ]] && { ir=i; break }
  done
  (( ir )) || { out "WARN: breakdown-hit: render 行が見つからない"; return 1 }
  local -F t_render t_match t_hit t_req t_arm
  t_render=0; t_match=0; t_hit=0; t_req=0; t_arm=0
  ts_of $L[ir]; t_render=$REPLY
  for (( i = ir - 1; i >= 1; --i )); do
    case $L[i] in
      *" finalize: match ok"*) (( t_match == 0 )) && { ts_of $L[i]; t_match=$REPLY } ;;
      *" cache: hit"*)         (( t_hit == 0 ))   && { ts_of $L[i]; t_hit=$REPLY } ;;
      *" request: widened"*)   (( t_req == 0 ))   && { ts_of $L[i]; t_req=$REPLY } ;;
      *" MEAS-arm"*)           (( t_req != 0 )) && { ts_of $L[i]; t_arm=$REPLY; break } ;;
    esac
  done
  (( t_arm && t_req && t_hit && t_match )) || \
    { out "WARN: breakdown-hit: チェーン不完全(ヒットしていない?)"; return 1 }
  printf 'BREAK | debounce=%4.0f | cache-check=%4.0f | match=%4.0f | render=%4.0f | total(arm→render)=%5.0f ms\n' \
    $(( (t_req - t_arm) * 1000 )) \
    $(( (t_hit - t_req) * 1000 )) \
    $(( (t_match - t_hit) * 1000 )) \
    $(( (t_render - t_match) * 1000 )) \
    $(( (t_render - t_arm) * 1000 )) >&2
  return 0
}

paint_break_hit_case() {  # 事前の同種ケースでキャッシュが温まっている前提
  local -i skip=0
  [[ -r $HOSTLOG ]] && skip=$(wc -l < $HOSTLOG)
  paint_once $3 $4 20 || { out "WARN: [$1/$2] 不達"; return 1 }
  out "CASE  | ${(r:12:)1} | ${(r:18:)2} | first-paint=$(fmt $REPLY)ms"
  breakdown_hit_last $HOSTLOG $skip
  drain 0.6
  return 0
}

# ---------------------------------------------------------------- ホスト
typeset -g MEAS_RC=$WORK/meas.zsh
cat > $MEAS_RC <<'EOF'
functions[_zrush_arm_timer_orig]=$functions[_zrush_arm_timer]
_zrush_arm_timer() { _zlog "MEAS-arm"; _zrush_arm_timer_orig "$@" }
print MEAS-READY
EOF

start_min_zrush() {  # $1=host-label $2=XDG dir(config 済み)
  HOST=$1 HOSTLOG=$WORK/$1.log CURXDG=$2
  export ZRUSH_REPO=$REPO ZRUSH_TEST_TMP=$WORK/t-$1 ZDOTDIR=$WORK/zdot-$1
  export XDG_CONFIG_HOME=$2 ZRUSH_LOG=$HOSTLOG
  mkdir -p $ZDOTDIR $ZRUSH_TEST_TMP $2/zrush
  print "source $REPO/tests/zsh/rc/minimal.zshrc" > $ZDOTDIR/.zshrc
  cd $PLAYGROUND || return 1
  local REPLY=
  zpty -b $HOST zsh -d -i || return 1
  HOSTFD=$REPLY
  expect '*MARK-RC-DONE*' 30 || return 1
  drain 0.5
  run_cmd "source $MEAS_RC" || return 1
  return 0
}

start_min_zac() {
  HOST=zac HOSTLOG= CURXDG=
  export ZDOTDIR=$WORK/zdot-zac
  unset ZRUSH_LOG
  mkdir -p $ZDOTDIR
  cat > $ZDOTDIR/.zshrc <<EOF
PS1='HP> '
zstyle ':autocomplete:*' min-delay 0.05
zstyle ':autocomplete:*' min-input 0
source $ZAC_SRC
print MARK-RC-DONE
EOF
  cd $PLAYGROUND || return 1
  local REPLY=
  zpty -b $HOST zsh -d -i || return 1
  HOSTFD=$REPLY
  expect '*MARK-RC-DONE*' 30 || return 1
  drain 1.0
  return 0
}

start_real_zrush() {
  HOST=real HOSTLOG=$WORK/real.log CURXDG=
  unset ZDOTDIR XDG_CONFIG_HOME ZRUSH_LOG ZRUSH_REPO ZRUSH_TEST_TMP
  cd $PLAYGROUND || return 1
  local REPLY=
  zpty -b $HOST zsh -i || return 1
  HOSTFD=$REPLY
  local m=BOOT$(( ++SYNCN ))
  send_line "print -r -- MARK-'$m'"
  expect "*MARK-$m*" 60 || return 1
  drain 0.5
  run_cmd 'unset HISTFILE; SAVEHIST=0' || return 1
  run_cmd "export ZRUSH_LOG=$HOSTLOG" || return 1
  run_cmd "source $MEAS_RC" || return 1
  run_cmd "cd $PLAYGROUND" || return 1
  return 0
}

host_rss() {
  typeset -g REPLY=NA
  local m=R$(( ++SYNCN ))
  send_line "print -r -- RSS-'$m'-\$(ps -o rss= -p \$\$ | tr -d ' ')-END"
  local buf= chunk
  local -F dl=$(( SECONDS + 15 ))
  while (( SECONDS < dl )); do
    if zselect -t 20 -r $HOSTFD 2>/dev/null; then
      zpty -r $HOST chunk 2>/dev/null && buf+=$chunk
      if [[ $buf == *RSS-$m-<->-END* ]]; then
        REPLY=${${buf##*RSS-$m-}%%-END*}
        break
      fi
    fi
  done
  drain 0.3
}

stop_host() { zpty -d $HOST 2>/dev/null; HOSTFD=-1 }

# ---------------------------------------------------------------- 実行
typeset -g HIST_HASH_BEFORE=
[[ -r ~/.zsh_history ]] && HIST_HASH_BEFORE=$(shasum ~/.zsh_history 2>/dev/null)

{
  # ============ min-zrush(既定 delay 30ms)============
  out "==== min-zrush(隔離 + 既定 delay-ms=30)===="
  if start_min_zrush min-zrush $WORK/xdg-default; then
    host_rss; out "INFO: RSS=${REPLY}KB"
    paint_break_case min-zrush "cmd 1st (whic)"   'whic'         'which'   # 初回 = キャッシュミス
    paint_break_case min-zrush "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_break_case min-zrush "git (git chec)"   'git chec'     'checkout'
    # キャッシュヒット(004): 上の cmd ケースで温まった 2 回目以降
    paint_break_hit_case min-zrush "cmd hit (whic)" 'whic'       'which'
    # 中央値用に追加試行(cmd はヒット、file/git はキャッシュ対象外)
    paint_case min-zrush "cmd hit (whic)"   'whic'         'which'
    paint_case min-zrush "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_case min-zrush "git (git chec)"   'git chec'     'checkout'
  else
    out "FATAL: min-zrush 起動失敗"
  fi
  stop_host

  # ============ min-zrush delay-ms=0 ============
  out "==== min-zrush-d0(隔離 + delay-ms=0)===="
  mkdir -p $WORK/xdg-d0/zrush
  print -r -- $'[display]\ndelay-ms = 0' > $WORK/xdg-d0/zrush/config.toml
  if start_min_zrush min-d0 $WORK/xdg-d0; then
    paint_case min-d0 "cmd (whic)"       'whic'         'which'
    paint_case min-d0 "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_case min-d0 "git (git chec)"   'git chec'     'checkout'
  else
    out "FATAL: min-d0 起動失敗"
  fi
  stop_host

  # ============ min-zac ============
  out "==== min-zac(隔離 + zsh-autocomplete, min-delay 0.05)===="
  if [[ -r $ZAC_SRC ]] && start_min_zac; then
    host_rss; out "INFO: RSS=${REPLY}KB"
    paint_case zac "cmd (whic)"       'whic'         'which'
    paint_case zac "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_case zac "git (git chec)"   'git chec'     'checkout'
  else
    out "FATAL: min-zac 起動失敗(ZAC_SRC=$ZAC_SRC)"
  fi
  stop_host

  # ============ real-zrush ============
  out "==== real-zrush(実 ~/.zshrc)===="
  if start_real_zrush; then
    host_rss; out "INFO: RSS=${REPLY}KB"
    paint_break_case real "cmd 1st (cla)"    'cla'          'clang'   # 初回 = キャッシュミス
    paint_break_case real "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_break_case real "git (git chec)"   'git chec'     'checkout'
    paint_break_hit_case real "cmd hit (cla)" 'cla'         'clang'
    paint_case real "cmd hit (cla)"    'cla'          'clang'
    paint_case real "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_case real "git (git chec)"   'git chec'     'checkout'
  else
    out "FATAL: real-zrush 起動/セットアップ失敗"
  fi
  stop_host
} always {
  zpty -d min-zrush 2>/dev/null
  zpty -d min-d0 2>/dev/null
  zpty -d zac 2>/dev/null
  zpty -d real 2>/dev/null
  # 履歴ガードレール検証
  if [[ -n $HIST_HASH_BEFORE ]]; then
    local now=$(shasum ~/.zsh_history 2>/dev/null)
    if [[ $now == $HIST_HASH_BEFORE ]]; then
      out "GUARD: ~/.zsh_history 不変を確認"
    else
      out "GUARD-FAIL: ~/.zsh_history が変化した!(要確認)"
    fi
  fi
  [[ -n $WORK && $WORK == */zrush-lat.* ]] && rm -rf $WORK
}
