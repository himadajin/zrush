# Host rc for the [history].limit boundary scenario in tests/zsh/driver.zsh
# ("h8"). Same isolation as tests/zsh/rc/history.zshrc, but with its own
# small, deliberately ordered fixture set so the newest-N-raw-entries scan
# window (config's [history].limit, written to this host's own
# XDG_CONFIG_HOME/zrush/config.toml by the driver) is easy to reason about
# exactly. Required environment: ZRUSH_REAL_BIN, ZRUSH_TEST_TMP.
PS1='HP> '
HISTFILE=$ZRUSH_TEST_TMP/histfile-hist-limit
HISTSIZE=1000
SAVEHIST=0
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-histlimit
source <($ZRUSH_REAL_BIN init zsh)

_zrt_dump_postdisplay() { _zlog "TESTPOST=${(qqqq)POSTDISPLAY}" }
zle -N _zrt-dump-postdisplay _zrt_dump_postdisplay
bindkey '^Xp' _zrt-dump-postdisplay

# Oldest to newest. With [history].limit=5 (the driver writes that to this
# host's config.toml) the scan window is exactly the newest 5 RAW entries
# below: dupA (x2) + ctrlone (SOH, excluded) + keep3 + keep4. Within that
# window, dedup and exclusion leave only 3 candidates (dupA once, keep3,
# keep4); keep5-outside/oldest-outside sit just past the window and must
# never appear, even though nothing but their position disqualifies them.
print -sr -- 'echo keep5-outside'
print -sr -- 'echo oldest-outside'
print -sr -- 'echo keep4'
print -sr -- 'echo keep3'
print -sr -- $'echo ctrlone\x01tail'
print -sr -- 'echo dupA'
print -sr -- 'echo dupA'

print MARK-RC-DONE
