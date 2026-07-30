# Host rc for headless regression tests, loaded by tests/zsh/driver.zsh through ZDOTDIR
# Required environment: ZRUSH_REPO (repository root), ZRUSH_TEST_TMP (isolated tmp)
PS1='HP> '
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-test
source $ZRUSH_REPO/zsh/zrush.zsh

# Test-only ^Xb widget that dumps the current BUFFER to ZRUSH_LOG.
# Drivers use it to verify confirmation and replacement exactly; it is not production code.
_zrt_dump_buffer() { _zlog "TESTBUF=${(qqqq)BUFFER}" }
zle -N _zrt-dump-buffer _zrt_dump_buffer
bindkey '^Xb' _zrt-dump-buffer

print MARK-RC-DONE
