//! zrush CLI entry point.
//!
//! Subcommands per docs/internal/contracts/cli-protocol.md (source of truth):
//! - `zrush worker` persistently builds render plans for session requests.
//! - `zrush config` emits zsh-sourceable settings.
//!
//! Argument parsing uses clap's derive API. Session requests remain raw bytes:
//! user input mid-composition and filesystem paths need not be UTF-8.
//!
//! The library surface is intentionally limited to [`run`] and [`wire`].

mod config;
mod framing;
mod insert;
mod keybind;
mod layout;
mod matching;
mod plan;
mod ranking;
mod record;
mod worker;

pub mod wire;

use std::io::Write;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

/// Exit codes per cli-protocol.md. Usage errors (invalid/missing/unknown
/// arguments or subcommand) are exit 2, handled by clap's default error
/// path (`Cli::parse()` calls `std::process::exit(2)` on a parse failure,
/// and exit 0 on `--help`/`help`, matching the contract's "human-facing
/// affordance" note in the 終了コード section).
const EXIT_INTERNAL: u8 = 1;

/// zrush: live completion candidates for zsh, computed per keystroke.
#[derive(Parser)]
#[command(name = "zrush")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Serve render-plan requests over a persistent byte-stream session.
    Worker,
    /// Emit zsh-sourceable settings (cli-protocol.md "zrush config").
    Config,
}

/// Run the command-line interface and return its process exit code.
pub fn run() -> ExitCode {
    match Cli::parse().command {
        Command::Worker => cmd_worker(),
        Command::Config => cmd_config(),
    }
}

fn cmd_worker() -> ExitCode {
    match worker::run(std::io::stdin().lock(), std::io::stdout().lock()) {
        Ok(worker::End::Eof | worker::End::Incompatible) => ExitCode::SUCCESS,
        Err(_) => ExitCode::from(EXIT_INTERNAL),
    }
}

/// Per cli-protocol.md "zrush config", including config-error fallback.
fn cmd_config() -> ExitCode {
    let result = config::load();
    let out = config::to_zsh(&result);
    if std::io::stdout().write_all(out.as_bytes()).is_err() {
        return ExitCode::from(EXIT_INTERNAL);
    }
    ExitCode::SUCCESS
}
