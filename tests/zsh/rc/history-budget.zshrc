# Host rc for the payload byte-ceiling scenario in the Rust pty harness
# (tests/driver/hist_config.rs). Same isolation as tests/zsh/rc/history.zshrc,
# but with a fixture history whose newest-first byte total crosses the ceiling
# of behavior.md 「履歴メニュー」 partway through, so the scan provably stops
# before the oldest entry. Required environment: ZRUSH_REAL_BIN, ZRUSH_TEST_TMP.
PS1='HP> '
HISTFILE=$ZRUSH_TEST_TMP/histfile-hist-budget
HISTSIZE=1000
SAVEHIST=0
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-histbudget
source <($ZRUSH_REAL_BIN init zsh)

_zrt_dump_postdisplay() { _zlog "TESTPOST=${(qqqq)POSTDISPLAY}" }
zle -N _zrt-dump-postdisplay _zrt_dump_postdisplay
bindkey '^Xp' _zrt-dump-postdisplay

_zrt_dump_kind() { _zlog "TESTKIND=kind=$_zrush_plan_kind sel=$_zrush_selected listing=$_zrush_listing npos=$_zrush_plan_npos" }
zle -N _zrt-dump-kind _zrt_dump_kind
bindkey '^Xk' _zrt-dump-kind

# Oldest to newest. Each bulk entry costs about 4030 payload bytes, so the
# newest ~65 of them already fill the 262144-byte ceiling: the scan stops in
# the middle of the bulk run and never reaches 'echo zqxoutside'. The 80 here
# leaves room for the exact stopping point to move without invalidating the
# scenario. `y` padding and the `zqx` markers share no letters, so neither
# marker query can match a bulk entry through any matching tier.
typeset _zrt_pad=${(l:4000::y:)}
typeset -i _zrt_i
print -sr -- 'echo zqxoutside'
for (( _zrt_i = 1; _zrt_i <= 80; ++_zrt_i )); do
  print -sr -- "echo budget-bulk-${_zrt_i} ${_zrt_pad}"
done
print -sr -- 'echo zqxinside'

print MARK-RC-DONE
