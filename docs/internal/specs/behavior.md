# behavior: zrush の挙動仕様

zrush の挙動の規範。
コンポーネント境界の詳細は `../contracts/cli-protocol.md`(zsh ↔ Rust CLI)と
`../contracts/config-schema.md`(config.toml)が持ち、この文書はそれ以外の
観測可能な挙動を定義する。設定キー名は config-schema.md の表記に従う。

責務境界: Rust(`zrush` バイナリ)がマッチング・ランキング・レコード解析・
グループ分割・グリッドレイアウト・ハイライト計算・ナビゲーション表構築・
挿入テキスト構築・config 解釈を担う。
zsh は zle 統合・compsys 呼び出しによる捕獲・プランの適用
(POSTDISPLAY/region_highlight への描画、BUFFER 編集、bindkey)を担う。
「zsh の意味論は zsh が計算し、データとして渡す」
(`${(Q)}` 復元・`${(q)}` クォート・`~` 展開・terminfo 解決は zsh 側)。
詳細な入出力仕様は `../contracts/cli-protocol.md`。

対象環境: zsh 5.8 以上(macOS / Linux)。
`KEYS_QUEUED_COUNT` は 5.9 追加のため、5.8 では入力圧の見送り(後述)が縮退する。

## 原則(コードに固定。設定項目にしない)

- **勝手に何かをしない**: 明示操作なしに入力内容を書き換えない。
  `~` は入力中も確定時も展開しない。
  補完候補の確定はカーソル以降のテキスト(RBUFFER)に触らない。
  履歴候補の確定は行全体の置き換えを求める明示操作であり、RBUFFER も含めて置き換える
  (規範は `../contracts/cli-protocol.md`「適用」節)。
- **入力は決してブロックしない**: 候補収集は非同期で行う。
  収集が遅い場合も「一覧が遅れて出る」だけで、打鍵は常に即応する。
  ただし履歴メニュー(後述)はユーザーの明示操作であり、同期実行を許す:
  走査する履歴エントリ数は `[history].limit` 件までに限り、worker 交換には固定の絶対 100ms deadline を置く。
- **確定は挿入のみ**: コマンドは実行しない(実行はもう一度 Enter)。
- zrush は compinit を実行しない。compsys 未初期化を検知したら警告のみ表示する。

## worker ライフサイクル

- 対話シェルごとに `zrush worker` を最大 1 プロセス持つ。source 時には `zrush config` だけを one-shot で実行し、
  worker は最初の plan 要求が生じた時点で遅延起動する。worker は config.toml と `HISTFILE` を読まず、
  候補キャッシュ・履歴 payload 合成・デバウンス/収集キャンセルの状態も持たない。
- worker の stdin/stdout は pty ではなく専用 pipe へ接続する。zsh は stdout の read fd を `zle -F` で監視し、
  通常の補完 plan 応答を非同期に読む。セッションの nested-netstring 形式と `hello` / `ready` 握手は
  `../contracts/cli-protocol.md` が定める。
- worker は対話シェルの job table に登録せず、動作中でもシェルの `exit` を妨げない。
- 通常の補完経路では、worker の cold start と握手を待たない。起動処理は ZLE へ直ちに制御を返し、
  `hello` も outbound queue の先頭フレームとして、他の plan 要求と同じく後述の writer child 経由で送る。
  `ready` の受信は worker stdout の既存の `zle -F` callback で進める。
  握手中に生じた plan 要求は `hello` より後ろの outbound queue に置く。
  同期的に worker を待ってよいのは履歴メニューだけであり、その待機も後述の 1 本の絶対 100ms deadline 内に限る。
