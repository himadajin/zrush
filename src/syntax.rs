//! Command-line buffer tokenization and command/path classification.
//!
//! Semantics: docs/internal/specs/syntax.md (source of truth).  The scanner
//! works on raw bytes and only turns spans into the crate's lossy-UTF-8
//! character offsets at the final boundary.  Filesystem access is isolated in
//! [`PathResolver`]; the lexical scanner and namespace classification remain
//! deterministic and unit-testable without a real filesystem.

use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::PermissionsExt;
use std::time::SystemTime;

use crate::span::CharSpan;

/// A syntax role over one character range of the input buffer.
///
/// Semantic word roles and lexical decoration roles intentionally overlap:
/// the same quoted command can be both `Command` and `DoubleQuote`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TokenKind {
    Command,
    Reserved,
    Alias,
    Function,
    Builtin,
    Precommand,
    Unknown,
    Word,
    Assignment,
    Option,
    Redirect,
    Operator,
    Comment,
    SingleQuote,
    DoubleQuote,
    DollarQuote,
    Escape,
    Substitution,
    Path,
}

/// One token returned by [`analyze`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Token {
    pub kind: TokenKind,
    pub span: CharSpan,
}

/// Names zsh supplies to the worker for one syntax-analysis snapshot.
///
/// Names are raw bytes because aliases, functions, and executable files need
/// not be UTF-8.  `path` is the raw colon-separated `$PATH` value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct NamespaceSnapshot {
    pub aliases: BTreeSet<Vec<u8>>,
    pub functions: BTreeSet<Vec<u8>>,
    pub builtins: BTreeSet<Vec<u8>>,
    pub reserved: BTreeSet<Vec<u8>>,
    pub path: Vec<u8>,
}

impl Default for NamespaceSnapshot {
    fn default() -> Self {
        Self {
            aliases: BTreeSet::new(),
            functions: BTreeSet::new(),
            builtins: BTreeSet::new(),
            reserved: default_reserved(),
            path: Vec::new(),
        }
    }
}

/// Filesystem-backed state is deliberately not part of [`NamespaceSnapshot`].
/// A resolver owns its directory-entry cache and can be reused for successive
/// buffers in one worker session.
#[derive(Debug, Default)]
pub(crate) struct PathResolver {
    directories: Vec<DirectoryCache>,
}

#[derive(Debug)]
struct DirectoryCache {
    path: Vec<u8>,
    modified: SystemTime,
    entries: BTreeSet<Vec<u8>>,
}

impl PathResolver {
    /// Return whether a literal path exists, following symlinks like zsh's
    /// ordinary path tests do.  The caller has already decided the path is
    /// literal and bounded the number of calls by the number of tokens.
    fn path_exists(&self, cwd: &[u8], path: &[u8]) -> bool {
        metadata(&resolve_path(cwd, path)).is_some()
    }

    /// Return whether `name` names an executable command either directly or on
    /// the supplied raw `$PATH`.
    fn command_exists(&mut self, cwd: &[u8], path: &[u8], name: &[u8]) -> bool {
        if name.contains(&b'/') {
            return is_executable(&resolve_path(cwd, name));
        }

        for element in path.split(|byte| *byte == b':') {
            let directory = path_directory(cwd, element);
            let Some(entries) = self.entries_for(&directory) else {
                continue;
            };
            if entries.contains(name) && is_executable(&join_bytes(&directory, name)) {
                return true;
            }
        }
        false
    }

    fn entries_for(&mut self, directory: &[u8]) -> Option<BTreeSet<Vec<u8>>> {
        let modified = fs::metadata(os_path(directory)).ok()?.modified().ok()?;

        if let Some(cache) = self
            .directories
            .iter()
            .find(|cache| cache.path == directory && cache.modified == modified)
        {
            return Some(cache.entries.clone());
        }

        let entries = fs::read_dir(os_path(directory))
            .ok()?
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().into_vec())
            .collect::<BTreeSet<_>>();

        self.directories.retain(|cache| cache.path != directory);
        self.directories.push(DirectoryCache {
            path: directory.to_vec(),
            modified,
            entries: entries.clone(),
        });
        Some(entries)
    }
}

/// Filesystem resolution is the only impure part of syntax analysis.  Tests
/// can provide a deterministic implementation while the production resolver
/// keeps its directory-mtime cache.
pub(crate) trait Resolver {
    fn path_exists(&self, cwd: &[u8], path: &[u8]) -> bool;
    fn command_exists(&mut self, cwd: &[u8], path: &[u8], name: &[u8]) -> bool;
}

