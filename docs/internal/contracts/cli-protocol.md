# cli-protocol: zsh ↔ Rust CLI の境界仕様

zrush.zsh(zsh 側)と `zrush` バイナリ(Rust 側)の入出力仕様。
この文書が真実であり、コードはこれに追従する。

## プロトコル版

- **PROTOCOL_VERSION = 1**
- `zrush config` の出力に `ZRUSH_PROTOCOL_VERSION` が含まれる。
  zrush.zsh は自身が期待する版番号と照合し、不一致なら警告を 1 回表示して動作は継続する
  (git pull 後の rebuild し忘れ検知)。
- 照合の機会を保証するため、zrush.zsh は **source 時に無条件で `zrush config` を 1 回実行**する
  (config.toml の mtime 変化だけをトリガにすると、バイナリのみ更新された場合に照合されない)。
- 互換性が壊れる変更(フィールドの追加・削除・意味変更、キー記法の変更)で版番号を上げる。
- 未知の引数を渡された `zrush` は exit 2 で拒否する(前方互換より誤用の早期検出を優先する意図的選択。
  版不整合は上記の警告で検知される)。

## 共通事項

- `zrush` はキー入力・プロンプト表示のたびに都度起動される。常駐しない。
- `zrush match` は **config.toml を読まない純関数**。
  設定はすべて引数で渡す(設定スナップショットの取得・mtime 監視は zsh 側の責務)。
- 文字列はバイト列として扱い、エンコーディング変換をしない(ファイル名は任意バイト列であり得る)。
  マッチング計算の内部で lossy な UTF-8 解釈を行うのは構わない
  (結果は index で返すため原バイト列は損なわれない)。
- フレーミングは NUL(`\0`)終端フィールドによる。
  **NUL はファイル名には出現しないが、zsh の文字列(変数値・履歴語など)には出現し得る**。
  そのため **送信側(zsh)が保証する**: NUL を含む候補はレコードを送出前に除外し、
  `--query` に渡す文字列からは NUL を除去する。Rust 側はフィールド内に NUL が無いことを前提としてよい。
- **候補語の二形**(M1 の確定事項): 収集で捕獲した候補語は compsys の**挿入用クォート済み形**
  (例: `space\ name.txt`)。その `${(Q)}` 復元形(生テキスト)がマッチング・表示用。
  挿入にはクォート済み形をそのまま使う。両形の対応管理は zsh 側の責務で、
  本プロトコルを流れる `match-text` は常に復元形である。

## zrush match

候補列とクエリを受け取り、マッチ・ランキングして上位を返す。

### 起動

```
zrush match --query <fuzzy-query> \
            --mode <prefix|substring|typo> \
            --smart-case <true|false> \
            --max-lines <N>
```

- `--query`: 広げ規則で削った末尾(ユーザーの as-typed 断片、NUL 除去済み)。空文字列も有効
  (空クエリは全候補が最高同点マッチ = compsys 順のまま上位 N 件を返す)。
- `--mode` / `--smart-case`: マッチング設定のスナップショット(config-schema.md 参照)。
- `--max-lines`: 出力する最大候補数。表示行数クリップ(`$LINES` との min)は zsh 側の責務。
- 未知の引数・不正値は exit 2(usage エラー)。

### stdin(候補列)

候補 1 件につき **3 フィールド**を NUL 終端で連続して流す:

```
<index> NUL <match-text> NUL <display-text> NUL
```

- `index`: zsh 側の候補配列の添字(**1 始まり**の 10 進数字列)。Rust はこれを不透明トークンとして扱い、
  そのまま返す(挿入用メタデータは zsh 側の配列に残り、往復しない)。
  数字列でないフィールドは exit 3。
- `match-text`: マッチング対象のテキスト(候補語の `${(Q)}` 復元形。「共通事項」参照)。
- `display-text`: 表示文字列(compadd `-d`)。無い候補は空フィールド。
  **空の場合、zsh 側は match-text を表示に使う**(候補データの解釈規則。描画層を差し替えても不変)。
  ランキングの補助には使わない(フェーズ 1)。
- 重複候補(同一の match-text/display-text 組)は除去せずそのまま送ってよい。
  Rust も重複除去しない(compsys の出力順の情報を保つ。除去を導入する場合は版番号を上げる)。
- ストリーム終端は EOF。総フィールド数が 3 の倍数でない場合は exit 3(プロトコルエラー)。

### stdout(結果)

先頭に共通接頭辞フィールド、続いてランク順(良い順)に上位 `max-lines` 件の `index`:

```
<common-prefix> NUL <index> NUL <index> NUL ...
```

- `common-prefix`: **全マッチ候補**(max-lines 打ち切り前)の match-text の
  バイト単位最長共通接頭辞。マッチ 0 件・共通部分なしのときは空フィールド。
  `tab = "common-prefix"` の挙動(config-schema.md)のために返す:
  zsh 側は「クエリが common-prefix の真の接頭辞である場合に限り、
  削った末尾領域を `${(q)}` でクォートした common-prefix で置き換える」
  (typo マッチではクエリと乖離した接頭辞になり得るため、入力を縮める・別文字列に置き換える挿入はしない。
  条件を満たさない Tab は何もしない)。詳細挙動仕様は M4 で specs に昇格する。
- マッチ 0 件なら `common-prefix`(空)のみ出力(exit 0)。
- 総マッチ件数は返さない(「+truncated 表示」を導入するときに版番号を上げて拡張する)。

