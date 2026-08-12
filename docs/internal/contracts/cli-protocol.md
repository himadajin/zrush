# cli-protocol: zsh ↔ Rust CLI の境界仕様

zrush.zsh(zsh 側)と `zrush` バイナリ(Rust 側)の入出力仕様。
この文書が真実であり、コードはこれに追従する。

## この文書の読み方

節の冒頭に「検証:」行がある節は、そこに挙げたテストがその節の規範を機械検証している。
挙げられた規範を破れば、そのテストが落ちる。
検証行の無い節、および検証行が挙げていない規範は、散文だけが規範の在処であり、破ってもテストは落ちない
(自由に変えてよいという意味ではない。この文書が真実であることは変わらない)。

節の一部だけが機械検証されている場合は、検証行がその範囲を明示する。
検証行が挙げるのはテストの所在(ディレクトリまたはファイル)までで、個々のベクタ名は挙げない。
ゴールデンベクタ群の構成・追加手順・カバー範囲は `tests/vectors/README.md`。

## ビルドスタンプ

- `BUILD_STAMP` は Cargo build script が実際の package rebuild ごとに生成する一意な lowercase hex ASCII 値である。
  同じバイナリに含まれる Rust worker、`zrush config`、`zrush init zsh` は必ず同じ値を使う。
- `zrush init zsh` は期待値 `_ZRUSH_EXPECTED_BUILD_STAMP` を埋め込みスクリプトより前に注入し、
  `zrush config` は実値 `ZRUSH_BUILD_STAMP` を出力する。zrush.zsh は source 時に両者を照合する。
  worker 握手も同じスタンプを照合する。異なるビルド間の互換性は保証せず、単一規則
  **同一 build stamp ⇔ 互換**を用いる。
- 照合の機会を保証するため、zrush.zsh は **source 時に無条件で `zrush config` を 1 回実行**する
  (config.toml の mtime 変化だけをトリガにすると、バイナリのみ更新された場合に照合されない)。
- スタンプ不一致を検出したシェルは `$ZRUSH_BIN init zsh` を自動で re-source し、現行ビルドへ追従する。
  既に worker が起動していた場合は新 generation の worker も直ちに起動し直す。まだ遅延起動前なら lazy 状態を保つ。
  試行は 1 回だけで、成功時は警告せず `ZRUSH_LOG` にだけ記録する。re-source 自体の失敗、または
  re-source 中の再度の不一致は警告を 1 回表示して zrush を無効化する。後の明示的 re-source は
  この stale-build 無効化を巻き戻せる。session failure の circuit breaker は、旧 worker の停止が完了した
  後の明示的 re-source でだけ解除できる。自動 re-source、quarantine 中の re-source、その他の disable reason は
  解除しない。
- 未知の引数を渡された `zrush` は exit 2 で拒否する(前方互換より誤用の早期検出を優先する意図的選択。
  build 不整合は上記のスタンプ照合で検知される)。

## 共通事項

> 検証: 制御バイトを含む候補・値の除外(送信側の保証)のうち「compsys 捕獲 profile」の分 —
> `tests/vectors/encode/`(`zsh -f tests/zsh/vectors.zsh`)。他の profile の分を固定するテストは無い。

- 対話シェルごとに `zrush worker` を最大 1 プロセス常駐させ、複数のメッセージを同じ
  stdin/stdout セッションで処理する。ワーカーは最初の実メッセージ(要求または入力通知)まで起動しない。
  `zrush config` は設定の読み込みごとに、`zrush init` はシェル起動(source)時に、
  それぞれ one-shot で起動する。
- 文字列はバイト列として扱い、エンコーディング変換をしない(ファイル名は任意バイト列であり得る)。
  マッチング・レイアウト計算の内部で lossy な UTF-8 解釈を行うのは構わないが、
  それはオフセット計算(文字数の数え上げ)のためだけに用いる。
  実際に返すバイト列を Rust 側が再エンコードすることはない:
  挿入テキストは由来となった候補語の原バイト列をそのまま保持し、
  表示行テキストは制御バイト→スペース正規化(「表示行の中身」節)だけを施したバイト列を保持する。
- 候補 payload 内部のフレーミングには制御バイト(`\0` `\1` `\2`)を使う。
  これらのバイトを含む候補・値の除外は送信側(zsh)が保証し、
  Rust 側はフィールド内にこれらのバイトが出現しないことを前提としてよい。
  どの機構が除外を担うかは producer profile が定める。詳細は「`zrush worker`」節。

### 終了コード

> 検証: `zrush worker` の in-band エラー応答 — `tests/vectors/plan/`(ランナーは `tests/vectors.rs`)。
> `--help` の exit 0、未知サブコマンドと `zrush config` への余計な引数の exit 2 — `tests/cli.rs`。
> `zrush init` の未指定・未知シェル・余計な引数の exit 2 — `tests/cli.rs`。
> exit 1 と、`-h` / `help` サブコマンドを固定するテストは無い。

| コード | 意味 |
|---|---|
| 0 | 成功。worker は frame 境界での stdin EOF、または `incompatible` 応答後の discard 状態での stdin EOF・read error で終了する。`zrush config` は設定ファイルの問題があっても既定値と警告を出力して成功する。`zrush init` は自身の絶対パス解決とスクリプト出力に成功する |
| 1 | worker の session-fatal framing/I/O/内部エラー、control-fd の setup failure、watchdog による abort、`zrush config` の内部エラー、または `zrush init` の自身のパス解決失敗を含む内部エラー |
| 2 | usage エラー(未知・不足・不正な引数、未知または未指定のサブコマンド) |

`--help` / `-h`、および `help` サブコマンドは使用方法を表示して exit 0 する。
これは人間向けの補助機能であり、zsh がこれらを起動することはない。
完全で相関可能な要求のエラーは exit code を変えず、`error` 応答で通知する。

## `zrush worker`

候補列を受け取って解析済みのまま保持し、クエリと組み合わせてマッチング・ランキング・
グループ分割・グリッドレイアウト・ハイライト計算・ナビゲーション表構築・挿入テキスト構築までを行い、
zsh がそのまま適用できる描画プランを返す。
入力の静穏判定(デバウンス)と、その結果どの入力に対して描画プランを作るかの決定も worker が持つ。

### 起動と責務

```
zrush worker --control-fd N
```

`--control-fd N` は必須で、`N > 2` の open 済み readable Unix fd を指定する。
worker は検証後にこの fd の sole ownership を引き取り、watchdog 以外からは使用しない。
option の欠落、数字でない/2 以下の値、未知または余分な引数は起動前に exit 2 で拒否する。
fd が closed / write-only である場合、または watchdog setup に失敗した場合は、`hello` / `ready` や
request 処理を始める前に startup 診断を stderr へ 1 行書いて exit 1 する。
起動後は stdin から要求と入力通知を読み、
`store` 要求では候補レコードストリームを解析してスロットへ格納し、
`history-snapshot` / `history-append` 要求では同じ形式のストリームを解析して history index を
置き換え・追記し、
`plan` 要求ごとにマッチング・ランキング・グループ分割・グリッドレイアウト・ハイライト計算・
ナビゲーション表構築・挿入テキスト構築を行って stdout へ応答する。
`input` 通知は静穏期間で置き換えながら最新の 1 個だけを保持し、期間の満了で描画プランまたは
捕獲要求を worker event として stdout へ送る(「入力通知と worker event」節)。
したがって worker は「1 要求を読む → 1 応答を書く」だけの loop ではなく、
stdin の待機に静穏期間の満了時刻を deadline として与え、新しいメッセージが来なくても
期間の満了だけで event を送れる session event loop として動く。
one-shot の `zrush plan` サブコマンドは存在しない。

ワーカーは **config.toml を読まない**。設定スナップショットは要求・通知のフィールドで受け取る
(設定の取得・mtime 監視は zsh 側の責務)。`HISTFILE` も読まず、候補もそのイベント番号も
`store` / `history-snapshot` / `history-append` 要求で受け取る。
candidate store のスロットと history index、および静穏判定のための current input はいずれも
worker セッションに属し、worker の終了とともに失われる(永続化も再構築もしない)。
ただし純粋な関数ではない: `f = 1` 候補の `/` 合成判定は要求・通知の `cwd` を基準に stat し、
静穏期間の計測には単調時計を使う。
マッチング・ランキング・レイアウト・挿入テキスト構築そのものは、時計にも session state にも依存しない
純粋な計算として保つ。

### abort control と worker 終了

`--control-fd` は request/response protocol と独立した private control byte stream で、message framing を持たない。
worker は通常の request 処理を始める前に watchdog thread を起動し、control fd を blocking read する。

- 1 byte 以上を受信した場合は値によらず abort。zsh は byte 1 個だけを書けばよい。
- EOF は control writer の喪失を表し、同じく abort。
- `EINTR` は read を retry し、それ以外の read error は fatal abort。
- abort は小さな Unix 専用 wrapper から process 全体へ `_exit(1)` を実行する。
  main worker thread が request 処理で停止していても watchdog 単独で終了させる。
- watchdog は detached であり、frame 境界の stdin EOF による main thread の正常 exit 0 を妨げない。
  `incompatible` 応答後の discard 状態も同じく stdin EOF で exit 0 し、request write end を閉じないシェルに対しては
  watchdog がその上限を与える。
  zsh は正常 shutdown の response EOF まで control write fd を open に保ち、先に閉じて abort と競合させない。

stdout(fd 1)は response stream 専用で、worker は起動時に cloexec を付ける。
worker が起動する descendant は fd 1 を継承しないため、zsh は buffered response bytes を raw drain した後の
stdout EOF を worker completion の唯一の oracle にできる。control channel は supervisor process でも
request/response の shutdown message でもなく、request/response の netstring fields は変更しない。

### セッションフレーミングと握手

stdin/stdout は pty を介さないバイトストリームである。両方向の各メッセージは canonical netstring 1 個で、
その payload はフィールドを表す canonical netstring の連結である。したがってメッセージは再帰的に netstring で囲む。

```
netstring = <length> ":" <length bytes of payload> ","
message   = netstring(netstring(field-1) ... netstring(field-N))
```