- worker stdin への送信はフレーム単位で行う。
  フレームは不可分な送信単位であり、outbound queue は完成済みフレームのリストを持つだけで、
  対話シェル側に送信オフセットは存在しない。
  対話シェルは worker stdin(request FIFO)への blocking な write fd を worker 起動時に確保し、
  FIFO パスの unlink 前に開いた上で cloexec を付けて worker には継承させない
  (fork した子は cloexec の性質上、exec するまで fd を引き継ぐ)。
  1 フレームの送信は、この blocking fd を渡して fork した短命な writer child に委譲する。
  writer child は 1 回の `syswrite` でフレーム全体を書き切り、書き終えたら通知用パイプへ
  ack バイトを 1 個書く。
  writer child は worker と同じく対話シェルの job table に登録しない。
  対話シェルは通知 fd を `zle -F` で監視し、blocking write を一切行わず
  ZLE callback 内で書き込み完了を待たない。
  ack の消費は通知 fd の readiness を確認したうえで行い、通知 fd の `zle -F` callback・
  worker 応答の受信時・同期履歴ループのいずれから行ってもよい。
  in-flight の writer child は常に高々 1 個であり、次のフレームは直前の child が
  ack バイトを書いた時点で送る。
  worker は受信した plan を直列に処理するため、この直列送信によって queue も request_id 順を保つ。
  busy loop は行わない。
- queue に入った通常の補完要求は、新しい要求で coalesce・置換・除去しない。
  送信時点ですでに stale でも同じ session 上で順に送り、worker の終端応答まで読み取って UI への適用だけを捨てる。
  request FIFO の backpressure が及ぶのは writer child の `syswrite` だけであり、ZLE を止める理由にはならない。
  queue の残りは、writer child からの ack を受けてから次のフレームとして送る。
- `request_id` は zsh が所有し、実 plan 要求ごとに増やす。同じシェルセッションでは worker の再起動後も
  リセット・再利用しない。新しい実要求を開始した後に古い request_id の正常応答が届いても stale として捨て、
  表示には適用しない。worker は受け取った各要求へ `ok` / `error` を 1 個返し、zsh 側の stale 判定を理由に
  応答を省略させない。
- 外側/nested framing の破損、stdout の EOF/read error、writer child の通知 fd が ack バイトなしで
  EOF に達すること(stdin の write 失敗)、予期しない終了、要求と対応しない応答、
  仕様を満たさない `ok` の描画プラン、履歴交換の deadline 超過は **worker セッション失敗**である。
  stdin の write 失敗は通知 fd の EOF/ack のみで判定し、writer child の終了ステータスからは
  一切推測しない。
  その session に割り当て済みで終端応答のない要求を、writer child に渡して送信中のフレーム・
  outbound queue 内のフレーム・送信済みの要求の区別なくすべて破棄し、既存一覧も消す。
  いずれも自動 replay しない。
  in-flight の writer child がいれば、未送信のフレームを queue から破棄したうえで
  その child の終了を有界時間だけ待ち、なお終了しなければ TERM してから KILL する。
  フレーム送信の途中で kill された child は request FIFO に不完全なフレームを残すが、
  これは worker がフレーミングエラーとして検出する想定内の abort 挙動であり、正常な EOF とは区別できる。
  worker プロセスが残っていれば終了させて消滅を確認し、`zle -F` watcher を解除して
  stdin/stdout pipe fd と通知 fd を閉じ、head-of-line blocking を残さない。
  この cleanup が完了するまで代替 worker を起動せず、worker を重複させない。
- 連続 worker セッション失敗回数は、正常に形成された終端 `ok` / `error` を受けたときだけ 0 に戻す。
  握手成功だけでは戻さない。1 回目の失敗後は worker 不在のままにし、**次の実要求**で 1 個だけ代替 worker を
  遅延起動する。終端応答を 1 個も受けないまま 2 回目のセッション失敗が起きたら、そのシェルでは zrush を無効化する。
  無限 respawn や one-shot plan への fallback は行わない。
- `hello` / `ready` の版不一致または worker の `incompatible` 応答は、失敗回数による再起動を介さず
  即座に zrush を無効化する。source 時の `zrush config` 版照合も同じく不一致なら無効化する。
- worker 障害のユーザー向け警告は、種類や再発回数によらず同じシェルセッションで高々 1 回表示する。
  `ZRUSH_LOG` が設定されている場合、ユーザー向け警告を抑止した後も各障害の診断を追記する。
- worker の起動・通常終了・異常終了・再起動・re-source・無効化を含む全 lifecycle で、zsh が所有する
  内部 fd の操作は対話シェル自身の fd 0 / 1 / 2 の open / closed 状態と接続先を変更しない。
  内部 fd の close error を抑止するときも、その抑止を対話シェルの標準エラーへ恒久適用しない。
