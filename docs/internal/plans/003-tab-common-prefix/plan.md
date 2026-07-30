# 003-tab-common-prefix 実装計画

**状態: 実装完了(2026-07-28 マージ)。**
フォールバック(分岐点での先頭候補確定挿入)は経過観察の結果、
現状維持のまま解決(検討記録は `../001-prototype/notes-dogfooding.md`)。

## 背景と目的

M5 ドッグフーディングで「Tab(`common-prefix`)が体感無反応」を記録した
(`../001-prototype/notes-dogfooding.md` 2026-07-28。使用をためらうレベル)。

原因は現行仕様の 2 点の組み合わせ:

1. 共通接頭辞(common-prefix)を**全マッチ候補**(typo・あいまい階層を含む)の LCP で
   計算するため、mode=typo では雑多な候補が混ざって LCP がすぐ空になる。
2. 「クエリが LCP の真の接頭辞のときのみ挿入、それ以外は何もしない」ため、
   1 と合わさって無反応が常態化する。

期待は zsh-autocomplete の `insert-unambiguous yes` + `complete-word` 相当:
「まず共通部分を挿入、伸びなければ先頭候補を挿入」。この挙動に合わせる。

## 決定事項

- **LCP の計算対象は prefix 階層のマッチのみ**とする(全マッチから変更)。
  - prefix 階層(match-text がクエリで始まる)の LCP は必ずクエリで始まるため、
    「as-typed 入力をそのまま伸ばせる分だけ伸ばす」という共通接頭辞挿入の意味論と一致する。
  - substring / edit / fuzzy 階層の候補はクエリの接頭辞拡張になり得ず、
    LCP に混ぜても発散させるだけなので除外する。
  - 空クエリは従来どおり全候補が prefix 階層扱い(例: `ls ../huge/` で Tab →
    `file0` のようなディレクトリ内共通部分の挿入が成立する)。
  - 検討して不採用: 「表示中の上位候補の LCP」。階層混在の発散問題が残るうえ、
    max-lines(表示容量)に挙動が依存してしまうため。
- **共通部分が「ない・伸びない」ときは先頭候補を確定挿入する**(フォールバック。
  notes で決定済み)。
  - 適用条件: cp が空 / cp == クエリ / クエリが cp のバイト接頭辞でない
    (smart-case の大文字小文字差でずれるケースを含む)のいずれか。
  - 挿入は `tab = "insert"` と同じ確定動作(`_zrush_confirm_index shown[1]`。
    挿入文字列の再構成・trailing-space・ディレクトリ `/` 付与も同一)。
  - 先頭候補への「置き換え」は Tab という明示操作による確定なので
    「勝手に何かをしない」原則と両立する(tab = "insert" と同じ整理)。
    cp 挿入側は従来どおり as-typed の接頭辞拡張のみで、入力を縮める・
    別文字列に置き換える挿入はしない。
  - 候補 0 件の Tab は従来どおり何もしない。
- **プロトコル版番号を上げる**。
  - common-prefix フィールドの意味変更(全マッチ → prefix 階層のみ)のため
    (cli-protocol.md の版上げ基準「フィールドの意味変更」に該当)。
    フィールドの形式・位置は不変。
- 設定は増やさない。`tab = "common-prefix"` の意味を上記に更新する
  (config-schema.md の説明を「共通部分を挿入、伸びなければ先頭候補を挿入」へ)。

## 実装手順

1. **contracts 更新**(docs 先行):
   - cli-protocol.md: プロトコル版番号を上げ、common-prefix の定義を
     「prefix 階層マッチの match-text のバイト単位 LCP(マッチ 0 件・prefix 階層
     0 件・共通部分なしは空)」へ。zsh 側挙動(規範)にフォールバックを追記。
   - config-schema.md: `[insert].tab` の `common-prefix` 説明を更新。
2. **Rust**: `cmd_match` の LCP 入力を `Tier::Prefix` のマッチに限定。
   プロトコル版番号を上げる。単体・CLI テスト追従
   (例: `chec` → prefix 階層 {checkout, check-attr} の LCP "check" を返し、
   substring の sparse-checkout を含めない / `gti` → prefix 階層なしで空)。
3. **zsh**: `_zrush_tab_with_results` の common-prefix 分岐に
   「条件を満たさなければ `_zrush_confirm_index ${_zrush_shown[1]}`」を追加。
   `_ZRUSH_EXPECTED_PROTO` を追従させる。
4. **driver.zsh**: tab-2b(旧: typo クエリで何もしない)を新仕様に書き換え。
   環境依存を避けるため gd fixture で判定する:
   - 伸びるケース: `ls docs/inte` + Tab → `ls docs/internal`(現行 tab-2a のまま)。
   - 伸びないケース: `ls gd/a1` + Tab → prefix 階層 {a10..a19} の LCP "a1" ==
     クエリ → フォールバックで先頭候補 a10 を確定挿入(`ls gd/a10 `)。

## 受け入れ条件

1. 共通部分が伸びるケースで Tab が共通部分を挿入する(現行維持)。
2. 共通部分がない・伸びないケースで Tab が先頭候補を確定挿入し、
   確定の挙動(trailing-space・ディレクトリ `/`・`~` 非展開)が
   `tab = "insert"` と一致する。
3. 候補 0 件の Tab は何もしない(現行維持)。
4. cp 挿入パスで入力が縮む・別文字列に置き換わることがない(現行維持)。
5. 契約文書とコードが一致し、Rust・driver・coexist の全テストが通る。

## 未解決事項

なし(設計判断はすべて上記で確定)。