- `length` は payload の**バイト数**を表す非空の ASCII 10 進数。0 は `0`、正数は先頭ゼロなしで表す。
- payload は NUL・`\1`・`\2`・不正 UTF-8 を含む任意のバイト列であり、エスケープや文字コード変換をしない。
- 長さの整数オーバーフロー、空または先頭ゼロ付きの長さ、`:` / 末尾 `,` の欠落・不一致、
  宣言長未満の EOF、外側 payload 内の不完全または余分なフィールドバイトは framing error である。
- 読み取りの分割位置に意味はない。1 回の read に複数メッセージが含まれる場合、壊れた後続メッセージより前に
  完成していたメッセージは先に処理し、OS の read 境界によって配送結果を変えない。
- 候補レコードストリームは `store` / `history-snapshot` / `history-append` 要求の、
  描画プランストリームは `plan` の成功応答と `plan-ready` event の、
  それぞれ 1 個の opaque field として入れ子にする。その内側の NUL フレーミングは後述の規範を保つ。
- kind・build stamp・request_id・列挙値・真偽値・数値・error code は、以下に示す ASCII バイト列と
  完全一致しなければならない。前後空白、符号、別の大小文字表記を許さない。

起動直後、zsh は最初の要求・通知より前に `hello` を送り、worker はその build stamp を照合して応答する。
zsh は kind・フィールド数・build stamp が完全一致する `ready` だけを握手の成立として受け入れる。
要求と入力通知は握手応答の到着を待たずに `hello` の後ろへ pipeline してよい。
pipeline されたメッセージの帰結は握手の結果が定める:
`ready` を返したセッションは通常のメッセージとして受信順に処理し、
`incompatible` を返したセッションは request としても通知としても解釈せず読み捨てる
(「要求と応答」の終端応答規範の対象外であり、event も生じない)。
`build_stamp` は非空の lowercase hex ASCII (`[0-9a-f]+`)である。

```
hello:        ["hello", build_stamp]
ready:        ["ready", build_stamp]
incompatible: ["incompatible", worker_build_stamp]
```

worker は `hello` の build stamp が自身の値と一致しなければ、自身の stamp を
`worker_build_stamp` に入れた `incompatible` を 1 個返し、以後は request bytes を解釈しない discard 状態に入る。
discard 状態の worker は stdin を読み捨てるだけで、frame として解釈も応答もせず、stdin EOF、または
読み捨て中の read error で exit 0 する。
worker が pipeline された要求を読み捨てて request stream を書き込み可能に保つため、その write は失敗せず、`incompatible` が失われない。
zsh は、正しい形の `incompatible` または stamp の異なる `ready` を stale build として扱い、自動 re-source を 1 回試みる。
握手での別 kind・別フィールド数・不正な stamp は protocol failure、
EOF・I/O エラー・非 canonical framing は worker session failure である。
worker が受ける `hello` の kind・フィールド数・stamp 表記自体が不正な場合は、応答せず終了する。

### メッセージの種別

握手の後にセッション上を流れるメッセージは 3 種類ある。いずれも同じ nested netstring framing を使う。

| 種別 | 向き | 相関の鍵 | 応答 |
|---|---|---|---|
| 要求(`store` / `history-snapshot` / `history-append` / `plan`) | zsh → worker | `request_id` | `ok` / `error` をちょうど 1 個 |
| 入力通知(`input` / `flush`) | zsh → worker | `input_generation` | 無し(帰結は worker event) |
| worker event(`plan-ready` / `capture-required`) | worker → zsh | `input_generation` | 無し |

- 要求だけが `request_id` を持ち、zsh の未完了要求表に登録される。
  入力通知は `request_id` を持たず、未完了要求表にも登録しない。
- worker は通知を静穏期間で置き換えるため、通知 1 個が event 1 個に対応するとは限らない。
- worker event は必ず対象の `input_generation` を持ち、どの要求とも対応しない。
  zsh は自分がいま有効としている `input_generation` に一致する event だけを適用する。
- worker は受信順に処理し、応答と event は生成順に同じ stdout ストリームへ並ぶ。
  静穏期間の満了で生じる event は、要求とその応答の間にも現れる。
- 相関の鍵を安全に回収できないメッセージ(要求の `request_id`、通知・event の `input_generation`)は
  in-band で報告できないため、セッションを終了させる(各節の規範)。

### 要求と応答

角括弧内は外側 message payload に固定順で並ぶ netstring field を表す。

```
store:            ["store", request_id, slot, candidate_generation, input_generation,
                   candidate_payload]
history-snapshot: ["history-snapshot", request_id, candidate_generation, candidate_payload]
history-append:   ["history-append", request_id, candidate_generation, candidate_payload]
plan:             ["plan", request_id, candidate_generation, cwd, producer, query, mode,
                   smart_case, rows, width, trailing_space, history_limit]
ok:               ["ok", request_id, body]
error:            ["error", request_id, code]
```

要求は 4 種類ある。
`store` は候補レコードストリームを worker へ渡して解析済みの candidate store のスロットへ格納し、
`history-snapshot` / `history-append` は同じ形式のストリームを worker の history index へ渡し、
`plan` はスロットまたは history index を `candidate_generation` で参照して描画プランを得る。
候補 payload は `plan` に載せない。

- `request_id`: zsh が所有する `1..=9223372036854775807`(`i64::MAX`)の canonical ASCII 10 進識別子。
  先頭ゼロを付けない。
  シェルセッション内で単調増加し、worker の終了・再起動でもリセットまたは再利用しない。
  候補集合や履歴の revision を表す値ではない。
- `slot`: `live` または `cache`。`store` だけが持つフィールドである。
  zsh が所有する列挙であり、worker はスロットの意味を解釈しない。
  worker はスロットごとに最大 1 generation の解析済み candidate store を保持し、
  新しい `store` の受理は**同一スロットの**前 generation だけを破棄する(他スロットの generation は残る)。
  candidate store は worker セッションに属し、worker の終了とともに失われる。
  history index はスロットではない。
  `store` は index を変更せず、`history-snapshot` / `history-append` はどのスロットも変更しない。
- `candidate_generation`: zsh が所有する `1..=9223372036854775807`(`i64::MAX`)の canonical ASCII 10 進識別子。
  先頭ゼロを付けない。
  `request_id` とは独立の値である。
  シェルセッション内で単調増加し、再利用せず、worker の終了・再起動でもリセットしない。
  `store` では格納先の generation を、`history-snapshot` / `history-append` では
  index に刻む generation を、`plan` では参照する generation を表す。
  `plan` の generation 検索は 2 つのスロットと history index を横断して行い、
  ヒットした側から描画プランを計算する(index は現 stamp との完全一致でヒットとする)。
  index の revision は index を最後に書いた要求の `candidate_generation` そのものであり、
  別の revision 識別子は存在しない。
- `input_generation`: zsh が所有する `1..=9223372036854775807`(`i64::MAX`)の canonical ASCII 10 進識別子。
  先頭ゼロを付けない。
  `request_id` とも `candidate_generation` とも独立の値である。
  シェルセッション内で単調増加し、再利用せず、worker の終了・再起動・re-source でもリセットしない。
  `store` だけが持つフィールドであり、その捕獲がどの入力の `capture-required` に答えたものかを表す
  (「入力通知と worker event」節)。`store` は必ずこの束縛を持ち、束縛のない `store` は存在しない。
- `candidate_payload`: 後述の候補レコードストリーム全体をそのまま格納する opaque bytes。
- `history_limit`: `plan` だけが持つ、先頭ゼロなしの正の canonical ASCII 10 進数
  (`1..=9223372036854775807`)。
  history index を参照する `plan` が index の新しい側から走査する件数の上限であり、
  worker はこれを retention cap へクランプする(走査の意味論は「history profile」節)。
  スロットを参照する `plan` では無視する
  (`producer = history` 以外の要求でも値は必須であり、欠落・非 canonical 表記は不正である)。
- `producer`: `compsys` または `history`。
  結果順に加えてレイアウト方針を選ぶ: `compsys` は最大 8 列・上から下、
  `history` は 1 列・下から上。レコード解釈・ハイライト・挿入テキスト構築は共通である
  (「表示行の中身」「マッチング・ランキングの意味論」節)。
- `query`: マッチングに用いるユーザーの as-typed バイト列(NUL 除去済み)。空も有効
  (空クエリは全候補が最高同点マッチになる)。
  渡す値は producer profile(「compsys 捕獲 profile」「history profile」)が定める。
- `mode` は `prefix` / `substring` / `typo`、`smart_case` は `true` / `false`。
  マッチング設定のスナップショットであり、
  意味論は後述「マッチング・ランキングの意味論」節。
- `rows`: 先頭ゼロなしの正の ASCII 10 進数。表示行の最終予算。zsh が `min(max-lines, $LINES - 1)` を計算し、
  1 以上にクランプして渡す(Rust は端末サイズを知らない)。
- `width`: 先頭ゼロなしの正の ASCII 10 進数。zsh が `$COLUMNS - 1` を 1 以上にクランプして渡す。
- `trailing_space`: `true` / `false`。挿入テキストへ末尾スペースを焼き込むかどうかの指定
  (対応する設定は config-schema.md `[insert].trailing-space`)。
  渡す値は producer profile(「compsys 捕獲 profile」「history profile」)が定める。
- `cwd`: 要求時点の `$PWD` の生バイト列。`f = 1` 候補の stat パスが相対パスなら、このディレクトリを
  基準に解決する。worker 自身の起動時 cwd は判定に使わない。絶対 stat パスはそのまま使い、
  シンボリックリンクは追跡する。`~` は展開しない。cwd または対象パスを stat できない場合は
  「ディレクトリでない」と扱い、`/` を合成しない。

history index は worker が保持する履歴専用の候補列で、スロットとは独立に 1 個だけ存在する。

- `history-snapshot` は index の内容を要求の payload のレコード列で丸ごと置き換える。
  `history-append` は要求の payload のレコード列を、その順のまま index の新しい側へ連結する
  (1 件だけを運ぶ追記はその退化形である)。
  どちらも受理と同時に index の stamp を要求の `candidate_generation` へ更新する。