- 同じシェルで zrush.zsh を re-source するときは、既存 worker プロセスを終了させて消滅を確認し、`zle -F` watcher を解除して
  stdin/stdout pipe fd を閉じてからフックとキーバインドを再構築する。cleanup 中に新旧 worker を重複させない。
  re-source は同じシェルセッションの request_id 単調性・警告済み状態・連続失敗回数・無効化状態を巻き戻さない。
  `zshexit` でも worker プロセスを終了させて消滅を確認し、watcher を解除して pipe fd を閉じる。
  worker が既に終了していることはエラーにしない。

## 候補収集

- バッファ変化の検知は `zle-line-pre-redraw`(前回の `BUFFER`/`CURSOR` との差分)。
  登録は `add-zle-hook-widget` 経由。
- 変化からデバウンス(`delay-ms`、既定 30ms)後に収集を開始する。
  タイマー発火時に未処理のキー入力がある場合は見送り、次の変化で再アームする。
- **空バッファ(空白のみを含む)では収集も表示もしない**。
  `min-input` はこの抑止規則とは独立に現在語の長さで一律判定する。
  空の引数語も長さ 0 として扱うため、`min-input >= 1` なら `ls ` 直後の一覧は抑止される。
  この抑止規則と `min-input` が適用されるのは入力に追従する自動表示のみで、
  明示操作である履歴メニュー(後述)には適用しない。
- **広げ規則**: 現在語(カーソルまで)のうち、最後の `/` または `=` より後ろを
  空にした文字列で収集する。区切りがなく `-` で始まる語は先頭のダッシュ列を保持する。
  それ以外は語全体を空にする。削った末尾が Rust に渡す fuzzy クエリになる。
- 現在語は「カーソルまでのバッファの最後の空白文字より後ろ」という素朴な規則で特定する。
  クォートを解釈しないため、クォート内空白を含む語は正しく扱えない。
- 収集は zpty(現在シェルの fork)内で compsys を駆動し、compadd フックが
  候補レコードを継承 pipe fd へ NUL 区切りで搬出する(終端 = EOF)。
  フレーミングに使う制御バイト(NUL、`\1`、`\2`)を含む候補は一覧に載らない。
  レコードのタグ構成(バッチヘッダ・`m` タグを含む)は
  `../contracts/cli-protocol.md`(plan 要求の `candidate_payload`)の契約に従う。
  キャンセルは worker 自己申告 pid のプロセスグループへの SIGINT → `zpty -d`。
- 新しいリクエストの開始時に進行中の収集をキャンセルする。
  **キャンセルされたリクエストの結果は、その後に到着しても表示に使わない**
  (`zpty -d` 後に届く残留データは捨てる)。
- キャンセルされずに完走したリクエストの結果は、そのリクエストのクエリに基づく表示として適用する
  (一覧はバッファ変化時に選択ハイライトのみ即解除され、テキストは次の結果が届くか
  リクエストがキャンセルされるまで残るという「表示」節の規範と整合する)。
- fork 側の衛生(コードに固定): 継承フック(precmd / preexec / chpwd /
  zshaddhistory / periodic / zshexit)と zle-* フックを無効化し、`SAVEHIST=0` で
  実履歴を保護する。候補データは zpty の擬似端末を経由せず、
  リクエスト開始時に用意した匿名パイプへ `print -rn -u` で直接書き込む
  (`zpty -w` / `zpty -r` は使わない)ため、pty の行制御による改行注入は構造的に起こらない。
  `zpty -t` も使わない(無出力の子で数秒ブロックし得る)。
- compadd フックの pipe 書き込みは compadd 呼び出し単位のバッチで行う
  (レコード毎の書き込みは読み手の read 回数を増やし、大量候補で顕著に遅くなる)。
- compsys 初期化済みの検知は `$+functions[_main_complete]` による
  (zsh-autocomplete が compinit を代行する構成も検出できる)。

## 空語収集キャッシュ

行頭のコマンド位置(広げ結果が空文字列)の収集は最重量ケース(全コマンド名)のため、
結果をプロンプトを跨いでキャッシュする。

