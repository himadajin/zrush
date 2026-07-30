//! zrush CLI entry point.
//!
//! Subcommands per docs/internal/contracts/cli-protocol.md (source of truth):
//! - `zrush match` ranks candidates for a query.
//! - `zrush config` emits zsh-sourceable settings.
//!
//! Argument parsing is hand-written on purpose: zrush is spawned per
//! keystroke, so we keep dependencies (and startup work) minimal.
//! The query is taken as raw bytes (std::os::unix — zrush targets
//! macOS + Linux only): user input mid-composition need not be UTF-8.

mod config;
mod keybind;
mod layout;
mod matching;
mod ranking;
mod record;

use std::ffi::OsString;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::process::ExitCode;

use matching::Mode;

/// Exit codes per cli-protocol.md.
const EXIT_INTERNAL: u8 = 1;
const EXIT_USAGE: u8 = 2;
const EXIT_PROTOCOL: u8 = 3;

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    match args.first().and_then(|a| a.to_str()) {
        Some("match") => cmd_match(&args[1..]),
        Some("config") => cmd_config(&args[1..]),
        _ => usage(),
    }
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: zrush match --query <q> --mode <prefix|substring|typo> \
         --smart-case <true|false> --max-lines <N>\n       zrush config"
    );
    ExitCode::from(EXIT_USAGE)
}

/// Per cli-protocol.md "zrush match".
/// Invalid arguments exit 2; malformed input exits 3.
fn cmd_match(args: &[OsString]) -> ExitCode {
    let mut query: Option<Vec<u8>> = None;
    let mut mode: Option<Mode> = None;
    let mut smart_case: Option<bool> = None;
    let mut max_lines: Option<usize> = None;

    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let Some(value) = it.next() else {
            return usage();
        };
        match flag.as_bytes() {
            b"--query" => query = Some(value.as_bytes().to_vec()),
            b"--mode" => match value.to_str().and_then(Mode::parse) {
                Some(m) => mode = Some(m),
                None => return usage(),
            },
            b"--smart-case" => match value.to_str() {
                Some("true") => smart_case = Some(true),
                Some("false") => smart_case = Some(false),
                _ => return usage(),
            },
            b"--max-lines" => match value.to_str().and_then(|s| s.parse::<usize>().ok()) {
                Some(n) => max_lines = Some(n),
                None => return usage(),
            },
            _ => return usage(),
        }
    }
    let (Some(query), Some(mode), Some(smart_case), Some(max_lines)) =
        (query, mode, smart_case, max_lines)
    else {
        return usage();
    };

    let mut data = Vec::new();
    if std::io::stdin().read_to_end(&mut data).is_err() {
        return ExitCode::from(EXIT_INTERNAL);
    }

    // Fields are NUL-terminated: a non-empty stream must end with NUL,
    // and stripping it yields exactly the field list.
    let fields: Vec<&[u8]> = match data.last() {
        None => Vec::new(),
        Some(0) => data[..data.len() - 1].split(|&b| b == 0).collect(),
        Some(_) => return ExitCode::from(EXIT_PROTOCOL),
    };
    if !fields.len().is_multiple_of(3) {
        return ExitCode::from(EXIT_PROTOCOL);
    }

    let mut candidates: Vec<(&[u8], &[u8])> = Vec::with_capacity(fields.len() / 3);
    for record in fields.chunks_exact(3) {
        let index = record[0];
        if index.is_empty() || !index.iter().all(u8::is_ascii_digit) {
            return ExitCode::from(EXIT_PROTOCOL);
        }
        candidates.push((index, record[1]));
    }

    let mut qm = matching::QueryMatcher::new(&query, mode, smart_case);
    let mut scored = Vec::new();
    let mut prefix_texts: Vec<&[u8]> = Vec::new();
    for (pos, (_, text)) in candidates.iter().enumerate() {
        if let Some(ms) = qm.score(text) {
            scored.push((pos, ms));
            // Prefix-tier only, pre-truncation (cli-protocol.md).
            if ms.tier == matching::Tier::Prefix {
                prefix_texts.push(text);
            }
        }
    }

    let lcp = matching::common_prefix(prefix_texts.into_iter());
    let order = ranking::rank(&scored, max_lines);

    let mut out = Vec::with_capacity(lcp.len() + 1 + order.len() * 16);
    out.extend_from_slice(lcp);
    out.push(0);
    for pos in order {
        out.extend_from_slice(candidates[pos].0);
        out.push(0);
        // Spans are extracted only for the emitted (top max-lines)
        // candidates — a cheap second pass per candidate.
        for (i, (s, e)) in qm.spans(candidates[pos].1).into_iter().enumerate() {
            if i > 0 {
                out.push(b',');
            }
            let _ = write!(out, "{s}-{e}");
        }
        out.push(0);
    }
    if std::io::stdout().write_all(&out).is_err() {
        return ExitCode::from(EXIT_INTERNAL);
    }
    ExitCode::SUCCESS
}

/// Per cli-protocol.md "zrush config", including config-error fallback.
fn cmd_config(args: &[OsString]) -> ExitCode {
    if !args.is_empty() {
        return usage();
    }
    let result = config::load();
    let out = config::to_zsh(&result);
    if std::io::stdout().write_all(out.as_bytes()).is_err() {
        return ExitCode::from(EXIT_INTERNAL);
    }
    ExitCode::SUCCESS
}