### マッチング・ランキングの意味論

- モードは累積的に広がる: `typo` ⊇ `substring` ⊇ `prefix`。
  - `prefix`: match-text がクエリで始まる。
  - `substring`: match-text がクエリを部分文字列として含む。
  - `typo`: 上記に加えて、文字順保存のあいまい一致(`dcs` → `docs`)と
    軽度の誤字(隣接転置・1 文字の置換/挿入/脱落: `gti` → `git`)を許容する。
- `smart-case = true`: クエリが全て小文字なら大文字小文字を無視、
  大文字を含むなら区別する。`false`: 常に区別しない。
- ランキング: マッチ品質スコアの降順。同点は stdin での出現順(= compsys の出力順)を保つ。
  スコアは「より厳密なマッチほど高い」(prefix 一致 > 語頭・境界での一致 > 部分一致 > 誤字許容)。
  スコアの数値自体はプロトコルに含まれない(実装詳細)。

### エラー時の zsh 側挙動(規範)

- `zrush match` の exit が非 0(2/3 に限らず、パニック・シグナル死・実行失敗 127 を含む)の場合、
  zsh 側は出力を破棄して一覧を出さず(既存の一覧は消し)、動作を継続する。
  警告表示はセッション内で初回のみ(キー入力毎のスパム防止)。
- `zrush match` の stderr は端末に流さない(zle 表示を壊さないため。`/dev/null` へ)。

## zrush config

config.toml を解決・検証し、zsh が `source` できる形で設定値とキーバインド定義を出力する。

### 起動

```
zrush config
```

- config パスの解決: `$XDG_CONFIG_HOME/zrush/config.toml`、
  `$XDG_CONFIG_HOME` 未設定なら `~/.config/zrush/config.toml`。
  ファイル不在は正常(全既定値で出力、警告なし)。

### stdout(zsh source 形式)

```zsh
typeset -g  ZRUSH_PROTOCOL_VERSION='1'
typeset -g  ZRUSH_CFG_MAX_LINES='10'
typeset -g  ZRUSH_CFG_DELAY_MS='50'
typeset -g  ZRUSH_CFG_MIN_INPUT='0'
typeset -g  ZRUSH_CFG_MODE='typo'
typeset -g  ZRUSH_CFG_SMART_CASE='true'
typeset -g  ZRUSH_CFG_TAB='menu'
typeset -g  ZRUSH_CFG_TRAILING_SPACE='true'
typeset -ga ZRUSH_CFG_KEYBINDS=(
  'select-next' 'key:down'
  'select-prev' 'key:up'
  'confirm'     'seq:^M'
  'dismiss'     'seq:^G'
)
typeset -ga ZRUSH_CFG_WARNINGS=()
```

- 出力は `typeset` への静的代入のみ(コマンド実行を含む出力はしない)。
- **クォート規律(規範)**: すべての値を単一引用符 `'...'` で囲み、
  値内の `'` は `'\''` にエスケープする(警告メッセージはユーザー入力由来の任意文字列を含むため必須)。
- zsh 側は `emulate -L zsh` の統制された文脈で source する(継承 setopt による解釈事故の防止)。
- `ZRUSH_CFG_KEYBINDS` は「アクション名, キー指定」の平坦な交互配列。
  - `seq:<bindkey列>`: Rust 側で正規化が完結したもの(例: `ctrl-g` → `seq:^G`)。
    zsh はそのまま `bindkey` に渡す。
  - `key:<シンボリック名>`: 端末依存キー(例: `up`, `down`, `shift-tab`)。
    zsh 側が `$terminfo` を参照して解決する(矢印は CSI/SS3 両系統を bindkey)。
  - 正規化の詳細と対応キー一覧は config-schema.md。
  - 要素数が奇数の場合(版不整合等の異常)、zsh 側は配列全体を無視して既定キーバインドを適用し警告する。
  - bindkey の適用先はメインキーマップ(`main`)のみ(フェーズ 1)。
- `ZRUSH_CFG_WARNINGS` は設定エラーの人間可読メッセージの配列(正常時は空)。
  表示のタイミング・体裁は zsh 側の責務(config-schema.md「検証とエラーの扱い」)。
- 不正な設定値があっても exit 0 で全項目を出力する(該当項目は既定値)。

### エラー時の zsh 側挙動(規範)

- exit 非 0 または出力が source 不能の場合: 前回の設定値があればそれを維持して継続する。
  **source 時(初回)に失敗した場合は警告を表示して zrush を無効化する**
  (フック・キーバインドを登録しない。既定値表を zsh 側へ複製すると真実の二重化になるため)。
- `zrush config` の stderr は端末に流さない(警告は `ZRUSH_CFG_WARNINGS` 経由が唯一の経路)。

## 想定シーケンス(参考・規範ではない)

1. source 時: `zrush config` を実行して source、版番号を照合、キーバインドを適用。
2. プロンプト表示ごと: config.toml の mtime を確認し、変化していれば
   `zrush config` を再実行して source、キーバインドを再適用、警告があれば表示。
3. 入力変化 → デバウンス → zpty 収集完了後: zsh が候補レコードから
   `index/match-text/display-text` を組んで `zrush match` に渡し、
   返った index 列の順に自前レコードを引いて一覧を描画・選択に使う。