impl Resolver for PathResolver {
    fn path_exists(&self, cwd: &[u8], path: &[u8]) -> bool {
        self.path_exists(cwd, path)
    }

    fn command_exists(&mut self, cwd: &[u8], path: &[u8], name: &[u8]) -> bool {
        self.command_exists(cwd, path, name)
    }
}

/// Immutable shell facts plus the resolver used for one buffer analysis.
/// Keeping the context explicit makes the later zsh snapshot supply path
/// independent from the lexical scanner.
pub(crate) struct LexContext<'a, R: Resolver> {
    pub snapshot: &'a NamespaceSnapshot,
    pub cwd: &'a [u8],
    pub interactive_comments: bool,
    pub resolver: &'a mut R,
}

impl<'a, R: Resolver> LexContext<'a, R> {
    pub(crate) fn new(
        snapshot: &'a NamespaceSnapshot,
        cwd: &'a [u8],
        interactive_comments: bool,
        resolver: &'a mut R,
    ) -> Self {
        Self {
            snapshot,
            cwd,
            interactive_comments,
            resolver,
        }
    }
}

/// Analyze one raw buffer using a namespace snapshot and a filesystem
/// resolver.  The lexical pass is independent of the resolver; only command
/// and literal-path roles consult it.
pub(crate) fn analyze<R: Resolver>(input: &[u8], context: &mut LexContext<'_, R>) -> Vec<Token> {
    let snapshot = context.snapshot;
    let cwd = context.cwd;
    let interactive_comments = context.interactive_comments;
    let resolver = &mut *context.resolver;
    let lexed = tokenize(input, interactive_comments);
    let offsets = LossyOffsets::new(input);
    let mut result = Vec::new();
    let mut command_position = true;
    let mut precommand: Option<Precommand> = None;
    let mut precommand_value = false;
    let mut options_done = false;
    let mut redirect_pending = false;

    for raw in &lexed.tokens {
        match raw.kind {
            RawKind::Structural(kind) => {
                result.push(token(kind, raw.start, raw.end, &offsets));
                if kind == TokenKind::Redirect {
                    redirect_pending = true;
                } else if kind == TokenKind::Operator
                    && is_command_separator(&input[raw.start..raw.end])
                {
                    command_position = true;
                    precommand = None;
                    precommand_value = false;
                    options_done = false;
                    redirect_pending = false;
                }
            }
            RawKind::Word(index) => {
                let word = &lexed.words[index];
                let raw_word = &input[word.start..word.end];
                let mut kind = TokenKind::Word;

                if redirect_pending {
                    redirect_pending = false;
                } else if let Some(wrapper) = precommand {
                    if precommand_value {
                        // This is an argument consumed by the wrapper, not
                        // the command that follows it.
                        kind = TokenKind::Word;
                        precommand_value = false;
                    } else if !options_done && is_option_word(word, raw_word) {
                        kind = TokenKind::Option;
                        precommand_value = precommand_takes_value(wrapper, raw_word);
                    } else if !options_done && is_end_of_options(word, raw_word) {
                        kind = TokenKind::Option;
                        options_done = true;
                    } else if is_assignment(word, raw_word) {
                        kind = TokenKind::Assignment;
                    } else {
                        kind = resolve_command(word, raw_word, snapshot, cwd, resolver);
                        command_position = false;
                        precommand = None;
                    }
                } else if command_position && is_assignment(word, raw_word) {
                    kind = TokenKind::Assignment;
                } else if command_position {
                    if let Some(wrapper) = precommand_kind(word, raw_word) {
                        kind = TokenKind::Precommand;
                        precommand = Some(wrapper);
                        precommand_value = false;
                        options_done = false;
                    } else if is_reserved(snapshot, word, raw_word) {
                        kind = TokenKind::Reserved;
                        command_position = reserved_starts_command(raw_word);
                    } else {
                        kind = resolve_command(word, raw_word, snapshot, cwd, resolver);
                        command_position = false;
                    }
                } else if is_option_word(word, raw_word) {
                    kind = TokenKind::Option;
                }

                result.push(token(kind, word.start, word.end, &offsets));
                for decoration in &word.decorations {
                    result.push(token(
                        decoration.kind,
                        decoration.start,
                        decoration.end,
                        &offsets,
                    ));
                }
                if let Some(literal) = word.literal.as_deref()
                    && is_path_candidate(literal)
                    && resolver.path_exists(cwd, literal)
                {
                    result.push(token(TokenKind::Path, word.start, word.end, &offsets));
                }
            }
        }
    }

    result
}

