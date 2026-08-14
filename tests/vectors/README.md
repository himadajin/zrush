# Golden vectors

This corpus turns the prose rules in `docs/internal/contracts/cli-protocol.md` into executable byte-level fixtures.

Each `plan/<name>/` directory contains `args`, `payload`, and `expected`.
Each `reject/<name>/` directory contains `args` and `payload`.
Each `reject-plan/<name>/` directory contains only `plan`.
Each `encode/<name>/` directory contains `argv`, `hits`, `dscr`, `expected`, and an optional `env`.
The runner sends each vector as a `plan` request to a persistent `zrush worker`; `args` contains flags and their values only.
Reject vectors expect a worker session with exactly one terminal `error` response (`invalid-request` for malformed request shape/scalars, `invalid-payload` for candidate framing).
Vector names use kebab case and describe the rule being fixed.

## File format

Every file here except `env` holds one byte string, written as escaped text so it stays a reviewable diff and can be edited directly.

- Bytes `0x20`-`0x7e` other than `\` stand for themselves.
- `\0` `\1` `\2` `\n` `\r` `\t` `\\` spell those bytes; every other byte is `\xNN`, lower-case hex, always two digits.
- **A line break is layout, not data**: the decoded byte string is the concatenation of the decoded lines.
  Nothing about the record structure is assumed, so a deliberately malformed byte string is as expressible as a well-formed one.
- The writer starts a new line after every `\0` and `\2`, so a plan golden reads one field per line and a regenerated golden diffs field by field.
  That spelling is the canonical one, and both runners fail on any file that departs from it -- a decoder that silently substituted one byte string for another would otherwise let a `reject-plan/` vector pass while fixing nothing.
- An empty file is the empty byte string.

`args`, `argv`, `hits`, and `dscr` hold NUL-*terminated* lists in that same format: one element per line, each ending in `\0`.

`plan/` and `reject/` fix what the `zrush worker` process produces, so both run the binary.
`reject-plan/` fixes the opposite direction: each `plan` is a byte string that is not a valid plan, and every receiver must reject it.
One vector breaks exactly one acceptance condition from cli-protocol.md "エラー時の zsh 側挙動", and its name says which one.
The corpus covers each condition at digit widths both within and beyond a receiver's integer type, because a receiver that evaluates a digit string arithmetically can wrap an out-of-range value back into range.
Where a condition constrains a sum (`start + len` against the listing text), a vector also fixes the case where each value alone is in range and only the sum escapes.
No process runs and no golden output is derived, so `UPDATE_GOLDEN` does not apply: write `plan` by hand.

To add a `plan/` or `reject/` vector, create its directory, write `args` and `payload`, and run `UPDATE_GOLDEN=1 cargo test`.
Use golden regeneration only for an intentional protocol change, and review every generated diff.
When regeneration changes files, the test deliberately fails and lists every update so the changes cannot be missed.
After reviewing the diff, rerun the same command; it passes when no files change.

## `encode/`

`encode/` fixes the sender side of the capture stream: one `compadd` call in, the bytes `zsh/zrush.zsh` writes to the collection pipe out.
`argv` is the argument list the `compadd` call was made with, `hits` the candidates `compadd -A` returned, and `dscr` the display strings `compadd -D` returned.
The optional `env` file holds one `KEY=VALUE` per line and is applied to the calling scope only, so a vector can pin values (`IPREFIX`, `HOME`, parameters the `-f` real-directory expansion reads) that would otherwise depend on the machine.
It carries zsh parameter assignments rather than a wire byte string, so it is the one file not in the format above.

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
| `explicit-empty-visible-suffix-sets-es` | `-S ''` still emits `es = 1` -- presence of `-S`, not its value, drives `es` |

`plan/encoder-chain/payload` is identical to `encode/shared-tags-all/expected`, so one byte string runs the whole chain: encoder out, decoder in.
`zsh -f tests/zsh/vectors.zsh` fails if the two files ever diverge.

To add an `encode/` vector, create its directory, write `argv` / `hits` / `dscr` (and `env` if it needs one), then run `UPDATE_GOLDEN=1 zsh -f tests/zsh/vectors.zsh`.
It follows the same discipline as the Rust runner: it writes the golden, then fails listing every file it changed.
A generated `expected` is a proposal, not an answer -- read it against cli-protocol.md before rerunning.

## Who checks what

`cargo test` checks `plan/`, `reject/`, and `reject-plan/` against the Rust worker and the `wire` reference parser. Reject vectors structurally validate exactly `[ready,8]` plus one terminal in-band `error`; no process exit 2/3 compatibility is tested.
Both runners independently implement the file format above, check every corpus file for canonical spelling, and hold their own codec to a round trip over arbitrary byte strings.
`zsh -f tests/zsh/vectors.zsh` checks `encode/` against the zsh encoder `_zrush_encode_batch`,
the history sender's line/event-number pairing and filtering against `_zrush_history_payload`,
and the same `plan/` and `reject-plan/` corpus against the independent zsh decoder
`_zrush_parse_plan`, so both sides are held to one set of bytes.

`plan/` vectors omit `f = 1` candidates because directory slash synthesis depends on filesystem state.
That behavior remains covered by the injected-stat Rust unit tests.
`plan/` vectors also omit candidate values containing `\0`, `\1`, or `\2`, and omit redundant `m` fields equal to `w`, because a conforming sender never produces them; `encode/` is where those exclusions are fixed.
