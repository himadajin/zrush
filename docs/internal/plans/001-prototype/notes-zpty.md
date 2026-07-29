# notes-zpty: M1 収集方式の結論と計測値

M1(zpty による compsys 候補収集の技術検証)の成果記録。
検証スクリプト(`spikes/m1-zpty/`)は役目を終えたため削除済み(必要なら git 履歴を参照)。
成立した方式は `zsh/zrush.zsh` と `tests/zsh/driver.zsh` に移植済み。

## 結論: zpty 方式は成立(go)

「zpty 内部シェル(現在シェルの fork)で compsys を走らせ、複数候補+メタデータを
非同期で吸い出す」は、以下の構成で全必須検証項目が成立した。
フォールバック(同期収集/fish 型)は不要。

## 成立した方式

```
対話シェル(ウィジェット or zle -F -w ハンドラ文脈)
  ├ 匿名 pipe を作成(mkfifo → 両端 open → unlink)
  ├ zpty zrush-w<gen> worker   … 現在シェルの fork。write 側 fd を継承
  │    worker(fork 内):
  │      ├ ZRUSH_INTERNAL=1(再帰ガード)、継承フック無効化、SAVEHIST=0
  │      ├ pipe 先頭に自分の pid を申告(キャンセル用)
  │      ├ LBUFFER に広げクエリを注入し、zle <list-choices型ウィジェット> を直接呼ぶ
  │      ├ compadd を差し替え: -O/-A/-D は即委譲、
  │      │  builtin compadd -A/-D でマッチ判定を本体に委譲し、
  │      │  生存候補+メタデータを NUL 区切りレコードで pipe へバッチ書き込み
  │      └ always で write fd close + exit → pipe の EOF が完了通知
  ├ 親は zpty 作成直後に write 側 copy を close
  └ zle -F -w ハンドラで sysread 部分読み・再組み立て、EOF で確定
```

- **駆動**: fork 内での `zle` 直接呼び(zsh-autosuggestions sync 方式)。
  zrush は常にウィジェット文脈から fork するため常用可能。
  vared 方式は zle 活性文脈からの fork では開始できず不要(実測で確定)。
- **搬出**: 候補データは pty に流さず**継承 pipe fd** で運ぶ。
  tty の改行変換・エコーの影響を受けないため stty 清浄化も番兵も不要。
  完了通知は pipe の EOF(補完ウィジェットが関数を呼ばず戻っても must-fire)。
- **キャンセル**: 新リクエストごとに旧リクエストを破棄:
  `kill -INT -<pgid>`(worker が pipe 先頭で自己申告した pid)→ `zpty -d` → fd close。
  stale 結果は旧 rfd の `zle -F` 解除+close で物理遮断(旧 fork の遅延書き込みは
  EPIPE で fork が死ぬだけで親は無傷)。

## 計測値(macOS arm64 / zsh 5.9 / 中央値)

| ケース | 隔離ホスト (RSS 5.9MB) | 実 .zshrc+実履歴 (RSS 7.8MB) |
|---|---|---|
| ファイル補完(docs/) | 35ms | 35ms |
| git サブコマンド 141 件 | 165ms(初回 239ms) | 166ms |
| 空語→全コマンド 4,199 件 / 100KB | 125ms | 0 件(ZAC 共存の制約、下記) |
| 3 万件ディレクトリ / 2.1〜3.0MB | 2.5s | 3.3s |
| fork(zpty 作成〜worker 開始) | 3〜4ms | 3〜6ms |

- 巨大ディレクトリでも「一覧が遅れて出る」だけで入力は非ブロック(収集中のコマンド実行を実証)。
- 連打 10 回(100ms 間隔)で結果はちょうど 1 回・子プロセス蓄積なし。
- fork コストの親メモリ比例は本環境では問題にならず(実 rc が軽量)。
- 内訳(warm): fifo 準備 ~8ms(mkfifo/rm の外部コマンド)+ fork ~4ms + compsys 5ms〜。
- 速度要件「zsh-autocomplete と同等以上」は日常クエリ域で満たす見込み
  (ZAC 自体が遅延 50ms+収集時間の世界)。