fn classify_command(executable: bool) -> TokenKind {
    if executable {
        TokenKind::Command
    } else {
        TokenKind::Unknown
    }
}

fn lookup<'a>(word: &'a RawWord, raw_word: &'a [u8]) -> &'a [u8] {
    word.literal.as_deref().unwrap_or(raw_word)
}

fn namespace_kind(
    word: &RawWord,
    raw_word: &[u8],
    snapshot: &NamespaceSnapshot,
) -> Option<TokenKind> {
    let lookup = lookup(word, raw_word);
    if is_reserved(snapshot, word, raw_word) {
        Some(TokenKind::Reserved)
    } else if word.plain && snapshot.aliases.contains(lookup) {
        Some(TokenKind::Alias)
    } else if word.plain && snapshot.functions.contains(lookup) {
        Some(TokenKind::Function)
    } else if word.plain && snapshot.builtins.contains(lookup) {
        Some(TokenKind::Builtin)
    } else {
        None
    }
}

fn resolve_command<R: Resolver>(
    word: &RawWord,
    raw_word: &[u8],
    snapshot: &NamespaceSnapshot,
    cwd: &[u8],
    resolver: &mut R,
) -> TokenKind {
    if let Some(kind) = namespace_kind(word, raw_word, snapshot) {
        return kind;
    }
    let executable = resolver.command_exists(cwd, &snapshot.path, lookup(word, raw_word));
    classify_command(executable)
}

fn is_reserved(snapshot: &NamespaceSnapshot, word: &RawWord, raw_word: &[u8]) -> bool {
    let lookup = word.literal.as_deref().unwrap_or(raw_word);
    word.plain && snapshot.reserved.contains(lookup)
}

fn precommand_kind(word: &RawWord, raw_word: &[u8]) -> Option<Precommand> {
    if !word.plain {
        return None;
    }
    match raw_word {
        b"command" => Some(Precommand::Command),
        b"exec" => Some(Precommand::Exec),
        b"nohup" => Some(Precommand::Nohup),
        b"sudo" => Some(Precommand::Sudo),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy)]
enum Precommand {
    Command,
    Exec,
    Nohup,
    Sudo,
}

fn precommand_takes_value(precommand: Precommand, option: &[u8]) -> bool {
    match precommand {
        Precommand::Command => false,
        Precommand::Exec => option == b"-a",
        Precommand::Nohup => false,
        Precommand::Sudo => matches!(
            option,
            b"-u"
                | b"--user"
                | b"-g"
                | b"--group"
                | b"-p"
                | b"--prompt"
                | b"-r"
                | b"--role"
                | b"-t"
                | b"--type"
                | b"-C"
                | b"--close-from"
                | b"-D"
                | b"--chdir"
                | b"-R"
                | b"--chroot"
                | b"-T"
                | b"--command-timeout"
                | b"--host"
        ),
    }
}

fn is_option_word(word: &RawWord, raw_word: &[u8]) -> bool {
    word.plain && raw_word.len() > 1 && raw_word[0] == b'-'
}

fn is_end_of_options(word: &RawWord, raw_word: &[u8]) -> bool {
    word.plain && raw_word == b"--"
}

fn is_assignment(word: &RawWord, raw_word: &[u8]) -> bool {
    if !word.plain {
        return false;
    }
    let Some(equal) = raw_word.iter().position(|byte| *byte == b'=') else {
        return false;
    };
    let name = &raw_word[..equal];
    !name.is_empty()
        && (name[0].is_ascii_alphabetic() || name[0] == b'_')
        && name[1..]
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
}

fn reserved_starts_command(word: &[u8]) -> bool {
    matches!(
        word,
        b"if" | b"then" | b"else" | b"elif" | b"while" | b"until" | b"do" | b"in" | b"!"
    )
}

fn default_reserved() -> BTreeSet<Vec<u8>> {
    [
        b"if".as_slice(),
        b"then",
        b"else",
        b"elif",
        b"fi",
        b"for",
        b"while",
        b"until",
        b"do",
        b"done",
        b"case",
        b"esac",
        b"select",
        b"coproc",
        b"function",
        b"repeat",
        b"time",
        b"in",
        b"!",
        b"[[",
        b"]]",
    ]
    .into_iter()
    .map(|word| word.to_vec())
    .collect()
}

