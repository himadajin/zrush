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
  この原則に対する同期的な例外は、ユーザーが明示した履歴メニュー(後述)と、
  process の重複・frame 途中の EOF・fd の取り違えを防ぐための worker lifecycle 停止だけである。
  履歴メニューで走査する履歴エントリ数は `[history].limit` 件までに、合成する payload は
  固定のバイト上限までに限り、worker 交換には
  固定の絶対 100ms deadline を置く。lifecycle 停止も後述の 1 本の絶対 100ms deadline 内だけ
  同期待機を許し、正常 shutdown から異常 abort へ移っても更新しない。超過後は入力へ戻して
  readiness-driven cleanup を続けるため、入力を無期限に止めない。
- **確定は挿入のみ**: コマンドは実行しない(実行はもう一度 Enter)。
- zrush は compinit を実行しない。compsys 未初期化を検知したら警告のみ表示する。

## worker ライフサイクル

- zsh script の source generation ごとに、mode 0700 の private runtime directory を 1 個同期的に作り、
  その中に mode 0600 の request / response / abort-control FIFO を 1 個ずつ持つ。
  request は worker stdin、response は worker stdout、abort-control は watchdog の入力に使う。
  runtime directory と FIFO の path はその generation だけが所有し、設定項目にはしない。
  runtime の作成は source 時だけに行い、遅延 worker 起動は既存の path を開くだけで同期的な directory/FIFO 作成を
  行わない。通常の worker session 交換では taint されていない同じ directory を再利用し、re-source の handoff
  完了時または shell exit 時に所有する正確な path だけを unlink して directory を破棄する。
- runtime directory/FIFO の作成、worker spawn 前の各 endpoint fd 取得、cloexec の設定、active state の公開は
  transaction として行う。spawn 前の失敗は local な fd/path を rollback し、部分的な session を公開しない。
  未設定/割り当て失敗の fd を 0 と解釈せず、fd 0 / 1 / 2 を internal state へ格納したり stdin を監視したり、
  worker 起動/交換を部分的に active にしたりしない。source 時の同期 setup に失敗した generation は
  hook/keybind/worker transport を有効化しない。
- worker を spawn した後の parent endpoint allocation・cloexec・active-state 公開の失敗は、spawn 前の rollback には
  戻せない。local response/request/control fd を rollback 専用 state として公開して stopping gate を立て、control
  byte/EOF と request close で fail-closed abort を開始する。worker が ownership を持つ response stream の read fd は
  completion oracle として保持して raw drain し、response EOF と存在する writer gate の解決までは新しい worker を
  許可しないため、部分公開や worker overlap を起こさない。
- spawn 後の response watcher 登録に失敗した runtime は taint し、所有する 3 つの FIFO 名を直ちに unlink して
  既に開いた inode へ old worker/parent を閉じ込める。runtime directory/path の ownership ledger は source cleanup
  まで保持し、response EOF まで上記の rollback quarantine を続ける。readiness cleanup を保証できない場合は
  fail-closed のまま direct な明示 cleanup または shell exit に委ねてよい。EOF finalization 後も taint は残り、
  同じ source generation で worker を交換しない。
- worker は最初の実要求で遅延起動し、対話シェルごとに高々 1 個とする。
  stdin/stdout は request/response FIFO に接続し、abort-control FIFO の read fd を
  `zrush worker --control-fd N` で渡す(詳細は `../contracts/cli-protocol.md`)。
  worker と短命な writer child は対話シェルの job table に登録せず、zsh は両者の numeric PID を
  lifecycle state に記録せず、signal / `wait` / exit status で終了を判定しない。supervisor process も設けない。
- worker は通常の request 処理より先に watchdog thread を起動する。zsh は正常 session 中、
  abort-control FIFO の write fd を open のまま保持する。watchdog は control byte を 1 個でも受けた場合、
  control EOF、または retry 不能な read error の場合に process 全体を `_exit(1)` させる。
  正常な frame 境界の request EOF だけは worker の通常 exit 0 を生じさせる。
  worker は response FIFO に接続した fd 1 を自身の lifetime 全体で所有し、起動時に cloexec を付けて
  descendant へ継承させない。したがって raw drain 後の response EOF だけを worker completion の oracle とし、
  control channel や request FIFO の EOF、job/exit status から完了を推測しない。
