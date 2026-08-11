#!/bin/zsh -f
# Latency driver for isolating time from key input to the first candidate paint.
#
# Usage: zsh -f tests/zsh/driver-latency.zsh <playground-dir>
#   Prerequisites: cargo build --release completed, and a playground holding a
#   docs/internal tree, which the `ls docs/inte` case completes against (the
#   repo root qualifies; the `git chec` case needs git but no repository).
#   ZRUSH_LATENCY_TRIALS=N bounds every case to N attempts (default 4). N=1
#   medians are not trustworthy: a single trial is the per-host warm-up one.
#
# Hosts:
#   min-zrush     zsh -d -i + isolated minimal.zshrc
#   min-d0        same with delay-ms = 0 to isolate debounce contribution
#   hist5000      isolated history-latency.zshrc, ~5000 short fixture entries
#   hist20000     the same with 20000 long entries and [history].limit = 20000
#
# All hosts use a throwaway ZDOTDIR (and, where applicable, XDG_CONFIG_HOME)
# under $WORK: this driver never reads or sources the real ~/.zshrc, and
# never touches ~/.zsh_history (AGENTS.md guardrail).
#
# Every measurement is mandatory: an NA median, an incomplete breakdown chain
# or a host that fails to start counts as degraded, and a degraded run exits
# nonzero and keeps $WORK (per-host ZRUSH_LOG) instead of cleaning it up.
#
# Measurements:
#   first-paint: elapsed time from key sequence to expected pty text after stripping
#                SGR and its padding, with roughly 10ms zselect resolution
#   breakdown  : ZRUSH_LOG intervals, keyed off zsh's own _zlog checkpoints
#                matching, ranking, layout, and render-plan construction happen
#                in the persistent Rust worker. The worker-roundtrip bucket
#                starts after capture transport completes; there is deliberately
#                no per-plan Rust process-spawn bucket:
#                arm -> request -> capture-start -> compsys -> capture-transport
#                    -> worker-roundtrip+apply
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
[[ -d $PLAYGROUND/docs/internal ]] || { print -u2 "FATAL: invalid playground: $PLAYGROUND"; exit 1 }
[[ -x $REPO/target/release/zrush ]] || { print -u2 "FATAL: zrush binary not found"; exit 1 }
[[ $REPO/zsh/zrush.zsh -nt $REPO/target/release/zrush ]] && { print -u2 "FATAL: zsh/zrush.zsh is newer than the built binary; run cargo build --release"; exit 1 }

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-lat.XXXXXX)
export TERM=vt100
export LC_ALL=en_US.UTF-8

typeset -g HOST= HOSTLOG= CURXDG=
typeset -gi HOSTFD=-1 SYNCN=0 DEGRADED=0
out()  { print -r -u2 -- "$@" }
bad()  { (( ++DEGRADED )); out "$@" }   # a reported measurement is missing or unusable

send_line() { zpty -w  $HOST "$1" }
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
# Milliseconds from sending keys until expected text appears in the SGR-stripped
# pty stream. Each SGR is stripped together with the NUL run some platforms emit
# after it (terminfo padding, #64), the same rule as strip_sgr in tests/driver/host.rs.
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
        if [[ ${buf//$'\e['[0-9;]#m$'\0'#/} == *$pat* ]]; then
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
  local -i trials=${5:-${ZRUSH_LATENCY_TRIALS:-4}}
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
  # A median over the survivors of a partly failed case is optimistic (median
  # takes the lower middle), so any missing attempt degrades the whole case.
  (( $#ms == trials )) || bad "WARN: [$1/$2] $(( trials - $#ms )) of $trials attempts did not complete"
  out "PAINT | ${(r:12:)1} | ${(r:32:)2} | med=$(fmt $REPLY)ms | trials=[${(j:, :)${(@)ms/(#m)*/$(fmt $MATCH)}}]"
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
  (( ir )) || { bad "WARN: breakdown: 'plan: applied' line not found"; return 1 }
  local -F t_apply t_xfer t_comp t_fork t_req t_arm
  t_apply=0; t_xfer=0; t_comp=0; t_fork=0; t_req=0; t_arm=0
  ts_of $L[ir]; t_apply=$REPLY
  for (( i = ir - 1; i >= 1; --i )); do
    case $L[i] in
      *" finalize: "*" bytes"*)      (( t_xfer == 0 ))  && { ts_of $L[i]; t_xfer=$REPLY } ;;
      *" fork: _main_complete "*)    (( t_comp == 0 ))  && { ts_of $L[i]; t_comp=$REPLY } ;;
      *" fork: start "*)             (( t_fork == 0 ))  && { ts_of $L[i]; t_fork=$REPLY } ;;
      *" request: widened"*)         (( t_req == 0 ))   && { ts_of $L[i]; t_req=$REPLY } ;;
      *" MEAS-arm"*)                 (( t_req != 0 )) && { ts_of $L[i]; t_arm=$REPLY; break } ;;
    esac
  done
  (( t_arm && t_req && t_fork && t_comp && t_xfer )) || { bad "WARN: breakdown: incomplete chain"; return 1 }
  printf 'BREAK | debounce=%4.0f | capture-start=%4.0f | compsys=%5.0f | capture-transport=%4.0f | worker-roundtrip+apply=%4.0f | total(arm→apply)=%5.0f ms\n' \
    $(( (t_req - t_arm) * 1000 )) \
    $(( (t_fork - t_req) * 1000 )) \
    $(( (t_comp - t_fork) * 1000 )) \
    $(( (t_xfer - t_comp) * 1000 )) \
    $(( (t_apply - t_xfer) * 1000 )) \
    $(( (t_apply - t_arm) * 1000 )) >&2
  return 0
}