- 受理の条件は、要求の `candidate_generation` が index の現 stamp より**厳密に大きい**ことである。
  `history-append` はさらに index が初期化済み(`history-snapshot` を 1 回以上受理済み)であることを要求する。
  条件を満たさない要求は `unknown-generation` で終端し、index の内容も stamp も変更しない。
  未初期化の index は stamp を持たないため、「厳密に大きい」の条件は空に成り立つ。
  すなわち未初期化の index に対して `history-snapshot` は generation の値によらず受理され、
  `history-append` は初期化済みの条件により generation の値によらず拒否される。
  したがって worker の再起動・交換、途中で失われた追記、順序の巻き戻しはすべて
  `unknown-generation` として同じ形で観測される。
- worker は index を最大 **20000 件**(retention cap)保持し、これを超えた分は古い側から捨てる。
  retention cap は `history_limit` が取り得る最大値
  (config-schema.md `[history].limit` の上限)と同値であり、worker は要求の `history_limit` を
  この値へクランプする。したがって query の走査範囲が eviction で欠けることはない。
- index は worker セッションに属し、worker の終了とともに失われる。

完全な message から canonical な `request_id` を回収できた後に要求を遂行できない場合、
worker は同じ `request_id` の `error` を返してセッションを継続する。
終端 `error` の `code` は要求の kind ごとに次のいずれかである。

| kind | code | 意味 |
|---|---|---|
| `store` | `invalid-request` | kind・固定フィールド・scalar・`slot` 列挙の不正 |
| `store` | `superseded` | current input の `input_generation` と一致しない束縛 |
| `store` | `invalid-payload` | 候補レコードストリームの framing error |
| `history-snapshot` | `invalid-request` | kind・固定フィールド・scalar の不正 |
| `history-snapshot` | `invalid-payload` | 候補レコードストリームの framing error |
| `history-snapshot` | `unknown-generation` | index の現 stamp 以下の `candidate_generation` |
| `history-append` | `invalid-request` | kind・固定フィールド・scalar の不正 |
| `history-append` | `invalid-payload` | 候補レコードストリームの framing error |
| `history-append` | `unknown-generation` | 未初期化の index への追記、または index の現 stamp 以下の `candidate_generation` |
| `plan` | `invalid-request` | kind・固定フィールド・scalar の不正 |
| `plan` | `unknown-generation` | どのスロットにも history index にも存在しない `candidate_generation` の参照 |

`invalid-request` と `invalid-payload` は要求自体の不正を表す。
`unknown-generation` は整形としては正しい要求が成立しないことを表し、
`plan` では参照先が存在しないことを、`history-snapshot` / `history-append` では
名乗った `candidate_generation` が index の現 stamp と両立しないこと
(未初期化の index への追記を含む)を表す。
`superseded` は、整形としては正しい `store` が答えようとした入力が既に置き換えられていることを表す。
`store` の coalescing はこの終端応答で表現し、無応答で捨てることはしない。
`plan` は候補 payload を運ばないため、`invalid-payload` は `plan` の code 集合に現れない。
`store` と history 2 種の検証順は、`request_id` の回収 → kind・フィールド数・scalar
(`store` の `slot` 列挙を含む)→(`store` のみ)`input_generation` の束縛 →
`candidate_payload` の framing →
(history 2 種のみ)index の受理条件、である。
`superseded` の判定を payload の framing 検査より前に置くのは、
置き換えられた入力のための候補ストリームを解析しないためである。
複数の不正がある要求では、先に検出されるものを返す。
`error` で終わる `store` は既存のスロットをいっさい変更せず、event も生じない
(全スロット無変更のまま終端 error を返す)。
`error` で終わる `history-snapshot` / `history-append` も index の内容と stamp をいっさい変更しない。
外側または nested netstring framing の破損、あるいは request_id の欠落・非 canonical 表記・範囲外によって
安全に対応付けられない場合は応答せずセッションを終了する。

`ready` を返したセッションでは、相関可能な各 request は `ok` または `error` の**終端応答をちょうど 1 個**受ける。
`store` と `history-snapshot` / `history-append` もこの規範に従う 1 個の request である。
`incompatible` を返したセッションでその後に届くバイトは request ではなく、この規範の対象外である。
worker は要求を受信順に処理し、応答を黙って省略しない。`error` も正常に形成された終端応答であり、
worker セッション失敗には数えない。
`superseded` も同じく正常な終端応答であり、失敗にも stale な応答にも数えない。
zsh は `history-snapshot` / `history-append` の終端応答を待たずに、
同じ generation を参照する `plan` をその後ろへ pipeline してよい
(pipeline の許容範囲は握手の規範と同じ)。
`store` の後ろに `plan` を連送することはない。
受理された `store` の描画プランは `plan-ready` event として返る(「入力通知と worker event」節)。
受信順処理の帰結として、generation G を名乗る `plan` は、その `plan` より前に届いた
`history-snapshot` / `history-append` の効果を**ちょうどすべて**反映した index を参照する
(後から届く history 要求の効果は含まない)。
zsh は index への書き込みを query より後ろへ並べ替えず、まとめて後回しにもしない。
`ok` の `body` は kind で決まる: `store` と history 2 種の成功では空バイト列、
`plan` の成功では後述の描画プランストリームそのものである。

### 入力通知と worker event

バッファ変化の通知と、その帰結の配送はこの 4 kind で行う。
角括弧内は外側 message payload に固定順で並ぶ netstring field を表す。

```
input:            ["input", input_generation, candidate_generation, delay_ms, cwd, query,
                   mode, smart_case, rows, width, trailing_space]
flush:            ["flush", input_generation]
plan-ready:       ["plan-ready", input_generation, plan_body]
capture-required: ["capture-required", input_generation]
```

- `input_generation`: 「要求と応答」節と同じ zsh 所有の canonical 10 進識別子。
  zsh は通知を作るバッファ変化ごとに新しい値を 1 個採番する。
- `candidate_generation`: この入力を解決できると zsh が考える generation、または
  「再利用できる候補は無い」を表す `0`。
  `0` 以外の値は candidate store の 2 つのスロットに対して解決する
  (history index は `plan` だけが参照する)。
  `0` は「要求と応答」節の識別子の範囲外にある予約値であり、通知だけが取り得る。
- `delay_ms`: `0..=10000` の canonical ASCII 10 進数(先頭ゼロなし、`0` は `0`)。
  この通知に適用する静穏期間をミリ秒で表す(config-schema.md `[display].delay-ms` のスナップショット)。
- `cwd` / `query` / `mode` / `smart_case` / `rows` / `width` / `trailing_space` は
  同名の `plan` フィールドと同じ意味・同じ表記であり、通知時点のスナップショットである。
  通知から作るプランのレイアウトは常に `producer = compsys` のものとし、
  producer フィールドは持たない。
  history index を参照しないため `history_limit` も持たない。
- `plan_body`: `plan` の成功応答と同一形式の描画プランストリーム(「`plan` の `ok` body」節)。
  空バイト列も 0 マッチのプランではなく不正である(最小のプランは「0 マッチ」節の 4 フィールド)。

#### worker 側の規範

worker は 1 セッションで **current input** を高々 1 個保持する。
current input は最後に受理した `input` 通知そのもの(その全フィールド)であり、
静穏期間が満了するまでを **pending**、満了した後を **settled** と呼ぶ。

- **`input` の受理**: `input_generation` はセッション内で厳密に単調増加していなければならない。
  受理した通知は current input を丸ごと置き換え、その通知自身の `delay_ms` で静穏期間を張り直す。
  置き換えられた pending の入力は event を生まずに消える。
  `delay_ms = 0` の通知は受理と同時に settle する。
- **settle**: 通知の `candidate_generation` が `0` でなく、かつその generation を candidate store が
  保持していれば、その候補と通知のフィールドから描画プランを計算して `plan-ready` を 1 個送る。
  そうでなければ `capture-required` を 1 個送る。
  どちらの event も対象は settle した通知の `input_generation` である。
- **`flush`**: current input が pending で、その `input_generation` が一致するときだけ、
  静穏期間の残りを無視して直ちに settle する。
  効果を持たない `flush` は何も変えずに捨てる。次の 3 つがそれにあたる:
  current input が無い、current input が既に settled、`input_generation` が一致しない。
- **`store` の受理**: current input が存在し、その `input_generation` と束縛が一致する `store` だけを受理する。
  それ以外(current input が無い、`input_generation` が一致しない)の `store` は
  payload を解析せず `superseded` で終端する(「要求と応答」節)。
  受理した `store` は current input を直ちに settle させ(pending でも settled でも同じ)、
  格納した `candidate_generation` の候補と current input のフィールドから計算した
  `plan-ready` を 1 個送る。
  順序は固定で、終端 `ok` を先に書いてから `plan-ready` を書く。
- 1 つの `input_generation` が生む event は、高々 `capture-required` 1 個と `plan-ready` 1 個であり、
  両方が生じる場合は必ずこの順に並ぶ。
  これは上の受理規則と、zsh が `capture-required` 1 個につき `store` を 1 個だけ送ること
  (「zsh 側の規範」)からの帰結であり、worker は event 数を別途カウントして強制しない
  (同じ generation に束縛された 2 個目の `store` は 2 個目の `plan-ready` を生む)。
- worker は静穏期間を単調時計で測り、stdin の待機にその満了時刻を deadline として与える。
  新しいメッセージが来なくても、満了だけで settle して event を送る。
- 入力通知と worker event は `request_id` を持たないため、in-band の error 応答を持たない。
  kind・フィールド数・scalar 表記のいずれかが不正な通知と、
  `input_generation` が単調増加していない `input`(単調性を課すのは `input` の受理だけであり、
  `flush` は上の規則どおり何も変えずに捨てる)は
  worker session failure であり、worker は診断を stderr へ 1 行書いて exit 1 する。
  外側/nested netstring framing の破損も session failure である。
