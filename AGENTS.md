# AGENTS.md

zrush — zsh-autocomplete を置き換える自分専用の zsh 補完ツール。Rust + zsh スクリプトで実装する。

## ドキュメントが Single Source of Truth

このプロジェクトでは `docs/` ディレクトリを single source of truth とする。

- 設計・仕様・計画に関する疑問は、まず `docs/` を参照して解決する。
- 設計や仕様を変更したときは、コードより先に(少なくとも同時に)該当ドキュメントを更新する。
- コードとドキュメントが食い違う場合、ドキュメントを正とし、どちらが誤りかを確認して修正する。

## docs の構成

```
docs/
├── user/            # ユーザー向けドキュメント(インストール・設定・使い方)
└── internal/        # 開発者向けドキュメント
    ├── plans/       # 実装計画。連番ディレクトリ(001-prototype/ など)ごとに計画を置く
    ├── specs/       # 確定した仕様(挙動・設定スキーマなど)
    └── contracts/   # コンポーネント間の境界仕様(zsh↔Rust CLI プロトコルなど)
```

- `plans/` は作業単位のスナップショット。`specs/` / `contracts/` の文書は内容が確定した時点で随時作成してよい(作業完了を待たない)。作業完了時に、plans に残った確定内容を昇格させる。
- ドキュメントは常に「最新の姿」だけを書く。経緯・履歴・レビュー記録の類は残さない(履歴は git が持つ)。
- 現在進行中の計画: `docs/internal/plans/001-prototype/`

## コミットメッセージ

[Conventional Commits](https://www.conventionalcommits.org/) に従い、英語で簡潔に書く(例: `docs: add prototype plan`, `feat(match): add typo-tolerant matching`, `fix(zle): clear listing on accept-line`)。

## 実装の原則(要約)

詳細は各 plan / spec を参照。

- 「勝手に何かをしない」: 明示操作なしに入力内容を書き換えない。`~` は展開しない。
- 入力は決してブロックしない。候補収集は非同期で行う。
- 設定の真実は `~/.config/zrush/config.toml` に一元化する。zstyle による設定面は作らない。
- 責務分担: Rust = マッチング・ランキング・履歴検索・config 解釈。zsh = zle 統合・compsys 呼び出し・描画。
- Rust 側の純粋ロジック(マッチング・ランキング・設定パース)は UI から分離し、単体テスト可能に保つ。