#[derive(Debug)]
struct Lexed {
    tokens: Vec<RawToken>,
    words: Vec<RawWord>,
}

#[derive(Debug)]
struct RawWord {
    start: usize,
    end: usize,
    literal: Option<Vec<u8>>,
    plain: bool,
    decorations: Vec<RawDecoration>,
}

#[derive(Debug)]
struct RawDecoration {
    kind: TokenKind,
    start: usize,
    end: usize,
}

#[derive(Debug, Clone, Copy)]
struct RawToken {
    kind: RawKind,
    start: usize,
    end: usize,
}

#[derive(Debug, Clone, Copy)]
enum RawKind {
    Structural(TokenKind),
    Word(usize),
}

struct WordBuilder {
    start: usize,
    literal: Vec<u8>,
    literal_ok: bool,
    plain: bool,
    decorations: Vec<RawDecoration>,
}

impl WordBuilder {
    fn new(start: usize) -> Self {
        Self {
            start,
            literal: Vec::new(),
            literal_ok: true,
            plain: true,
            decorations: Vec::new(),
        }
    }

    fn raw(&mut self, bytes: &[u8]) {
        self.literal.extend_from_slice(bytes);
    }

    fn not_literal(&mut self) {
        self.literal_ok = false;
    }

    fn quoted(&mut self) {
        self.plain = false;
    }

    fn finish(self, end: usize) -> RawWord {
        RawWord {
            start: self.start,
            end,
            literal: self.literal_ok.then_some(self.literal),
            plain: self.plain,
            decorations: self.decorations,
        }
    }
}

fn tokenize(input: &[u8], interactive_comments: bool) -> Lexed {
    let mut lexed = Lexed {
        tokens: Vec::new(),
        words: Vec::new(),
    };
    let mut word: Option<WordBuilder> = None;
    let mut i = 0;

    while i < input.len() {
        let byte = input[i];
        if byte == b'\n' {
            flush_word(&mut lexed, &mut word, i);
            lexed.tokens.push(RawToken {
                kind: RawKind::Structural(TokenKind::Operator),
                start: i,
                end: i + 1,
            });
            i += 1;
            continue;
        }
        if byte.is_ascii_whitespace() {
            flush_word(&mut lexed, &mut word, i);
            i += 1;
            continue;
        }
        if interactive_comments && byte == b'#' && word.is_none() {
            let end = input[i..]
                .iter()
                .position(|byte| *byte == b'\n')
                .map_or(input.len(), |offset| i + offset);
            lexed.tokens.push(RawToken {
                kind: RawKind::Structural(TokenKind::Comment),
                start: i,
                end,
            });
            i = end;
            continue;
        }
        if let Some(length) = operator_len(&input[i..]) {
            flush_word(&mut lexed, &mut word, i);
            let kind = if is_redirect(&input[i..i + length]) {
                TokenKind::Redirect
            } else {
                TokenKind::Operator
            };
            lexed.tokens.push(RawToken {
                kind: RawKind::Structural(kind),
                start: i,
                end: i + length,
            });
            i += length;
            continue;
        }

        if word.is_none() {
            word = Some(WordBuilder::new(i));
        }
        let builder = word.as_mut().expect("word initialized above");
        match byte {
            b'\\' => {
                i = scan_escape(input, i, builder, false);
            }
            b'\'' => {
                i = scan_single_quote(input, i, builder, TokenKind::SingleQuote);
            }
            b'"' => {
                i = scan_double_quote(input, i, builder);
            }
            b'$' if input.get(i + 1) == Some(&b'\'') => {
                i = scan_dollar_quote(input, i, builder);
            }
            b'$' if input
                .get(i + 1)
                .is_some_and(|next| *next == b'(' || *next == b'{') =>
            {
                let end = scan_substitution(input, i, builder);
                i = end;
            }
            b'$' => {
                builder.not_literal();
                builder.raw(b"$");
                i += 1;
            }
            b'`' => {
                builder.not_literal();
                builder.raw(b"`");
                i += 1;
            }
            b'*' | b'?' | b'[' | b']' | b'{' | b'}' | b'~' => {
                builder.not_literal();
                builder.raw(&[byte]);
                i += 1;
            }
            _ => {
                builder.raw(&[byte]);
                i += 1;
            }
        }
    }
    flush_word(&mut lexed, &mut word, input.len());
    lexed
}