paint_break_case() {  # $1=host-label $2=case-label $3=keys $4=pattern
  local -i skip=0
  [[ -r $HOSTLOG ]] && skip=$(wc -l < $HOSTLOG)
  paint_once $3 $4 20 || { bad "WARN: [$1/$2] did not complete"; return 1 }
  out "CASE  | ${(r:12:)1} | ${(r:32:)2} | first-paint=$(fmt $REPLY)ms"
  breakdown_last $HOSTLOG $skip
  drain 0.6
  return 0
}

# Cache-hit breakdown: arm -> request -> cache hit -> worker roundtrip + apply
breakdown_hit_last() {  # $1=logfile $2=number of leading lines to skip
  local -a L=( ${(f)"$(<$1)"} )
  L=( "${(@)L[$(( $2 + 1 )),-1]}" )
  local -i i ir=0
  for (( i = $#L; i >= 1; --i )); do
    [[ $L[i] == *" plan: applied "* ]] && { ir=i; break }
  done
  (( ir )) || { bad "WARN: breakdown-hit: 'plan: applied' line not found"; return 1 }
  local -F t_apply t_hit t_req t_arm
  t_apply=0; t_hit=0; t_req=0; t_arm=0
  ts_of $L[ir]; t_apply=$REPLY
  for (( i = ir - 1; i >= 1; --i )); do
    case $L[i] in
      *" cache: hit"*)        (( t_hit == 0 ))  && { ts_of $L[i]; t_hit=$REPLY } ;;
      *" request: widened"*)  (( t_req == 0 ))  && { ts_of $L[i]; t_req=$REPLY } ;;
      *" MEAS-arm"*)          (( t_req != 0 )) && { ts_of $L[i]; t_arm=$REPLY; break } ;;
    esac
  done
  (( t_arm && t_req && t_hit )) || \
    { bad "WARN: breakdown-hit: incomplete chain (cache miss?)"; return 1 }
  printf 'BREAK | debounce=%4.0f | cache-check=%4.0f | worker-roundtrip+apply=%4.0f | total(arm→apply)=%5.0f ms\n' \
    $(( (t_req - t_arm) * 1000 )) \
    $(( (t_hit - t_req) * 1000 )) \
    $(( (t_apply - t_hit) * 1000 )) \
    $(( (t_apply - t_arm) * 1000 )) >&2
  return 0
}

paint_break_hit_case() {  # needs two preceding command-position collections (see the run block)
  local -i skip=0
  [[ -r $HOSTLOG ]] && skip=$(wc -l < $HOSTLOG)
  paint_once $3 $4 20 || { bad "WARN: [$1/$2] did not complete"; return 1 }
  out "CASE  | ${(r:12:)1} | ${(r:32:)2} | first-paint=$(fmt $REPLY)ms"
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
  export ZRUSH_REAL_BIN=$REPO/target/release/zrush ZRUSH_TEST_TMP=$WORK/t-$1 ZDOTDIR=$WORK/zdot-$1
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
  [[ $REPLY == NA ]] && bad "WARN: [$HOST] RSS scrape did not complete"
  drain 0.3
}

stop_host() { zpty -d $HOST 2>/dev/null; HOSTFD=-1 }

# ---------------------------------------------------------------- History-menu first paint
# Same isolation discipline as start_min_zrush, but sourcing
# tests/zsh/rc/history-latency.zshrc (bulk-generated fixture history) instead
# of minimal.zshrc, and optionally writing a [history].limit override so the
# large-history case can exercise a scan window bigger than the 5000 default
# (config-schema.md "[history]", max 20000).
start_hist_latency() {  # $1=host label $2=N fixture entries $3=long(0/1) [$4=history.limit override]
  HOST=$1 HOSTLOG=$WORK/$1.log CURXDG=$WORK/xdg-$1
  export ZRUSH_REAL_BIN=$REPO/target/release/zrush ZRUSH_TEST_TMP=$WORK/t-$1 ZDOTDIR=$WORK/zdot-$1
  export XDG_CONFIG_HOME=$CURXDG ZRUSH_LOG=$HOSTLOG
  export ZRUSH_HIST_N=$2 ZRUSH_HIST_LONG=$3
  # No ZRUSH_HISTORY_DEADLINE_MS seam: the payload byte ceiling (behavior.md
  # "履歴メニュー") keeps the exchange inside the production deadline at every
  # scan window this driver measures, so these numbers are production ones.
  mkdir -p $ZDOTDIR $ZRUSH_TEST_TMP $CURXDG/zrush
  if [[ -n ${4:-} ]]; then
    print -r -- $'[history]\nlimit = '$4 > $CURXDG/zrush/config.toml
  fi
  print "source $REPO/tests/zsh/rc/history-latency.zshrc" > $ZDOTDIR/.zshrc
  cd $PLAYGROUND || return 1
  local REPLY=
  zpty -b $HOST zsh -d -i || return 1
  HOSTFD=$REPLY
  expect '*MARK-RC-DONE*' 60 || return 1   # generating thousands of history entries can take a moment
  drain 0.5
  unset ZRUSH_HIST_N ZRUSH_HIST_LONG
  return 0
}

