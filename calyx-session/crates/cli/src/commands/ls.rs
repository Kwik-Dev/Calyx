use std::path::PathBuf;

use proto::{ControlMsg, SessionState};

use crate::cli::LsArgs;
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::{socket_path, CommandError};

/// Lists sessions (via `ControlMsg::List`, or `ControlMsg::ListAll`
/// with `--all` to include exited sessions from the ledger), printed
/// as JSON with `--json` or as a human-readable table otherwise.
pub fn run(runtime_dir: &Option<PathBuf>, args: LsArgs) -> Result<u8, CommandError> {
    let client = DaemonClient::connect(&socket_path(runtime_dir))?;
    let sessions = if args.all {
        match client.request(&ControlMsg::ListAll)? {
            ControlMsg::ListAllOk { sessions } => sessions,
            ControlMsg::Err { code, msg } => return Err(server_err(code, msg)),
            other => return Err(unexpected(&other)),
        }
    } else {
        match client.request(&ControlMsg::List)? {
            ControlMsg::ListOk { sessions } => sessions,
            ControlMsg::Err { code, msg } => return Err(server_err(code, msg)),
            other => return Err(unexpected(&other)),
        }
    };

    if args.json {
        let json = serde_json::to_string(&sessions)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        println!("{json}");
        return Ok(0);
    }

    for info in &sessions {
        let state = match info.state {
            SessionState::Running => "running".to_string(),
            // For a default macOS session the reaped child is
            // `login(1)`, whose parent always exits 0 after the shell
            // ends: this code is 0 regardless of the shell's own exit
            // status unless a signal kills `login` itself (137 after
            // `Kill`). The daemon starts `login(1)` only when it can
            // resolve its own passwd entry; in the degraded state where
            // that lookup fails it starts `$SHELL` directly, and this
            // code is then the shell's real exit status. Explicit-argv
            // sessions and other platforms show the child's real exit
            // status.
            SessionState::Exited { code } => format!("exited({code})"),
        };
        println!(
            "{}\t{}\tpid={}\tclients={}\t{}",
            info.id,
            state,
            info.pid,
            info.attached_clients,
            info.name.as_deref().unwrap_or("-"),
        );
    }
    Ok(0)
}