fn flush_word(lexed: &mut Lexed, word: &mut Option<WordBuilder>, end: usize) {
    let Some(builder) = word.take() else {
        return;
    };
    let index = lexed.words.len();
    let raw = builder.finish(end);
    lexed.tokens.push(RawToken {
        kind: RawKind::Word(index),
        start: raw.start,
        end: raw.end,
    });
    lexed.words.push(raw);
}

fn scan_escape(input: &[u8], start: usize, builder: &mut WordBuilder, dollar_quote: bool) -> usize {
    builder.quoted();
    builder.decorations.push(RawDecoration {
        kind: TokenKind::Escape,
        start,
        end: (start + 2).min(input.len()),
    });
    if start + 1 >= input.len() {
        builder.not_literal();
        return input.len();
    }
    if dollar_quote {
        if let Some((decoded, consumed)) = decode_dollar_escape(&input[start + 1..]) {
            builder.raw(&decoded);
            start + 1 + consumed
        } else {
            builder.not_literal();
            start + 2
        }
    } else {
        let next = input[start + 1];
        if next != b'\n' {
            builder.raw(&[next]);
        }
        start + 2
    }
}

fn scan_single_quote(
    input: &[u8],
    start: usize,
    builder: &mut WordBuilder,
    kind: TokenKind,
) -> usize {
    builder.quoted();
    let mut i = start + 1;
    while i < input.len() && input[i] != b'\'' {
        builder.raw(&[input[i]]);
        i += 1;
    }
    let end = if i < input.len() { i + 1 } else { input.len() };
    if i == input.len() {
        builder.not_literal();
    }
    builder.decorations.push(RawDecoration { kind, start, end });
    end
}

fn scan_double_quote(input: &[u8], start: usize, builder: &mut WordBuilder) -> usize {
    builder.quoted();
    let mut i = start + 1;
    while i < input.len() {
        match input[i] {
            b'"' => {
                let end = i + 1;
                builder.decorations.push(RawDecoration {
                    kind: TokenKind::DoubleQuote,
                    start,
                    end,
                });
                return end;
            }
            b'\\' => {
                i = scan_escape(input, i, builder, false);
            }
            b'$' if input
                .get(i + 1)
                .is_some_and(|next| *next == b'(' || *next == b'{') =>
            {
                i = scan_substitution(input, i, builder);
            }
            _ => {
                builder.raw(&[input[i]]);
                i += 1;
            }
        }
    }
    builder.not_literal();
    builder.decorations.push(RawDecoration {
        kind: TokenKind::DoubleQuote,
        start,
        end: input.len(),
    });
    input.len()
}

fn scan_dollar_quote(input: &[u8], start: usize, builder: &mut WordBuilder) -> usize {
    builder.quoted();
    let mut i = start + 2;
    while i < input.len() {
        match input[i] {
            b'\'' => {
                let end = i + 1;
                builder.decorations.push(RawDecoration {
                    kind: TokenKind::DollarQuote,
                    start,
                    end,
                });
                return end;
            }
            b'\\' => i = scan_escape(input, i, builder, true),
            _ => {
                builder.raw(&[input[i]]);
                i += 1;
            }
        }
    }
    builder.not_literal();
    builder.decorations.push(RawDecoration {
        kind: TokenKind::DollarQuote,
        start,
        end: input.len(),
    });
    input.len()
}

fn scan_substitution(input: &[u8], start: usize, builder: &mut WordBuilder) -> usize {
    builder.quoted();
    builder.not_literal();
    let opening = input[start + 1];
    let closing = if opening == b'(' { b')' } else { b'}' };
    let mut depth = 1usize;
    let mut i = start + 2;
    while i < input.len() {
        match input[i] {
            b'\\' => i = (i + 2).min(input.len()),
            b'\'' => i = skip_quote(input, i, b'\''),
            b'"' => i = skip_quote(input, i, b'"'),
            byte if byte == opening => {
                depth += 1;
                i += 1;
            }
            byte if byte == closing => {
                depth -= 1;
                i += 1;
                if depth == 0 {
                    break;
                }
            }
            _ => i += 1,
        }
    }
    builder.decorations.push(RawDecoration {
        kind: TokenKind::Substitution,
        start,
        end: i,
    });
    i
}

