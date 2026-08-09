//! `zrush init zsh` (cli-protocol.md "zrush init").
//!
//! Emits `ZRUSH_BIN` and build-stamp prelude lines followed by the zle-integration script,
//! embedded into the binary at build time (`.zshrc` sources this command's
//! output: `source <(zrush init zsh)`).

/// The zle-integration script, embedded at build time.
const ZRUSH_ZSH: &str = include_str!("../zsh/zrush.zsh");

/// Single-quote a byte string for zsh source output (cli-protocol.md
/// quoting discipline, same as `config::sq`): wrap in `'...'` and escape
/// embedded `'` as `'\''`. Byte-level (rather than `str`-based like
/// `config::sq`) because a binary path need not be valid UTF-8.
fn sq_bytes(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len() + 2);
    out.push(b'\'');
    for &b in s {
        if b == b'\'' {
            out.extend_from_slice(b"'\\''");
        } else {
            out.push(b);
        }
    }
    out.push(b'\'');
    out
}

/// Build the full `zrush init zsh` stdout: the `ZRUSH_BIN` prelude line
/// (default = `bin_path`, overridable by an already-set `$ZRUSH_BIN`)
/// and the non-overridable build-stamp prelude followed by the embedded script.
pub fn zsh_output(bin_path: &[u8]) -> Vec<u8> {
    let mut out = b"typeset -g ZRUSH_BIN=${ZRUSH_BIN:-".to_vec();
    out.extend(sq_bytes(bin_path));
    out.extend_from_slice(b"}\n");
    out.extend_from_slice(b"typeset -g _ZRUSH_EXPECTED_BUILD_STAMP='");
    out.extend_from_slice(crate::wire::BUILD_STAMP.as_bytes());
    out.extend_from_slice(b"'\n");
    out.extend_from_slice(ZRUSH_ZSH.as_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prelude_quotes_plain_path() {
        let out = zsh_output(b"/opt/zrush/target/release/zrush");
        let prelude = out.split(|&b| b == b'\n').next().unwrap();
        assert_eq!(
            prelude,
            b"typeset -g ZRUSH_BIN=${ZRUSH_BIN:-'/opt/zrush/target/release/zrush'}"
        );
    }

    #[test]
    fn prelude_escapes_embedded_single_quote() {
        let out = zsh_output(b"/opt/it's/zrush");
        let prelude = out.split(|&b| b == b'\n').next().unwrap();
        assert_eq!(
            prelude,
            b"typeset -g ZRUSH_BIN=${ZRUSH_BIN:-'/opt/it'\\''s/zrush'}"
        );
    }

    #[test]
    fn output_embeds_the_zsh_script_verbatim_after_the_prelude() {
        let out = zsh_output(b"/bin/zrush");
        let mut lines = out.splitn(3, |&b| b == b'\n');
        lines.next().unwrap();
        assert_eq!(
            lines.next().unwrap(),
            format!(
                "typeset -g _ZRUSH_EXPECTED_BUILD_STAMP='{}'",
                crate::wire::BUILD_STAMP
            )
            .as_bytes()
        );
        assert_eq!(lines.next().unwrap(), ZRUSH_ZSH.as_bytes());
    }
}
