# Host rc for the [history].limit boundary scenario in the Rust pty harness
# (tests/driver/hist_config.rs). Same isolation as tests/zsh/rc/history.zshrc,
# but with its own small, deliberately ordered fixture set so the newest-N
# index scan window (config's [history].limit, written to this host's own
# XDG_CONFIG_HOME/zrush/config.toml before it boots) is easy to reason about
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

# Oldest to newest. The scan window is over the worker's index, not over
# $history: the framing-byte line never enters the index, so it costs no window
# slot. With [history].limit=5 (the test writes that to this host's
# config.toml) the newest 5 index entries are dupA (x2) + keep3 + keep4 +
# oldest-outside, which dedup leaves as 4 candidates. Only keep5-outside sits
# past the window and must never appear, even though nothing but its position
# disqualifies it.
print -sr -- 'echo keep5-outside'
print -sr -- 'echo oldest-outside'
print -sr -- 'echo keep4'
print -sr -- 'echo keep3'
print -sr -- $'echo ctrlone\x01tail'
print -sr -- 'echo dupA'
print -sr -- 'echo dupA'

print MARK-RC-DONE
