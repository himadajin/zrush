//! zrush CLI entry point.
//!
//! Subcommands (see docs/internal/contracts/cli-protocol.md — the contract is
//! the source of truth; this code follows it):
//! - `zrush match`  — read candidates from stdin, rank against a fuzzy query.
//! - `zrush config` — resolve config.toml, emit zsh-sourceable settings.
//!
//! Argument parsing is hand-written on purpose: zrush is spawned per
//! keystroke, so we keep dependencies (and startup work) minimal.

mod config;
mod keybind;
mod matching;
mod ranking;

use std::process::ExitCode;

/// Exit codes per cli-protocol.md.
const EXIT_USAGE: u8 = 2;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("match") => cmd_match(&args[1..]),
        Some("config") => cmd_config(&args[1..]),
        _ => {
            eprintln!("usage: zrush <match|config> [options]");
            ExitCode::from(EXIT_USAGE)
        }
    }
}

/// `zrush match --query <q> --mode <m> --smart-case <b> --max-lines <n>`
///
/// TODO(M2): parse the four required options, read NUL-terminated
/// 3-field candidate records from stdin, run matching + ranking, and
/// write NUL-terminated indices of the top max-lines candidates.
fn cmd_match(_args: &[String]) -> ExitCode {
    eprintln!("zrush match: not implemented yet");
    ExitCode::from(EXIT_USAGE)
}

/// `zrush config`
///
/// TODO(M2): resolve $XDG_CONFIG_HOME/zrush/config.toml (fallback
/// ~/.config/zrush/config.toml), validate per config-schema.md with
/// per-key default fallback, and print zsh-sourceable typeset output
/// including ZRUSH_PROTOCOL_VERSION and ZRUSH_CFG_WARNINGS.
fn cmd_config(_args: &[String]) -> ExitCode {
    eprintln!("zrush config: not implemented yet");
    ExitCode::from(EXIT_USAGE)
}