# The history menu is opened by a bare select-prev (Up) on an empty buffer,
# not by typing a pattern, so this cannot reuse paint_case/paint_once as-is:
# once open, a second Up would navigate the still-open menu (select-prev on
# an already-selected position 1) instead of re-opening it, so each trial
# must explicitly dismiss first to guarantee it measures the same open
# transition every time.
paint_history_once() {  # $1=pattern $2=timeout -> REPLY=ms (NA if not reached)
  send_keys $'\C-g'; drain 0.2   # ensure the menu starts closed (a no-op if it already is)
  paint_once $'\e[A' $1 ${2:-20}
}

paint_history_case() {  # $1=host-label $2=case-label $3=pattern [$4=trials]
  local -i trials=${4:-${ZRUSH_LATENCY_TRIALS:-4}}
  local -a ms=()
  local -i i
  for (( i = 1; i <= trials; ++i )); do
    if paint_history_once $3 20; then
      ms+=( $REPLY )
    else
      out "WARN: [$1/$2] attempt $i did not complete"
    fi
  done
  median $ms
  (( $#ms == trials )) || bad "WARN: [$1/$2] $(( trials - $#ms )) of $trials attempts did not complete"
  out "PAINT | ${(r:12:)1} | ${(r:32:)2} | med=$(fmt $REPLY)ms | trials=[${(j:, :)${(@)ms/(#m)*/$(fmt $MATCH)}}]"
  return 0
}

# ---------------------------------------------------------------- Run
{
  # ============ min-zrush with default 30ms delay ============
  out "==== min-zrush (isolated + default delay-ms=30) ===="
  if start_min_zrush min-zrush $WORK/xdg-default; then
    host_rss; out "INFO: RSS=${REPLY}KB"
    # Command position is the only cached one (behavior.md "空語収集キャッシュ"),
    # and its first collection is followed by exactly one more invalidation
    # (同節「既知の癖」), so a guaranteed hit needs two collections before it:
    # the reported miss, then an unreported warm-up. Every cache-hit case has to
    # come before the file and git cases, which measure uncached collection.
    paint_break_case min-zrush "cmd 1st (whic)"   'whic'         'which'
    paint_once 'whic' 'which' 20 || out "WARN: cache warm-up did not complete"
    drain 0.6
    paint_break_hit_case min-zrush "cmd hit (whic)" 'whic'       'which'
    paint_case min-zrush "cmd hit (whic)"   'whic'         'which'
    paint_break_case min-zrush "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_break_case min-zrush "git (git chec)"   'git chec'     'checkout'
    paint_case min-zrush "file (docs/inte)" 'ls docs/inte' 'internal'
    paint_case min-zrush "git (git chec)"   'git chec'     'checkout'
  else
    bad "FATAL: min-zrush failed to start"
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
    bad "FATAL: min-d0 failed to start"
  fi
  stop_host

  # ============ history-menu first paint ============
  # behavior.md "履歴メニュー" bounds the synchronous exchange (100ms deadline,
  # payload byte ceiling) but sets no first-paint target: synthesis is outside
  # the deadline and stays linear in total history size, so this reports
  # measurements only -- same convention as the cases above.
  out "==== hist-5000 (history menu, default [history].limit=5000, ~5000-entry history) ===="
  if start_hist_latency hist5000 5000 0; then
    paint_history_case hist5000 "empty-buf Up (5000)" 'needle-latency-target'
  else
    bad "FATAL: hist5000 failed to start"
  fi
  stop_host

  out "==== hist-20000-long (limit=20000, 20000-entry history, long single lines) ===="
  if start_hist_latency hist20000 20000 1 20000; then
    paint_history_case hist20000 "empty-buf Up (20000, long lines)" 'needle-latency-target'
  else
    bad "FATAL: hist20000 failed to start"
  fi
  stop_host

  out "SUMMARY: degraded=$DEGRADED"
} always {
  zpty -d min-zrush 2>/dev/null
  zpty -d min-d0 2>/dev/null
  zpty -d hist5000 2>/dev/null
  zpty -d hist20000 2>/dev/null
  if (( DEGRADED )); then
    out "NOTE: kept $WORK (per-host ZRUSH_LOG) for post-mortem"
  else
    [[ -n $WORK && $WORK == */zrush-lat.* ]] && rm -rf $WORK
  fi
}
(( DEGRADED == 0 ))
