#!/bin/zsh -f
# zrush 手動検証用の起動スクリプト(plan.md「検証方法」の zsh 統合確認用)。
#
# 使い方:
#   zsh -f zsh/verify.zsh [作業ディレクトリ]
#
# ユーザーの実環境(~/.zshrc・履歴・config)には一切触れず、
# 隔離した ZDOTDIR で「compinit + zrush.zsh のみ」の対話シェルを起動する。
#   - 設定を試す場合: 起動後に表示される $XDG_CONFIG_HOME の下に
#     zrush/config.toml を書くと、次のプロンプトから自動反映される。
#   - デバッグトレース: ZRUSH_LOG=<file> を設定してから起動する。
#   - 終了は通常どおり exit / Ctrl-D。
emulate -L zsh

local here=${${(%):-%N}:A:h}
local work=$(mktemp -d ${TMPDIR:-/tmp}/zrush-verify.XXXXXX)
mkdir -p $work/zdot $work/xdg

print -r -- "zrush verify: sandbox=$work"
print -r -- "  config は $work/xdg/zrush/config.toml に置くと自動反映されます"

cat > $work/zdot/.zshrc <<EOF
autoload -Uz compinit
compinit -u -d $work/zcompdump
source $here/zrush.zsh
PS1='zrush-verify %1~ %# '
EOF

cd ${1:-$PWD}
XDG_CONFIG_HOME=$work/xdg ZDOTDIR=$work/zdot exec zsh -d -i
