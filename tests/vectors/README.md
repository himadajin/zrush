# Golden vectors

This corpus turns the prose rules in `docs/internal/contracts/cli-protocol.md` into executable byte-level fixtures.

Each `plan/<name>/` directory contains `args`, `payload.bin`, and `expected.bin`.
Each `reject/<name>/` directory contains `args`, `payload.bin`, and `exit`.
Each `reject-plan/<name>/` directory contains only `plan.bin`.
The runner implicitly prepends the `plan` subcommand, so `args` contains flags and their values only.
The `args` file stores one argument per line, with an empty line representing an empty argument.
Shell quoting is not interpreted, and argument values containing newlines cannot be represented.
The `.bin` files contain raw bytes, including `\0`, `\1`, and `\2` separators.
The `exit` file contains one decimal line whose value is `2` or `3`.
Vector names use kebab case and describe the rule being fixed.

`plan/` and `reject/` fix what the `zrush` process produces, so both run the binary.
`reject-plan/` fixes the opposite direction: each `plan.bin` is a byte string that is not a valid plan, and every receiver must reject it.
One vector breaks exactly one acceptance condition from cli-protocol.md "エラー時の zsh 側挙動", and its name says which one.
The corpus covers each condition at digit widths both within and beyond a receiver's integer type, because a receiver that evaluates a digit string arithmetically can wrap an out-of-range value back into range.
No process runs and no golden output is derived, so `UPDATE_GOLDEN` does not apply: write `plan.bin` by hand.

To add a `plan/` or `reject/` vector, create its directory, write `args` and `payload.bin`, and run `UPDATE_GOLDEN=1 cargo test`.
Use golden regeneration only for an intentional protocol change, and review every generated diff.
When regeneration changes files, the test deliberately fails and lists every update so the changes cannot be missed.
After reviewing the diff, rerun the same command; it passes when no files change.

For a readable raw-byte dump, run `od -An -tx1c tests/vectors/plan/<name>/payload.bin`.

Vectors omit `f = 1` candidates because directory slash synthesis depends on filesystem state.
That behavior remains covered by the injected-stat Rust unit tests.
Vectors also omit candidate values containing `\0`, `\1`, or `\2`, and omit redundant `m` fields equal to `w`.
Those are sender-side zsh guarantees and cannot be observed in Rust output.

`cargo test` checks this corpus against the Rust serializer and the `wire` reference parser.
`zsh -f tests/zsh/vectors.zsh` checks the same corpus against the independent zsh decoder `_zrush_parse_plan`, so both sides are held to one set of bytes.
