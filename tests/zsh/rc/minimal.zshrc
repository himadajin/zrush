# ヘッドレス回帰テスト用ホスト rc(tests/zsh/driver.zsh が ZDOTDIR 経由で読み込む)
# 必要な環境変数: ZRUSH_REPO(リポジトリルート)、ZRUSH_TEST_TMP(隔離 tmp)
PS1='HP> '
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-test
source $ZRUSH_REPO/zsh/zrush.zsh
print MARK-RC-DONE
