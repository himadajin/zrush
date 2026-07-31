# Golden vectors

This corpus turns the prose rules in `docs/internal/contracts/cli-protocol.md` into executable byte-level fixtures.

Each `plan/<name>/` directory contains `args`, `payload.bin`, and `expected.bin`.
Each `reject/<name>/` directory contains `args`, `payload.bin`, and `exit`.
The runner implicitly prepends the `plan` subcommand, so `args` contains flags and their values only.
The `args` file stores one argument per line, with an empty line representing an empty argument.
Shell quoting is not interpreted, and argument values containing newlines cannot be represented.
The `.bin` files contain raw bytes, including `\0`, `\1`, and `\2` separators.
The `exit` file contains one decimal line whose value is `2` or `3`.
Vector names use kebab case and describe the rule being fixed.

To add a vector, create its directory, write `args` and `payload.bin`, and run `UPDATE_GOLDEN=1 cargo test`.
Use golden regeneration only for an intentional protocol change, and review every generated diff.
When regeneration changes files, the test deliberately fails and lists every update so the changes cannot be missed.
After reviewing the diff, rerun the same command; it passes when no files change.

For a readable raw-byte dump, run `od -An -tx1c tests/vectors/plan/<name>/payload.bin`.

Vectors omit `f = 1` candidates because directory slash synthesis depends on filesystem state.
That behavior remains covered by the injected-stat Rust unit tests.
Vectors also omit candidate values containing `\0`, `\1`, or `\2`, and omit redundant `m` fields equal to `w`.
Those are sender-side zsh guarantees and cannot be observed in Rust output.

A later zsh-side runner will consume this same corpus.
