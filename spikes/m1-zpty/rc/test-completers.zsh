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