- request/response の nested-netstring と `hello` / `ready` は
  `../contracts/cli-protocol.md` が定める。通常の補完経路は cold start・握手・応答を同期的に待たず、
  response fd の `zle -F` callback で進める。同期的に起動と応答を待てるのは履歴メニューだけで、
  その 1 本の絶対 100ms deadline に起動・握手・先行 request・`store` と `plan` の連送・
  `plan` の終端応答をすべて含める。
- worker stdin への送信単位は完成済み frame 1 個で、outbound queue に send offset を持たない。
  対話シェル自身は request FIFO へ blocking write せず、cloexec 付き request write fd を fork した
  短命な writer child に渡す。fork した child は request と通知以外の transport fd copy を直ちに閉じ、
  control/response EOF を保持しない。writer は 1 回の `syswrite` で frame 全体を書き、直後に自身の request fd を
  閉じてから通知 pipe へ ack byte 1 個を書く。ack は full-frame delivery を証明し、その時点で writer の
  通知 watcher/fd、transport ownership、sole writer slot を解放するため、通常送信では writer process の
  通知 EOF を待たず次 frame を渡してよい。ack 前の通知 EOF は write failure であり、通常 session を失敗にする。
  停止中の unacked writer は ack または通知 EOF のどちらかを観測するまで replacement gate として残るが、
  numeric PID や writer process の消滅確認は必要としない。
- writer を spawn した後に notification fd の取得、watcher 登録、または slot 公開が失敗した場合は、frame が
  request FIFO へ部分的に届いた可能性を否定できないため、その 3-FIFO runtime generation 全体を taint する。
  所有する 3 つの FIFO 名を直ちに unlink して open 済み inode へ old writer/worker を閉じ込め、worker を異常 abort
  する。取得済みの notification fd があれば ack/EOF まで gate として保持し、response EOF まで raw drain する。
  runtime directory/path の ledger は source cleanup まで保持するが、taint された FIFO inode/runtime は replacement に
  再利用しない。cleanup 後も同じ source generation では worker を再開せず、新しい source generation の同期 runtime
  setup が成功した後だけ transport を再び有効化する。notification watcher 登録に失敗した場合は direct な明示
  cleanup まで fail-closed でよい。
- 通常の queue は coalesce・置換・除去せず request_id 順に直列送信する。送信時に stale でも worker の
  終端応答まで読み、UI 適用だけを捨てる。backpressure を受けるのは writer の `syswrite` だけで、
  ZLE callback は ack を同期的に待たず busy loop もしない。
- response / writer-ack / drain の callback 登録ごとに同じ shell session 内で単調増加する compact generation を
  割り当て、callback は fd と generation が現在の登録に一致するときだけ state を変更する。response と ack の
  watcher は停止開始時にも登録を保ち、callback 自身が stopping gate を見て通常の parse/send ではなく raw drain /
  stop-progress へ分岐する。停止専用の別 callback kind へ登録し直さない。finalization・rollback は watcher より先に
  registration generation を無効化するため、snapshot 済み callback や numeric fd 再利用後の stale callback は
  何もしない。fd/watcher/generation/active state の公開と rollback も transaction とする。
- transport の停止には、健全な session を手放す **正常 shutdown** と、session を信用できない
  **異常 abort** がある。どちらも最初に stopping gate を立て、normal callback と新しい enqueue/send/start を止め、
  unhanded frame と session の未完了 request をすべて破棄し、一覧を消して replay しない。
  zrush の disable policy は stop mode と別に決める。
