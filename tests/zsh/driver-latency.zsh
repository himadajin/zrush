#!/bin/zsh -f
# Latency driver for isolating time from key input to the first candidate paint
# (protocol v2).
#
# Usage: zsh -f tests/zsh/driver-latency.zsh <playground-dir>
#   Prerequisite: cargo build --release completed. Use a real-terminal TERM
#   (xterm-256color), because zsh-autocomplete skips initialization under vt100.
#
# Hosts:
#   min-zrush     zsh -d -i + isolated minimal.zshrc
#   min-zrush-d0  same with delay-ms = 0 to isolate debounce contribution
#   min-zac       zsh -d -i + zsh-autocomplete with min-delay 0.05
#
# All hosts use a throwaway ZDOTDIR (and, where applicable, XDG_CONFIG_HOME)
# under $WORK: this driver never reads or sources the real ~/.zshrc, and
# never touches ~/.zsh_history (AGENTS.md guardrail -- a prior real-
# environment host here read the real ~/.zshrc/history and was removed).
#
# Measurements:
#   first-paint: elapsed time from key sequence to expected pty text after stripping
#                SGR, with roughly 10ms zselect resolution
#   breakdown  : ZRUSH_LOG intervals, keyed off zsh's own _zlog checkpoints
#                (cli-protocol.md / zsh/zrush.zsh -- v2 moved matching, ranking,
#                grid layout, and highlight/nav-table construction out of zsh
#                and into the single `zrush plan` external call, so what v1
#                split into a "match" (Rust) bucket + a "render" (zsh grid/
#                highlight computation) bucket is now one "plan" bucket (the
#                whole `zrush plan` round trip) followed by a thin "apply"
#                bucket (zsh copying the already-built plan into POSTDISPLAY/
#                region_highlight)):
#                arm (last key) -> request -> fork -> compsys -> transport -> plan -> apply
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
[[ -d $PLAYGROUND/docs ]] || { print -u2 "FATAL: invalid playground: $PLAYGROUND"; exit 1 }
[[ -x $REPO/target/release/zrush ]] || { print -u2 "FATAL: zrush binary not found"; exit 1 }
typeset -g ZAC_SRC=~/.zsh/zsh-autocomplete/zsh-autocomplete.plugin.zsh

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-lat.XXXXXX)
export TERM=xterm-256color
export LC_ALL=en_US.UTF-8

typeset -g HOST= HOSTLOG= CURXDG=
typeset -gi HOSTFD=-1 SYNCN=0
out() { print -r -u2 -- "$@" }

send_line() { zpty -w  $HOST " $1" }   # leading space: harmless hist_ignore_space habit, kept for parity with driver.zsh
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
# Milliseconds from sending keys until expected text appears in the SGR-stripped pty stream
paint_once() {  # $1=keys $2=fixed string $3=timeout -> REPLY=ms (NA if not reached)
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
      out "WARN: [$1/$2] attempt $i did not complete"
    fi
    drain 0.6
  done
  median $ms
  out "PAINT | ${(r:12:)1} | ${(r:18:)2} | med=$(fmt $REPLY)ms | trials=[${(j:, :)${(@)ms/(#m)*/$(fmt $MATCH)}}]"
  return 0
}

# ---------------------------------------------------------------- breakdown
# Derive interval milliseconds from the final ZRUSH_LOG chain, walking back from latest render.
ts_of() { typeset -g REPLY=${${${(z)1}[2]}%\]} }