fn skip_quote(input: &[u8], start: usize, quote: u8) -> usize {
    let mut i = start + 1;
    while i < input.len() {
        if input[i] == b'\\' {
            i = (i + 2).min(input.len());
        } else if input[i] == quote {
            return i + 1;
        } else {
            i += 1;
        }
    }
    input.len()
}

fn decode_dollar_escape(bytes: &[u8]) -> Option<(Vec<u8>, usize)> {
    let byte = *bytes.first()?;
    let decoded = match byte {
        b'a' => b'\x07',
        b'b' => b'\x08',
        b'e' => b'\x1b',
        b'f' => b'\x0c',
        b'n' => b'\n',
        b'r' => b'\r',
        b't' => b'\t',
        b'v' => b'\x0b',
        b'\\' | b'\'' | b'"' => byte,
        b'x' if bytes.len() >= 3 => {
            let high = hex(bytes[1])?;
            let low = hex(bytes[2])?;
            return Some((vec![(high << 4) | low], 3));
        }
        _ => return None,
    };
    Some((vec![decoded], 1))
}

fn hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn operator_len(bytes: &[u8]) -> Option<usize> {
    let candidates = [
        b"<<<".as_slice(),
        b";;&",
        b">>&",
        b"&&",
        b"||",
        b";;",
        b";&",
        b">>",
        b"<<",
        b"<&",
        b">&",
        b"<>",
        b">|",
        b";",
        b"|",
        b"&",
        b"(",
        b")",
        b"<",
        b">",
    ];
    candidates
        .iter()
        .find(|candidate| bytes.starts_with(candidate))
        .map(|candidate| candidate.len())
}

fn is_redirect(bytes: &[u8]) -> bool {
    matches!(
        bytes,
        b"<" | b">" | b">>" | b"<<" | b"<<<" | b"<&" | b">&" | b"<>" | b">|" | b">>&"
    )
}

fn is_command_separator(bytes: &[u8]) -> bool {
    matches!(
        bytes,
        b"\n" | b";" | b";;" | b";&" | b";;&" | b"&&" | b"||" | b"|" | b"&" | b"(" | b")"
    )
}

fn is_path_candidate(path: &[u8]) -> bool {
    path.contains(&b'/') || path == b"." || path == b".."
}

fn token(kind: TokenKind, start: usize, end: usize, offsets: &LossyOffsets) -> Token {
    Token {
        kind,
        span: CharSpan::new(offsets.at(start), offsets.at(end)),
    }
}

fn path_directory(cwd: &[u8], element: &[u8]) -> Vec<u8> {
    if element.is_empty() {
        cwd.to_vec()
    } else if element.starts_with(b"/") {
        element.to_vec()
    } else {
        join_bytes(cwd, element)
    }
}

fn resolve_path(cwd: &[u8], path: &[u8]) -> Vec<u8> {
    if path.starts_with(b"/") {
        path.to_vec()
    } else {
        join_bytes(cwd, path)
    }
}

fn join_bytes(directory: &[u8], name: &[u8]) -> Vec<u8> {
    if directory.is_empty() {
        return name.to_vec();
    }
    let mut joined = directory.to_vec();
    if !joined.ends_with(b"/") {
        joined.push(b'/');
    }
    joined.extend_from_slice(name);
    joined
}

fn os_path(bytes: &[u8]) -> &OsStr {
    OsStr::from_bytes(bytes)
}

fn metadata(path: &[u8]) -> Option<fs::Metadata> {
    fs::metadata(os_path(path)).ok()
}

fn is_executable(path: &[u8]) -> bool {
    let Some(metadata) = metadata(path) else {
        return false;
    };
    metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
}

/// Prefix sums of character counts in the standard lossy UTF-8 reading.
/// Invalid maximal subsequences occupy one replacement character, matching
/// `String::from_utf8_lossy` and the existing matching/layout offset rules.
struct LossyOffsets {
    offsets: Vec<usize>,
}