- 候補数上限は不要と判断する材料が揃った(3 万件/3MB でも壊れない)。
  打ち切りは最適化として必要になったときに導入する。

## 検証で確定した設計事項

### 置換範囲モデル(plan.md の決定事項に反映済み)

- 再構成順序 `<IPREFIX><i><P><p><word><s><S><I>` が素の compsys の実挿入と一致
  (変数・オプション・describe・ファイル・compadd -U・_multi_parts・`~/` の全ケース)。
- ディレクトリ末尾 `/` は compadd 引数に現れない。realdir
  (`${${(Qe)~${:-$IPREFIX$hpre}}}`、非クォート+二重 `${}` 必須)からの合成で一致。
- 部分パス略記(`pp/u/lo`)では hpre が展開済み(`pp/usr/`)で返るため、
  「捕獲接頭辞(IPREFIX+hpre)が保持バッファ末尾と一致すれば末尾置換、
  不一致なら現在語全体に拡張」の規則を採用(全ケース一致を実証)。
- `~/` は hpre 未展開のまま返るため常に末尾置換側になり、`~` 非展開は維持される。

### M2(cli-protocol / Rust)への引き継ぎ

- compsys が渡す候補語は**挿入用クォート済み**(`space\ name.txt` 形式)。
  挿入にはそのまま、マッチング・表示には `${(Q)}` 復元形を使う。プロトコルに両形を明記する。
- スパイクのレコード区切り(`\1`/`\2`)は値衝突で壊れ得る。
  本実装のプロトコルは長さプレフィックスかエスケープを採用する。
- pipe への書き込みは **compadd 呼び出し単位のバッチが必須**
  (レコード毎 print は 959 reads/115ms → バッチで 18 reads/105ms)。
- realdir の「dir なら `/` 付与」判定は cwd 依存 → zsh 側で判定するか realdir を Rust に渡す。

### M3(zle 統合)への引き継ぎ

- 収集開始は plain ウィジェット・`zle -F -w` ハンドラのどちらの文脈からでも成立(実証済み)。
- worker の pid 自己申告(pipe 先頭レコード)と `kill -INT -pgid` によるキャンセルを移植する。
  `zpty -d` の HUP は外部コマンド待ち中の fork に効かない(トラップ延期)。
- `zpty -t` は使用禁止(無出力の子で数秒ブロックする)。TMOUT は補完実行中に発火せず保険にならない。
- fork 衛生: 継承フック(precmd/preexec/chpwd/zshaddhistory/periodic/zshexit)と
  zle-* フックの無効化、`emulate -L zsh` + 統制 setopt、SAVEHIST=0、`zpty -wn`(改行付加防止)。
- `zle -F -w` のハンドラは `zle -N` でのウィジェット登録が必須(忘れると無言で発火しない)。
- compinit 済み検知は `$+functions[_main_complete]` で行う
  (zsh-autocomplete が compinit を代行する構成も正しく検出できる)。

### M5(日常投入)への引き継ぎ

- **zsh-autocomplete 共存ホストではコマンド位置の空語収集が 0 件になる**
  (ZAC の compsys パッチが空行補完を拒否。ファイル・git・オプション補完は共存でも正常)。
  ドッグフーディングは ZAC を外してから開始する(plan M5 のとおり)。
  実環境での空語収集の計測はそのときに再実施する。
- 広げ規則の現在語特定は「最後の空白より後ろ」の素朴規則で実装した。
  クォート内空白は未対応。実装時に compsys の語分割との整合を再検討する。

## 検証ハーネスの知見(スパイク運用向け)

- ドライバが pty を読まない区間があるとホストが `tcsetattr(TCSADRAIN)` で
  永久ブロックする。待ちループは常に pty を drain しながら回す。
- zle 再初期化時の typeahead フラッシュでコマンド直後のキー送信が消える。
  プロンプト同期(マーカー往復)をしてから次を送る。
- 実 .zshrc ホストでの検証はコマンドを先頭スペース付きで送る(hist_ignore_space)。
  履歴ファイルへの書き込みゼロを mtime/ハッシュで確認する。
