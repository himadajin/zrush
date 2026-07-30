# AGENTS.md

zrush is a zsh completion tool that replaces zsh-autocomplete, showing a live candidate listing below the prompt as you type.
Implemented in Rust (matching, ranking, history search, config) plus zsh scripts (zle integration, compsys, rendering).
Development is dogfooding-driven: the author's daily use comes first.

## Docs are the single source of truth

The `docs/` directory is authoritative for design and behavior:

- Resolve design/spec questions by reading `docs/` first.
- When changing design or behavior, update the relevant doc before (or together with) the code.
- If code and docs disagree, treat the docs as correct; verify which side is wrong and fix it.

Layout: `docs/user/` (install, configuration, usage), `docs/internal/specs/` (settled behavior specs), `docs/internal/contracts/` (component boundaries such as the zsh ↔ Rust CLI protocol and config schema).

Plans and task tracking live in GitHub issues, not in docs.
Docs describe only the current state — no history or review notes (git keeps the history).

## Build and test

Run all four before considering a change done (CI enforces the same):

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo build --release
cargo test
```

zle-integration regression tests live in `tests/zsh/driver*.zsh`, and `zsh/verify.zsh` launches an isolated shell for manual verification; each file's header documents prerequisites and usage.

## Commits

Follow [Conventional Commits](https://www.conventionalcommits.org/), concise and in English
(e.g. `docs: update config schema`, `feat(match): add typo-tolerant matching`, `fix(zle): clear listing on accept-line`).

## Core principles

Details live in `docs/internal/specs/`; these are the invariants:

- Never act on the user's behalf: don't rewrite input without an explicit action, and don't expand `~`.
- Never block input; collect candidates asynchronously.
- Configuration lives solely in `~/.config/zrush/config.toml`; no zstyle-based settings.
- Responsibilities: Rust = matching, ranking, history search, layout/render-plan computation, insertion-text construction, config interpretation; zsh = zle integration, compsys capture, applying the plan (rendering).
- Keep pure Rust logic (matching, ranking, config parsing) separate from the UI and unit-testable.

## Guardrails

- Never run tests or verification against the real `~/.zshrc` or shell history; use the isolated sandbox (`zsh/verify.zsh`).
- Do not push or open pull requests unless explicitly asked.