impl LossyOffsets {
    fn new(bytes: &[u8]) -> Self {
        let mut offsets = vec![0; bytes.len() + 1];
        let mut byte = 0;
        let mut chars = 0;
        while byte < bytes.len() {
            match std::str::from_utf8(&bytes[byte..]) {
                Ok(valid) => {
                    for (offset, character) in valid.char_indices() {
                        offsets[byte + offset] = chars;
                        chars += 1;
                        offsets[byte + offset + character.len_utf8()] = chars;
                    }
                    byte = bytes.len();
                }
                Err(error) if error.valid_up_to() > 0 => {
                    let valid_len = error.valid_up_to();
                    let valid =
                        std::str::from_utf8(&bytes[byte..byte + valid_len]).expect("valid prefix");
                    for (offset, character) in valid.char_indices() {
                        offsets[byte + offset] = chars;
                        chars += 1;
                        offsets[byte + offset + character.len_utf8()] = chars;
                    }
                    byte += valid_len;
                }
                Err(error) => {
                    let invalid_len = error.error_len().unwrap_or(bytes.len() - byte);
                    for offset in 0..invalid_len {
                        offsets[byte + offset] = chars;
                    }
                    chars += 1;
                    offsets[byte + invalid_len] = chars;
                    byte += invalid_len;
                }
            }
        }
        Self { offsets }
    }

    fn at(&self, byte: usize) -> usize {
        self.offsets[byte.min(self.offsets.len() - 1)]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, File};
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    use tempfile::tempdir;

    fn snapshot() -> NamespaceSnapshot {
        NamespaceSnapshot {
            aliases: [b"ll".to_vec()].into_iter().collect(),
            functions: [b"build".to_vec()].into_iter().collect(),
            builtins: [b"echo".to_vec()].into_iter().collect(),
            reserved: default_reserved(),
            path: Vec::new(),
        }
    }

    fn kinds(input: &[u8], comments: bool) -> Vec<TokenKind> {
        let mut resolver = PathResolver::default();
        let snapshot = snapshot();
        let mut context = LexContext::new(&snapshot, b".", comments, &mut resolver);
        analyze(input, &mut context)
            .into_iter()
            .map(|token| token.kind)
            .collect()
    }

    #[test]
    fn command_position_and_resolution_precedence() {
        let tokens = kinds(b"ll && build | echo unknown", false);
        assert_eq!(
            tokens,
            vec![
                TokenKind::Alias,
                TokenKind::Operator,
                TokenKind::Function,
                TokenKind::Operator,
                TokenKind::Builtin,
                TokenKind::Word,
            ]
        );
    }

    #[test]
    fn assignments_and_options_do_not_consume_command_position() {
        let tokens = kinds(b"A=1 sudo -u root echo --long", false);
        assert_eq!(
            tokens,
            vec![
                TokenKind::Assignment,
                TokenKind::Precommand,
                TokenKind::Option,
                TokenKind::Word,
                TokenKind::Builtin,
                TokenKind::Option,
            ]
        );
    }

    #[test]
    fn quote_escape_and_substitution_ranges_are_returned() {
        let snapshot = snapshot();
        let mut resolver = PathResolver::default();
        let mut context = LexContext::new(&snapshot, b".", false, &mut resolver);
        let tokens = analyze(
            b"echo 'one' \"two\" $'three\\n' $(printf x) ${HOME}",
            &mut context,
        );
        assert!(
            tokens
                .iter()
                .any(|token| token.kind == TokenKind::SingleQuote)
        );
        assert!(
            tokens
                .iter()
                .any(|token| token.kind == TokenKind::DoubleQuote)
        );
        assert!(
            tokens
                .iter()
                .any(|token| token.kind == TokenKind::DollarQuote)
        );
        assert!(tokens.iter().any(|token| token.kind == TokenKind::Escape));
        assert_eq!(
            tokens
                .iter()
                .filter(|token| token.kind == TokenKind::Substitution)
                .count(),
            2
        );
    }

    #[test]
    fn comments_are_conditional_and_stop_before_newline() {
        let off = kinds(b"echo # not-comment\necho", false);
        assert!(!off.contains(&TokenKind::Comment));
        let on = kinds(b"echo # comment\necho", true);
        assert!(on.contains(&TokenKind::Comment));
        assert_eq!(
            on.iter()
                .filter(|kind| **kind == TokenKind::Builtin)
                .count(),
            2
        );
    }

    #[test]
    fn lossy_offsets_count_invalid_maximal_subsequence_as_one_character() {
        let input = [b'a', 0xff, 0xfe, b'b'];
        let offsets = LossyOffsets::new(&input);
        assert_eq!(offsets.at(0), 0);
        assert_eq!(offsets.at(1), 1);
        assert_eq!(offsets.at(3), 3);
        assert_eq!(offsets.at(4), 4);
    }

