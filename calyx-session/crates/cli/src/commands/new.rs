use std::path::PathBuf;

use proto::{ControlMsg, SessionSpec};

use crate::cli::NewArgs;
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::terminal_env::resolve_terminal_env;
use crate::commands::{socket_path, CommandError};

/// Creates a new session (via `ControlMsg::New`) without attaching to
/// it, printing the resulting session id. No daemon auto-start: only
/// `attach` does that.
pub fn run(runtime_dir: &Option<PathBuf>, args: NewArgs) -> Result<u8, CommandError> {
    let client = DaemonClient::connect(&socket_path(runtime_dir))?;
    let (cols, rows) = crate::commands::attach::tty_size().unwrap_or((80, 24));
    let spec = build_spec(args, cols, rows, |k| std::env::var(k).ok());
    match client.request(&ControlMsg::New { spec })? {
        ControlMsg::NewOk { info } => {
            println!("{}", info.id);
            Ok(0)
        }
        ControlMsg::Err { code, msg } => Err(server_err(code, msg)),
        other => Err(unexpected(&other)),
    }
}

/// Builds the `SessionSpec` for a `new`-created session. `lookup` is
/// injected so the terminal-env wiring below is testable as a pure
/// function without mutating real process-wide environment variables
/// (the same seam `resolve_terminal_env` itself uses).
fn build_spec(
    args: NewArgs,
    cols: u16,
    rows: u16,
    lookup: impl Fn(&str) -> Option<String>,
) -> SessionSpec {
    SessionSpec {
        id: ulid::Ulid::new().to_string(),
        name: args.name,
        cwd: args.cwd,
        argv: (!args.argv.is_empty()).then_some(args.argv),
        // `resolve_terminal_env` re-supplies `TERM`/`TERMINFO`/`LANG`/
        // `PATH`/etc, which a launchd-owned daemon's job environment
        // doesn't provide (see `terminal_env`'s module doc); without
        // it, a session created via `new` under that daemon loses
        // `TERM` outright. Unlike attach.rs, no
        // resolve_shell_integration_env here: no production caller
        // synthesizes sessions via `new`, so wiring the ghostty
        // shell-integration env in is deferred.
        env: resolve_terminal_env(lookup),
        cols,
        rows,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `new`'s `SessionSpec.env` must carry the terminal/locale
    /// environment `resolve_terminal_env` produces, not an empty vec:
    /// without this, a session created via `new` under a launchd-owned
    /// daemon loses `TERM` (see `terminal_env`'s module doc).
    #[test]
    fn spec_env_carries_the_resolved_terminal_env() {
        let args = NewArgs {
            cwd: None,
            name: None,
            argv: vec![],
        };
        let spec = build_spec(args, 80, 24, |key| {
            (key == "TERM").then(|| "xterm-ghostty".to_string())
        });
        assert_eq!(
            spec.env,
            vec![("TERM".to_string(), "xterm-ghostty".to_string())]
        );
    }

    /// When nothing is present in the lookup, `spec.env` must be empty
    /// rather than panicking or fabricating a default.
    #[test]
    fn spec_env_is_empty_when_nothing_is_present() {
        let args = NewArgs {
            cwd: None,
            name: None,
            argv: vec![],
        };
        let spec = build_spec(args, 80, 24, |_key| None);
        assert_eq!(spec.env, Vec::<(String, String)>::new());
    }
}
