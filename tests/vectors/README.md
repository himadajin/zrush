# Golden vectors

This corpus turns the prose rules in `docs/internal/contracts/cli-protocol.md` into executable byte-level fixtures.

Each `plan/<name>/` directory contains `args`, `payload`, an optional `append`, and `expected`: the `plan` request's scalar fields, the write request's `candidate_payload`, a second payload appended to the history index, and the `plan` response's `ok` body.
Each `reject/<name>/` directory contains `args` and `payload`.
Each `reject-plan/<name>/` directory contains only `plan`.
Each `encode/<name>/` directory contains `argv`, `hits`, `dscr`, `expected`, and an optional `env`.
Each `message/<name>/` directory contains a single `frame`.
The runner drives each vector through one persistent `zrush worker` session as the contract's requests: one write (request_id 1, generation 1) carrying `payload`, then a `plan` referencing the last generation written.
A `store` write is bound to the worker's current input, so its session opens with an `input` notification (input_generation 1) whose quiet period outlives the exchange; the `store` settles it, and the resulting `plan-ready` trails the `store`'s terminal `ok`.
`args` contains flags and their values only.

Two flags select what the session does with `payload` rather than what the `plan` computes:

| flag | meaning |
|---|---|
| `--source` | the write kind: `store` (the default: slot `live`), `history` (`history-snapshot`), or `history-append` |
| `--history-limit` | the `plan`'s scan bound over the history index; omitted, it is the `[history].limit` default of `5000` |

An `append` file adds a `history-append` (request_id 2, generation 2) between the write and the `plan`, so a vector can fix how appended records order and dedup against the snapshot's.
`history_limit` is a mandatory `plan` field whichever store the generation resolves to, so every vector carries one whether or not it reads the index.

Reject vectors expect that session to answer with a terminal response per request, exactly one of which is an `error`.
A candidate-stream framing violation fails the write with `invalid-payload`, and a `history-append` against the uninitialized index fails it with `unknown-generation`; either leaves no generation for the `plan` to reference (`unknown-generation`).
A failed `store` settles nothing, so the `plan-ready` above appears only in the sessions whose `store` is accepted.
A malformed request shape or scalar writes fine and fails the `plan` itself with `invalid-request`.
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

To add a `plan/` or `reject/` vector, create its directory, write `args` and `payload` (plus `append` if it needs one), and run `UPDATE_GOLDEN=1 cargo test`.
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
| `shared-tags-all` | `-P -p -S -s -i -I -X -J` and `IPREFIX` map to the `P p S s i I X J ip` header fields; `-S` also sets `es` |
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
| `explicit-empty-visible-suffix-sets-es` | `-S ''` still emits `es = 1` even though `S` itself is omitted as empty |

`plan/encoder-chain/payload` is identical to `encode/shared-tags-all/expected`, so one byte string runs the whole chain: encoder out, decoder in.
`zsh -f tests/zsh/vectors.zsh` fails if the two files ever diverge.

To add an `encode/` vector, create its directory, write `argv` / `hits` / `dscr` (and `env` if it needs one), then run `UPDATE_GOLDEN=1 zsh -f tests/zsh/vectors.zsh`.
It follows the same discipline as the Rust runner: it writes the golden, then fails listing every file it changed.
A generated `expected` is a proposal, not an answer -- read it against cli-protocol.md before rerunning.

## `message/`

`message/` fixes whole outer messages of the session that carry no candidate stream and no render plan of their own: the input notifications zsh sends, the events the worker sends back, and the terminal response that tells zsh a capture arrived too late.
Each `frame` is one complete outer message, byte for byte as cli-protocol.md "入力通知と worker event" spells it, so the six examples in that section and this corpus are one set of bytes.

| vector | message it fixes |
|---|---|
| `input-no-cache` | an `input` notification with no reusable candidates (`candidate_generation = 0`) |
| `capture-required` | the `capture-required` event answering that input |
| `store-capture` | the `store` carrying that capture, bound to the same `input_generation` |
| `error-superseded` | the `superseded` that store receives when the input is already gone |
| `plan-ready-zero-match` | a `plan-ready` carrying the four-field zero-match plan |
| `flush` | the `flush` that settles an input immediately |

`zsh -f tests/zsh/vectors.zsh` drives these in both directions: it makes the sender produce the notification, flush and store frames byte for byte, and feeds the event and error frames to the receiver to fix what each one does -- including that an event whose `input_generation` is not the current one is dropped before its body is looked at.
The Rust runner reads no vector here; it only holds every `frame` to the canonical spelling above.

## Who checks what

`cargo test` checks `plan/`, `reject/`, and `reject-plan/` against the Rust worker and the `wire` reference parser.
Reject vectors structurally validate exactly the handshake `ready` plus the terminal in-band responses of the session's `store` and `plan`; no process exit 2/3 compatibility is tested.
Both runners independently implement the file format above, check every corpus file for canonical spelling, and hold their own codec to a round trip over arbitrary byte strings.
`zsh -f tests/zsh/vectors.zsh` checks `encode/` against the zsh encoder `_zrush_encode_batch`,
the history sender's line/event-number pairing and filtering against `_zrush_history_snapshot_payload`,
and the same `plan/` and `reject-plan/` corpus against the independent zsh decoder
`_zrush_parse_plan`, so both sides are held to one set of bytes.

`plan/` vectors omit `f = 1` candidates because directory slash synthesis depends on filesystem state.
That behavior remains covered by the injected-stat Rust unit tests.
`plan/` vectors also omit candidate values containing `\0`, `\1`, or `\2`, and omit redundant `m` fields equal to `w`, because a conforming sender never produces them; `encode/` is where those exclusions are fixed.
