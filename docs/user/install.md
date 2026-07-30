# インストール

## 前提

- zsh 5.8 以上(macOS / Linux)
- Rust ツールチェイン(`cargo`)
- `.zshrc` で compinit を実行していること(zrush は compinit を実行しない)

## 手順

```sh
git clone <このリポジトリ> ~/path/to/zrush
cd ~/path/to/zrush
cargo build --release
```

`.zshrc` に以下を追加する:

```sh
source ~/path/to/zrush/zsh/zrush.zsh
```

### source の位置

- **compinit より後**に置く(前に置くと `command not found: compdef` などの原因になる。
  他ツールの補完設定 `eval "$(... completion)"` も compinit より後にすること)。
- zsh-abbr より後、zsh-syntax-highlighting より前に置く。
- zsh-autocomplete とは併用しない(置き換え)。

バイナリは zrush.zsh の位置から `../target/release/zrush` を自動解決する。
別の場所に置く場合は `$ZRUSH_BIN` で明示する。

## 更新

```sh
git pull
cargo build --release
```

zsh スクリプトとバイナリの版がずれると起動時に警告が出る(動作は継続)。
警告が出たら rebuild する。複数環境(SSH 先など)ではそれぞれの環境でビルドする。

## デバッグ

`ZRUSH_LOG=<ファイル>` を設定するとタイムスタンプ付きトレースを追記する(既定は無効)。