- 通知の `candidate_generation` が worker の保持しない値であることは失敗ではない。
  それは `capture-required` として通常どおり観測される。
- pending の入力を抱えたままでも、frame 境界での stdin EOF は通常どおり exit 0 で終わる
  (event は送らない)。
- worker が失われるとき、current input と静穏期間は candidate store・history index と同じく失われる。

#### zsh 側の規範

- zsh は「いま有効な `input_generation`」を高々 1 個持つ。
  event の `input_generation` がそれと一致しなければ、その event は捨てる。
  `plan-ready` では **generation の照合を `plan_body` の検証より先に行い**、
  一致しない body は解析しない。
- 一致する `plan-ready` の `plan_body` は `plan` の `ok` body と同じ受理条件で検証し、
  同じ規則で適用する(「応答の検証と zsh 側の適用(規範)」節)。
- 一致する `capture-required` を受けた `input_generation` について、zsh は compsys 捕獲を
  ちょうど 1 回開始し、その結果を同じ `input_generation` を束縛した `store` で送る。
- 未知の kind、フィールド数違い、非 canonical な `input_generation` を持つ event は
  worker session failure である。
- outbound queue では、通知を取り消す・置き換えるときに、まだ writer child へ委譲していない
  `input` / `flush` frame を除去・置換してよい。
  要求の frame は除去しない(停止時にセッションごと破棄する場合を除く)。
  委譲済みの frame は ack か session abort で決着する(behavior.md「worker ライフサイクル」)。
- session failure・worker の交換・re-source の後、zsh は入力通知も
  `capture-required` に答える捕獲も自動 replay しない。
  現在の `input_generation` は無効化され、次のバッファ変化が新しい値を作る
  (無効化点は behavior.md「worker ライフサイクル」節)。

#### 具体例

いずれも外側 message 1 個ぶんのバイト列である(`\0` は NUL 1 バイト、`\1` は 0x01)。

- `input_generation = 7`、再利用できる候補は無く(`candidate_generation = 0`)、
  静穏期間 30ms、`cwd = /tmp`、`query = gi`、`mode = typo`、`smart_case = true`、
  `rows = 10`、`width = 79`、`trailing_space = true` の入力通知:

  ```
  64:5:input,1:7,1:0,2:30,4:/tmp,2:gi,4:typo,4:true,2:10,2:79,4:true,,
  ```

- 同じ generation に対する `capture-required`:

  ```
  24:16:capture-required,1:7,,
  ```

- その捕獲結果を運ぶ `store`(`request_id = 12`、`live` スロット、
  `candidate_generation = 41`、`input_generation = 7`、
  payload は共有フィールド無しのヘッダ 1 個と候補 `ls` 1 件):

  ```
  40:5:store,2:12,4:live,2:41,1:7,8:b\1\0w\1ls\0,,
  ```

- 上の `store` が届いた時点で generation 7 が既に置き換えられていた場合の終端応答:

  ```
  27:5:error,2:12,10:superseded,,
  ```

- 0 マッチのプラン(「0 マッチ」節の 4 フィールド)を運ぶ `plan-ready`:

  ```
  28:10:plan-ready,1:7,7:\00\00\00\0,,
  ```

- generation 7 の即時確定を求める `flush`:

  ```
  12:5:flush,1:7,,
  ```

### `candidate_payload`(候補レコードストリーム)

> 検証(この節と以下の小節): 送信側(zsh のエンコーダ)の発行規範 — `tests/vectors/encode/`(`zsh -f tests/zsh/vectors.zsh`)。
> worker セッションを通した受信側(Rust のパーサ)の解釈規範と、候補ストリーム framing error の
> `invalid-payload` 応答 — `tests/vectors/plan/`(`tests/vectors.rs`)。
> パーサの全域性 — `src/record.rs` の proptest。
> 「history profile」の送信側規範(イベント番号との対応、制御バイト行の除外、バイト上限での打ち切り) —
> `tests/zsh/vectors.zsh`。受信側の解釈は上記のベクタが覆う。
> 「compsys 捕獲 profile」の transport 側の規範(pid レコードの除去)も上記の検証の範囲外。

`store` / `history-snapshot` / `history-append` の `candidate_payload` は、すべてこの形式である。

フレーミングは NUL(`\0`)終端のレコードが連続する形式。
レコード内は `\2` で連結した `<tag>\1<value>` 形式のフィールドの並び。
制御バイト(`\0` `\1` `\2`)を含む候補語・付随テキストの除外は送信側が保証する(「共通事項」参照)。

レコードモデルは payload の由来(producer)に依らない。
「レコード解釈の規律」「バッチヘッダレコード」「候補レコード」「スキップ規律」の各小節は
すべての payload に適用され、Rust 側は payload の由来を知らない。
由来ごとの追加規約は「compsys 捕獲 profile」「history profile」が定める。

#### レコード解釈の規律(規範)

- レコード内に未知のタグが含まれる場合、そのフィールドは無視する
  (将来のタグ追加に対する前方許容)。
- 同一レコード内で同じタグが複数回現れた場合、最初の出現を採用する。
- `b` ヘッダとそれに続く候補レコード群は 1 つの連続した論理バッチを成す。
  送信側はバッチを直列に発行するため、複数バッチのレコードが交錯することはない
  (規範: 送信側が直列化を保証する)。
  ヘッダの効力(共有フィールド)は次の `b` ヘッダが現れるまで持続する。

#### バッチヘッダレコード

バッチごとに、その先頭へヘッダレコードを 1 つ発行する。

- 第 1 フィールドはタグ `b`(値は空)。
- 続けて、そのバッチに属する候補が共有するフィールドのうち非空のものを載せる:
  `P` `p` `S` `s` `i` `I` `ip` `f` `rd` `X` `J`。
  - `P` / `p` / `S` / `s` / `i` / `I`: 可視・隠しの接頭辞/接尾辞。
  - `ip`: 挿入テキストの最も外側に置く接頭辞。
  - `f`(値 `1`): ファイル候補であることを示す。
  - `rd`: チルダ・パラメータ展開済みの実ディレクトリ(ファイル候補の合成 `/` 判定に使う)。
  - `X`: グループ見出し文字列。`J`: グループ名。
    グループキーの決定規則は「描画プランストリーム」の「表示行の中身」節。
- 共有フィールドが全て空でも、ヘッダレコードは必ず発行する
  (バッチ境界を一意に識別するため)。
- 候補レコードを 1 件も発行しないバッチについては、
  ヘッダごと発行を省略してよい(受信側はヘッダの無いバッチを観測しない)。

#### 候補レコード

ヘッダに続けて、そのバッチの候補ごとに 1 レコードを発行する。
フィールドは以下の 4 種のみ:

- `w`(必須・先頭・非空): 挿入テキスト構築に使う候補本体。
- `m`(任意): match-text。**`w` と異なる場合のみ**発行する。
- `d`(任意): 表示文字列。
- `n`(任意): 履歴イベント番号。history profile の候補だけが発行する。

`m` / `d` / `n` は値が非空のときのみ発行する。
フィールドが無いことと値が空文字列であることは同義に扱う(いずれも「不在」)。
送信側は空の `w` を持つレコードを送出しない
(受信側の空 `w` スキップ規律は保険として維持する。「スキップ規律」節)。

match-text(マッチング・ハイライト計算・表示の対象テキスト)の決定規則:
`m` があれば `m`、なければ `w` のバイト列そのもの。
Rust は zsh のクォート規則を一切実装しない
(`${(Q)}` 復元・`${(q)}` クォートは zsh 側の責務)。

レコードストリームの解析そのものは重複候補(同一の match-text/display-text 組)を除去しない
(送信側の発行順の情報を保つ)。
重複を送出してよいか、解析結果に profile 固有の重複除去を掛けるかは producer profile が定める
(「history profile」は index の query 時に除去し、「compsys 捕獲 profile」は除去しない)。

#### スキップ規律(規範)

- 候補レコードの第 1 フィールドが非空の値を持つ `w` タグでない場合、
  そのレコードはスキップする(空の `w` は候補として無効)。
- ヘッダレコードより前に現れた候補レコードは黙ってスキップする。
- 先頭タグが `b` / `w` のいずれでもないレコードは黙ってスキップする
  (compsys 捕獲のワーカー `pid` レコードなど)。

#### compsys 捕獲 profile

zpty 内で compsys を駆動して得る payload(behavior.md「候補収集」節)。

- `w` は compsys の挿入用にクォート済みの候補語(例: `space\ name.txt`)。
  `m` はそのクォート復元形 `${(Q)w}`、`d` は compadd `-d` の表示文字列。
- compadd 呼び出し 1 回が 1 バッチに対応する。
- 共有フィールドの写像: `P` `p` `S` `s` `i` `I` `X` `J` は compadd の
  `-P` `-p` `-S` `-s` `-i` `-I` `-X` `-J`、`ip` は `IPREFIX`。
- 重複候補(同一の match-text/display-text 組)は除去せずそのまま送ってよい。
- 制御バイト(`\0` `\1` `\2`)を含む候補・値の除外は fork 内の compadd フックが保証する。
- ワーカーの pid レコード(`pid\1<pid>\0` としてストリーム先頭に流れる)は、
  zsh が受信中に取り除いてから `store` 要求の `candidate_payload` へ入れる。
  Rust 側でのスキップは保険であり、通常の入力では発生しない。
- `store` 要求のフィールド値: `slot` は空語収集キャッシュの対象となる収集なら `cache`、それ以外の収集なら `live`。
  どの収集がキャッシュの対象かは behavior.md「空語収集キャッシュ」節が定める。
  `input_generation` は、この収集を始めさせた `capture-required` の対象 generation。
- `input` 通知のフィールド値: `query` は広げ規則が定めるクエリ(behavior.md「候補収集」節)、
  `trailing_space` は `[insert].trailing-space`、`delay_ms` は `[display].delay-ms` の設定値、
  `candidate_generation` は空語収集キャッシュの latch が有効ならその generation、
  それ以外は `0`(behavior.md「空語収集キャッシュ」節)。
