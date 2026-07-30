//! zrush CLI entry point.
//!
//! Subcommands per docs/internal/contracts/cli-protocol.md (source of truth):
//! - `zrush plan` builds a full render plan (layout, highlights,
//!   navigation, insertion texts) for a captured candidate stream + query.
//! - `zrush config` emits zsh-sourceable settings.
//!
//! Argument parsing is hand-written on purpose: zrush is spawned per
//! keystroke, so we keep dependencies (and startup work) minimal.
//! The query is taken as raw bytes (std::os::unix — zrush targets
//! macOS + Linux only): user input mid-composition need not be UTF-8.

mod config;
mod insert;
mod keybind;
mod layout;
mod matching;
mod plan;
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
        Some("plan") => cmd_plan(&args[1..]),
        Some("config") => cmd_config(&args[1..]),
        _ => usage(),
    }
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: zrush plan --query <q> --mode <prefix|substring|typo> \
         --smart-case <true|false> --rows <N> --width <N> \
         --trailing-space <true|false>\n       zrush config"
    );
    ExitCode::from(EXIT_USAGE)
}

/// Per cli-protocol.md "zrush plan". Invalid/missing/unknown arguments
/// exit 2; a framing-broken stdin stream exits 3; stdin/stdout I/O
/// failure exits 1.
fn cmd_plan(args: &[OsString]) -> ExitCode {
    let mut query: Option<Vec<u8>> = None;
    let mut mode: Option<Mode> = None;
    let mut smart_case: Option<bool> = None;
    let mut rows: Option<usize> = None;
    let mut width: Option<usize> = None;
    let mut trailing_space: Option<bool> = None;

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
            // 0 is rejected: cli-protocol.md guarantees zsh clamps both
            // to >= 1 before invoking; a 0 here indicates misuse, not a
            // legitimate degenerate budget (layout.rs still handles 0
            // gracefully as defense in depth, but the CLI contract treats
            // it as a usage error).
            b"--rows" => match value.to_str().and_then(|s| s.parse::<usize>().ok()) {
                Some(n) if n > 0 => rows = Some(n),
                _ => return usage(),
            },
            b"--width" => match value.to_str().and_then(|s| s.parse::<usize>().ok()) {
                Some(n) if n > 0 => width = Some(n),
                _ => return usage(),
            },
            b"--trailing-space" => match value.to_str() {
                Some("true") => trailing_space = Some(true),
                Some("false") => trailing_space = Some(false),
                _ => return usage(),
            },
            _ => return usage(),
        }
    }
    let (Some(query), Some(mode), Some(smart_case), Some(rows), Some(width), Some(trailing_space)) =
        (query, mode, smart_case, rows, width, trailing_space)
    else {
        return usage();
    };

    let mut data = Vec::new();
    if std::io::stdin().read_to_end(&mut data).is_err() {
        return ExitCode::from(EXIT_INTERNAL);
    }

    let params = plan::Params {
        query,
        mode,
        smart_case,
        rows,
        width,
        trailing_space,
    };
    let out = match plan::run(&params, &data, &real_is_dir) {
        Ok(out) => out,
        Err(plan::Error::Framing) => return ExitCode::from(EXIT_PROTOCOL),
    };
    if std::io::stdout().write_all(&out).is_err() {
        return ExitCode::from(EXIT_INTERNAL);
    }
    ExitCode::SUCCESS
}

/// `-f` directory-synthesis stat (cli-protocol.md "挿入テキスト"):
/// resolved against the process's current directory, following symlinks
/// (`fs::metadata`, not `symlink_metadata`). Stat failure or a non-
/// directory target both read as "not a directory".
fn real_is_dir(path: &[u8]) -> bool {
    let os = std::ffi::OsStr::from_bytes(path);
    std::fs::metadata(os).map(|m| m.is_dir()).unwrap_or(false)
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
