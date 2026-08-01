# Host rc for the history-menu latency cases in tests/zsh/driver-latency.zsh.
# Required environment: ZRUSH_REPO, ZRUSH_TEST_TMP, and:
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
source $ZRUSH_REPO/zsh/zrush.zsh

# Bulk-generate fixture history rather than writing thousands of literal
# print -s lines; behavior.md "履歴メニュー" measures against realistic
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

print MARK-RC-DONE
