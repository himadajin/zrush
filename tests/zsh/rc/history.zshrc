# Host rc for the headless history-menu regression scenarios, loaded through
# ZDOTDIR by the Rust pty harness (tests/driver/) (issue #9:
# docs/internal/specs/behavior.md "履歴メニュー",
# docs/internal/contracts/cli-protocol.md "history profile").
# Required environment: ZRUSH_REAL_BIN, ZRUSH_TEST_TMP (see tests/zsh/rc/minimal.zshrc).
# Isolated HISTFILE + SAVEHIST=0: the fixture history below lives only in this
# throwaway shell's memory and is never written out or read back from the
# real ~/.zsh_history (AGENTS.md guardrail).
PS1='HP> '
HISTFILE=$ZRUSH_TEST_TMP/histfile-hist
HISTSIZE=1000
SAVEHIST=0
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-histtest
source <($ZRUSH_REAL_BIN init zsh)

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

# ^Xi: the history index latch and the fingerprint baseline it carries, which
# no other dump exposes -- the scenarios in tests/driver/hist_index.rs need to
# tell "the worker's index is usable" from "the next menu op re-snapshots".
# A generation of 0 is the single unusable state (an invalid latch and a dirty
# index are one thing), so there is no separate dirty field to dump
# (behavior.md "履歴メニュー").
_zrt_dump_hist() { _zlog "TESTHIST=gen=$_zrush_hist_gen head=$_zrush_hist_head count=$_zrush_hist_count unacked=$_zrush_hist_unacked" }
zle -N _zrt-dump-hist _zrt_dump_hist
bindkey '^Xi' _zrt-dump-hist

# ^Xu: raw history movement that bypasses zrush entirely, used to put HISTNO
# into "browsing" state (HISTNO != HISTCMD) ahead of testing zrush's
# select-prev/select-next delegation rule for that state
# (behavior.md "選択・キーバインド").
bindkey '^Xu' up-line-or-history

# ^Xl: a plain cursor-movement widget zrush never binds (not one of the six
# configurable actions), used to exercise an external change that moves CURSOR
# while leaving BUFFER text alone.
bindkey '^Xl' backward-char

# ^Xz: CURSOR position, for scenarios that need to confirm a delegated widget
# actually moved the cursor, not just that BUFFER text was left alone.
_zrt_dump_cursor() { _zlog "TESTCUR=$CURSOR" }
zle -N _zrt-dump-cursor _zrt_dump_cursor
bindkey '^Xz' _zrt-dump-cursor

# ^Xt: debounce timer / in-flight collection fd state, for confirming that a
# send-break leaves behind neither an armed timer nor a live collection.
# Neither is observable through the plan state (_zrush_plan_npos/
# _zrush_listing) that the other send-break scenarios read.
_zrt_dump_fds() { _zlog "TESTFDS=timer=$_zrush_timer_fd rfd=$_zrush_rfd wfd=$_zrush_wfd pty=${_zrush_pty:-<none>}" }
zle -N _zrt-dump-fds _zrt_dump_fds
bindkey '^Xt' _zrt-dump-fds

# ^Xq: deterministic test-only transport teardown before replacing the private
# binary. Unlike typing an internal function call, this does not pollute history.
_zrt_teardown_worker() { _zrush_worker_shutdown }
zle -N _zrt-teardown-worker _zrt_teardown_worker
bindkey '^Xq' _zrt-teardown-worker

# ^Xe: the real event number for the newest fixture line. Resolve it lazily
# in the widget so every `print -s` fixture below has entered `$history`.
_zrt_dump_newest_event() {
  local event
  for event in "${(@k)history}"; do
    [[ $history[$event] == 'echo newest' ]] && { _zlog "TESTEVENT=$event"; return 0 }
  done
  _zlog 'TESTEVENT=<missing>'
}
zle -N _zrt-dump-newest-event _zrt_dump_newest_event
bindkey '^Xe' _zrt-dump-newest-event

# Slow fake completion, for the scenarios that act while a collection is still
# in flight (behavior.md "候補収集" cancellation semantics). Defined here as
# plain script rather than a typed command, so this definition and its compdef
# registration never become history entries themselves (they would otherwise
# coincidentally contain "zrushtestslow"/"slowcand" and confuse the very query
# those scenarios use to open the history menu).
_zrushtestslow() { local -a m=(slowcandA slowcandB); sleep 0.5; compadd -a m }
compdef _zrushtestslow zrushtestslow

# Fixture history, oldest to newest ($history itself reports newest first, so
# the *last* print -s here is position 1 of an unfiltered history menu).
# Each entry's role in the scenarios that consume it is noted alongside it;
# keep this list and those scenarios in sync if either changes.
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
