#!/bin/zsh -f
# Step A: pipe fd 継承のミニスパイク
#
# 検証: 親シェルで開いた pipe の write 側 fd が zpty fork(現在シェルの fork)に
# 継承され、fork 内からそこへ書いた NUL 区切りデータを親が読めるか。
# 併せて:
#   - EOF 終端(親が write 側 copy を閉じる+fork の exit/close で read 側に EOF)
#   - 64KB パイプバッファ超のペイロードの部分読み再組み立て
#   - fork 内での外部コマンド実行と、外部コマンドへの fd 継承
#
# 同期は pipe の EOF のみで行い、pty 出力(zpty -r のパターン読み)には依存しない。
# 理由: macOS では fork が pty へ書いて即 exit すると出力が失われることがあり、
# パターン付き zpty -r は永遠にマッチせずビジーループする(probe6 で実証)。
#
# 実行: zsh -f 01-fd-inherit.zsh
# 出力: PASS/FAIL 行。最後に SUMMARY。
emulate -L zsh
setopt extended_glob

zmodload zsh/zpty   || { print -r "FATAL: zsh/zpty unavailable"; exit 1 }
zmodload zsh/system || { print -r "FATAL: zsh/system unavailable"; exit 1 }

typeset -gi PASS=0 FAIL=0
ok() { print -r -- "PASS: $1"; (( ++PASS )) }
ng() { print -r -- "FAIL: $1"; (( ++FAIL )) }

# 匿名 pipe の構成: FIFO を作り、両端を親の fd として開いてから unlink する。
# rw (O_RDWR) を先に開くのは、reader/writer 不在での open ブロックを避けるため。
typeset -gi RFD=-1 WFD=-1
mkpipe() {
  local fifo=${TMPDIR:-/tmp}/zrush-01-$$-$RANDOM.fifo
  mkfifo $fifo || return 1
  local rw
  exec {rw}<>$fifo
  exec {RFD}<$fifo
  exec {WFD}>$fifo
  exec {rw}>&-
  rm -f $fifo
}

# 親: 自分の write 側 copy を閉じ、EOF まで読み集める。
# 戻り値 0 = EOF で正常終端。$REPLY_BUF に全データ。
drain() {
  local -i timeout=${1:-10}
  typeset -g REPLY_BUF=
  typeset -gi REPLY_NREADS=0
  exec {WFD}>&-
  local chunk= st=0
  while :; do
    sysread -t $timeout -i $RFD chunk; st=$?
    (( st == 0 )) || break
    REPLY_BUF+=$chunk
    (( ++REPLY_NREADS ))
  done
  exec {RFD}<&-
  (( st == 5 ))  # 5 = EOF
}

# NUL 区切りレコードへ分割(末尾 NUL を要求し、除去してから分割)
# 注意: "${(@0)...}" は末尾 NUL の後ろに空要素を作るため、先に末尾 NUL を落とす。
split_records() {  # $1=data -> reply 配列
  typeset -ga reply=()
  [[ $1 == *$'\0' ]] || return 1
  reply=( "${(@0)${1%$'\0'}}" )
}

# ---------------------------------------------------------------- test 1: 小メッセージ
# fork は fd 番号(継承したシェル変数 $WFD)だけを頼りに書く。パス経由 open はしない。
worker_small() {
  exec {RFD}<&-
  if print -rn -u $WFD -- $'alpha\0beta beta\0we\nird\0' 2>/dev/null; then
    : # 成否は親がデータ内容で判定する(pty 出力には依存しない)
  fi
  exec {WFD}>&-
}

if mkpipe && zpty a1 worker_small; then
  if drain 10; then
    ok "test1: EOF arrived after fork exit (parent wfd closed first)"
  else
    ng "test1: pipe read did not end with EOF"
  fi
  if split_records "$REPLY_BUF" && (( $#reply == 3 )) &&
     [[ $reply[1] == alpha && $reply[2] == "beta beta" && $reply[3] == $'we\nird' ]]; then
    ok "test1: fork wrote via inherited fd; 3 NUL-delimited records intact (space + embedded newline)"
  else
    ng "test1: records mismatch: ${(qqqq)REPLY_BUF}"
  fi
  zpty -d a1 2>/dev/null
else
  ng "test1: setup (mkpipe/zpty) failed"
fi

# ---------------------------------------------------------------- test 2: 1MiB ペイロード
# パイプバッファ(64KB)を大きく超える量を fork が書く。fork は途中で write ブロックするが、
# 親が読み進めれば全量届くこと、親側で部分読みの再組み立てが必要なことを確認する。
typeset -gi NREC=1024
worker_big() {
  exec {RFD}<&-
  local rec=${(l:1023::x:)} i=
  for (( i = 1; i <= NREC; ++i )); do
    print -rn -u $WFD -- $rec$'\0' 2>/dev/null || return
  done
  exec {WFD}>&-
}

if mkpipe && zpty a2 worker_big; then
  if drain 10; then
    ok "test2: EOF after 1MiB payload"
  else
    ng "test2: pipe read did not end with EOF (got $#REPLY_BUF bytes)"
  fi
  split_records "$REPLY_BUF"
  if (( $#REPLY_BUF == NREC * 1024 && $#reply == NREC )); then
    ok "test2: $#REPLY_BUF bytes / $#reply records reassembled (sysread calls: $REPLY_NREADS)"
  else
    ng "test2: got $#REPLY_BUF bytes, $#reply records (want $((NREC*1024)) / $NREC)"
  fi
  if (( REPLY_NREADS > 1 )); then
    ok "test2: partial reads occurred as expected (nreads=$REPLY_NREADS > 1)"
  else
    ng "test2: expected multiple partial reads, got nreads=$REPLY_NREADS"
  fi
  zpty -d a2 2>/dev/null
else
  ng "test2: setup (mkpipe/zpty) failed"
fi

# ---------------------------------------------------------------- test 3: 外部コマンド
# fork 内で外部コマンドが実行でき、外部コマンド(exec を伴う)にも fd が継承されること。
worker_ext() {
  exec {RFD}<&-
  local out
  out=$(/bin/ls /dev/fd 2>&1)
  print -rn -u $WFD -- "fds:${out//$'\n'/,}"$'\0'
  /bin/echo -n "external-direct" >&$WFD
  print -rn -u $WFD -- $'\0'
  exec {WFD}>&-
}

if mkpipe && zpty a3 worker_ext; then
  if drain 10 && split_records "$REPLY_BUF" && (( $#reply == 2 )); then
    if [[ $reply[1] == fds:*${WFD}* && $reply[2] == external-direct ]]; then
      ok "test3: external commands run in fork; fd $WFD visible in /dev/fd and usable via exec (${reply[1]})"
    else
      ng "test3: unexpected records: ${(qqqq)reply}"
    fi
  else
    ng "test3: drain/split failed: ${(qqqq)REPLY_BUF}"
  fi
  zpty -d a3 2>/dev/null
else
  ng "test3: setup failed"
fi

print -r -- "SUMMARY: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
