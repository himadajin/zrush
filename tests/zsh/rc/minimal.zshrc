# Host rc for headless regression tests, loaded by tests/zsh/driver.zsh through ZDOTDIR
# Required environment: ZRUSH_REPO (repository root), ZRUSH_TEST_TMP (isolated tmp)
PS1='HP> '
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-test
source $ZRUSH_REPO/zsh/zrush.zsh

# Test-only dump widgets that write internal state to ZRUSH_LOG so drivers can
# assert on it precisely. Not production code.
_zrt_dump_buffer() { _zlog "TESTBUF=${(qqqq)BUFFER}" }
zle -N _zrt-dump-buffer _zrt_dump_buffer
bindkey '^Xb' _zrt-dump-buffer

# ^Xp: POSTDISPLAY, quoted (cli-protocol.md "適用": leading \n + listing text).
_zrt_dump_postdisplay() { _zlog "TESTPOST=${(qqqq)POSTDISPLAY}" }
zle -N _zrt-dump-postdisplay _zrt_dump_postdisplay
bindkey '^Xp' _zrt-dump-postdisplay

# ^Xh: this plugin's region_highlight entries only (_zrush_rh ledger), space-joined
# so a single ZRUSH_LOG line carries every entry (role spec + memo=zrush suffix).
_zrt_dump_rh() { _zlog "TESTRH=${(pj: | :)_zrush_rh}" }
zle -N _zrt-dump-rh _zrt_dump_rh
bindkey '^Xh' _zrt-dump-rh

print MARK-RC-DONE
