# M1-4: 広げクエリ(セグメント保持規則)の実装
#
# plan.md 決定事項:
#   現在語(カーソルまで)のうち、最後の `/` または `=` より後ろを空にして収集する。
#   区切りがなく `-` で始まる語は先頭のダッシュ列を保持する。
#   それ以外は語全体を空にする。削った末尾が Rust に渡す fuzzy クエリになる。
#
# 純関数(pty 不要)。後で zsh/zrush.zsh に移植する部品。
#
# 制限(スパイク時点): 現在語の特定は「最後の空白文字より後ろ」の素朴な規則。
# クォートされた空白(`ls space\ name`)は考慮しない(実装時に compsys の語分割との
# 整合を再検討する)。カーソルは末尾想定(呼び出し側が $LBUFFER を渡す)。

zrush_widen() {  # $1 = カーソルまでのバッファ
                 # → REPLY_WIDENED(広げ後バッファ) REPLY_QUERY(fuzzy クエリ)
                 #   REPLY_KEEP(現在語のうち保持した部分)
  emulate -L zsh
  setopt extendedglob
  local buf=$1
  local word=${buf##*[[:space:]]}          # 現在語 = 最後の空白より後ろ(空白なしなら全体)
  local pre=${buf[1,$#buf-$#word]}         # 現在語より前の部分
  local keep= query=
  if [[ $word == *[/=]* ]]; then
    query=${word##*[/=]}                   # 最後の / or = より後ろ
    keep=${word[1,$#word-$#query]}
  elif [[ $word == -* ]]; then
    keep=${(M)word##-##}                   # 先頭のダッシュ列
    query=${word[$#keep+1,-1]}
  else
    query=$word                            # 語全体を空にする
  fi
  typeset -g REPLY_WIDENED=$pre$keep REPLY_QUERY=$query REPLY_KEEP=$keep
}
