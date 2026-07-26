# 検証ホスト用の最小 rc。
# driver.zsh が ZDOTDIR=<this dir> で zsh -d -i を起動すると、この .zshrc だけが読まれる
# (-d = NO_GLOBAL_RCS。ユーザーの ~/.zshrc には触れない)。
# 必要な環境変数: ZRUSH_SPIKE_DIR(spike ディレクトリ)、ZRUSH_TEST_TMP(隔離 tmp)

PS1='HP> '
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-spike
# 既定は v1(メタデータ捕獲)。ZRUSH_CAPTURE=02-capture-v0.zsh で v0 に切替可能。
source $ZRUSH_SPIKE_DIR/${ZRUSH_CAPTURE:-03-capture-v1.zsh}
source $ZRUSH_SPIKE_DIR/rc/test-completers.zsh
print MARK-RC-DONE