- 解析済みの候補は worker がスロット(`live` / `cache`)ごとに candidate generation 単位で保持する
  (`../contracts/cli-protocol.md`「要求と応答」節)。
  zsh が要求を跨いで参照するのは `cache` スロットだけであり、
  「現 worker session が `cache` スロットにどの generation を保持しているか」を
  **candidate store latch** として持つ。
  `live` スロットの store は直後に連送する `plan` からしか参照しないため、latch を持たない。
  candidate store は worker session に属するため、latch は worker の起動・正常 shutdown・異常 abort・
  session failure・worker の交換・re-source のたび、および latch を参照して送った `plan` が
  `unknown-generation` を受けたときに無効化する。
  latch を無効化した generation を payload の再送で復元することはせず、
  失敗した `store` / `plan` も replay しない。
  次の実入力による新しい収集だけが新しい generation を作る。
- 正常 shutdown は unhanded frame を破棄し、unacked writer があれば full-frame ack を待つ。
  ack を受けると writer が既に自身の request fd を閉じているため、対話シェルの request write fd を閉じて
  frame 境界の EOF を作る。その後も abort-control write fd は閉じず、response FIFO を bytes のまま EOF まで
  raw drain する。drain 中の `ready` / `ok` / `error` は parse も UI 適用もしない。
  response EOF と、writer slot が ack または通知 EOF で解決して通知 watcher/fd も解放済みであることの
  両方で停止完了とする。
- 異常 abort は abort-control FIFO へ byte 1 個(値は任意)の送信を 1 回だけ試み、その write fd と
  対話シェルの request write fd を閉じる。byte を送れなくても control EOF が watchdog を停止させる。
  response FIFO は正常 shutdown と同じく raw drain し、response EOF を worker completion とする。
  unacked writer は ack または通知 EOF まで replacement gate に残す。abort は request を replay せず、
  response を通常応答として parse/apply しない。
- 1 回の lifecycle stop が入力を同期的に止めてよいのは、開始時に定めた **1 本の絶対 100ms deadline** 内だけである。
  正常 shutdown 中の ack failure や session failure は同じ deadline のまま abort へ遷移し、
  deadline を更新しない。deadline までに停止 predicates が揃わなければ control byte/EOF による abort を確実に開始して
  入力へ制御を戻し、runtime directory・endpoint・stopping gate を quarantine として保持する。
  以後は generation 検証付きの既存 ack/response callback が stopping branch で readiness-driven に writer gate の解決と
  raw response drain を続け、新しい deadline や同期 loop を開始しない。response EOF と writer gate 解決後にだけ
  finalization が fd/session state を解放し、代替 worker を許可する。
- 外側/nested framing の破損、通常処理中の response EOF/read error、ack なしの writer 通知 EOF、
  予期しない終了、要求と対応しない応答、仕様を満たさない `ok`、履歴交換の deadline 超過は
  **worker session failure** であり、異常 abort を開始する。その session の未完了 request は
  queue/送信中/送信済みを区別せず破棄して replay しない。
- 連続 worker session failure 回数は、正常に形成された終端 `ok` / `error` を受けたときだけ 0 に戻す。
  握手成功だけでは戻さない。1 回目の失敗を finalization した後は worker 不在のままとし、次の実要求で
  代替 worker を 1 個だけ遅延起動する。終端応答なしの 2 回目でその shell の zrush を無効化し、
  無限 respawn や one-shot fallback は行わない。ただし taint された runtime generation はこの通常の 1 回交換の
  対象外であり、cleanup 後も fresh re-source まで代替 worker を起動しない。
- 2 回目の session failure による circuit breaker は `session-failure` の disable reason を持つ。
  worker が健全に finalization された後、ユーザーが明示的に re-source した場合だけ、この reason と
  failure counter を 0 に戻して新しい worker 起動を許可する。request_id、callback generation、warning latch は
  戻さず、未完了 request の replay もしない。自動 build-stamp re-source はこの解除を行わない。
  invalid handshake、request_id 枯渇、runtime setup failure など別の disable reason はこの操作で解除しない。
