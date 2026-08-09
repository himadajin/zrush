//! zrush CLI entry point.
//!
//! Subcommands per docs/internal/contracts/cli-protocol.md (source of truth):
//! - `zrush worker` persistently builds render plans for session requests.
//! - `zrush config` emits zsh-sourceable settings.
//! - `zrush init zsh` emits the embedded zle-integration script.
//!
//! Argument parsing uses clap's derive API. Session requests remain raw bytes:
//! user input mid-composition and filesystem paths need not be UTF-8.
//!
//! The library surface is intentionally limited to [`run`] and [`wire`].

mod config;
mod framing;
mod init;
mod insert;
mod keybind;
mod layout;
mod matching;
mod plan;
mod ranking;
mod record;
mod span;
mod worker;

pub mod wire;

use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::io::RawFd;
use std::process::ExitCode;

use clap::{Parser, Subcommand, ValueEnum};

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
    Worker {
        /// Read end of the worker abort control channel.
        #[arg(long, value_parser = parse_control_fd)]
        control_fd: RawFd,
    },
    /// Emit zsh-sourceable settings (cli-protocol.md "zrush config").
    Config,
    /// Emit the zsh integration script for `.zshrc` to source
    /// (cli-protocol.md "zrush init"): `source <(zrush init zsh)`.
    Init {
        /// Shell to emit an integration script for. Only `zsh` is supported.
        shell: Shell,
    },
}

fn parse_control_fd(value: &str) -> Result<RawFd, String> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("control fd must be an unsigned decimal integer".into());
    }
    let fd = value
        .parse::<RawFd>()
        .map_err(|_| "control fd is out of range".to_string())?;
    if fd <= libc::STDERR_FILENO {
        return Err("control fd must be greater than 2".into());
    }
    Ok(fd)
}

#[derive(Clone, Copy, ValueEnum)]
enum Shell {
    Zsh,
}

/// Run the command-line interface and return its process exit code.
pub fn run() -> ExitCode {
    match Cli::parse().command {
        Command::Worker { control_fd } => cmd_worker(control_fd),
        Command::Config => cmd_config(),
        Command::Init { shell: Shell::Zsh } => cmd_init_zsh(),
    }
}

fn cmd_worker(control_fd: RawFd) -> ExitCode {
    if let Err(error) = worker::start_watchdog(control_fd) {
        let _ = writeln!(std::io::stderr().lock(), "zrush worker: {error}");
        return ExitCode::from(EXIT_INTERNAL);
    }

    match worker::run(std::io::stdin().lock(), std::io::stdout().lock()) {
        Ok(worker::End::Eof | worker::End::Incompatible) => ExitCode::SUCCESS,
        Err(error) => {
            let _ = writeln!(std::io::stderr().lock(), "zrush worker: {error}");
            ExitCode::from(EXIT_INTERNAL)
        }
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

/// Per cli-protocol.md "zrush init": the `ZRUSH_BIN` prelude defaults to
/// this process's own path, so failing to resolve it is an internal error
/// like `cmd_config`'s stdout-write failure.
fn cmd_init_zsh() -> ExitCode {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return ExitCode::from(EXIT_INTERNAL),
    };
    let out = init::zsh_output(exe.as_os_str().as_bytes());
    if std::io::stdout().write_all(&out).is_err() {
        return ExitCode::from(EXIT_INTERNAL);
    }
    ExitCode::SUCCESS
}
