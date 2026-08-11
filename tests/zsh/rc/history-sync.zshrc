# Host rc for the history-index resync scenarios in the Rust pty harness
# (tests/driver/hist_index.rs). Same isolation as tests/zsh/rc/history.zshrc,
# but with a fixture history short enough that one unfiltered menu shows all of
# it, so a resync is read off the listing directly, and with the history file
# the bulk-load trigger (`fc -R`) reads.
# Required environment: ZRUSH_REAL_BIN, ZRUSH_TEST_TMP.
# Isolated HISTFILE + SAVEHIST=0: the fixture history below lives only in this
# throwaway shell's memory and is never written out or read back from the
# real ~/.zsh_history (AGENTS.md guardrail).
PS1='HP> '
HISTFILE=$ZRUSH_TEST_TMP/histfile-hist-sync
HISTSIZE=1000
SAVEHIST=0
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-histsync
source <($ZRUSH_REAL_BIN init zsh)

_zrt_dump_postdisplay() { _zlog "TESTPOST=${(qqqq)POSTDISPLAY}" }
zle -N _zrt-dump-postdisplay _zrt_dump_postdisplay
bindkey '^Xp' _zrt-dump-postdisplay

_zrt_dump_kind() { _zlog "TESTKIND=kind=$_zrush_plan_kind sel=$_zrush_selected listing=$_zrush_listing npos=$_zrush_plan_npos" }
zle -N _zrt-dump-kind _zrt_dump_kind
bindkey '^Xk' _zrt-dump-kind

# ^Xi: history index latch and fingerprint baseline; see tests/zsh/rc/history.zshrc.
_zrt_dump_hist() { _zlog "TESTHIST=gen=$_zrush_hist_gen head=$_zrush_hist_head count=$_zrush_hist_count unacked=$_zrush_hist_unacked" }
zle -N _zrt-dump-hist _zrt_dump_hist
bindkey '^Xi' _zrt-dump-hist

# What the bulk-load trigger reads. Written here rather than from the test, so
# it is in place before the shell takes its first keystroke. It is deliberately
# not this shell's own HISTFILE: `fc -R` on it is an explicit bulk load, not a
# save/restore round trip (SAVEHIST=0 leaves the real HISTFILE unwritten).
print -rl -- 'echo bulkone' 'echo bulktwo' > $ZRUSH_TEST_TMP/histfile-sync-bulk

# Fixture history, oldest to newest ($history reports newest first, so the last
# print -s here is position 1 of an unfiltered history menu). Short on purpose:
# every entry fits in one menu, so "the index was rebuilt" is visible as the
# whole listing rather than as its newest rows.
print -sr -- 'echo syncbase'
print -sr -- 'echo syncnewest'

print MARK-RC-DONE