- 正しい形の `incompatible`、stamp の異なる `ready`、source/config の build-stamp 不一致は stale build として
  失敗回数を介さず `$ZRUSH_BIN init zsh` の自動 re-source を 1 回だけ試みる。成功時は警告せず診断ログだけを残し、
  検出時点の未完了 request はすべて破棄して replay しない。re-source の失敗または re-source 中の再不一致だけが
  警告 1 回と無効化へ落ちる。正しい形の `incompatible` は worker session failure に数えず、連続失敗回数も進めない。
  worker は `incompatible` の後も request stream を読み捨てるため、hello の後ろに queue されていた frame は
  通常どおり書き込まれて破棄され、stale worker は re-source の正常 shutdown で停止する。
  旧 generation に worker がいた場合は replacement worker を直ちに起動して握手を検証し、
  worker が未起動なら lazy 状態を保つ。認識済み `incompatible` や local request_id 枯渇のように
  transport が健全なら正常 shutdown、壊れた handshake/session なら異常 abort を使う。
  stopping/quarantine 中の re-source・config reload・build-stamp 照合は fail fast し、新しい deadline や stop を
  自動開始せず、既存 generation の functions/hooks/runtime directory/endpoints/stopping gate を保持する。
- 同じ shell で re-source するときは、旧 generation の hook/keybind を外す前に正常 shutdown を開始する。
  同じ invocation の deadline 内に predicates が揃った場合だけ旧 fd/path/hook を finalization し、
  private runtime directory を破棄してから新 generation の同期 setup と hook/keybind 導入へ進む。
  deadline 超過時は re-source 自体を失敗させ、非同期 cleanup は旧 worker session の finalization だけを行う。
  新 generation の導入は cleanup 完了後の次の re-source invocation に任せる。
  旧 generation が quarantine 中の re-source は fail fast し、新旧 transport を重複させない。
  request_id と callback generation の単調性・警告済み状態は巻き戻さない。session-failure の disable reason と
  連続失敗回数だけは、旧 generation の停止が完了した後の明示的 re-source で新しい recovery epoch として
  巻き戻せる。自動 re-source、quarantine 中の re-source、その他の disable reason は巻き戻さない。
- `zshexit` も同じ停止を開始し、同期待ちは 100ms を超えない。deadline で未完了でも shell exit を妨げず、
  control/request/response を含む所有 fd を閉じ、所有する正確な FIFO path と runtime directory を unlink する。
  control EOF により worker watchdog は abort し、この経路も numeric PID・`wait`・exit status を使わない。
- worker 障害の user notice は同じ shell session で高々 1 回表示し、ZLE の status line を使う。
  最初の失敗では次の要求で 1 回だけ retry することを示し、circuit breaker が開いた後は
  `source <(zrush init zsh)` による recovery 方法を disable 中の status line に表示し続ける。
  `ZRUSH_LOG` が設定されていれば notice 抑止後も診断を追記する。worker stderr は端末へ流さない。
- worker の起動・正常 shutdown・異常 abort・交換・quarantine・re-source・disable・exit の全経路で、
  internal fd 操作は対話シェル自身の fd 0 / 1 / 2 の open/closed 状態と接続先を変えない。
  internal close error の抑止を shell stderr へ恒久適用しない。

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
  それ以外は語全体を空にする。
- Rust に渡す fuzzy クエリは、現在語のうち最後の `/` または `=` より後ろ
  (区切りがなければ語全体)。ダッシュ列の保持はクエリには効かず、
  保持したランは収集文字列とクエリの両方に現れる。
  compsys はオプション候補をダッシュ込み(`-a`、`--all`)で返すため、
  ランをクエリから外すと common-prefix が保持したランと重なり、
  `tab = "common-prefix"` の挿入がダッシュを二重化する。
- 上の 2 規則により、現在語は常に「クエリにならなかった接頭辞 + クエリ」に分かれる。
  クエリだけを置き換える挿入(common-prefix)は、この接頭辞をそのまま前置する。
- 現在語は「カーソルまでのバッファの最後の空白文字より後ろ」という素朴な規則で特定する。
  クォートを解釈しないため、クォート内空白を含む語は正しく扱えない。