- 対象は広げ結果が空文字列の収集のみ。`sudo ` 後などのコマンド位置は対象外。
- キャッシュが保持するのは**生の捕獲 payload(ワーカーの pid レコードを取り除いた形。
  cli-protocol.md)・フィンガープリント・保存時刻**の 3 つ。
  解析・マッチング結果そのものはキャッシュしない(解析は Rust worker の責務のため)。
- 検証は使用時に行う: **フィンガープリント**(`$PATH` 文字列 + PATH 各ディレクトリの
  mtime + 関数・エイリアス・ビルトインの個数。`autocd` 有効または PATH に相対要素が
  ある場合のみ `$PWD` を含める)の一致と、**TTL 300 秒**(固定値)。
- ヒット時は compsys の fork をせず、キャッシュした payload をそのまま plan 要求の
  `candidate_payload` に入れて結果を得る。ミス時は通常どおり収集し、成功時に payload とフィンガープリントを保存する。
- 既知の癖: compsys が補完関数を遅延ロードすると関数個数が増え、直後の 1 回だけ
  余計にミスする。これは正しい無効化であり一度きりで収束する。

## マッチング

- 常駐 Rust worker の plan 要求処理が担う。ティア序列は
  **prefix > substring > edit(誤字許容)> fuzzy(部分列)** で、`mode` が
  どのティアまで拾うかの上限を決める。prefix / substring は literal、edit / fuzzy は
  approximate とする。`mode` が許す literal マッチが 1 件以上あれば approximate マッチを
  すべて除外し、literal マッチがなければ `mode` が許す approximate マッチを残す。
  この規則は補完一覧と履歴一覧の両方に適用する。`smart-case` はクエリが全小文字のとき大小を無視する。
  結果順を含む意味論の規範は cli-protocol.md「マッチング・ランキングの意味論」節。
- common-prefix は prefix 階層マッチのバイト単位 LCP(cli-protocol.md)。

## 表示

- 候補一覧はプロンプト下に POSTDISPLAY + region_highlight で描画する。
- 更新は POSTDISPLAY の**置き換え**(消してから描かない。空白・点滅を見せない)。
  バッファ変化時は選択ハイライトのみ即解除し、一覧テキストは次の結果まで残す。
- レイアウト(グループ分割・補完一覧の列優先グリッド・履歴一覧の単一列・見出しの省略・セル幅・ハイライト範囲・
  ナビゲーション表・挿入テキスト)の計算は Rust worker が行う。
  zsh は返った描画プランをそのまま POSTDISPLAY / region_highlight へ適用するだけで、
  行数・列数・装飾範囲を独自に計算しない。
  行数予算(`rows`)は zsh が `min(max-lines, $LINES - 1)` から、
  桁数予算(`width`)は `$COLUMNS - 1` から都度算出して渡す(cli-protocol.md)。
  zsh は収集を制限しない(compsys が返す候補をすべて捕獲する)。
  worker が補完一覧ではランキング上位 `rows × 8` 件、履歴一覧では先頭 `rows` 件
  (それぞれのレイアウトが取り得る最大容量)までをレイアウト対象に取る
  (Rust 内部の上限。プロトコルには現れない)。
- 補完一覧の plan 要求は、収集完了後の非同期結果経路から worker へ送る。
  応答は worker stdout の `zle -F` コールバックで受け、キー入力を同期的に待たせない
  (「入力は決してブロックしない」原則)。
  例外は履歴メニューで、こちらは select-prev の押下時に同期実行する(「履歴メニュー」節)。
  ディレクトリ合成 `/` 判定のための stat(cli-protocol.md「挿入テキスト」節)は
  表示位置として採用された候補数に有界であるため、この非同期実行を妨げない。
- ワイド文字の整列: プラン内のオフセット(ハイライト範囲・セル実テキスト範囲)は文字数、
  セルのパディング・切り詰めは表示幅(unicode-width)で計算済み(cli-protocol.md)。
  候補テキスト中の制御バイト(C0 と DEL)のスペース置換も Rust worker が行う正規化であり
  (改行が消えることで表示が 1 行化される。規範は cli-protocol.md「表示行の中身」節)、
  挿入テキストは原文のまま返る。
- 端末リサイズ時: 描画プランは要求時点の `rows` / `width` に基づくスナップショットであり、
  リサイズ直後に自動で再計算されることはない。
  次の plan 要求までのレイアウトのズレは仕様外として許容する。
