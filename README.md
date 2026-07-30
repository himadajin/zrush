# zrush

zsh-autocomplete を置き換える zsh 補完ツール。入力に追従して候補一覧を
プロンプト下にリアルタイム表示する。Rust(マッチング・ランキング・設定解釈)+
zsh スクリプト(zle 統合・候補収集・描画)で実装。

作者の日常利用を第一に、ドッグフーディング駆動で開発している。

- インストール・設定・使い方: [docs/user/](docs/user/)
- 設計・仕様(開発者向け): [docs/internal/](docs/internal/)