- 収集は zpty(現在シェルの fork)内で compsys を駆動し、compadd フックが
  候補レコードを継承 pipe fd へ NUL 区切りで搬出する(終端 = EOF)。
  フレーミングに使う制御バイト(NUL、`\1`、`\2`)を含む候補は一覧に載らない。
  レコードのタグ構成(バッチヘッダ・`m` タグを含む)は
  `../contracts/cli-protocol.md`(`store` 要求の `candidate_payload`)の契約に従う。
  キャンセルは worker 自己申告 pid のプロセスグループへの SIGINT → `zpty -d`。
- 収集が完走したら、その payload を新しい candidate generation の `store` 要求で worker へ渡し、
  続けて同じ generation を参照する `plan` 要求を連送する
  (`../contracts/cli-protocol.md`「要求と応答」節)。
  スロットは空語収集キャッシュの対象となる収集が `cache`、それ以外の収集が `live`。
  どの収集がキャッシュの対象かは「空語収集キャッシュ」節が定める。
  payload を zsh 側に保持することはせず、後続の要求は generation 参照だけで済ませる。
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
- fork 内では `globdots` を有効にし、ドットファイル候補も無条件に生成させる。
  stock compsys は補完接頭辞そのものが `.` で始まるときにしかドットファイル候補を生成しないため、広げた収集では取りこぼす。
  生成したドットファイル候補をクエリが `.` を打つまで一覧に出さない絞り込みは Rust 側の規則が担う(`../contracts/cli-protocol.md`「隠し候補の除外」)。
- compadd フックの pipe 書き込みは compadd 呼び出し単位のバッチで行う
  (レコード毎の書き込みは読み手の read 回数を増やし、大量候補で顕著に遅くなる)。
- compsys 初期化済みの検知は `$+functions[_main_complete]` による
  (zsh-autocomplete が compinit を代行する構成も検出できる)。

## 空語収集キャッシュ

行頭のコマンド位置(広げ結果が空文字列)の収集は最重量ケース(全コマンド名)のため、
結果をプロンプトを跨いでキャッシュする。

- 対象は広げ結果が空文字列の収集のみ。
  `sudo ` 後などのコマンド位置は、広げ結果が空文字列でも対象外とする。
  ここで対象とした収集だけが `cache` スロットを使い、対象外の収集は `live` スロットを使う
  (cli-protocol.md「要求と応答」節)。
- 解析済みの候補を保持するのは worker の `cache` スロットである(cli-protocol.md「要求と応答」節)。
  zsh が保持するのは**フィンガープリント・保存時刻・`cache` スロットの candidate store latch**
  (現 worker session が保持している generation)の 3 つだけで、生の捕獲 payload は保持しない。
- 検証は使用時に行う。
  ヒットの条件は次の 3 つがすべて成り立つこと:
  **フィンガープリント**(`$PATH` 文字列 + PATH 各ディレクトリの
  mtime + 関数・エイリアス・ビルトインの個数。`autocd` 有効または PATH に相対要素が
  ある場合のみ `$PWD` を含める)の一致、**TTL 300 秒**(固定値)以内、latch が有効であること。
- ヒット時は compsys の fork も `store` も行わず、latch が指す generation を参照する `plan` 要求だけを送る
  (payload の転送も再解析も起こらない)。
- ミス時は通常どおり収集し、成功時に新しい generation を `cache` スロットへ `store` してから
  フィンガープリント・保存時刻・latch を更新する。
  worker session を失った後は latch が無効なため、フィンガープリントと TTL が有効でもミスとして再収集する
  (latch の無効化点は「worker ライフサイクル」節)。
- 既知の癖: compsys が補完関数を遅延ロードすると関数個数が増え、直後の 1 回だけ
  余計にミスする。これは正しい無効化であり一度きりで収束する。

## マッチング

- 常駐 Rust worker の `plan` 要求処理が担う。ティア序列は
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
- 補完一覧の要求(`store` と `plan`)は、収集完了後の非同期結果経路から worker へ送る。
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
  次の `plan` 要求までのレイアウトのズレは仕様外として許容する。
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
  合成した payload は新しい candidate generation の `store` 要求(`live` スロット)で送り、
  続けて同じ generation を参照する `plan` 要求を連送する。
  worker との要求/応答を同期的に待つのはこの経路だけである。
