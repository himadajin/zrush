# M1-3 検証用のテスト補完定義(minimal.zshrc から compinit 後に source される)
# 実在コマンドに依存しない決定的なケースを用意する。

# 1) 合成 -P/-S/-p/-s/-i/-I ケース: 挿入文字列の合成順序の検証
#    (単一候補。実挿入との突き合わせで <ipre><apre><hpre><word><hsuf><asuf><isuf> 順を確認)
_tst_ps() {
  compadd -P 'PRE:' -S ':SUF' -p 'hidp:' -s ':hids' -i 'ign:' -I ':igns' -- coreword
}
compdef _tst_ps tstps

# 2) _describe ケース: -O/-A 除外の実証と、表示文字列(-d)と挿入文字列の区別
_tst_desc() {
  local -a cmds=( 'add:add stuff to the index' 'remove:remove stuff' 'update:update stuff' )
  _describe -t commands 'test command' cmds
}
compdef _tst_desc tstdesc

# 3) _arguments ケース: オプション補完(--opt= の -S 付与、説明文)
_tst_args() {
  _arguments -S \
    '--verbose[be verbose]' \
    '--file=[input file]:file:_files' \
    '--mode=[mode]:mode:(fast slow)'
}
compdef _tst_args tstargs

# 4) compadd -U ケース: 語全体の書き換えを前提とする補完
_tst_u() {
  compadd -U -- replacement-word
}
compdef _tst_u tstu

# 5) _multi_parts ケース: セグメント単位補完(複数セグメント略記の挙動観察)
_tst_multi() {
  _multi_parts / '(/usr/local/bin /usr/local/lib /usr/share/doc)'
}
compdef _tst_multi tstmulti

# 6) 変数補完ケース用の一意な変数($ZRUSHUNIQ<TAB> が単一候補になる)
typeset -g ZRUSHUNIQVAR=1

# ---- M1-5: キャンセル・後始末検証用 ----

# 7) 遅い補完(3 秒)。fork の実 pid を $ZRUSH_SLOW_LOG に記録してから眠る。
_tst_slow() {
  print -r -- "SLOWPID=$sysparams[pid]" >>| ${ZRUSH_SLOW_LOG:-/dev/null}
  _zlog "tst_slow: pid logged to ${ZRUSH_SLOW_LOG:-(unset)}"
  command sleep 3
  compadd -- slow-one slow-two
}
compdef _tst_slow tstslow

# 8) ハング級の補完(15 秒)。fork の TMOUT=10 が補完実行中に効くかの観察と、
#    ハング中 fork のキャンセル検証用。
_tst_hang() {
  print -r -- "HANGPID=$sysparams[pid]" >>| ${ZRUSH_SLOW_LOG:-/dev/null}
  command sleep 15
  compadd -- hang-done
}
compdef _tst_hang tsthang

# 9) 部分ペイロードで異常死する補完(NUL 終端なしで fork が exit)。
#    親側の unterminated-payload 経路の検証用。
_tst_die() {
  compadd -- die-one                                      # 正常レコード 1 件
  print -rn -u ${_zrush_wfd:-1} -- "PARTIAL-NO-NUL" 2>/dev/null   # NUL なしの断片
  builtin exit 7
}
compdef _tst_die tstdie

# 10) fork 内から zrush のリクエスト関数を呼ぶ補完(再帰防止ガードの検証)。
#     ZRUSH_INTERNAL ガードが効けば即 return し、補完は正常に続くはず。
_tst_recur() {
  _zrush_request 2>/dev/null
  compadd -- recur-done
}
compdef _tst_recur tstrecur
