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

[keybind]
select-next  = ["down", "ctrl-n"]
select-prev  = ["up", "ctrl-p"]
select-left  = ["left", "ctrl-b"]
select-right = ["right", "ctrl-f"]
confirm      = ["enter"]
dismiss      = ["ctrl-g"]
```

上の値はすべて既定値なので、変えたい項目だけ書けばよい。

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
- 選択キーが既定キーと重なっていても、キーを奪うのは**候補を選択している間だけ**。
  非選択時の ↑↓ は履歴移動、ctrl-p / ctrl-n / ctrl-b / ctrl-f も通常の動きのまま。
