#!/bin/zsh -f
# Launch an isolated interactive shell for manual zrush integration verification.
#
# Usage:
#   zsh -f zsh/verify.zsh [working-directory]
#   Prerequisite: cargo build --release completed.
#
# This never touches the user's ~/.zshrc, history, or config. It starts an interactive
# shell with only compinit and the embedded zrush script (via `zrush init zsh`)
# under an isolated ZDOTDIR, with its own HISTFILE seeded with a small fixture
# history so the history menu has something to list from the first ↑.
#   - To test configuration, write zrush/config.toml below the printed
#     $XDG_CONFIG_HOME; changes apply at the next prompt.
#   - For debug traces, set ZRUSH_LOG=<file> before launch.
#   - To verify the history index across shells (share_history imports, which the
#     menu has to notice), launch a second shell into the same sandbox and
#     `setopt share_history` in both:
#       ZRUSH_VERIFY_DIR=<the sandbox printed below> zsh -f zsh/verify.zsh
#     A reused sandbox keeps the history the previous shell saved into it.
#   - To check coexistence with the plugins actually installed on this machine,
#     point ZRUSH_VERIFY_PRE / ZRUSH_VERIFY_POST at them; they are sourced
#     before and after zrush, the order docs/user/install.md documents. The
#     automated suite covers this against doubles, so a released plugin that
#     changed its technique shows up here and nowhere else:
#       ZRUSH_VERIFY_PRE=/opt/homebrew/share/zsh-abbr/zsh-abbr.zsh \
#       ZRUSH_VERIFY_POST=/opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
#         zsh -f zsh/verify.zsh
#   - Exit normally with exit or Ctrl-D.
emulate -L zsh

local here=${${(%):-%N}:A:h}
local bin=$here/../target/release/zrush
[[ -x $bin ]] || { print -u2 "FATAL: zrush binary not found (cargo build --release)"; exit 1 }
[[ $here/zrush.zsh -nt $bin ]] && { print -u2 "FATAL: zsh/zrush.zsh is newer than the built binary; run cargo build --release"; exit 1 }
local pre= post= plugin
for plugin in ${ZRUSH_VERIFY_PRE:-} ${ZRUSH_VERIFY_POST:-}; do
  [[ -r $plugin ]] || { print -u2 "FATAL: cannot read $plugin"; exit 1 }
done
[[ -n ${ZRUSH_VERIFY_PRE:-} ]] && pre="source $ZRUSH_VERIFY_PRE"
[[ -n ${ZRUSH_VERIFY_POST:-} ]] && post="source $ZRUSH_VERIFY_POST"

# Absolute, because the shell below is launched from another directory.
local work=${${ZRUSH_VERIFY_DIR:-$(mktemp -d ${TMPDIR:-/tmp}/zrush-verify.XXXXXX)}:A}
mkdir -p $work/zdot $work/xdg

# Seed history only when the sandbox has none, so a reused sandbox keeps what
# its previous shell saved. This file, not the user's ~/.zsh_history, is the
# only history the shell below reads or writes.
if [[ ! -e $work/history ]]; then
  print -rl -- \
    'git status' \
    'git commit -m "seeded fixture"' \
    'ls -la /tmp' \
    'echo one two three' \
    'echo *.glob "quoted" -dash 日本語' \
    'grep -rn zrush docs' \
    > $work/history
fi

print -r -- "zrush verify: sandbox=$work"
print -r -- "  config changes in $work/xdg/zrush/config.toml are applied automatically"
print -r -- "  history is $work/history (seeded; the real ~/.zsh_history is untouched)"

cat > $work/zdot/.zshrc <<EOF
HISTFILE=$work/history
HISTSIZE=5000
SAVEHIST=5000
autoload -Uz compinit
compinit -u -d $work/zcompdump
$pre
source <($bin init zsh)
$post
PS1='zrush-verify %1~ %# '
EOF

cd ${1:-$PWD}
XDG_CONFIG_HOME=$work/xdg ZDOTDIR=$work/zdot exec zsh -d -i