- この profile の候補は `input` 通知の帰結として一覧になる。
  `plan` 要求は履歴メニューの同期交換が使う明示操作であり、
  入力に追従する一覧のために送ることはない。

#### history profile

zsh が `$history` から合成し、`history-snapshot` / `history-append` で worker の history index へ渡す payload。
index から作られた一覧を履歴一覧、その候補を履歴候補と呼ぶ。

**payload の形**(2 つの kind に共通):

- 共有フィールドが全て空のバッチヘッダを 1 個だけ発行し、以降は候補レコードのみが続く
  (見出し `X` を含め、共有フィールドは 1 つも載せない)。
- `w` は履歴行の生バイト列(compsys のクォートは施さない)。
  `n` はその履歴行に対応する `$history` のキーを、非空の ASCII 10 進数で発行する。
  欠番を詰めず、キーをそのまま使う。`m` / `d` は発行しない
  (match-text も番号接頭辞を付ける前のセル表示テキストも `w` そのもの)。
- 候補レコードは新しい順(最新の履歴行が先頭)。
  `history-snapshot` はこの列で index を置き換え、`history-append` はこの列をその順のまま
  index の新しい側へ連結するため、index 全体でも「新しい順」という 1 つの順序が保たれる。
- フレーミングに使う制御バイト(`\0` `\1` `\2`)を含む履歴行は、
  zsh が payload を合成する時点で**行ごと**除外する(バイトだけを削って残りを送ることはしない)。
  空の履歴行も送らない。
  それ以外の制御バイト(ESC・CR・TAB など)を含む履歴行は除外せず原バイト列のまま送り、
  表示側の制御バイト→スペース正規化(「表示行の中身」節)に委ねる。
- 送信側は重複除去をせず、`[history].limit` による絞り込みもしない。
  index には受け取った列がそのまま入り、重複除去も走査範囲の制限も query 時に worker が行う(下記)。
- `history-snapshot` の payload の総バイト数には固定の上限があり、
  次の候補レコードを加えると上限を超える時点で合成を打ち切る(上限値は behavior.md「履歴メニュー」節)。
  打ち切りは候補レコードの境界で行い、レコードの途中では切らない。
  打ち切った場合、発行するレコードは新しい側の連続した一部になる。
- `history-append` にはこのバイト上限を課さない。
  上限は 100ms deadline の内側で運ぶバイト量を有界にするためのものであり、
  追記はその外側のプロンプトごとの非同期経路で送るためである。
- `history-append` の payload には、上記の除外規則を通ったイベントのレコードだけを載せる。
  除外されたイベントについては要求そのものを送らないため、
  候補レコードを 1 件も含まない追記が wire に現れることはない。

**index の query**(`producer = history` の `plan` が index を解決したとき):

- 走査対象は index の新しい側から `window = min(history_limit, index の件数)` 件である
  (`[history].limit` を途中で上げても、index の件数がそれに満たない間の走査範囲は index 全体である)。
- 走査範囲の中で、同一の履歴行(`w` のバイト列が一致するもの)は**最も新しい出現だけを残す**。
  残った候補はその出現の位置と `n` を持つ。
  走査範囲の外から補充はしないため、一覧の対象になる行数は `window` より少なくなり得る
  (重複が走査枠を消費する)。
- `producer = history` は走査順(新しい順)をそのまま保つため(「マッチング・ランキングの意味論」節)、
  この順序がそのまま位置番号順になり、位置 1 は**マッチした候補のうち最も新しい履歴行**になる
  (クエリにマッチしない履歴行は位置を持たないため、位置 1 が index の先頭エントリとは限らない。
  クエリが非空でもマッチ品質で並べ替わらない)。
  画面上では単一列を下から上へ配置するため、位置 1 が最下行になり、位置番号が大きいほど上に来る
  (「表示行の中身」節)。

**要求のフィールド値**:

- `history-snapshot` / `history-append`: `candidate_generation` は zsh が新しく採番した値
  (index の現 stamp より厳密に大きい。「要求と応答」節)。
- `plan`: `producer` は `history`、`query` はバッファ全体(as-typed)、
  `trailing_space` は常に `false`(挿入テキストを履歴行の原文と一致させるため)、
  `history_limit` は `[history].limit` の設定値(config-schema.md)。
- 履歴候補は `f = 1` を持たないため、`cwd` は履歴一覧の計算に影響しない。

`history-snapshot` の payload の合成は、全履歴の値の一括展開 1 回(履歴の総件数に線形)と、
打ち切りまでに読んだ行数と行長に線形な処理からなり、同期経路で行う。
`history-append` の payload は該当イベントの読み出しだけで作り、履歴の総件数に依存しない
(どちらをいつ送るかは behavior.md「履歴メニュー」節)。

### `plan` の `ok` body(描画プランストリーム)

> 検証(この節と以下の小節。ただし「適用(zsh 側の規範)」を除く):
> ワイヤ形式とプランの中身 — `tests/vectors/plan/` を、Rust のシリアライザと参照パーサ `src/wire.rs`(`tests/vectors.rs`)、
> および zsh のデコーダ `_zrush_parse_plan`(`zsh -f tests/zsh/vectors.zsh`。パース後に再直列化して往復させる)の双方で検査する。
> 任意の入力に対して出力がワイヤ形状の不変条件を満たすことは `src/plan.rs` の proptest。
> ゴールデンは `f = 1` の候補を含まないため、`/` 合成だけはこの検証の対象外(`tests/vectors/README.md`)。その検証手段は「挿入テキスト」節の検証行。
> 「オフセット規律」の範囲の上界は、この proptest が生成した任意の入力について参照パーサ側で検査される
> (レイアウトが listing text の外を指すオフセットを出力しないこと)。上界を破るプランの拒否は「エラー時の zsh 側挙動」節の検証行。
> ただし、受信側が用いる文字数が Rust 側の文字数以上であるべき規範は、どのテストも固定していない。
> 制御バイト→スペース正規化(表示テキスト・表示幅・パディング・切り詰め・オフセットへの反映と、挿入テキストが原文のままであること)— `src/plan.rs` の単体テスト。

同じ形式を `plan-ready` event の `plan_body` にも用いる(「入力通知と worker event」節)。

NUL(`\0`)終端フィールドの平坦列。数値は ASCII 10 進表記。順序は固定:

```
フィールド 1: common-prefix(バイト列。空 = なし)
フィールド 2: L(表示行数)
フィールド 3: P(選択可能位置数)
続く L 個: 表示行テキスト(1 行 1 フィールド。改行を含まない)
次の 1 個: H(ハイライトエントリ数)
続く H 個: "role pos start len"(空白区切り)
続く P 個: "start len"(位置ごとのセル実テキスト範囲)
続く P 個: "next prev left right"(位置ごとのナビゲーション先)
続く P 個: 位置ごとの挿入テキスト(バイト列そのまま)
```

総フィールド数は `4 + L + H + 3P`。
選択可能位置は 1 始まりで `1..P` の番号を持つ(0 は「未選択」を表す予約値)。

#### オフセット規律

- 文字オフセットと表示幅は同一の lossy UTF-8 スカラー列ビューの上で計算する
  (対象のバイト列を 1 回だけ lossy UTF-8 解釈し、その文字列に対して
  文字数・表示幅の両方を数える。解釈のズレを単一箇所に閉じ込めるための統一)。
- 切り詰め(接頭辞の選択)は、制御バイト→スペース正規化(「表示行の中身」節)を施した
  **表示テキストに対して**行い、「lossy 表示幅が予算に収まる最大の接頭辞」を返す
  (不正 UTF-8 バイト列を `U+FFFD` などへ再エンコードすることはしない)。
  パディングは ASCII スペースで行う。
  したがって表示行テキストは正規化後のバイト列の部分列であり、
  制御バイトを含んでいた候補では原バイト列の部分列にはならない。
  原バイト列をそのまま返す保証が課されるのは挿入テキストのみである(「共通事項」節)。
- ハイライト範囲・セル実テキスト範囲の `start` / `len` はすべて**文字数**
  (match-text 等を lossy UTF-8 解釈したときの Unicode スカラー値の並びに対する
  0 始まり・長さ表現。match-spans と同じベストエフォート)。
- 基準は「L 個の表示行テキストを `\n` で連結した listing text」。**先頭に改行は含まない**
  (表示行 1 のオフセット 0 がその行の先頭)。
  zsh は region_highlight へ適用する際に `$#BUFFER + 1` を加算する
  (POSTDISPLAY はバッファの直後に続くため)。
- ハイライト範囲・セル実テキスト範囲は listing text の内側に収まる:
  `start + len <= listing text の文字数`(`L = 0` のときこの文字数は 0)。
  各範囲は 1 本の表示行の内側に収まるが、契約が課す上界は listing text 全体の文字数であり、
  行ごとの内訳ではない(受信側に行の切り出しを要求しないため)。
  受信側はこれを満たさないプランを破棄する(「エラー時の zsh 側挙動」)。
  受信側が自身の文字数の数え方を使うことは許す
  (zsh の `$#` はロケール依存であり、不正 UTF-8 バイトを個別に数える)。
  ただし正当なプランを弾かないよう、受信側が用いる上界は Rust 側の文字数以上でなければならない。
  厳密一致は要求しない(表示幅と同じくベストエフォート)。
- 一方、**セルのパディング・切り詰めは表示幅**(unicode-width)で計算されている。
  zsh の `$terminfo`/wcwidth 実装との差(East Asian 曖昧幅など)によるズレは
  ベストエフォートとして許容する(仕様外)。

#### ハイライト

- `role` ∈ `match` | `heading` | `history-number`。zsh が `role` を
  `[display.highlight]` の該当スペックへ写像する
  (空スペック = 装飾なし)。
- `pos` はそのエントリが属する選択可能位置。見出しエントリは `pos = 0`(いずれの位置にも属さない)。
- **選択中セルには match / history-number 装飾を適用しない**規則は、zsh が選択変更のたびに
  受け取ったプランからエントリを再構築することで実現する:
  `pos == 選択位置` の match / history-number エントリをスキップし、
  代わりに選択エントリ(その位置のセル実テキスト範囲 + `selected` スペック)を追加する。
  プランの再取得・`plan` 要求の再送は伴わない。