- 装飾は `[display.highlight]` の 4 種(selected / match / heading / history-number)。
  match と history-number の装飾は選択中セルには適用しない
  (実現方法は cli-protocol.md「ハイライト」節: 選択変更のたびに
  プランからエントリを再構築し、選択エントリへ差し替える)。空文字列は装飾なし。
- region_highlight の自エントリは帳簿で管理し、zsh 5.9+ では `memo=zrush` を付与して
  他プラグイン(zsh-syntax-highlighting 0.8+ など)のエントリと区別する。
  5.8 では memo が使えないため、バッファ編集後の選択ハイライト解除が
  次の描画まで遅れる劣化を許容する。

## 選択・キーバインド

- zrush がキーを奪うのは次の 4 つの場合だけで、それ以外は zrush 適用前に
  そのキーへ束縛されていたウィジェット(前任者チェーン)へフォールバックする:
  ① 選択中(全アクション)、② 一覧表示中の dismiss(非選択でも一覧を閉じる)、
  ③ 一覧表示中・非選択の select-next が後述の優先順位規則で選択開始に解決した場合、
  ④ 非選択時の select-prev が後述の委譲条件に当たらない場合(履歴メニューを開く明示アクション)。
- 非選択時の select-next(既定 ↓ / ctrl-n)は優先順位規則で解決する:
  ① 複数行バッファの途中行にカーソル → カーソル移動、
  ② 履歴移動中(`HISTNO != HISTCMD`)→ 履歴戻り、
  ③ 一覧表示中 → 選択開始、④ それ以外 → 前任者。
- 非選択時の select-prev(既定 ↑ / ctrl-p)も優先順位規則で解決する:
  ① `LBUFFER` に改行を含む(複数行バッファの先頭行以外にカーソル)→ カーソル移動、
  ② 履歴移動中(`HISTNO != HISTCMD`)→ 前任者(素の履歴移動を続ける)、
  ③ それ以外 → 履歴メニューを開く(「履歴メニュー」節)。
  ① は select-next の複数行規則と対称で、どちらもカーソルが動くべき場面を優先する。
- 補完一覧の先頭候補での select-prev は選択を解除して通常状態に戻る(一覧テキストは残る)。
  そこでもう一度押すと、非選択時の規則に従って履歴メニューが開く。
- select-left / select-right は選択中のみ列ジャンプ(グリッド行数ぶん移動、
  グループ範囲でクランプ)。
- dismiss は一覧を閉じる(バッファには触らない)。
- 選択移動・列ジャンプの実現は、直前の plan 応答が返したナビゲーション表
  (位置ごとの next/prev/left/right。cli-protocol.md)を参照するだけで完結する。
  再収集・再計算は伴わない。
  補完一覧では select-next が `next`、select-prev が `prev` に対応する
  (履歴一覧での写像は「履歴メニュー」節)。
- アクションと既定キー・記法・検証規則は config-schema.md の `[keybind]`。

## 履歴メニュー

現在の入力で絞り込んだ履歴を一覧表示し、選んで挿入するための明示操作。

- 一覧には種別があり、**補完一覧**か**履歴一覧**のどちらか一方である(両方が同時に存在することはない)。
  確定規則(cli-protocol.md「適用」節)とキーの写像は種別で決まる。
- **開く操作**は非選択時の select-prev(既定 ↑ / ctrl-p)。専用のアクションは設けない。
  補完一覧を表示中でも、非選択なら履歴メニューが開いて補完一覧を置き換える。
  ctrl-p も既定で同じ挙動になる。ctrl-p を素の履歴移動のまま使いたい場合は
  keybind 設定で select-prev から外す(config-schema.md `[keybind]`)。
- **開くときの遷移**は不可分に行う: デバウンス待ちのタイマーを解除し、進行中の収集をキャンセルし、
  現在の一覧とプランを破棄してから、履歴 payload の合成・同期 worker 交換・履歴一覧としての表示・
  位置 1 の選択までを一度に確定させる。
  キャンセルされた収集の結果は後から届いても表示に使わない(「候補収集」節)ため、
  遅れて到着した補完結果が履歴メニューを置き換えることはない。
