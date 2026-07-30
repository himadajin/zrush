#!/bin/zsh -f
# Launch an isolated interactive shell for manual zrush integration verification.
#
# Usage:
#   zsh -f zsh/verify.zsh [working-directory]
#
# This never touches the user's ~/.zshrc, history, or config. It starts an interactive
# shell with only compinit and zrush.zsh under an isolated ZDOTDIR.
#   - To test configuration, write zrush/config.toml below the printed
#     $XDG_CONFIG_HOME; changes apply at the next prompt.
#   - For debug traces, set ZRUSH_LOG=<file> before launch.
#   - Exit normally with exit or Ctrl-D.
emulate -L zsh

local here=${${(%):-%N}:A:h}
local work=$(mktemp -d ${TMPDIR:-/tmp}/zrush-verify.XXXXXX)
mkdir -p $work/zdot $work/xdg

print -r -- "zrush verify: sandbox=$work"
print -r -- "  config changes in $work/xdg/zrush/config.toml are applied automatically"

cat > $work/zdot/.zshrc <<EOF
autoload -Uz compinit
compinit -u -d $work/zcompdump
source $here/zrush.zsh
PS1='zrush-verify %1~ %# '
EOF

cd ${1:-$PWD}
XDG_CONFIG_HOME=$work/xdg ZDOTDIR=$work/zdot exec zsh -d -i