- 合成する payload の総バイト数には**固定の上限 262144 バイト(256 KiB)**を置く。
  新しい方から走査し、次の候補レコードを加えると上限を超える時点で走査を打ち切る。
  そのレコードとそれより古い履歴行は送らず、レコードの途中で切ることもしない。
  この上限は、同期経路が扱うバイト量を有界にして下記の deadline を満たせる状態に保つためにあり、
  deadline と同じく固定方針であって設定項目にしない。
  1 行の長さには上限を設けないため、`[history].limit` 件に達するより先にバイト上限へ達することがあり、
  その場合に履歴一覧が対象にするのは走査範囲のうち新しい側の一部だけになる。
  最も新しい候補レコード 1 件だけで上限を超える場合は候補が 0 件になり、後述の「マッチ 0 件」に従う。
- 履歴 payload の合成が完了した直後から、`plan` 要求の完全な終端応答を受け取るまでを
  **1 本の絶対 100ms deadline**で制限する。worker が未起動なら、その起動・`hello` / `ready` 握手・
  `store` と `plan` の送信・`store` の終端応答の消費・完全な `plan` 応答の受信をすべて同じ 100ms に含める。
  deadline は固定方針であり設定項目にしない。
  環境変数 `ZRUSH_HISTORY_DEADLINE_MS`(ミリ秒、未設定時は 100)で deadline を上書きできるが、これは `zsh/zrush.zsh` の `ZRUSH_BIN` と `ZRUSH_NO_INIT` に倣ったテストドライバ専用の seam である。
  payload 合成に費やす時間はこの deadline に含めない。
- `plan` 要求の完全な終端応答を受信した時点で同期待ちは終了する
  (先行する `store` の終端応答はその途中で消費する)。
  受信済みで未処理の後続応答は同期待ちの中では処理せず、非同期経路が引き取る。
- 同期待ちの間に先行する非同期要求の応答を受けた場合も通常どおり終端まで読み、stale なら破棄して
  `plan` 要求の request_id を待ち続ける。先行要求の outbound queue 送信と直列処理に費やす時間も同じ deadline を消費する。
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
  - **同期 worker 交換の失敗**(`store` または `plan` の `error` 応答、worker セッション失敗、
    deadline 超過、または仕様を満たさない `ok`)→ 一覧と種別を破棄し、
    バッファは変えない(cli-protocol.md「応答の検証と zsh 側の適用(規範)」)。
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
- zsh スクリプトとバイナリの build stamp が不一致の場合は自動 re-source を 1 回試みる。
  成功時は警告せず、ガード失敗時だけ警告を 1 回表示して zrush を無効化する。

## プラグイン共存

- キーのフォールバックは前任者チェーン(builtin 直呼びはしない)。
  config リロードでの再適用時に自分自身を前任者として捕まえない。
- config リロードまたは re-source で不要になった dispatch layer は、キーと widget の両方を
  zrush が直接所有している場合に限り、キーを前任者へ戻して function/widget 登録を解放する。
  第三者の binding または wrapper が上にある layer は上書きも解放もせず、非 active な
  dispatcher として前任者へ委譲させ、第三者を含む既存チェーンを維持する。
- `zle-line-pre-redraw` は `add-zle-hook-widget` で登録する。
- fork 内で候補を収集するときは、他プラグイン(zsh-autosuggestions など)が定義した
  compadd ラッパーを除去してから compsys を呼ぶ。この変更は fork 内に限られ、
  親の対話シェルの状態には影響しない。
- 保証範囲は作者環境の zsh-syntax-highlighting と zsh-abbr の 2 つ。
  一般のプラグイン互換性は保証しない。
- 自動テストが検証するのは上記の共存規則そのもの、すなわち第三者の前任者 widget・
  pre-redraw フック・compadd ラッパーという形に耐えることであって、特定のプラグインではない。
  配布されている実物との突き合わせはドッグフーディングによる。