- payload は zsh がメモリ上の履歴から合成する(fork も compsys も介さない。
  合成規則は cli-protocol.md「history profile」)。
  worker との plan 要求/応答を同期的に待つのはこの経路だけである。
- 履歴 payload の合成が完了した直後から、対象 request_id の完全な終端応答を受け取るまでを
  **1 本の絶対 100ms deadline**で制限する。worker が未起動なら、その起動・`hello` / `ready` 握手・
  要求送信・完全な応答受信をすべて同じ 100ms に含める。deadline は固定方針であり設定項目にしない。
  環境変数 `ZRUSH_HISTORY_DEADLINE_MS`(ミリ秒、未設定時は 100)で deadline を上書きできるが、これは `zsh/zrush.zsh` の `ZRUSH_BIN` と `ZRUSH_NO_INIT` に倣ったテストドライバ専用の seam である。
  payload 合成に費やす時間はこの deadline に含めない。
- 対象 request_id の完全な終端応答を受信した時点で同期待ちは終了する。
  受信済みで未処理の後続応答は同期待ちの中では処理せず、非同期経路が引き取る。
- 同期待ちの間に先行する非同期要求の応答を受けた場合も通常どおり終端まで読み、stale なら破棄して
  対象 request_id を待ち続ける。先行要求の outbound queue 送信と直列処理に費やす時間も同じ deadline を消費する。
  deadline を要求ごと・write/read ごとに延長しない。超過時は worker プロセスを終了させて消滅を確認し、
  watcher を解除して pipe fd を閉じてから、その session の未完了要求をすべて破棄する。自動 replay しない
  (連続失敗の扱いは「worker ライフサイクル」)。
- クエリは `BUFFER` 全体。`min-input` と空バッファ抑止規則は適用しないため、
  空バッファの ↑ は全履歴の一覧を出す。
- 並びは新しい順のままで、位置 1 はマッチした候補のうち最も新しい履歴行
  (クエリにマッチしない履歴行は一覧に含まれないため、必ずしも履歴全体の最新行ではない)。
  マッチングのティア(prefix > substring > edit > fuzzy)と smart-case は、
  候補を一覧に含めるかの判定とハイライトにのみ効く(cli-protocol.md「マッチング・ランキングの意味論」節)。
- 履歴一覧は単一列で、スクロールバックのように上へ伸びる。位置 1(最新)を最下行に置き、
  位置番号が大きくなるほど古い履歴として 1 行ずつ上へ配置する。
- 各表示セルの先頭には、その履歴行のイベント番号(`$history` のキー)を右寄せした番号欄と
  空白 2 個を表示する。番号は `[display.highlight].history-number` で装飾し、
  選択中はセル全体の selected 装飾を優先する。番号と表示用の空白は確定時の挿入に含めない。
- 履歴メニューは開いた時点で位置 1 を選択済みであり、**非選択の履歴メニューは存在しない**。
  選択が外れる遷移はすべて履歴メニュー全体の消去になる。
- キーの写像(履歴はスクロールバックのように上へ伸び、矢印は画面上の向きに選択を動かす):
  - select-prev(既定 ↑ / ctrl-p)= 1 つ古い履歴へ(ナビゲーション表の `next`)。
  - select-next(既定 ↓ / ctrl-n)= 1 つ新しい履歴へ(ナビゲーション表の `prev`)。
  - 位置 1 での select-next は履歴メニュー全体を閉じて通常状態に戻る(バッファは変えない)。
  - select-left / select-right は共通ナビゲーション表の単一列での帰結として、
    それぞれ位置 1(最新) / 表示中の最終位置(最古)へ移動する。
- ブラウズ中は `BUFFER` に触らない(移動のたびに挿入することはしない)。
- confirm(既定 Enter)は行全体の置き換えで挿入する(実行はしない。「確定(挿入)」節)。
  選択中の Tab も同じく確定。確定後は通常のバッファ変化として再収集へ戻り、履歴一覧は残らない。
