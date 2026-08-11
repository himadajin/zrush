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
#   history    : each history host reports three things. `index-cold` opens
#                (first open of the host, then one forced discontinuity per
#                later trial) and `index-warm` opens (the index already built)
#                are separate classes, each with a per-open phase breakdown, so
#                the payload synthesis and the snapshot send show up on cold and
#                are visibly absent on warm. `TAX` rows are the per-prompt index
#                update, measured from precmd entry, for the three prompt
#                classes behavior.md distinguishes: a prompt that appends, one
#                with no new event, and one whose index is not ready.
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
# Sub-millisecond quantities are carried as whole microseconds: the median above
# sorts numerically on the integer part only, which is fine for first-paint tens
# of milliseconds but would misorder 0.4 against 0.378.
fmtus() { [[ $1 == NA ]] && print -rn NA || printf '%.2f' $(( $1 / 1000.0 )) }

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

log_has_since() {  # $1=logfile $2=lines to skip $3=substring
  local -a L=( ${(f)"$(<$1)"} )
  [[ ${(j:
:)L[$(( $2 + 1 )),-1]} == *$3* ]]
}

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

# Phases of one open transition, from the checkpoints behavior.md "履歴メニュー"
# prescribes, in the order they are emitted:
#   history: fingerprint cold|warm  -- the Level A/B verdict at the entrance
#   history: snapshot ... bytes=N   -- cold only: payload synthesized and enqueued
#   history: query ...              -- the plan request (cold: right behind the snapshot)
#   plan: applied                   -- the listing is on screen
# A cold row therefore carries the two phases a warm row must not have at all,
# which is the whole point of splitting the two classes.
breakdown_history_last() {  # $1=logfile $2=lines to skip $3=expected mode -> one table row
  local -a L=( ${(f)"$(<$1)"} )
  L=( "${(@)L[$(( $2 + 1 )),-1]}" )
  local -i i ir=0
  for (( i = $#L; i >= 1; --i )); do
    [[ $L[i] == *" plan: applied "* ]] && { ir=i; break }
  done
  (( ir )) || { bad "WARN: breakdown-history: 'plan: applied' line not found"; return 1 }
  local -F t_apply t_query t_snap t_fp
  t_apply=0; t_query=0; t_snap=0; t_fp=0
  local mode= bytes=NA
  ts_of $L[ir]; t_apply=$REPLY
  for (( i = ir - 1; i >= 1; --i )); do
    case $L[i] in
      *" history: query "*)         (( t_query == 0 )) && { ts_of $L[i]; t_query=$REPLY } ;;
      *" history: snapshot "*)      (( t_snap == 0 ))  && { ts_of $L[i]; t_snap=$REPLY; bytes=${L[i]##*bytes=} } ;;
      *" history: fingerprint cold "*) ts_of $L[i]; t_fp=$REPLY; mode=cold; break ;;
      *" history: fingerprint warm "*) ts_of $L[i]; t_fp=$REPLY; mode=warm; break ;;
    esac
  done
  (( t_fp && t_query )) || { bad "WARN: breakdown-history: incomplete chain"; return 1 }
  [[ $mode == $3 ]] || bad "WARN: breakdown-history: expected $3, log says $mode"
  if [[ $mode == cold ]]; then
    (( t_snap )) || { bad "WARN: breakdown-history: cold open without a snapshot"; return 1 }
    printf 'BREAK | mode=cold | fingerprint→snapshot=%6.1f | snapshot→query=%6.1f | query→apply=%6.1f | total(fingerprint→apply)=%6.1f ms | payload=%sB\n' \
      $(( (t_snap - t_fp) * 1000 )) \
      $(( (t_query - t_snap) * 1000 )) \
      $(( (t_apply - t_query) * 1000 )) \
      $(( (t_apply - t_fp) * 1000 )) \
      $bytes >&2
  else
    (( t_snap )) && bad "WARN: breakdown-history: warm open synthesized a snapshot"
    printf 'BREAK | mode=warm | fingerprint→query=%9.1f | synthesis=none | snapshot=none | query→apply=%6.1f | total(fingerprint→apply)=%6.1f ms\n' \
      $(( (t_query - t_fp) * 1000 )) \
      $(( (t_apply - t_query) * 1000 )) \
      $(( (t_apply - t_fp) * 1000 )) >&2
  fi
  return 0
}