    #[test]
    fn path_resolver_finds_executables_and_literal_paths() {
        let directory = tempdir().expect("tempdir");
        let bin = directory.path().join("bin");
        fs::create_dir(&bin).expect("bin");
        let command = bin.join("demo");
        let mut file = File::create(&command).expect("command");
        file.write_all(b"#!/bin/sh\n").expect("write");
        fs::set_permissions(&command, fs::Permissions::from_mode(0o755)).expect("mode");

        let path = bin.as_os_str().as_bytes().to_vec();
        let snapshot = NamespaceSnapshot { path, ..snapshot() };
        let cwd = directory.path().as_os_str().as_bytes();
        let input = b"demo ./bin/demo";
        let mut resolver = PathResolver::default();
        let mut context = LexContext::new(&snapshot, cwd, false, &mut resolver);
        let tokens = analyze(input, &mut context);
        assert_eq!(
            tokens
                .iter()
                .filter(|token| token.kind == TokenKind::Command)
                .count(),
            1
        );
        assert!(tokens.iter().any(|token| token.kind == TokenKind::Path));
    }

    #[test]
    fn path_cache_refreshes_when_directory_entries_change() {
        let directory = tempdir().expect("tempdir");
        let bin = directory.path().join("bin");
        fs::create_dir(&bin).expect("bin");
        let mut resolver = PathResolver::default();
        let cwd = directory.path().as_os_str().as_bytes();
        let path = bin.as_os_str().as_bytes();
        assert!(!resolver.command_exists(cwd, path, b"later"));
        let command = bin.join("later");
        File::create(&command).expect("command");
        fs::set_permissions(&command, fs::Permissions::from_mode(0o755)).expect("mode");
        assert!(resolver.command_exists(cwd, path, b"later"));
    }

    #[test]
    fn path_cache_rechecks_executable_bits_after_a_chmod_only_change() {
        let directory = tempdir().expect("tempdir");
        let bin = directory.path().join("bin");
        fs::create_dir(&bin).expect("bin");
        let command = bin.join("mode");
        File::create(&command).expect("command");
        fs::set_permissions(&command, fs::Permissions::from_mode(0o644)).expect("mode");

        let mut resolver = PathResolver::default();
        let cwd = directory.path().as_os_str().as_bytes();
        let path = bin.as_os_str().as_bytes();
        assert!(!resolver.command_exists(cwd, path, b"mode"));
        fs::set_permissions(&command, fs::Permissions::from_mode(0o755)).expect("mode");
        assert!(resolver.command_exists(cwd, path, b"mode"));
    }

    #[test]
    fn operator_and_redirect_tokens_are_distinct() {
        assert_eq!(
            kinds(b"echo hi >out && echo <in", false),
            vec![
                TokenKind::Builtin,
                TokenKind::Word,
                TokenKind::Redirect,
                TokenKind::Word,
                TokenKind::Operator,
                TokenKind::Builtin,
                TokenKind::Redirect,
                TokenKind::Word,
            ]
        );
        assert_eq!(
            kinds(b">out echo", false),
            vec![TokenKind::Redirect, TokenKind::Word, TokenKind::Builtin]
        );
    }

    #[test]
    fn no_path_stat_for_unresolved_expansion_or_glob() {
        let directory = tempdir().expect("tempdir");
        let path = directory.path().join("existing");
        File::create(&path).expect("path");
        let cwd = directory.path().as_os_str().as_bytes();
        let snapshot = NamespaceSnapshot::default();
        let mut resolver = PathResolver::default();
        let mut context = LexContext::new(&snapshot, cwd, false, &mut resolver);
        let tokens = analyze(b"./$name ./exist*", &mut context);
        assert!(!tokens.iter().any(|token| token.kind == TokenKind::Path));
    }

    #[test]
    fn quoted_glob_characters_remain_literal() {
        let directory = tempdir().expect("tempdir");
        let path = directory.path().join("*");
        File::create(&path).expect("path");
        let cwd = directory.path().as_os_str().as_bytes();
        let snapshot = NamespaceSnapshot::default();
        let mut resolver = PathResolver::default();
        let mut context = LexContext::new(&snapshot, cwd, false, &mut resolver);
        let tokens = analyze(b"\"./*\"", &mut context);
        assert!(tokens.iter().any(|token| token.kind == TokenKind::Path));
    }
}
