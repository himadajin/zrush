# ヘッドレス回帰テスト用ホスト rc(tests/zsh/driver.zsh が ZDOTDIR 経由で読み込む)
# 必要な環境変数: ZRUSH_REPO(リポジトリルート)、ZRUSH_TEST_TMP(隔離 tmp)
PS1='HP> '
autoload -Uz compinit
compinit -u -d ${ZRUSH_TEST_TMP:-${TMPDIR:-/tmp}}/zcompdump-zrush-test
source $ZRUSH_REPO/zsh/zrush.zsh

# テスト支援: 現在の BUFFER を ZRUSH_LOG へダンプするウィジェット(^Xb)。
# ドライバが確定・置換結果を正確に検証するために使う(本体には含めない)。
_zrt_dump_buffer() { _zlog "TESTBUF=${(qqqq)BUFFER}" }
zle -N _zrt-dump-buffer _zrt_dump_buffer
bindkey '^Xb' _zrt-dump-buffer

print MARK-RC-DONE