paint_history_trial() {  # $1=host-label $2=case-label $3=pattern $4=expected mode -> REPLY=ms
  local -i skip=0
  [[ -r $HOSTLOG ]] && skip=$(wc -l < $HOSTLOG)
  paint_history_once $3 20 || { typeset -g REPLY=NA; return 1 }
  local ms=$REPLY
  out "CASE  | ${(r:12:)1} | ${(r:32:)2} | first-paint=$(fmt $ms)ms"
  breakdown_history_last $HOSTLOG $skip $4
  typeset -g REPLY=$ms
  return 0
}

# One class of history-menu opens. `index-cold` takes its first sample from the
# host's own first open (nothing has built the index yet, so that sample also
# carries the lazy worker start) and forces the later ones with the rc's
# _zrush_lat_resync, which makes Level A see a discontinuity the same way a real
# one does. `index-warm` needs no preparation: the last cold open latched the
# index, and opening a menu is not an invalidation point.
history_class() {  # $1=host-label $2=case-label $3=pattern $4=mode $5=resync-before-later-trials(0/1) [$6=trials]
  local -i trials=${6:-${ZRUSH_LATENCY_TRIALS:-4}}
  local -a ms=()
  local -i i
  for (( i = 1; i <= trials; ++i )); do
    if (( $5 && i > 1 )) && ! run_cmd _zrush_lat_resync; then
      bad "WARN: [$1/$2] forced resync before attempt $i did not complete"
      break
    fi
    if paint_history_trial $1 "$2 #$i" $3 $4; then
      ms+=( $REPLY )
    else
      out "WARN: [$1/$2] attempt $i did not complete"
    fi
    drain 0.3
  done
  median $ms
  (( $#ms == trials )) || bad "WARN: [$1/$2] $(( trials - $#ms )) of $trials attempts did not complete"
  out "PAINT | ${(r:12:)1} | ${(r:32:)2} | med=$(fmt $REPLY)ms | trials=[${(j:, :)${(@)ms/(#m)*/$(fmt $MATCH)}}]"
  return 0
}

# ------------------------------------------------- Per-prompt index update tax
# behavior.md "履歴メニュー" 更新経路: what every prompt pays, whether or not it
# has anything to send. Two of the three classes emit no checkpoint of their own
# (they return on arithmetic alone), so the host rc brackets _zrush_precmd with
# MEAS-precmd / MEAS-precmd-end and this reads the first bracket of the window.
tax_once() {  # $1=logfile $2=lines to skip -> REPLY/REPLY_ENQ = microseconds, REPLY_KIND
  local -a L=( ${(f)"$(<$1)"} )
  L=( "${(@)L[$(( $2 + 1 )),-1]}" )
  local -F t0 t1 t2
  t0=0; t1=0; t2=0
  local kind=none
  local -i i
  for (( i = 1; i <= $#L; ++i )); do
    if (( t0 == 0 )); then
      [[ $L[i] == *" MEAS-precmd" ]] && { ts_of $L[i]; t0=$REPLY }
      continue
    fi
    case $L[i] in
      *" history: append request_id="*) (( t1 == 0 )) && { ts_of $L[i]; t1=$REPLY; kind=append } ;;
      *" history: append skipped "*)    (( t1 == 0 )) && { ts_of $L[i]; t1=$REPLY; kind=excluded } ;;
      *" MEAS-precmd-end")              ts_of $L[i]; t2=$REPLY; break ;;
    esac
  done
  typeset -g REPLY=NA REPLY_ENQ=NA REPLY_KIND=$kind
  (( t0 && t2 )) || return 1
  local -i us
  us=$(( (t2 - t0) * 1000000 ))   # an integer assignment truncates the float
  REPLY=$us
  if (( t1 )); then
    us=$(( (t1 - t0) * 1000000 ))
    REPLY_ENQ=$us
  fi
  return 0
}

tax_case() {  # $1=host-label $2=case-label $3=trigger(cmd|enter) $4=expected kind [$5=trials]
  local -i trials=${5:-${ZRUSH_LATENCY_TRIALS:-4}}
  local -a tot=() enq=()
  local -i i skip
  for (( i = 1; i <= trials; ++i )); do
    skip=0
    [[ -r $HOSTLOG ]] && skip=$(wc -l < $HOSTLOG)
    # Either trigger ends on a sync command of its own, so the window always
    # holds the bracket under test first and the sync command's bracket after it.
    case $3 in
      cmd)   send_line "print -r -- TAX-$i" ;;
      enter) send_keys $'\r' ;;
    esac
    if ! sync_host; then
      bad "WARN: [$1/$2] prompt $i did not return"
      continue
    fi
    if tax_once $HOSTLOG $skip; then
      [[ $REPLY_KIND == $4 ]] || bad "WARN: [$1/$2] prompt $i took the '$REPLY_KIND' path, expected '$4'"
      tot+=( $REPLY )
      [[ $REPLY_ENQ == NA ]] || enq+=( $REPLY_ENQ )
    else
      bad "WARN: [$1/$2] prompt $i produced no precmd bracket"
    fi
  done
  (( $#tot == trials )) || bad "WARN: [$1/$2] $(( trials - $#tot )) of $trials prompts were not measured"
  median $tot; local m_tot=$REPLY
  median $enq; local m_enq=$REPLY
  local col
  if [[ $m_enq == NA ]]; then
    col="precmd→enqueue: no frame sent            "
  else
    col="precmd→enqueue med=$(fmtus $m_enq)ms [${(j:, :)${(@)enq/(#m)*/$(fmtus $MATCH)}}]"
  fi
  out "TAX   | ${(r:12:)1} | ${(r:32:)2} | $col | precmd total med=$(fmtus $m_tot)ms [${(j:, :)${(@)tot/(#m)*/$(fmtus $MATCH)}}]"
  return 0
}

# The three per-prompt classes, in the only order that lets each one hold: the
# append class leaves the index latched, the no-new-event class does not touch
# it, and the resync that sets up the not-ready class is deliberately last.
history_tax_suite() {  # $1=host-label
  tax_case $1 "per-prompt: append sent"     cmd   append
  tax_case $1 "per-prompt: no new event"    enter none
  local -i skip=0
  [[ -r $HOSTLOG ]] && skip=$(wc -l < $HOSTLOG)
  if run_cmd _zrush_lat_resync; then
    log_has_since $HOSTLOG $skip 'history: index dirty (reason=continuity)' ||
      bad "WARN: [$1] forced resync did not invalidate the index"
  else
    bad "WARN: [$1] forced resync before the not-ready class did not complete"
  fi
  tax_case $1 "per-prompt: index not ready" cmd   none
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
    history_class hist5000 "index-cold (5000)" 'needle-latency-target' cold 1
    history_class hist5000 "index-warm (5000)" 'needle-latency-target' warm 0
    history_tax_suite hist5000
  else
    bad "FATAL: hist5000 failed to start"
  fi
  stop_host

  out "==== hist-20000-long (limit=20000, 20000-entry history, long single lines) ===="
  if start_hist_latency hist20000 20000 1 20000; then
    history_class hist20000 "index-cold (20000, long)" 'needle-latency-target' cold 1
    history_class hist20000 "index-warm (20000, long)" 'needle-latency-target' warm 0
    history_tax_suite hist20000
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
