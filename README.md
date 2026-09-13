# zrush

入力に合わせて補完候補をプロンプト下に表示する zsh 補完ツール。

- タイプミスや省略した入力から候補を探せる（`gti` → `git`、`dcs` → `docs`）。
- 入力中の内容でコマンド履歴を絞り込める。
- コマンドやパスを色分けし、入力を確認しやすくする。

候補を選んで確定するまで、入力を書き換えることはありません。

## Getting started

macOS / Linux、zsh 5.8 以上に対応。
ビルドには Rust ツールチェイン（cargo）が必要です。

- [インストール](docs/user/install.md)
- [使い方・キー操作](docs/user/usage.md)
- [設定](docs/user/configuration.md)

開発者向けの情報は [設計・仕様](docs/internal/) を参照してください。
