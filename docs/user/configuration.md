# 設定

設定ファイルは `~/.config/zrush/config.toml`(`$XDG_CONFIG_HOME` があればそちらを優先)。
ファイルがなくても全既定値で動作する。変更はプロンプト表示ごとに自動反映される
(リロード操作は不要)。不正な値があっても止まらず、その項目だけ既定値に
フォールバックして警告を表示する。

厳密な仕様(型・制約・検証規則)は `../internal/contracts/config-schema.md` を参照。

## 設定例

```toml
[display]
max-lines = 10        # 一覧の最大行数
delay-ms  = 30        # 打鍵から収集開始までのデバウンス(ms)
min-input = 0         # 一覧を出し始める現在語の最小文字数

[display.highlight]   # zsh の highlight 指定文字列。"" で装飾なし
selected = "standout" # 選択中セル
match    = "underline"# マッチ箇所
heading  = "bold"     # グループ見出し

[matching]
mode = "typo"         # "prefix" / "substring" / "typo"(後ほど広く拾う)
smart-case = true     # クエリが全小文字なら大小無視

[insert]
tab = "menu"          # 下記「Tab の挙動」参照
trailing-space = true # 確定時に末尾スペースを付与

[history]
limit = 5000          # 履歴メニューが遡る履歴の最大件数(1〜20000)

[keybind]
select-next  = ["down", "ctrl-n"]
select-prev  = ["up", "ctrl-p"]
select-left  = ["left", "ctrl-b"]
select-right = ["right", "ctrl-f"]
confirm      = ["enter"]
dismiss      = ["ctrl-g"]
```

上の値はすべて既定値なので、変えたい項目だけ書けばよい。

## 履歴メニューの件数(`[history].limit`)

↑ で開く履歴メニューは、新しい方から `limit` 件までの履歴を対象に絞り込む
(同じコマンドは最新の 1 件だけが残るため、出る候補は `limit` 件より少なくなる)。
この一覧は ↑ を押した時点で作るので、大きくするほど押してから出るまでの時間が延びる
(1 行が極端に長い履歴が多い場合も同じ)。
通常の履歴なら既定の 5000 で待たされることはない。

## Tab の挙動(`[insert].tab`)

- `"menu"`(既定): 選択メニューに入る。
- `"insert"`: 先頭候補を確定挿入する。
- `"common-prefix"`: 候補の共通接頭辞を挿入し、伸びなければ先頭候補を確定挿入する。

## キーバインドの注意

- 配列は既定リストの**置き換え**(マージではない)。`[]` でそのアクションを無効化できる。
- 記法は小文字で `ctrl-` / `alt-` を前置(`ctrl-n`、`alt-j` など)。
  特殊キーは `up` / `down` / `left` / `right` / `enter` / `space` / `escape` /
  `shift-tab` / `home` / `end` / `pgup` / `pgdn` / `delete`。
- Tab(`tab` / `ctrl-i`)はアクションに割り当てられない(Tab の挙動は `[insert].tab` で決める)。
- 選択キーが既定キーと重なっていても、キーを奪うのは基本的に**候補を選択している間だけ**。
  非選択時の ↓ / ctrl-n / ctrl-b / ctrl-f・← → は通常の動きのまま。
  例外は 3 つ: `select-prev`(既定 ↑ / ctrl-p)は選択していなければ履歴メニューを開き、
  一覧表示中の `select-next`(既定 ↓ / ctrl-n)は選択を開始し
  (複数行バッファの行移動・履歴の戻りはそれより優先)、
  一覧表示中の `dismiss`(既定 ctrl-g)は選択していなくても一覧を閉じる。
- ctrl-p を素の履歴移動(`up-line-or-history` など)のまま使いたい場合は、
  `select-prev` から外して ↑ だけを割り当てる。配列は置き換えなのでこの 1 行で足りる。

  ```toml
  [keybind]
  select-prev = ["up"]
  ```
