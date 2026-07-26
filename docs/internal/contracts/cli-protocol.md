# cli-protocol: zsh ↔ Rust CLI の境界仕様

zrush.zsh(zsh 側)と `zrush` バイナリ(Rust 側)の入出力仕様。
この文書が真実であり、コードはこれに追従する。

## プロトコル版

- **PROTOCOL_VERSION = 1**
- `zrush config` の出力に `ZRUSH_PROTOCOL_VERSION` が含まれる。
  zrush.zsh は自身が期待する版番号と照合し、不一致なら警告を 1 回表示して動作は継続する
  (git pull 後の rebuild し忘れ検知)。
- 互換性が壊れる変更(フィールドの追加・削除・意味変更、キー記法の変更)で版番号を上げる。

## 共通事項

- `zrush` はキー入力・プロンプト表示のたびに都度起動される。常駐しない。
- `zrush match` は **config.toml を読まない純関数**。
  設定はすべて引数で渡す(設定スナップショットの取得・mtime 監視は zsh 側の責務)。
- 文字列はバイト列として扱う(エンコーディング変換をしない。
  ファイル名は任意バイト列であり得るため、UTF-8 検証で候補を落とさない)。
- NUL(`\0`)は zsh の文字列・ファイル名に出現しないため、フレーミングに使う。
  **レコード内のフィールドも各々 NUL 終端**とし、固定フィールド数でレコード境界を決める
  (エスケープ・長さプレフィックス不要。M1 の「\1/\2 区切りは値衝突で壊れる」問題の解)。

## zrush match

候補列とクエリを受け取り、マッチ・ランキングして上位を返す。

### 起動

```
zrush match --query <fuzzy-query> \
            --mode <prefix|substring|typo> \
            --smart-case <true|false> \
            --max-lines <N>
```

- `--query`: 広げ規則で削った末尾(ユーザーの as-typed 断片)。空文字列も有効
  (空クエリは全候補が最高同点マッチ = compsys 順のまま上位 N 件を返す)。
- `--mode` / `--smart-case`: マッチング設定のスナップショット(config-schema.md 参照)。
- `--max-lines`: 出力する最大候補数。表示行数クリップ(`$LINES` との min)は zsh 側の責務。
- 未知の引数・不正値は exit 2(usage エラー)。zsh 側はその場合一覧を出さない。

### stdin(候補列)

候補 1 件につき **3 フィールド**を NUL 終端で連続して流す:

```
<index> NUL <match-text> NUL <display-text> NUL
```

- `index`: zsh 側の候補配列の添字(10 進数字列)。Rust はこれを不透明トークンとして扱い、
  そのまま返す(挿入用メタデータは zsh 側の配列に残り、往復しない)。
- `match-text`: マッチング対象のテキスト。
  候補語の**クォート解除形**(zsh 側で `"${(@Q)words}"` により一括復元したもの)。
- `display-text`: 表示文字列(compadd `-d`)。無い候補は空フィールド。
  ランキングの補助には使わない(フェーズ 1)。
- ストリーム終端は EOF。総フィールド数が 3 の倍数でない場合は exit 3(プロトコルエラー)。

### stdout(結果)

ランク順(良い順)に上位 `max-lines` 件の `index` を NUL 終端で返す:

```
<index> NUL <index> NUL ...
```

- マッチ 0 件なら出力なし(exit 0)。
- 総マッチ件数を最終フィールドとして付加しない(フェーズ 1 では不要。
  「+truncated 表示」を導入するときに版番号を上げて拡張する)。

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
typeset -g  ZRUSH_PROTOCOL_VERSION=1
typeset -g  ZRUSH_CFG_MAX_LINES=10
typeset -g  ZRUSH_CFG_DELAY_MS=50
typeset -g  ZRUSH_CFG_MIN_INPUT=0
typeset -g  ZRUSH_CFG_MODE=typo
typeset -g  ZRUSH_CFG_SMART_CASE=true
typeset -g  ZRUSH_CFG_TAB=menu
typeset -g  ZRUSH_CFG_TRAILING_SPACE=true
typeset -ga ZRUSH_CFG_KEYBINDS=(
  'select-next' 'key:down'
  'select-prev' 'key:up'
  'confirm'     'seq:^M'
  'dismiss'     'seq:^G'
)
typeset -ga ZRUSH_CFG_WARNINGS=()
```

- 値はすべて `typeset` への静的代入のみ(コマンド実行を含む出力はしない。
  zsh 側は信頼できる自前バイナリの出力として source する)。
- `ZRUSH_CFG_KEYBINDS` は「アクション名, キー指定」の平坦な交互配列。
  - `seq:<bindkey列>`: Rust 側で正規化が完結したもの(例: `ctrl-g` → `seq:^G`)。
    zsh はそのまま `bindkey` に渡す。
  - `key:<シンボリック名>`: 端末依存キー(例: `up`, `down`, `shift-tab`)。
    zsh 側が `$terminfo` を参照して解決する(矢印は CSI/SS3 両系統を bindkey)。
  - 正規化の詳細と対応キー一覧は config-schema.md。
- `ZRUSH_CFG_WARNINGS` は設定エラーの人間可読メッセージの配列(正常時は空)。
  表示のタイミング・体裁は zsh 側の責務(config-schema.md「設定エラーの扱い」)。
- 不正な設定値があっても exit 0 で全項目を出力する(該当項目は既定値)。
  exit が非 0 になるのは zrush 自体の内部エラーのみで、
  その場合 zsh 側は既存の設定値のまま動作を継続する。

## 想定シーケンス(参考・規範ではない)

1. プロンプト表示ごと: zsh が config.toml の mtime を確認し、変化していれば
   `zrush config` を実行して source、キーバインドを再適用、警告があれば表示。
2. 入力変化 → デバウンス → zpty 収集完了後: zsh が候補レコードから
   `index/match-text/display-text` を組んで `zrush match` に渡し、
   返った index 列の順に自前レコードを引いて一覧を描画・選択に使う。