breakdown_last() {  # $1=logfile $2=number of leading lines to skip -> one table row
  local -a L=( ${(f)"$(<$1)"} )
  L=( "${(@)L[$(( $2 + 1 )),-1]}" )
  local -i i ir=0
  for (( i = $#L; i >= 1; --i )); do
    [[ $L[i] == *" plan: applied "* ]] && { ir=i; break }
  done
  (( ir )) || { out "WARN: breakdown: 'plan: applied' line not found"; return 1 }
  local -F t_apply t_plan t_xfer t_comp t_fork t_req t_arm
  t_apply=0; t_plan=0; t_xfer=0; t_comp=0; t_fork=0; t_req=0; t_arm=0
  ts_of $L[ir]; t_apply=$REPLY
  for (( i = ir - 1; i >= 1; --i )); do
    case $L[i] in
      # v2: `zrush plan` does matching/ranking/layout/highlights/nav/insert in
      # one external call, replacing v1's separate "finalize: match ok" (Rust
      # match) + the zsh-side render/layout leg now folded into "plan: ok".
      *" plan: ok "*)                (( t_plan == 0 ))  && { ts_of $L[i]; t_plan=$REPLY } ;;
      *" finalize: "*" bytes"*)      (( t_xfer == 0 ))  && { ts_of $L[i]; t_xfer=$REPLY } ;;
      *" fork: _main_complete "*)    (( t_comp == 0 ))  && { ts_of $L[i]; t_comp=$REPLY } ;;
      *" fork: start "*)             (( t_fork == 0 ))  && { ts_of $L[i]; t_fork=$REPLY } ;;
      *" request: widened"*)         (( t_req == 0 ))   && { ts_of $L[i]; t_req=$REPLY } ;;
      *" MEAS-arm"*)                 (( t_req != 0 )) && { ts_of $L[i]; t_arm=$REPLY; break } ;;
    esac
  done
  (( t_arm && t_req && t_fork && t_comp && t_xfer && t_plan )) || { out "WARN: breakdown: incomplete chain"; return 1 }
  printf 'BREAK | debounce=%4.0f | spawn=%4.0f | compsys=%5.0f | transport=%4.0f | plan=%4.0f | apply=%4.0f | total(arm→apply)=%5.0f ms\n' \
    $(( (t_req - t_arm) * 1000 )) \
    $(( (t_fork - t_req) * 1000 )) \
    $(( (t_comp - t_fork) * 1000 )) \
    $(( (t_xfer - t_comp) * 1000 )) \
    $(( (t_plan - t_xfer) * 1000 )) \
    $(( (t_apply - t_plan) * 1000 )) \
    $(( (t_apply - t_arm) * 1000 )) >&2
  return 0
}

paint_break_case() {  # $1=host-label $2=case-label $3=keys $4=pattern
  local -i skip=0
  [[ -r $HOSTLOG ]] && skip=$(wc -l < $HOSTLOG)
  paint_once $3 $4 20 || { out "WARN: [$1/$2] did not complete"; return 1 }
  out "CASE  | ${(r:12:)1} | ${(r:18:)2} | first-paint=$(fmt $REPLY)ms"
  breakdown_last $HOSTLOG $skip
  drain 0.6
  return 0
}

# Cache-hit breakdown: arm -> request -> cache hit -> plan -> apply
breakdown_hit_last() {  # $1=logfile $2=number of leading lines to skip
  local -a L=( ${(f)"$(<$1)"} )
  L=( "${(@)L[$(( $2 + 1 )),-1]}" )
  local -i i ir=0
  for (( i = $#L; i >= 1; --i )); do
    [[ $L[i] == *" plan: applied "* ]] && { ir=i; break }
  done
  (( ir )) || { out "WARN: breakdown-hit: 'plan: applied' line not found"; return 1 }
  local -F t_apply t_plan t_hit t_req t_arm
  t_apply=0; t_plan=0; t_hit=0; t_req=0; t_arm=0
  ts_of $L[ir]; t_apply=$REPLY
  for (( i = ir - 1; i >= 1; --i )); do
    case $L[i] in
      *" plan: ok "*)         (( t_plan == 0 )) && { ts_of $L[i]; t_plan=$REPLY } ;;
      *" cache: hit"*)        (( t_hit == 0 ))  && { ts_of $L[i]; t_hit=$REPLY } ;;
      *" request: widened"*)  (( t_req == 0 ))  && { ts_of $L[i]; t_req=$REPLY } ;;
      *" MEAS-arm"*)          (( t_req != 0 )) && { ts_of $L[i]; t_arm=$REPLY; break } ;;
    esac
  done
  (( t_arm && t_req && t_hit && t_plan )) || \
    { out "WARN: breakdown-hit: incomplete chain (cache miss?)"; return 1 }
  printf 'BREAK | debounce=%4.0f | cache-check=%4.0f | plan=%4.0f | apply=%4.0f | total(arm→apply)=%5.0f ms\n' \
    $(( (t_req - t_arm) * 1000 )) \
    $(( (t_hit - t_req) * 1000 )) \
    $(( (t_plan - t_hit) * 1000 )) \
    $(( (t_apply - t_plan) * 1000 )) \
    $(( (t_apply - t_arm) * 1000 )) >&2
  return 0
}

