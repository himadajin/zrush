//! Real-pty plumbing for the host zsh: openpty plus a child that takes the
//! slave as its controlling terminal.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

/// Geometry the host terminal starts at, matching zpty's fixed 80x24. The
/// single-column grid fixture is sized against these 80 columns, so a test
/// that wants another width asks for it explicitly via [`Pty::resize`].
pub const COLS: libc::c_ushort = 80;
const ROWS: libc::c_ushort = 24;

const READ_CHUNK: usize = 8192;

pub struct Pty {
    master: OwnedFd,
}

impl Pty {
    /// Spawn `command` with a fresh pty as its stdin/stdout/stderr and
    /// controlling terminal.
    pub fn spawn(command: &mut Command) -> io::Result<(Self, Child)> {
        let mut master_fd: libc::c_int = -1;
        let mut slave_fd: libc::c_int = -1;
        // SAFETY: both out-parameters are written on success; the null
        // termios/winsize pointers leave the defaults in place.
        let rc = unsafe {
            libc::openpty(
                &mut master_fd,
                &mut slave_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: openpty returned two freshly opened, owned descriptors.
        let (master, slave) = unsafe {
            (
                OwnedFd::from_raw_fd(master_fd),
                OwnedFd::from_raw_fd(slave_fd),
            )
        };

        set_winsize(&master, COLS, ROWS)?;
        set_cloexec(&master)?;

        let stdin = slave.try_clone()?;
        let stdout = slave.try_clone()?;
        command
            .stdin(Stdio::from(stdin))
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(slave));
        // SAFETY: setsid and ioctl are async-signal-safe, and fd 0 is already
        // the pty slave by the time pre_exec closures run.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(io::Error::last_os_error());
                }
                if libc::ioctl(0, libc::TIOCSCTTY as _, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn()?;
        Ok((Self { master }, child))
    }

    /// Change the terminal geometry after spawn. The kernel raises SIGWINCH on
    /// the slave's foreground process group, which is how the host zsh learns
    /// to re-read `COLUMNS` -- what the tmux resize scenario used to provide.
    pub fn resize(&self, cols: libc::c_ushort, rows: libc::c_ushort) -> io::Result<()> {
        set_winsize(&self.master, cols, rows)
    }

    pub fn write_all(&self, bytes: &[u8]) -> io::Result<()> {
        let mut rest = bytes;
        while !rest.is_empty() {
            // SAFETY: the pointer/length pair comes from a live slice.
            let n =
                unsafe { libc::write(self.master.as_raw_fd(), rest.as_ptr().cast(), rest.len()) };
            if n < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(err);
            }
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "host pty accepted no bytes",
                ));
            }
            rest = &rest[n as usize..];
        }
        Ok(())
    }

    /// Wait up to `timeout` for host output and return whatever was readable.
    pub fn read_available(&self, timeout: Duration) -> Vec<u8> {
        match self.read_chunk(timeout) {
            Chunk::Data(bytes) => bytes,
            Chunk::Idle => Vec::new(),
            Chunk::Eof => {
                // A hung-up pty stays permanently ready; without this the
                // caller's deadline loop would spin at full speed.
                std::thread::sleep(Duration::from_millis(10));
                Vec::new()
            }
        }
    }

    /// One read attempt, keeping the host's own hang-up distinguishable from a
    /// quiet host: only the tests that let their shell exit for real care.
    pub fn read_chunk(&self, timeout: Duration) -> Chunk {
        let mut poll_fd = libc::pollfd {
            fd: self.master.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let ms = timeout.as_millis().min(i32::MAX as u128) as libc::c_int;
        // SAFETY: a single initialized pollfd is passed with a matching count.
        let ready = unsafe { libc::poll(&mut poll_fd, 1, ms) };
        if ready <= 0 {
            return Chunk::Idle;
        }
        let mut buf = [0u8; READ_CHUNK];
        // SAFETY: reads at most buf.len() bytes into an owned buffer.
        let n = unsafe { libc::read(self.master.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
        if n > 0 {
            return Chunk::Data(buf[..n as usize].to_vec());
        }
        // A master whose last slave is gone reads as 0 on macOS and as EIO on
        // Linux. Nothing else may be reported as `Eof`: that is the passing
        // signal of the tests that let their host exit, so a descriptor bug
        // here has to fail loudly instead of reading as a clean exit.
        if n == 0 {
            return Chunk::Eof;
        }
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            return Chunk::Idle;
        }
        if error.raw_os_error() == Some(libc::EIO) {
            return Chunk::Eof;
        }
        panic!("read from the host pty failed: {error}");
    }
}

/// The outcome of one [`Pty::read_chunk`].
pub enum Chunk {
    Data(Vec<u8>),
    /// Nothing readable within the timeout.
    Idle,
    /// The child closed the slave end: no further output can arrive.
    Eof,
}

fn set_winsize(master: &OwnedFd, cols: libc::c_ushort, rows: libc::c_ushort) -> io::Result<()> {
    let size = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: TIOCSWINSZ reads one winsize through the pointer.
    if unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCSWINSZ, &size) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn set_cloexec(fd: &OwnedFd) -> io::Result<()> {
    // SAFETY: fcntl on a live descriptor with a flag-setting command.
    if unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
