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

`target/release/zrush` を `$PATH` の通ったディレクトリに置く(シンボリックリンクでも可)。

`.zshrc` に以下を追加する:

```sh
source <(zrush init zsh)
```

`zrush` を `$PATH` に置かない場合は、ビルドツリーの絶対パスで直接呼び出す:

```sh
source <(~/path/to/zrush/target/release/zrush init zsh)
```

### source の位置

- **compinit より後**に置く(前に置くと `command not found: compdef` などの原因になる。
  他ツールの補完設定 `eval "$(... completion)"` も compinit より後にすること)。
- zsh-abbr より後、zsh-syntax-highlighting より前に置く。
- zsh-autocomplete とは併用しない(置き換え)。

`zrush init zsh` は自身の絶対パスを `$ZRUSH_BIN` として埋め込んで出力する。
テストや特殊な配置で別のバイナリを使わせたい場合は、source する前に `$ZRUSH_BIN` を設定すれば、
埋め込まれたパスより優先される。

## 更新

```sh
git pull
cargo build --release
```

zsh スクリプトはバイナリに埋め込まれているため、配布物の中でスクリプトとバイナリがずれることは構造的に起きない。
ただし既に起動中のシェルは rebuild 前の古いスクリプトと、それが起動した常駐 worker を保持し続ける。
build stamp の照合はその古い worker または読み込み済みスクリプトを検知し、現行バイナリの
`zrush init zsh` を自動で re-source して追従する。通常は新しいシェルを起動する必要はない。
自動追従の警告が出た場合だけ `$ZRUSH_BIN` を確認して明示的に re-source する。
複数環境(SSH 先など)ではそれぞれの環境でビルドする。

## デバッグ

`ZRUSH_LOG=<ファイル>` を設定するとタイムスタンプ付きトレースを追記する(既定は無効)。