paint_break_hit_case() {  # assumes a preceding equivalent case warmed the cache
  local -i skip=0
  [[ -r $HOSTLOG ]] && skip=$(wc -l < $HOSTLOG)
  paint_once $3 $4 20 || { out "WARN: [$1/$2] did not complete"; return 1 }
  out "CASE  | ${(r:12:)1} | ${(r:18:)2} | first-paint=$(fmt $REPLY)ms"
  breakdown_hit_last $HOSTLOG $skip
  drain 0.6
  return 0
}

# ---------------------------------------------------------------- Hosts
typeset -g MEAS_RC=$WORK/meas.zsh
cat > $MEAS_RC <<'EOF'
functions[_zrush_arm_timer_orig]=$functions[_zrush_arm_timer]
_zrush_arm_timer() { _zlog "MEAS-arm"; _zrush_arm_timer_orig "$@" }
print MEAS-READY
EOF

start_min_zrush() {  # $1=host label $2=XDG directory with configuration
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

# ---------------------------------------------------------------- Run
{
  # ============ min-zrush with default 30ms delay ============
  out "==== min-zrush (isolated + default delay-ms=30) ===="
  if start_min_zrush min-zrush $WORK/xdg-default; then
    host_rss; out "INFO: RSS=${REPLY}KB"
    paint_break_case min-zrush "cmd 1st (whic)"   'whic'         'which'   # first run is a cache miss
    paint_break_case min-zrush "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_break_case min-zrush "git (git chec)"   'git chec'     'checkout'
    # Cache-hit path after the command case above has warmed it.
    paint_break_hit_case min-zrush "cmd hit (whic)" 'whic'       'which'
    # Additional median trials; command hits, while file and git are not cacheable.
    paint_case min-zrush "cmd hit (whic)"   'whic'         'which'
    paint_case min-zrush "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_case min-zrush "git (git chec)"   'git chec'     'checkout'
  else
    out "FATAL: min-zrush failed to start"
  fi
  stop_host

  # ============ min-zrush delay-ms=0 ============
  out "==== min-zrush-d0 (isolated + delay-ms=0) ===="
  mkdir -p $WORK/xdg-d0/zrush
  print -r -- $'[display]\ndelay-ms = 0' > $WORK/xdg-d0/zrush/config.toml
  if start_min_zrush min-d0 $WORK/xdg-d0; then
    paint_case min-d0 "cmd (whic)"       'whic'         'which'
    paint_case min-d0 "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_case min-d0 "git (git chec)"   'git chec'     'checkout'
  else
    out "FATAL: min-d0 failed to start"
  fi
  stop_host

  # ============ min-zac ============
  out "==== min-zac (isolated + zsh-autocomplete, min-delay 0.05) ===="
  if [[ -r $ZAC_SRC ]] && start_min_zac; then
    host_rss; out "INFO: RSS=${REPLY}KB"
    paint_case zac "cmd (whic)"       'whic'         'which'
    paint_case zac "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_case zac "git (git chec)"   'git chec'     'checkout'
  else
    out "FATAL: min-zac failed to start (ZAC_SRC=$ZAC_SRC)"
  fi
  stop_host
} always {
  zpty -d min-zrush 2>/dev/null
  zpty -d min-d0 2>/dev/null
  zpty -d zac 2>/dev/null
  [[ -n $WORK && $WORK == */zrush-lat.* ]] && rm -rf $WORK
}