- match 装飾は match-text をそのまま表示しているセルにのみ発行される
  (display-text 表示セルには発行されない)。
  切り詰め済みセルへのクリップも Rust 側で計算済み。

#### 表示行の中身

- **セルの表示テキストの決定規則**: `d` があれば `d`、なければ match-text
  (候補データの解釈規則。描画層の実装に依らない)。
- `n` を持つ候補では、上記で決めたテキストの前に履歴イベント番号欄を付ける。
  番号欄幅は `max(5, n を持つ全レイアウト対象候補の n の最大バイト長)` とし、
  `n` を ASCII スペースで右寄せした後に区切りの ASCII スペース 2 個を置く。
  `history-number` ハイライトは数字そのものだけを指し、左パディングと区切り空白は含めない。
  match ハイライトのオフセットは番号欄と区切りの分だけ移動する。
  セル実テキスト範囲には番号欄・区切り・従来の表示テキストをすべて含める。
  この合成後のセル全体に、他のセルと同じパディング・右端切り詰め規則を適用し、
  横幅不足時の特例は設けない。挿入テキストには `n` と表示用の空白を含めない。
- **グループ分割**: グループキーは `J` を優先し、無ければ `X`。
  `J` の値が `-default-` の場合は空(グループなし)として扱う。
  キーが空のグループはグループなし・見出しなしとして扱う。
  グループの割り当ては候補の初出現順による。
- **見出しテキスト**: グループの初出メンバーが属したバッチの
  `X` があれば `X`、なければ `J`(グループキーが空の場合は見出しなし。上記と同じ判定)。
  見出しテキストにも候補テキストと同じ制御バイト→スペース正規化を適用する
  (表示行フィールドは改行を含まない)。
- **セル幅**: `gmaxw = max(1, min(width, グループ全メンバーの表示幅の最大値))`。
- **列数**: 補完一覧は `cols = clamp(floor((width + 2) / (gmaxw + 2)), 1, 8)`、
  履歴一覧は常に `cols = 1`。
  列数上限 8 とガター幅 2 は Rust 内部定数であり、プロトコルには現れない。
- **行数**: `grows = ceil(メンバー数 / cols)` を、そのグループに残っている行予算にクランプする。
  表示するメンバー数を `gcount = min(cols × grows, メンバー数)` とし、
  空列を作らないよう `cols` を `ceil(gcount / grows)` へ再圧縮する。
- **配置**: 位置番号は列優先(column-major)で割り当てる。列 `c`・論理行 `r`
  (いずれも 1 始まり)のセルには、初出現順で `p = (c - 1) × grows + r` 番目のメンバーを置く。
  補完一覧は論理行を上から下へ描画する。履歴一覧は単一列の論理行を下から上へ描画し、
  位置 1 を最下行、最終位置を最上行に置く。位置番号・ナビゲーション表の意味は反転しない。
- 見出し行は、そのグループの表示に行予算が 2 以上残っているときのみ出す。
  先頭グループのみ、予算不足時は見出しを省略して候補は表示する。
  行予算に収まらない最初の後続グループが現れた時点でレイアウトを打ち切り、
  そのグループを含む以降のグループはすべて出さない。
- 見出しテキストが `width` を超える場合は、セルと同じ規則
  (lossy 表示幅が収まる最大の原バイト列接頭辞)で `width` に切り詰める。
- 各セルはグループ内で一様な幅(`gmaxw`)にパディングする(表示幅基準)。
- **制御バイト→スペース正規化(producer 共通)**: 表示テキスト中の C0 制御バイト
  (`0x00`–`0x1F`。改行 `0x0A` を含む)と DEL(`0x7F`)は、それぞれスペース 1 バイト(`0x20`)へ置換する。
  これは表示だけの正規化であり、挿入テキストは原文のまま返る。
  改行が消えることで表示は 1 行化され、端末制御列が表示行へ漏れることもなくなる。
  置換は 1 バイトを 1 バイトへ写すため、正規化の前後で文字数は変わらない
  (match-text 上で計算したハイライト範囲が正規化でずれない)。
  表示幅・パディング・切り詰めは正規化後のテキストに対して計算する。

#### ナビ

位置ごとに `next prev left right` の絶対遷移先(位置番号、または 0 = 未選択)を返す。

- `next` = 位置 + 1(末尾でクランプ、すなわち最終位置では自己参照)。
- `prev` = 位置 - 1。ただし位置 1 の `prev` は 0(選択解除)。
- `left` = `max(グループ先頭位置, p - grows)`、`right` = `min(グループ末尾位置, p + grows)`
  (`grows` は所属グループの行数。「表示行の中身」節参照)。
  単一列のグループ(`cols = 1`)では `grows` がグループのメンバー数に等しいため、
  `left` はグループ先頭位置へ、`right` はグループ末尾位置へのジャンプになる
  (一般式から導かれる帰結であり、特例ではない)。
- `next` / `left` / `right` のクランプは自己参照(遷移先 = 自分自身)で表現する。
  zsh は自己参照(遷移先 == 現在位置)を no-op として扱う(規範)。
  `prev` のみ、位置 1 での特例として 0(選択解除)を返す。
- ナビゲーション表は producer に依らず同じ意味を持つ。
  どのキーがどの遷移に対応するか、および遷移先 0 を受けたときの扱い
  (補完一覧は選択解除、履歴一覧は一覧全体の消去)は zsh 側の規範であり、
  behavior.md「選択・キーバインド」「履歴メニュー」節が定める。

#### 挿入テキスト

> 検証(この節のうち、上の節のゴールデンが届かない `/` 合成の判定):
> 連結順・stat パス(`rd` + match-text)の構築・`f` が `1` でない候補を stat しないこと・nospace 条件 — `src/insert.rs` の単体テスト(`is_dir` を注入する)。
> stat するのは表示位置として採用された `f = 1` の候補だけであること、および stat 失敗・非ディレクトリ時の扱い — `src/plan.rs`。
> 実ファイルシステムに対する `/` 合成 — `tests/cli.rs`。

- 位置ごとに、確定時にそのまま使える完成済みの挿入テキストを 1 個ずつ返す。
- 構築規則: `ip + i + P + p + w + s + S + I` の連結
  (バッチヘッダの共有フィールド + その候補固有の `w`)。
- `f = 1` かつ連結結果の末尾が `/` でない候補は、`rd` と match-text
  (`m` があれば `m`、なければ `w`)の生バイト列を連結したパスを、
  そのプランを計算した要求または通知の `cwd` を基準に、シンボリックリンクを追跡して stat する。
  stat が失敗する場合・対象がディレクトリでない場合は `/` を合成しない。
  この判定はプラン計算時点のスナップショットであり、zsh は確定時に再検証しない
  (該当ディレクトリがプラン計算後に削除・変更されていても、返された挿入テキストをそのまま使う)。
- 末尾スペースは `trailing_space = true` かつ nospace 条件
  (`S` / `s` / `I` のいずれかが非空、または `/` 合成に該当)に該当しないとき、
  この時点で付与済みとして返す。

#### 適用(zsh 側の規範)

> 検証: いずれも実際の zle 配線に対するスモークテスト(`cargo test --test driver`)。
> `POSTDISPLAY` の組み立て — `tests/driver/apply.rs`。
> 補完一覧の確定時の `LBUFFER` 置換と `RBUFFER` 保持 — `tests/driver/confirm.rs`。

- **表示**: `L > 0` なら `POSTDISPLAY` を「改行 1 個 + L 個の表示行テキストを改行で連結したもの」に
  置き換える(オフセット規律の `$#BUFFER + 1` 加算は、この先頭の改行 1 個に対応する)。
  `L = 0` なら `POSTDISPLAY` を消去する。
- **確定**: 置換の規則は一覧の種類(補完一覧 / 履歴一覧)ごとに 2 つある。
  プランの出力形式はどちらでも同じであり、どちらを適用するかは
  zsh が保持する現在の一覧の種類で決める(種類の遷移は behavior.md「履歴メニュー」節)。
  - 補完一覧: `pre` を「`LBUFFER` から現在語(広げ規則が対象にした語。behavior.md「候補収集」節)を
    除いた前半部分」とし、`LBUFFER = pre + 挿入テキスト` で置き換える
    (`RBUFFER` は変更しない)。
  - 履歴一覧: `BUFFER = 挿入テキスト` で行全体を置き換え、`CURSOR` を末尾に置く。

#### 0 マッチ

common-prefix(空も可)+ `L = 0` + `P = 0` + `H = 0` の、ちょうど 4 フィールドを出力して exit 0
(総フィールド数の式 `4 + L + H + 3P` と整合する)。
表示行・ハイライトエントリ・セル範囲・ナビゲーション・挿入テキストのいずれのフィールドも存在しない。
zsh は一覧を消す。

#### common-prefix の意味論

- **prefix 階層のマッチ**(match-text がクエリで始まる候補)の match-text の
  バイト単位最長共通接頭辞。空クエリでは全マッチが prefix 階層。
  マッチ 0 件・prefix 階層 0 件・共通部分なしのときは空フィールド。
  substring 以下の階層はクエリの接頭辞拡張になり得ないため計算に含めない。
- `tab = "common-prefix"` の挙動(config-schema.md)のために返す。zsh 側の規範:
  - クエリが common-prefix の真のバイト接頭辞である場合、現在語のクエリ領域を
    `${(q)}` でクォートした common-prefix で置き換える(as-typed の接頭辞拡張のみ。
    入力を縮める・別文字列に置き換える挿入はしない)。
  - それ以外(空・クエリと同一・バイト接頭辞でない。smart-case の大文字小文字差で
    ずれるケースを含む)は**先頭候補(位置 1)を確定挿入**する(`tab = "insert"` と同じ確定動作)。
    候補 0 件なら何もしない。

- 総マッチ件数は返さない(「+truncated 表示」の導入は wire contract の拡張として意図的に保留する)。

### マッチング・ランキングの意味論

