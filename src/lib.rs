//! zrush CLI entry point.
//!
//! Subcommands per docs/internal/contracts/cli-protocol.md (source of truth):
//! - `zrush plan` builds a full render plan (layout, highlights,
//!   navigation, insertion texts) for a captured candidate stream + query.
//! - `zrush config` emits zsh-sourceable settings.
//!
//! Argument parsing uses clap's derive API: zrush is spawned per keystroke,
//! but the parse cost is noise relative to the ~2ms process spawn itself,
//! so declarative, robustly-validated parsing wins over hand-rolling it
//! (see Cargo.toml for the measured tradeoff).
//! The query is still taken as raw bytes (std::os::unix — zrush targets
//! macOS + Linux only): user input mid-composition need not be UTF-8.
//!
//! The library surface is intentionally limited to [`run`] and [`wire`].

mod config;
mod insert;
mod keybind;
mod layout;
mod matching;
mod plan;
mod ranking;
mod record;

pub mod wire;

use std::ffi::OsString;
use std::io::{Read, Write};
use std::num::NonZeroUsize;
use std::os::unix::ffi::OsStrExt;
use std::process::ExitCode;

use clap::{Parser, Subcommand, ValueEnum};

use matching::Mode;

/// Exit codes per cli-protocol.md. Usage errors (invalid/missing/unknown
/// arguments or subcommand) are exit 2, handled by clap's default error
/// path (`Cli::parse()` calls `std::process::exit(2)` on a parse failure,
/// and exit 0 on `--help`/`help`, matching the contract's "human-facing
/// affordance" note in the 終了コード section).
const EXIT_INTERNAL: u8 = 1;
const EXIT_PROTOCOL: u8 = 3;

/// zrush: live completion candidates for zsh, computed per keystroke.
#[derive(Parser)]
#[command(name = "zrush")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Build a render plan for a captured candidate stream + query (cli-protocol.md "zrush plan").
    Plan(PlanArgs),
    /// Emit zsh-sourceable settings (cli-protocol.md "zrush config").
    Config,
}

/// Flags for `zrush plan` (cli-protocol.md "zrush plan" > "起動").
#[derive(clap::Args)]
struct PlanArgs {
    /// As-typed query fragment, raw bytes (not necessarily UTF-8).
    #[arg(long)]
    query: OsString,
    /// Matching mode (cli-protocol.md "マッチング・ランキングの意味論").
    #[arg(long, value_enum)]
    mode: CliMode,
    /// Case sensitivity for matching (true/false only).
    // clap derive turns a bare `bool` field into a value-less SetTrue
    // flag; `Set` makes it take an explicit value. `bool`'s FromStr
    // accepts exactly `true`/`false`, so `yes`/`1`/etc are rejected as
    // the contract requires.
    #[arg(long, action = clap::ArgAction::Set)]
    smart_case: bool,
    /// Display row budget (>= 1).
    // cli-protocol.md guarantees zsh clamps this to >= 1 before
    // invoking; a 0 here indicates misuse, not a legitimate degenerate
    // budget (layout.rs still handles 0 gracefully as defense in depth,
    // but the CLI contract treats it as a usage error). NonZeroUsize
    // enforces the >= 1 contract by type.
    #[arg(long)]
    rows: NonZeroUsize,
    /// Usable column budget (>= 1).
    // Same >= 1 contract and rationale as `rows`.
    #[arg(long)]
    width: NonZeroUsize,
    /// Append trailing space to insertion text (true/false only).
    // See `smart_case` for why this takes an explicit true/false value.
    #[arg(long, action = clap::ArgAction::Set)]
    trailing_space: bool,
}

/// CLI-side mirror of `matching::Mode` (cli-protocol.md "起動"). Kept out
/// of matching.rs deliberately: pure logic modules stay free of CLI
/// dependencies (AGENTS.md responsibility split).
#[derive(Copy, Clone, ValueEnum)]
enum CliMode {
    Prefix,
    Substring,
    Typo,
}

impl From<CliMode> for Mode {
    fn from(mode: CliMode) -> Mode {
        match mode {
            CliMode::Prefix => Mode::Prefix,
            CliMode::Substring => Mode::Substring,
            CliMode::Typo => Mode::Typo,
        }
    }
}

/// Run the command-line interface and return its process exit code.
pub fn run() -> ExitCode {
    match Cli::parse().command {
        Command::Plan(args) => cmd_plan(args),
        Command::Config => cmd_config(),
    }
}

/// Per cli-protocol.md "zrush plan". Invalid/missing/unknown arguments
/// exit 2 (via `Cli::parse()`); a framing-broken stdin stream exits 3;
/// stdin/stdout I/O failure exits 1.
fn cmd_plan(args: PlanArgs) -> ExitCode {
    let mut data = Vec::new();
    if std::io::stdin().read_to_end(&mut data).is_err() {
        return ExitCode::from(EXIT_INTERNAL);
    }

    let params = plan::Params {
        query: args.query.as_bytes().to_vec(),
        mode: args.mode.into(),
        smart_case: args.smart_case,
        rows: args.rows.get(),
        width: args.width.get(),
        trailing_space: args.trailing_space,
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
fn cmd_config() -> ExitCode {
    let result = config::load();
    let out = config::to_zsh(&result);
    if std::io::stdout().write_all(out.as_bytes()).is_err() {
        return ExitCode::from(EXIT_INTERNAL);
    }
    ExitCode::SUCCESS
}
