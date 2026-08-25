# syntax: buffer tokenization specification

コマンドラインバッファの字句分類の規範。
この文書は lexer の純粋な分類と、環境を参照する名前・path の解決を分ける。
wire、zsh、描画への接続は別の契約で定める。

## Input and offsets

- 入力は zsh の `BUFFER` をそのまま受け取るバイト列であり、UTF-8 であるとは限らない。
  Rust は入力を再エンコードしない。
- token の span は `CharSpan` と同じ文字オフセットで、`String::from_utf8_lossy` が読む文字列の
  `[start, end)` 範囲である。invalid byte は lexer を失敗させず、通常の word 内容として扱う。
- token は重なってよい。word の意味分類と、quote／escape／substitution／path の装飾範囲を
  同じ入力上で表すためである。
- 明示的な操作なしに入力を書き換えない。lexer は入力内容を返さず、token と分類だけを返す。

## Token kinds

lexer が返す種別は次のとおり。

`Command`, `Reserved`, `Alias`, `Function`, `Builtin`, `Precommand`, `Unknown`,
`Word`, `Assignment`, `Option`, `Redirect`, `Operator`, `Comment`,
`SingleQuote`, `DoubleQuote`, `DollarQuote`, `Escape`, `Substitution`, `Path`。

意味分類 token (`Command` から `Unknown`、`Word`、`Assignment`、`Option`) と構文範囲 token
(`SingleQuote` から `Path`) は同じ span に重なってよい。

## Lexical boundaries

- 空白、改行、制御演算子、redirect は word を終了する。
- 対応する制御演算子は `;`, `;;`, `;&`, `;;&`, `&&`, `||`, `|`, `&`, `(`, `)` とする。
- 対応する redirect は `<`, `>`, `>>`, `<<`, `<<<`, `<&`, `>&`, `<>`, `>|` とする。
  `>>&` も一つの redirect token とする。
  redirect の後ろの word は command position を開始しない。
- single quote は次の single quote まで、double quote は次の double quote まで、`$'...'` は
  `$` から対応する single quote までを一つの quote 範囲とする。終端が無い場合は buffer の末尾までとする。
- `\` とその直後の byte は `Escape` とする。quote 内でも同じ範囲 token を返す。
- `$(...)` と `${...}` は対応する終端までを `Substitution` とする。内部を再帰的に分類しないが、
  内部の quote と同じ構文境界を認識して終端を誤らせない。
- `interactive_comments` が有効で、`#` が word の先頭に現れた場合、行末までを `Comment` とする。

## Command position and meaning

command position は buffer の先頭、または control operator の直後に始まる。
前置 assignment は command position を消費せず、redirect は command position を変更しない。
command word を一つ分類した後は、次の control operator まで通常の argument position になる。

command position での優先順位は次のとおり。

1. `command`, `exec`, `nohup`, `sudo` は `Precommand`。
2. reserved word は `Reserved`。
3. snapshot の alias、function、builtin はそれぞれの種別。
4. slash を含む executable path、または `$PATH` 上の executable は `Command`。
5. 上記のいずれにも該当しない command word は `Unknown`。

reserved word の初期集合は `if`, `then`, `else`, `elif`, `fi`, `for`, `while`, `until`, `do`,
`done`, `case`, `esac`, `select`, `coproc`, `function`, `repeat`, `time`, `in`, `!`, `[[`, `]]` とする。
snapshot は alias／function／builtin／reserved の名前集合と `$PATH` の raw 値を供給する。

`NAME=` または `NAME=value` の unquoted name prefix を持ち、command position にある word は
`Assignment` とする。assignment の後ろでは command position を維持する。
command position 以外で unquoted `-` から始まる二文字以上の word は `Option` とする。
その他の argument word は `Word` とする。

## Literal paths and resolution

- quote delimiter と単純な escape を除去して一意な byte 列になる word だけを literal とする。
  parameter／command substitution、backtick、glob／brace expansion、`~` は literal path として解決しない。
- slash を含む literal word、および単独の `.`／`..` は path candidate である。
  `cwd` に対して `metadata`（symlink は追跡）し、存在すれば `Path` token を重ねる。
- slash を含む command word は `cwd` に対する executable 判定を行う。slash を含まない command word は
  `$PATH` の各 directory で executable を探す。
- `$PATH` の空要素と相対要素は `cwd` に対して解決する。`PATH` の directory entries は mtime を key とする
  cache に保持し、directory entry の列挙を省略できる。最終的な executable bit は lookup 時にも確認できるため、
  chmod-only の変化は cache の stale 判定を越えて誤分類しない。
- stat の回数は token 数と PATH 要素数に比例し、buffer の長さに無制限に比例する走査を行わない。

## Context and purity

lexer は `LexContext` を引数に取る。context は `NamespaceSnapshot`、`cwd`、
`interactive_comments`、path resolver を含む。
字句境界と意味分類は resolver の filesystem 状態から独立して unit-test できる。
resolver だけが filesystem を参照し、cache の lifetime も resolver 内に閉じる。