> 検証: モードの累積性・ティアの序列と literal / approximate グループ分類・smart-case の真偽両方・誤字許容の範囲(候補の接頭辞に対する 1 編集、1 文字クエリでは不適用)・非 UTF-8 バイト列でもマッチすること —
> `src/matching.rs` の単体テスト(小さなアルファベット上での DP 参照実装との網羅照合を含む)。
> literal の存在による approximate の抑止・approximate だけが存在する場合の保持・両 producer の結果順・ティア順のソートと同点時の candidate payload 順保存 — `src/ranking.rs`。
> `producer = history` がマッチ品質で並べ替えないこと・隠し候補の除外(空クエリと非ドットのクエリで落ちること、`.` 始まりのクエリで残ること、`f = 1` でないバッチには掛からないこと、common-prefix に入らないこと)— `src/plan.rs`。
> worker セッション越しの producer ごとの結果順と common-prefix — `tests/cli.rs`。`producer = history` のプラン全体 — `tests/vectors/plan/`。
> 大文字小文字の畳み込みを ASCII に限る規範は、どのテストも固定していない。

- **隠し候補の除外**: クエリの先頭バイトが `.` でないとき、`f = 1` のバッチに属し match-text が `.` で始まる候補を、ティア判定より前に除外する(空クエリも「`.` で始まらない」に含む)。
  除外した候補は一覧にも common-prefix にも入らない。
  捕獲 fork が `globdots` でドットファイル候補を無条件に生成する(behavior.md「候補収集」)ため、隠しファイルをドット入力まで伏せる判断はこの規則が一手に担う。
  除外を `f = 1` に限るのは、`globdots` が増やすのが glob 由来のファイル候補だけであり、ドット始まりでもファイル候補でないものの見え方を変えないため。
- モードは累積的に広がる: `typo` ⊇ `substring` ⊇ `prefix`。
  - `prefix`: match-text がクエリで始まる。
  - `substring`: match-text がクエリを部分文字列として含む。
  - `typo`: 上記に加えて、文字順保存のあいまい一致(`dcs` → `docs`)と
    軽度の誤字(隣接転置・1 文字の置換/挿入/脱落: `gti` → `git`)を許容する。
    誤字許容は**候補の接頭辞に対する**編集距離 ≤ 1 として判定する
    (候補の残り接尾辞は自由: `gti` → `git-lfs` も拾う)。
    また誤字許容はクエリが 2 バイト以上のときのみ適用する
    (1 文字クエリでは任意の 1 文字接頭辞が 1 編集以内となり全候補一致のノイズになるため)。
- 4 つのティアを 2 グループに分ける: **literal** は prefix と substring、
  **approximate** は edit(誤字許容)と fuzzy(文字順保存のあいまい一致)。
  `mode` は候補を拾える最も緩いティアを定める上限であり、このグループ分けや後述の抑止によって
  `mode` が許さないティアを拾うことはない。
- `mode` が許すティアで全候補を判定した後、producer ごとの結果順を適用する前に、
  グループ単位で動的に絞り込む。
  - literal のマッチが 1 件以上あれば、prefix と substring のマッチはすべて残し、
    edit と fuzzy のマッチはすべて除外する。
  - literal のマッチが 0 件なら、`mode` が許す edit と fuzzy のマッチを除外せず残す。
  この規則は `producer = compsys` と `producer = history` の両方に同一に適用する。
  絞り込みを通過した候補のマッチハイライトは各候補のティアから計算し、
  common-prefix は prefix ティアだけから計算する(「common-prefix の意味論」節)。
- `smart-case = true`: クエリが全て小文字なら大文字小文字を無視、
  大文字を含むなら区別する。`false`: 常に区別しない。
  大文字小文字の畳み込みは **ASCII の範囲のみ**(非 ASCII はバイト安全のため区別される。
  バイト列意味論を保つための意図的制限)。
- ランキング: 結果順は `producer` で決まる。
  - `producer = compsys`: マッチ品質スコアの降順。同点は candidate payload での出現順(送信側が発行した順)を保つ。
  - `producer = history`: 参照先の並び順(history index を走査した順、すなわち新しい順)を
    そのまま保つ(マッチ品質で並べ替えない)。
    ティアはこのとき「候補を一覧に含めるかの判定(グループ単位の動的な絞り込みを含む)」と
    「ハイライト範囲の計算」にのみ使う。
  どちらの producer でも、ティアに 1 つも該当しない候補は一覧に含めない。
- スコアの序列は「より厳密なマッチのティアほど上位」
  (prefix 一致 > 部分一致 > 誤字許容 > 文字順保存のあいまい一致)。
  誤字許容をあいまい一致より上位に置くのは、前者が高精度・少数
  (候補接頭辞と 1 編集以内)で、後者が大量になり得るため
  (`gti` で `git` が散在部分列の候補群に埋もれない)。
  この序列と各ティアのスコアはグループ単位の絞り込み後も同じである。
  同一ティア内の順位付け(語頭・境界で始まる一致の優遇など)は実装詳細とし、
  スコアの数値自体もプロトコルに含まれない。

### 応答の検証と zsh 側の適用(規範)

> 検証: プランの受理条件(下記の拒否条件)— `tests/vectors/reject-plan/` を、
> Rust の参照パーサ `src/wire.rs`(`tests/vectors.rs`)と zsh の `_zrush_parse_plan`(`zsh -f tests/zsh/vectors.zsh`)の双方が拒否することを検査する。
> 破棄と「セッション内 1 回警告」の実挙動 — 実際の zle 配線に対するスモークテスト `tests/driver/death.rs`(`cargo test --test driver`)。

- zsh は応答の外側/nested netstring、固定フィールド数、kind、canonical な request_id、
  および request_id が未完了要求の 1 つに対応することを検証する。不正なら worker セッションを壊れたものとして終了する。
  worker event の検証と適用は「入力通知と worker event」節の zsh 側規範が定める。
- `error` の `code` は `invalid-request` / `invalid-payload` / `unknown-generation` / `superseded` の
  いずれかでなければならない。
  それ以外の値は不正な応答であり、worker セッションを壊れたものとして終了する。
- `error` は相関する要求の正常な終端応答である。その要求の結果を破棄し、それが現在の最新要求なら
  既存一覧も消す。stale 要求なら UI 状態を変えない。どちらの場合も worker は継続利用する。
- `unknown-generation` は、`plan` が参照した generation を worker が保持していないこと、または
  `history-snapshot` / `history-append` が名乗った generation が index の現 stamp と両立しないことを表す。
  他の `error` と同じく正常な終端応答であり、worker セッション失敗にも連続失敗回数にも数えない。
  zsh はその要求も先行する `store` / history 要求も replay しない。
  履歴メニューの同期交換では、他の `error` と同じく交換の失敗として扱う
  (behavior.md「履歴メニュー」節)。
  `history-snapshot` / `history-append` が `unknown-generation` で終端した場合は index の同期が
  失われたことを表すため、zsh は history index latch を無効化する
  (latch の所在と無効化点は behavior.md「worker ライフサイクル」節が定める)。
  次の明示的な履歴メニュー操作が `history-snapshot` から作り直すだけで、payload の replay はしない。
- `superseded` は `store` だけが受ける終端応答で、その捕獲が答えようとした入力が既に
  置き換えられていることを表す。zsh は候補を保持していないため replay できず、replay もしない。
  candidate store latch はこの `store` について進めない(latch を進めるのは `ok` だけである)。
  対象の `input_generation` は既に無効なので UI 状態も変えない。
  worker セッション失敗にも連続失敗回数にも数えない。
- `store` と `history-snapshot` / `history-append` の `ok` は body が空バイト列であることを検証する。
  空でなければ仕様を満たさない応答として扱い、プランを破棄する場合と同じく worker セッションを終了する。
- `plan` の `ok` body、および現在の generation に一致する `plan-ready` の `plan_body` が
  仕様を満たさない場合
  (最終フィールドの NUL 終端欠落、`L` / `P` / `H` が非負の数字列でない、
  総フィールド数が `4 + L + H + 3P` と一致しない、ハイライト・セル範囲・ナビゲーションの
  各タプルの要素数が不正、`role` が `match` / `heading` / `history-number` 以外、
  位置・ナビゲーション値が `0..P` の範囲外、
  ハイライト範囲・セル実テキスト範囲の `start + len` が listing text の文字数を超える)は、
  プラン全体を破棄して一覧を消し、worker セッションを終了する。
  同じ session の他の未完了要求も behavior.md「worker ライフサイクル」に従ってすべて破棄する。
  壊れた success を受理してセッションを継続してはならない。
- 正常に形成された `ok` / `error` と正常に形成された worker event は、
  worker セッションの連続失敗回数を 0 に戻す。
  `ok` であっても、対応する要求より後の実要求を zsh が既に開始していれば stale なので適用せず捨てる。
  stale 応答も正常に形成されていれば終端応答として扱い、失敗回数を戻す。
  generation が一致せず捨てる event も、kind とフィールド数が正しければ同じく失敗回数を戻す。
- worker の stderr は端末に流さない(zle 表示を壊さないため)。`ZRUSH_LOG` が設定されていれば
  診断をそこへ追記し、未設定なら `/dev/null` へ送る。
  main request 処理がセッション失敗で終了するときは、その理由を 1 行の診断として stderr に書いてから終了する。
  control byte / EOF / fatal read error の watchdog abort は `_exit(1)` を使うため、この診断を要求しない。
  この行の内容は契約の対象外であり、zsh が解析してはならない。
- セッション失敗時の破棄・再起動・無効化・警告は behavior.md「worker ライフサイクル」が定める。

## zrush config

> 検証: 既定出力 — `src/config.rs` の `default_output_matches_contract_example` が**下の出力例そのものを読んで** `zrush config` の出力と突き合わせる(この文書が唯一のコピー)。
> 同じ出力を実プロセスで — `tests/cli.rs`(独立したコピーを持つ)。
> クォート規律・設定値の反映・不正値の既定値フォールバックと警告・キーバインド配列(正規化後の重複解決を含む)— `src/config.rs` と `tests/cli.rs` の設定テスト。
> config パス解決は `$XDG_CONFIG_HOME` が設定されている経路(ファイル不在を含む)のみ検査される。未設定・空文字列で `~/.config` に落ちる規範を固定するテストは無い。
> zsh 側の規範(`emulate -L zsh` での source、`key:` の `$terminfo` 解決、`main` キーマップへの bindkey)は、既定キーバインドの範囲で `cargo test --test driver`(実 pty 上の host zsh に既定キーを送る)がスモークテストする。

