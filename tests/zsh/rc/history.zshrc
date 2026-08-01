# Host rc for the headless history-menu regression scenarios in
# tests/zsh/driver.zsh (issue #9: docs/internal/specs/behavior.md "履歴メニュー",
# docs/internal/contracts/cli-protocol.md "history profile").
# Required environment: ZRUSH_REPO, ZRUSH_TEST_TMP (see tests/zsh/rc/minimal.zshrc).
# Isolated HISTFILE + SAVEHIST=0: the fixture history below lives only in this
# throwaway shell's memory and is never written out or read back from the
# real ~/.zsh_history (AGENTS.md guardrail).
PS1='HP> '
HISTFILE=$ZRUSH_TEST_TMP/histfile-hist
HISTSIZE=1000
SAVEHIST=0
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-histtest
source $ZRUSH_REPO/zsh/zrush.zsh

# Test-only dump widgets (see tests/zsh/rc/minimal.zshrc for the ^Xb/^Xp precedent).
_zrt_dump_buffer() { _zlog "TESTBUF=${(qqqq)BUFFER}" }
zle -N _zrt-dump-buffer _zrt_dump_buffer
bindkey '^Xb' _zrt-dump-buffer

_zrt_dump_postdisplay() { _zlog "TESTPOST=${(qqqq)POSTDISPLAY}" }
zle -N _zrt-dump-postdisplay _zrt_dump_postdisplay
bindkey '^Xp' _zrt-dump-postdisplay

# ^Xk: listing kind/selection/position-count. Not observable from
# BUFFER/POSTDISPLAY alone -- several scenarios need to tell a history listing
# apart from a completion listing, or confirm the kind resets to 'none'
# (behavior.md "履歴メニュー").
_zrt_dump_kind() { _zlog "TESTKIND=kind=$_zrush_plan_kind sel=$_zrush_selected listing=$_zrush_listing npos=$_zrush_plan_npos" }
zle -N _zrt-dump-kind _zrt_dump_kind
bindkey '^Xk' _zrt-dump-kind

# ^Xu: raw history movement that bypasses zrush entirely, used to put HISTNO
# into "browsing" state (HISTNO != HISTCMD) ahead of testing zrush's
# select-prev/select-next delegation rule for that state
# (behavior.md "選択・キーバインド").
bindkey '^Xu' up-line-or-history

# ^Xl: a plain cursor-movement widget zrush never binds (not one of the six
# configurable actions), used to exercise a CURSOR-only external change while
# a history menu is open (driver.zsh's (h23); h4 only covers a BUFFER-text change).
bindkey '^Xl' backward-char

# ^Xz: CURSOR position, for scenarios that need to confirm a delegated widget
# actually moved the cursor (driver.zsh's (h14c)), not just that BUFFER text
# was left alone.
_zrt_dump_cursor() { _zlog "TESTCUR=$CURSOR" }
zle -N _zrt-dump-cursor _zrt_dump_cursor
bindkey '^Xz' _zrt-dump-cursor

# ^Xt: debounce timer / in-flight collection fd state, for confirming nothing
# is leaked across a send-break (driver.zsh's (h26); the existing (sb-1)
# regression in this driver only checks _zrush_plan_npos/_zrush_listing, not
# the timer/collection fds).
_zrt_dump_fds() { _zlog "TESTFDS=timer=$_zrush_timer_fd rfd=$_zrush_rfd wfd=$_zrush_wfd pty=${_zrush_pty:-<none>}" }
zle -N _zrt-dump-fds _zrt_dump_fds
bindkey '^Xt' _zrt-dump-fds

# Slow fake completion (behavior.md "候補収集" cancellation semantics,
# exercised by driver.zsh's (h17)). Defined here as plain script rather than
# a typed command, so this definition and its compdef registration never
# become history entries themselves (they would otherwise coincidentally
# contain "zrushtestslow"/"slowcand" and confuse the very query that scenario
# uses to open the history menu).
_zrushtestslow() { local -a m=(slowcandA slowcandB); sleep 0.5; compadd -a m }
compdef _zrushtestslow zrushtestslow

# Fixture history, oldest to newest ($history itself reports newest first, so
# the *last* print -s here is position 1 of an unfiltered history menu).
# Each entry's role in the driver.zsh scenarios is noted alongside it; keep
# this list and those scenarios in sync if either changes.
print -sr -- 'echo oldest'
print -sr -- 'zqxstatusfoo'                                    # prefix match for query 'zqx' (older)
print -sr -- 'echo mid1'
print -sr -- 'aa zqx bb'                                        # substring-only match for 'zqx' (newer: ordering test)
print -sr -- 'git status'
print -sr -- 'ls -la /tmp'
print -sr -- 'git commit -m "wip"'
print -sr -- 'echo dup'
print -sr -- 'echo dup'                                         # duplicate of the line above: only the newer one is a candidate
print -sr -- $'echo multi\nline2'                               # multi-line entry (raw newline in the history line itself)
print -sr -- $'echo *.glob \'sq\' "dq" \\bs -dash 日本語'        # meta-characters: passed through verbatim, never interpreted
print -sr -- $'echo ctrlone\x01tail'                            # SOH framing byte: whole line excluded from the payload
print -sr -- $'echo ctrltwo\x02tail'                            # STX framing byte: whole line excluded from the payload
print -sr -- 'note: ls fx/basic/al is a real path'              # substring match for a completion-triggering query
print -sr -- 'note: zrushtestslow is a fixture completion function'  # substring match for the slow-collection race query
print -sr -- 'echo newest'

print MARK-RC-DONE
