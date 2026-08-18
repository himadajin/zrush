# Host rc for the history-menu latency cases in tests/zsh/driver-latency.zsh.
# Required environment: ZRUSH_REAL_BIN, ZRUSH_TEST_TMP, and:
#   ZRUSH_HIST_N     number of fixture history entries to generate (default 5000)
#   ZRUSH_HIST_LONG  1 = pad each entry to a long single line; 0 = short entries
# Isolated HISTFILE + SAVEHIST=0, same as tests/zsh/rc/history.zshrc.
PS1='HP> '
HISTFILE=$ZRUSH_TEST_TMP/histfile-histlat
typeset -i _zrt_n=${ZRUSH_HIST_N:-5000}
typeset -i _zrt_long=${ZRUSH_HIST_LONG:-0}
HISTSIZE=$(( _zrt_n + 100 ))
SAVEHIST=0
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-histlat
source <($ZRUSH_REAL_BIN init zsh)

# Bulk-generate fixture history rather than writing thousands of literal
# print -s lines; behavior.md "History Menu" measures against realistic
# history sizes ([history].limit's default and max, config-schema.md), not
# against this driver's small hand-written fixture sets.
typeset _zrt_pad=
(( _zrt_long )) && _zrt_pad=${(l:200::x:)}
typeset -i _zrt_i
for (( _zrt_i = 1; _zrt_i <= _zrt_n; ++_zrt_i )); do
  print -sr -- "echo fixture-cmd-${_zrt_i}-${_zrt_pad}"
done
# Freshest entry: an empty-buffer Up always selects this at position 1, so a
# driver can wait for one fixed, unambiguous string regardless of _zrt_n.
print -sr -- 'echo needle-latency-target'

# Force the worker's history index back to cold, from the outside: injecting one
# event makes HISTCMD advance by two (this command plus the injected line),
# which Level A reads as a discontinuity (behavior.md "History Menu"). No
# _zrush_hist_* internal is touched, so the driver measures the same cold path a
# real discontinuity takes. The injected line is the needle itself, so the next
# empty-buffer Up still paints a known string.
_zrush_lat_resync() { print -sr -- 'echo needle-latency-target' }

# Measurement seam for the per-prompt index update (driver-latency.zsh only):
# bracketing _zrush_precmd lets the driver time precmd entry -> history-append
# enqueue -> precmd exit out of ZRUSH_LOG alone, for the prompt classes that
# emit no checkpoint of their own (no new event, index not ready).
functions[_zrush_precmd_latorig]=$functions[_zrush_precmd]
_zrush_precmd() {
  _zlog "MEAS-precmd"
  _zrush_precmd_latorig "$@"
  local -i _zrt_st=$?
  _zlog "MEAS-precmd-end"
  return $_zrt_st
}

print MARK-RC-DONE