config.toml を解決・検証し、zsh が `source` できる形で設定値とキーバインド定義を出力する。

### 起動

```
zrush config
```

- config パスの解決: `$XDG_CONFIG_HOME/zrush/config.toml`、
  `$XDG_CONFIG_HOME` が未設定または空文字列なら `~/.config/zrush/config.toml`
  (XDG 仕様の「空文字列は未設定扱い」に従う)。
  ファイル不在は正常(全既定値で出力、警告なし)。

### stdout(zsh source 形式)

```zsh
typeset -g  ZRUSH_BUILD_STAMP='<build-stamp>'
typeset -g  ZRUSH_CFG_MAX_LINES='10'
typeset -g  ZRUSH_CFG_DELAY_MS='30'
typeset -g  ZRUSH_CFG_MIN_INPUT='0'
typeset -g  ZRUSH_CFG_MODE='typo'
typeset -g  ZRUSH_CFG_SMART_CASE='true'
typeset -g  ZRUSH_CFG_TAB='menu'
typeset -g  ZRUSH_CFG_TRAILING_SPACE='true'
typeset -g  ZRUSH_CFG_HL_SELECTED='standout'
typeset -g  ZRUSH_CFG_HL_MATCH='underline'
typeset -g  ZRUSH_CFG_HL_HEADING='bold'
typeset -g  ZRUSH_CFG_HL_HISTORY_NUMBER='faint'
typeset -g  ZRUSH_CFG_HISTORY_LIMIT='5000'
typeset -ga ZRUSH_CFG_KEYBINDS=(
  'select-next'  'key:down'
  'select-next'  'seq:^N'
  'select-prev'  'key:up'
  'select-prev'  'seq:^P'
  'select-left'  'key:left'
  'select-left'  'seq:^B'
  'select-right' 'key:right'
  'select-right' 'seq:^F'
  'confirm'      'seq:^M'
  'dismiss'      'seq:^G'
)
typeset -ga ZRUSH_CFG_WARNINGS=()
```

- 出力は `typeset` への静的代入のみ(コマンド実行を含む出力はしない)。
- **クォート規律(規範)**: すべての値を単一引用符 `'...'` で囲み、
  値内の `'` は `'\''` にエスケープする(警告メッセージはユーザー入力由来の任意文字列を含むため必須)。
- zsh 側は `emulate -L zsh` の統制された文脈で source する(継承 setopt による解釈事故の防止)。
- `ZRUSH_CFG_KEYBINDS` は「アクション名, キー指定」の平坦な交互配列。
  **同一アクション名の組は複数回現れ得る**(1 アクション複数キー。config-schema.md)。
  zsh 側は各組を独立に bindkey する。キーが 1 つも現れないアクションは束縛しない。
  - `seq:<bindkey列>`: Rust 側で正規化が完結したもの(例: `ctrl-g` → `seq:^G`)。
    zsh はそのまま `bindkey` に渡す。
  - `key:<シンボリック名>`: 端末依存キー(例: `up`, `down`, `shift-tab`)。
    zsh 側が `$terminfo` を参照して解決する(矢印は CSI/SS3 両系統を bindkey)。
  - 正規化の詳細と対応キー一覧は config-schema.md。
  - 要素数が奇数の場合(異常出力)、出力全体をロード失敗として扱う(「エラー時の zsh 側挙動」参照)。
  - bindkey の適用先はメインキーマップ(`main`)のみ。
- `ZRUSH_CFG_WARNINGS` は設定エラーの人間可読メッセージの配列(正常時は空)。
  表示のタイミング・体裁は zsh 側の責務(config-schema.md「検証とエラーの扱い」)。
- 不正な設定値があっても exit 0 で全項目を出力する(該当項目は既定値)。

### エラー時の zsh 側挙動(規範)

- exit 非 0、出力が source 不能、または source 結果が出力仕様を満たさない場合
  (zsh が消費する変数の欠落、`ZRUSH_CFG_KEYBINDS` の奇数長)、ロード失敗として扱う:
  前回の設定値があればそれを維持して継続する。
  **source 時(初回)に失敗した場合は警告を表示して zrush を無効化する**
  (フック・キーバインドを登録しない。既定値表を zsh 側へ複製すると真実の二重化になるため)。
- `zrush config` の stderr は端末に流さない(警告は `ZRUSH_CFG_WARNINGS` 経由が唯一の経路)。

## zrush init

> 検証: 起動パースと exit 2(未指定・未知シェル・余計な引数)、2 本の prelude 行の形とその後に続く
> 埋め込みスクリプト本体がリポジトリの `zsh/zrush.zsh` とバイト一致すること — `tests/cli.rs`。
> `$ZRUSH_BIN` が既に設定されている場合に prelude の `${ZRUSH_BIN:-...}` 展開が
> それを優先して使う規範自体は通常の zsh パラメータ展開であり、`tests/cli.rs` は固定しない
> (`tests/driver/` の pty ハーネスがテスト用ランチャー `zrush-fake-worker` を `$ZRUSH_BIN` に指定してこの経路を通しで使う)。

zsh 側の `.zshrc` が source する zle 統合スクリプトを標準出力へ書き出す。
スクリプト本体はビルド時にバイナリへ埋め込まれる。

### 起動

```
zrush init zsh
```

- 受け付けるシェル値は `zsh` のみ。シェル引数の未指定・`zsh` 以外の値・余計な引数は
  起動前に exit 2 で拒否する。

### stdout

1 行目は `ZRUSH_BIN` の prelude:

```zsh
typeset -g ZRUSH_BIN=${ZRUSH_BIN:-'<自身の絶対パス>'}
```

- `<自身の絶対パス>` の既定値は、この `zrush init` を実行したプロセス自身の絶対パス
  (`current_exe` 相当)。クォート規律は「zrush config」節と同じ(`'...'` で囲み、値中の `'` を `'\''` に
  エスケープする)。パスは非 UTF-8 バイト列であり得るため、バイト単位でクォートする。
- 既に `$ZRUSH_BIN` が設定されている呼び出し元シェルでは、上記の zsh パラメータ展開
  `${ZRUSH_BIN:-...}` によりその値が優先される(prelude 側は常にこの展開形で出力するのみで、
  Rust 側で環境変数を分岐しない)。
- 2 行目は同じバイナリの build stamp を注入する prelude。既存値を優先せず、re-source のたびに上書きする:

```zsh
typeset -g _ZRUSH_EXPECTED_BUILD_STAMP='<build-stamp>'
```

- 3 行目以降は、ビルド時に埋め込んだ `zsh/zrush.zsh` の内容をそのまま出力する。

自身の絶対パスの解決、または標準出力への書き込みに失敗した場合は exit 1
(`zrush config` の内部エラーと同じ扱い)。

## 想定シーケンス(参考・規範ではない)

1. source 時: `.zshrc` の `source <(zrush init zsh)` が `$ZRUSH_BIN` / build-stamp prelude と埋め込みスクリプトを読み込む。
   埋め込みスクリプト自身の source 時処理として `zrush config` を実行し、build stamp を照合し、private runtime directory と
   request/response/abort-control FIFO を同期的・transactional に作成してからキーバインドを適用する。
2. プロンプト表示ごと: config.toml の mtime を確認し、変化していれば
   `zrush config` を再実行して source、キーバインドを再適用、警告があれば表示。
3. 最初の実メッセージ時: source 時に作成済みの FIFO endpoint だけを開き、abort-control FIFO の read fd を渡して
   `zrush worker --control-fd N` を起動し、watchdog setup 後に `hello` を送る。
   最初のメッセージは `ready` を待たずに `hello` の後ろへ pipeline する(「セッションフレーミングと握手」節)。
   遅延起動時に runtime directory/FIFO を作成してはならない。spawn 後の parent endpoint/watcher failure と
   writer notification/watcher failure の fail-closed quarantine・runtime taint は behavior.md が定める。
4. 入力変化: zsh は新しい `input_generation` を採番して `input` 通知を直ちに送る。
   worker は `delay-ms` の静穏期間を張り、打鍵が続く間は新しい通知で置き換え続ける。
   期間が満了すると、通知が名乗った `candidate_generation` を保持していれば
   `plan-ready` を返し(空語収集キャッシュのヒットはこの経路になる)、
   保持していなければ `capture-required` を返す。
5. `capture-required` 受信後: zsh が zpty 収集を 1 回だけ開始し、完走したら pid レコードを取り除いた
   捕獲 payload を、新しい `candidate_generation` と対象の `input_generation` を載せた `store` 要求
   (空語収集キャッシュの対象なら `cache`、それ以外は `live`)で送る。
   worker は `ok` を返すとともに、同じ入力に対する `plan-ready` を送る。
   zsh は現在の `input_generation` に一致する `plan-ready` の描画プランを
   POSTDISPLAY / region_highlight に適用する。
   以降の選択移動・確定は、プラン内のナビゲーション表・セル範囲・挿入テキストの配列引きだけで完結する
   (要求の再送はしない)。
6. 非選択での select-prev(既定 ↑): worker の history index が同期済みなら、
   `producer = history` の `plan` だけを同期交換で送って、返ったプランを同じように適用する。
   index が未初期化または dirty なら、zsh がメモリ上の履歴から payload を合成し、
   `history-snapshot` と `plan` を同じ同期交換で連送する
   (fork も compsys も介さない。behavior.md「履歴メニュー」節)。
7. コマンド確定後のプロンプトごと: index が同期済みで、直前のコマンドが 1 件の追記として説明できる場合、
   zsh はその 1 件を `history-append` で送る(worker を起動することはない)。
   説明できない変化を見つけた場合は index を dirty とし、次の履歴メニュー操作で作り直す。
