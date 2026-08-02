#!/bin/zsh -f
# Non-pty unit tests for the zsh-side worker transport write path:
# _zrush_worker_flush's `syswrite` call that ships the pending transmit
# buffer to the worker process.
#
# Usage:
#   zsh -f tests/zsh/transport.zsh
#     No arguments, no pty, no terminal. The zrush binary is NOT needed and no
#     worker process is started: this runner only sources zsh/zrush.zsh with
#     ZRUSH_NO_INIT=1 (the test seam at the end of that file) and calls
#     _zrush_worker_flush directly against an fd opened on a temp file.
#     $HOME and $XDG_CONFIG_HOME are redirected to a fresh mktemp directory,
#     so the real ~/.zshrc, shell history and ~/.config/zrush are untouched.
#
# Scope: vectors.zsh covers the capture encoder and the plan decoder; this
# file is the home for non-pty unit tests of the zsh-side worker transport
# instead. Specifically: _zrush_worker_flush passes its data argument to
# `syswrite` after `--`, so that syswrite's own option parser never inspects
# the transmit buffer's bytes, no matter what they are (see
# docs/internal/specs/behavior.md's partial-write/backpressure section for
# why the buffer can start anywhere after a short write).
emulate -L zsh
setopt extended_glob
zmodload zsh/system || { print -u2 FATAL: system; exit 1 }

typeset -g HERE=${${(%):-%N}:A:h}
typeset -g REPO=${HERE:h:h}

typeset -gi PASS=0 FAIL=0
out() { print -r -u2 -- "$@" }
ok()  { out "PASS: $1"; (( ++PASS )) }
ng()  { out "FAIL: $1"; (( ++FAIL )) }

typeset -g WORK=$(mktemp -d ${TMPDIR:-/tmp}/zrush-transport.XXXXXX)
export HOME=$WORK/home             # isolated; never the real home
export XDG_CONFIG_HOME=$WORK/xdg   # isolated; never the real ~/.config/zrush
export HISTFILE=$WORK/histfile     # nothing writes history, but never the real one either
unset ZDOTDIR
mkdir -p $HOME $XDG_CONFIG_HOME

{
  typeset -g ZRUSH_NO_INIT=1
  source $REPO/zsh/zrush.zsh || { out "FATAL: cannot source zrush.zsh"; exit 1 }
  unset ZRUSH_NO_INIT
  (( $+functions[_zrush_worker_flush] )) || { out "FATAL: _zrush_worker_flush undefined after source"; exit 1 }
  (( $+functions[_zrush_encode_message] )) || { out "FATAL: _zrush_encode_message undefined after source"; exit 1 }
  (( _zrush_enabled )) && { out "FATAL: ZRUSH_NO_INIT did not suppress initialization"; exit 1 }

  # Build a representative nested-netstring message body (see
  # _zrush_encode_message, zsh/zrush.zsh:800): a "plan" request carrying
  # candidate-style fields ("w"$'\1' tag), the first of which has value $1,
  # then return only the tail of the encoded bytes starting at that value.
  # This stands in for the buffer _zrush_worker_flush is left holding after a
  # short write landed mid-field: it opens mid-value and runs to the end of
  # the message, so the candidates after the marker are part of the remainder.
  tail_from_field() {  # $1=field value (must appear verbatim exactly once) -> REPLY
    emulate -L zsh
    setopt nomultibyte
    local LC_ALL=C
    local marker=$1
    _zrush_encode_message plan 1 /some/path compsys somequery fuzzy 0 1 24 80 \
      "w"$'\1'"$marker" "w"$'\1'"README.md" "w"$'\1'"Makefile"
    local full=$REPLY
    local prefix=${full%%$marker*}
    typeset -g REPLY=${full[$#prefix+1,-1]}
  }

  # Drive _zrush_worker_flush directly: point _zrush_worker_wfd at a temp
  # file, prime _zrush_worker_tx with $2, flush once, and leave the result in
  # $flush_st / $WORK/$1.bin for the caller to check.
  flush_case() {  # $1=label $2=tx-buffer
    emulate -L zsh
    local label=$1 tx=$2
    local -i wfd
    exec {wfd}> $WORK/$label.bin
    typeset -g _zrush_worker_wfd=$wfd _zrush_worker_rfd=-1 _zrush_worker_setup_fd=-1
    typeset -g _zrush_worker_retry_fd=-1 _zrush_worker_drain_fd=-1
    typeset -g _zrush_worker_pid=-1 _zrush_worker_setup_pid=-1 _zrush_worker_setup_req=
    typeset -g _zrush_worker_tx=$tx
    _zrush_worker_flush
    typeset -gi flush_st=$?
    # On success the fd is still open (nothing failed); on failure
    # _zrush_worker_session_fail already closed it via the transport
    # teardown. Either way, don't touch it again here.
  }

  # ---------------- dash-led buffer: unknown-option case ----------------
  # A buffer beginning with -f (e.g. a dash-led completion candidate such as
  # -f/--force reaching the head of the buffer after a short write) must not
  # be parsed as a syswrite option.
  tail_from_field -f
  local case_f=$REPLY
  print -rn -- "$case_f" >| $WORK/dash-f.expected.bin
  flush_case dash-f "$case_f"
  if (( flush_st == 0 )) && cmp -s $WORK/dash-f.expected.bin $WORK/dash-f.bin \
     && [[ -z $_zrush_worker_tx ]]; then
    ok "flush: buffer beginning with -f is written verbatim, not parsed as an option"
  else
    ng "flush: dash-f case status=$flush_st tx-remaining=${#_zrush_worker_tx}"
  fi

  # ---------------- dash-led buffer: bundled-option case ----------------
  # -c takes an argument, so without the separator a buffer beginning with
  # -cvar bundles as `-c var` and swallows the data word itself. That is a
  # different syswrite parse path from the unknown-option case above: it fails
  # on a missing argument rather than on the leading byte.
  tail_from_field -cvar
  local case_c=$REPLY
  print -rn -- "$case_c" >| $WORK/dash-c.expected.bin
  flush_case dash-c "$case_c"
  if (( flush_st == 0 )) && cmp -s $WORK/dash-c.expected.bin $WORK/dash-c.bin \
     && [[ -z $_zrush_worker_tx ]]; then
    ok "flush: buffer beginning with -cvar is written verbatim, not bundled as -c var"
  else
    ng "flush: dash-c case status=$flush_st tx-remaining=${#_zrush_worker_tx}"
  fi

  out "SUMMARY: PASS=$PASS FAIL=$FAIL"
} always {
  [[ -n $WORK && $WORK == */zrush-transport.* ]] && rm -rf $WORK
}
(( FAIL == 0 ))
