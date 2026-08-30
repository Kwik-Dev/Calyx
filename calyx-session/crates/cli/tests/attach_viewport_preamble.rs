//! Pins the contract that `attach`'s very first stdout bytes are the
//! client's own viewport-clear preamble (written before it even
//! connects to the daemon, to hide anything the pane printed before
//! the client started, e.g. `login(1)`'s "Last login: ..."), without
//! touching scrollback, so a failed attach in an interactive terminal
//! keeps the user's history; and that the daemon's `Replay` frame
//! payload (which begins with `proto::BLANK_SLATE`, resetting the
//! terminal and erasing scrollback to commit the takeover) follows
//! immediately after it.

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

mod common;
use common::{bin, wait_for_socket, ChildGuard};

fn spawn_foreground_daemon(runtime_dir: &Path, state_dir: &Path) -> ChildGuard {
    let child = Command::new(bin())
        .args([
            "--runtime-dir".as_ref(),
            runtime_dir.as_os_str(),
            "--state-dir".as_ref(),
            state_dir.as_os_str(),
            "daemon".as_ref(),
            "--foreground".as_ref(),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn `calyx-session daemon --foreground`");
    let guard = ChildGuard(child);

    let socket_path = runtime_dir.join("sessiond.sock");
    assert!(
        wait_for_socket(&socket_path, Duration::from_secs(5)),
        "daemon --foreground should create {} within 5s",
        socket_path.display()
    );
    guard
}

/// Mirrors the client preamble constant in `crates/cli/src/commands/attach.rs`; integration tests cannot import from a bin crate.
const VIEWPORT_CLEAR: &[u8] = b"\x1b[H\x1b[2J";

#[test]
fn attach_writes_its_own_viewport_clear_preamble_before_the_daemons_replay() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let cwd_dir = tempdir.path().join("cwd");
    std::fs::create_dir_all(&cwd_dir).expect("create scratch cwd dir");
    let _guard = spawn_foreground_daemon(&runtime_dir, &state_dir);

    let attach_result = Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args([
            "attach",
            "01J-p2-cli-attach-viewport-preamble",
            "--create",
            "--cwd",
            cwd_dir.to_str().unwrap(),
            "--argv",
            "/bin/sh",
            "--argv",
            "-c",
            "--argv",
            "sleep 1",
        ])
        // Isolates this test from the ambient environment `cargo test`
        // happens to run under; see smoke.rs's identical use on the
        // exit-code attach test.
        .env_remove("GHOSTTY_RESOURCES_DIR")
        .stdin(Stdio::null())
        .output()
        .expect("run `calyx-session attach`");

    assert_eq!(
        attach_result.status.code(),
        Some(0),
        "attach should exit 0, got {attach_result:?}"
    );

    let stdout = attach_result.stdout;
    let m = VIEWPORT_CLEAR.len();
    let n = proto::BLANK_SLATE.len();
    assert!(
        stdout.len() >= m + n,
        "attach's stdout should contain the client's own viewport-clear \
         preamble followed by the daemon's Replay payload, got {} bytes: \
         {:?}",
        stdout.len(),
        stdout
    );

    assert_eq!(
        &stdout[..m],
        VIEWPORT_CLEAR,
        "attach's very first stdout bytes should be its own \
         viewport-clear preamble, written before it connects to the \
         daemon; first {} bytes were {:?}",
        m + n,
        &stdout[..m + n]
    );
    assert_eq!(
        &stdout[m..m + n],
        proto::BLANK_SLATE,
        "the daemon's Replay frame payload (which itself begins with the \
         blank-slate sequence) should immediately follow the client's own \
         preamble; first {} bytes were {:?}",
        m + n,
        &stdout[..m + n]
    );
}