- dismiss(既定 ctrl-g)は履歴メニューを閉じる(バッファは変えない)。
- 履歴メニューを消して通常状態へ戻る条件:
  - **マッチ 0 件**(履歴が 0 件の場合を含む)→ メニューは開かず(既存の一覧があれば消し)、
    キーは消費してバッファは変えない。素の履歴移動へのフォールバックはしない。
  - **同期 worker 交換の失敗**(`error` 応答、worker セッション失敗、deadline 超過、
    または仕様を満たさない `ok`)→ 一覧と種別を破棄し、
    バッファは変えない(cli-protocol.md「エラー時の zsh 側挙動」)。
  - **zrush のアクション以外の要因による `BUFFER` / `CURSOR` の変化**
    (文字入力・編集・カーソル移動・他ウィジェット)→ 履歴メニューを全消去して通常フローへ戻る。
    補完一覧のように一覧テキストを残すことはしない。
- 履歴行が複数行コマンドの場合、表示は 1 行化され(「表示」節)、
  確定で入る `BUFFER` は改行を含む原文になる。

## Tab

`^I` は固定の Tab フックに束縛され、挙動は `[insert].tab` に従う。

- `menu`: 選択開始。
- `insert`: 先頭候補を確定挿入。
- `common-prefix`: クエリが common-prefix の真の接頭辞なら共通部分を挿入する
  (確定ではない。挿入後は通常フローの再収集に任せる)。
  伸びない場合は先頭候補を確定挿入する(insert と同じ確定動作)。
- pending Tab の結果が候補 0 件なら何もしない。選択中の Tab は確定。
- 候補未着時(収集中・デバウンス待ち)の Tab は押下を記録して収集を前倒しし、
  結果到着時に上記の挙動を適用する。素の compsys への同期フォールバックはしない。
- 一覧がなく、収集中でもデバウンス待ちでもない静止状態の Tab は、
  前任者チェーン(素の補完など)へフォールバックする。

## 確定(挿入)

- 各位置の挿入テキストは Rust worker が構築済みで返す
  (`IPREFIX + ipre + apre + hpre + word + hsuf + asuf + isuf` の連結、
  `-f` 候補のディレクトリ合成 `/`、`trailing-space` の焼き込みまで含む。
  構築規則は cli-protocol.md「挿入テキスト」節)。
- 補完候補の確定は**単一規則**: `LBUFFER` を `pre + 挿入テキスト` で置き換える
  (`pre` = `LBUFFER` から現在語を除いた前半部分。`RBUFFER` は変更しない。
  適用規則は cli-protocol.md「適用」節)。
  候補の捕獲接頭辞(IPREFIX + hpre)が広げ規則の保持末尾と一致する場合、
  この置換は結果的に末尾のみの置換とバイト同一になり、as-typed の `~` などが保たれる。
  一致しない場合(部分パス略記の展開など)も同じ規則で置換する。
- 履歴候補の確定は行全体の置き換え: `BUFFER` を挿入テキストで置き換え、`CURSOR` を末尾に置く
  (適用規則は cli-protocol.md「適用」節)。
- 確定後は一覧をいったん消去し、確定による挿入も通常のバッファ変化として扱って
  再収集をトリガする(デバウンス経由)。trailing-space 付き確定なら次の引数位置、
  `/` 合成なら当該ディレクトリ内容の候補が非同期で表示される。

## 設定の反映と警告

- 設定はプロンプト表示ごとに config.toml の mtime を確認して自動反映する
  (明示リロードなし。検証・フォールバック規則は config-schema.md)。
- 設定警告は config を(再)読み込みしたプロンプトで stderr に 1 行ずつ表示する
  (再読み込みは mtime 変化時のみのため、変化のないプロンプトで再表示されない)。
- zsh スクリプトとバイナリのプロトコル版が不一致の場合は警告を 1 回表示して zrush を無効化する。

## プラグイン共存

- キーのフォールバックは前任者チェーン(builtin 直呼びはしない)。
  config リロードでの再適用時に自分自身を前任者として捕まえない。
- `zle-line-pre-redraw` は `add-zle-hook-widget` で登録する。
- fork 内で候補を収集するときは、他プラグイン(zsh-autosuggestions など)が定義した
  compadd ラッパーを除去してから compsys を呼ぶ。この変更は fork 内に限られ、
  親の対話シェルの状態には影響しない。
- 検証対象は作者環境の zsh-syntax-highlighting と zsh-abbr の 2 つ。
  一般のプラグイン互換性は保証しない。
