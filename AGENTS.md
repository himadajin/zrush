# AGENTS.md

zrush is a zsh completion tool that replaces zsh-autocomplete, showing a live candidate listing below the prompt as you type.
Implemented in Rust (matching, ranking, history search, config) plus zsh scripts (zle integration, compsys, rendering).
Development is dogfooding-driven: the author's daily use comes first.

## Docs are the single source of truth

The `docs/` directory records intended behavior — a commitment, not a description of the code:

- Resolve design/spec questions by reading `docs/` first.
- When changing design or behavior, update the relevant doc before (or together with) the code.
- Code that disagrees with docs is a bug in the code.
  If the intent itself has changed, that is a spec change: update the doc deliberately, never merely to match what the code happens to do.
  When unsure which case it is, ask instead of picking a side.
- Behavior the docs don't cover is not guaranteed and may change freely; to rely on it, spec it first.
- Code comments never restate the docs; at most they point to the relevant doc.

Layout: `docs/user/` (install, configuration, usage), `docs/internal/specs/` (settled behavior specs), `docs/internal/contracts/` (component boundaries such as the zsh ↔ Rust CLI protocol and config schema).

Plans and task tracking live in GitHub issues, not in docs.
Docs describe only the current state — no history or review notes (git keeps the history).

## Build and test

Run all of the following before considering a change done (CI enforces the same):

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo build --release
cargo test
```

For changes touching `zsh/`, the zle-integration drivers `tests/zsh/driver.zsh` and `tests/zsh/driver-coexist.zsh` must also pass — run them locally.
CI runs the headless `driver.zsh`, `tests/zsh/vectors.zsh` (capture-encoder and plan-decoder golden vectors), and `tests/zsh/transport.zsh` (worker transport write path); `driver-coexist.zsh` remains local-only.
CI's Linux jobs run the whole suite in a container whose zsh is built from source, as a matrix over the supported versions; the same run reproduces locally (needs Docker) with

```sh
tests/docker/run.sh 5.8.1   # or 5.9
```
`zsh/verify.zsh` launches an isolated shell for manual verification, and `tests/zsh/driver-latency.zsh` measures first-paint latency; each file's header documents prerequisites and usage.

## Commits, issues, and pull requests

One-line titles — issue titles, PR titles, commit messages — are concise English following [Conventional Commits](https://www.conventionalcommits.org/)
(e.g. `docs: update config schema`, `feat(match): add typo-tolerant matching`, `fix(zle): clear listing on accept-line`), because they flow through tooling.
A change is titled once: the issue names it, and the PR reuses that title — written as the commit message for the whole change, so that it can land on `main` unedited.
Never write the ` (#N)` suffix by hand; GitHub appends it on squash merge.
Omit the scope when the affected component is not yet known.
Mark the type with `!` only for breakage the user sees — configuration, keybindings, observable behavior; a zsh ↔ Rust protocol version bump is internal and does not qualify.
Bodies may be English or Japanese.

Issue bodies must be self-contained for a reader who was not part of the conversation that spawned them:
open with one or two paragraphs stating the current state, the change or decision being made, and the reason, before any detail.
Do not use vocabulary or references that only made sense in that conversation; reference other issues as `#N` plus a short description.
Numbers used as evidence come with the measurement environment and reproduction steps.
Templates under `.github/ISSUE_TEMPLATE/` mirror these rules; only the title and the opening paragraphs are mandatory — the other sections are guidance to keep or drop.

## Core principles

Details live in `docs/internal/specs/`; these are the invariants:

- Never act on the user's behalf: don't rewrite input without an explicit action, and don't expand `~`.
- Never block input; collect candidates asynchronously.
- Configuration lives solely in `~/.config/zrush/config.toml`; no zstyle-based settings.
- Responsibilities: Rust = matching, ranking, history search, layout/render-plan computation, insertion-text construction, config interpretation; zsh = zle integration, compsys capture, applying the plan (rendering).
- Keep pure Rust logic (matching, ranking, config parsing) separate from the UI and unit-testable.

## Design discipline

zrush is alpha software developed by dogfooding; simplicity outranks continuity.

- No backward compatibility.
  When behavior, config, protocol, or data formats change, replace the old form and delete the old code path in the same change — no deprecation shims, migration code, legacy aliases, or versioned fallbacks.
  (The protocol version check stays: it detects a stale build, it is not a compat layer.)
- Prefer a few principled rules over many ad-hoc ones.
  Growing special cases, conditionals, or implementation size relative to the goal is a sign of a wrong approach: step back and restructure so a general rule covers the cases, instead of patching case by case.
  If a requested change would require such growth, propose the simpler restructuring first.

## Guardrails

- Never run tests or verification against the real `~/.zshrc` or shell history; use the isolated sandbox (`zsh/verify.zsh`).
- Do not push or open pull requests unless explicitly asked.
