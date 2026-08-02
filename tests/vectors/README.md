# Golden vectors

This corpus turns the prose rules in `docs/internal/contracts/cli-protocol.md` into executable byte-level fixtures.

Each `plan/<name>/` directory contains `args`, `payload.bin`, and `expected.bin`.
Each `reject/<name>/` directory contains `args`, `payload.bin`, and `exit`.
Each `reject-plan/<name>/` directory contains only `plan.bin`.
Each `encode/<name>/` directory contains `argv.bin`, `hits.bin`, `dscr.bin`, `expected.bin`, and an optional `env`.
The runner sends each vector as a `plan` request to a persistent `zrush worker`; `args` contains flags and their values only.
The `args` file stores one argument per line, with an empty line representing an empty argument.
Shell quoting is not interpreted, and argument values containing newlines cannot be represented.
The `.bin` files contain raw bytes, including `\0`, `\1`, and `\2` separators.
Reject vectors expect a worker session with exactly one terminal `error` response (`invalid-request` for malformed request shape/scalars, `invalid-payload` for candidate framing).
Vector names use kebab case and describe the rule being fixed.

`plan/` and `reject/` fix what the `zrush worker` process produces, so both run the binary.
`reject-plan/` fixes the opposite direction: each `plan.bin` is a byte string that is not a valid plan, and every receiver must reject it.
One vector breaks exactly one acceptance condition from cli-protocol.md "エラー時の zsh 側挙動", and its name says which one.
The corpus covers each condition at digit widths both within and beyond a receiver's integer type, because a receiver that evaluates a digit string arithmetically can wrap an out-of-range value back into range.
Where a condition constrains a sum (`start + len` against the listing text), a vector also fixes the case where each value alone is in range and only the sum escapes.
No process runs and no golden output is derived, so `UPDATE_GOLDEN` does not apply: write `plan.bin` by hand.

To add a `plan/` or `reject/` vector, create its directory, write `args` and `payload.bin`, and run `UPDATE_GOLDEN=1 cargo test`.
Use golden regeneration only for an intentional protocol change, and review every generated diff.
When regeneration changes files, the test deliberately fails and lists every update so the changes cannot be missed.
After reviewing the diff, rerun the same command; it passes when no files change.

For a readable raw-byte dump, run `od -An -tx1c tests/vectors/plan/<name>/payload.bin`.

## `encode/`

`encode/` fixes the sender side of the capture stream: one `compadd` call in, the bytes `zsh/zrush.zsh` writes to the collection pipe out.
`argv.bin` is the argument list the `compadd` call was made with, `hits.bin` the candidates `compadd -A` returned, and `dscr.bin` the display strings `compadd -D` returned.
These three are NUL-*terminated* lists, not the line-per-argument form `plan/args` uses, because candidates and option values are arbitrary byte strings and may contain newlines; an empty file means an empty list.
The optional `env` file holds one `KEY=VALUE` per line and is applied to the calling scope only, so a vector can pin values (`IPREFIX`, `HOME`, parameters the `-f` real-directory expansion reads) that would otherwise depend on the machine.

These vectors exist because the guarantees below are the sender's, never appear in Rust output, and so cannot be fixed by a `plan/` vector:

| vector | rule it fixes |
|---|---|
| `shared-tags-all` | `-P -p -S -s -i -I -X -J` and `IPREFIX` map to the `P p S s i I X J ip` header fields |
| `shared-tags-none` | the header record is emitted even when every shared field is empty |
| `no-candidates` | a `compadd` call producing no candidate emits nothing at all, header included |
| `all-candidates-dropped` | when every candidate is dropped the header is still emitted (the contract permits either) |
| `match-equals-word` | `m` is omitted when it would equal `w` |
| `match-differs-quoted` | `m` carries `${(Q)w}` when the quoted and unquoted forms differ |
| `display-text` | `d` is emitted only when non-empty, whether the `-D` entry is empty or absent |
| `control-byte-candidate` | a candidate containing a framing byte is dropped whole, with its description |
| `control-byte-decoded` | so is a candidate whose quoted form is clean but whose `${(Q)}` form is not |
| `control-byte-shared-field` | a shared field whose value contains a framing byte is dropped, the others stay |
| `newline-in-candidate` | a newline is not a framing byte and passes through `w` and `d` unchanged |
| `file-real-dir-tilde` | `-f` adds `f` and `rd`; `rd` is `IPREFIX` + `-p` with tilde expansion applied |
| `file-real-dir-param` | `rd` also resolves parameter expansion, while `p` keeps the raw form |

`plan/encoder-chain/payload.bin` is byte-identical to `encode/shared-tags-all/expected.bin`, so one byte string runs the whole chain: encoder out, decoder in.
`zsh -f tests/zsh/vectors.zsh` fails if the two files ever diverge.

To add an `encode/` vector, create its directory, write `argv.bin` / `hits.bin` / `dscr.bin` (and `env` if it needs one), then run `UPDATE_GOLDEN=1 zsh -f tests/zsh/vectors.zsh`.
It follows the same discipline as the Rust runner: it writes the golden, then fails listing every file it changed.
A generated `expected.bin` is a proposal, not an answer -- read it against cli-protocol.md before rerunning.

## Who checks what

`cargo test` checks `plan/`, `reject/`, and `reject-plan/` against the Rust worker and the `wire` reference parser. Reject vectors structurally validate exactly `[ready,6]` plus one terminal in-band `error`; no process exit 2/3 compatibility is tested.
`zsh -f tests/zsh/vectors.zsh` checks `encode/` against the zsh encoder `_zrush_encode_batch`,
the history sender's line/event-number pairing and filtering against `_zrush_history_payload`,
and the same `plan/` and `reject-plan/` corpus against the independent zsh decoder
`_zrush_parse_plan`, so both sides are held to one set of bytes.

`plan/` vectors omit `f = 1` candidates because directory slash synthesis depends on filesystem state.
That behavior remains covered by the injected-stat Rust unit tests.
`plan/` vectors also omit candidate values containing `\0`, `\1`, or `\2`, and omit redundant `m` fields equal to `w`, because a conforming sender never produces them; `encode/` is where those exclusions are fixed.
