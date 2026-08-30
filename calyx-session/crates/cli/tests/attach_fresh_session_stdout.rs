//! Pins that a fresh `attach` writes nothing to stdout until the
//! session itself produces output. The attach client writes nothing to
//! stdout before the daemon's own frames, and a session whose mirror
//! terminal has never been fed a byte sends an empty Replay, so for a
//! session whose command prints nothing, stdout stays exactly 0 bytes
//! for the whole run.

use std::process::{Command, Stdio};

mod common;
use common::{bin, spawn_foreground_daemon};

#[test]
fn attach_to_a_fresh_session_writes_nothing_to_stdout_before_the_sessions_first_output() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let cwd_dir = tempdir.path().join("cwd");
    std::fs::create_dir_all(&cwd_dir).expect("create scratch cwd dir");
    let _guard = spawn_foreground_daemon(
        &runtime_dir,
        &state_dir,
        |cmd| {
            cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        },
        String::new,
    );

    let attach_result = Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args([
            "attach",
            "01J-p2-cli-attach-fresh-session-stdout",
            "--create",
            "--cwd",
            cwd_dir.to_str().unwrap(),
            "--argv",
            "/bin/sleep",
            "--argv",
            "1",
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

    assert!(
        attach_result.stdout.is_empty(),
        "attach's stdout should be empty for a session whose command \
         produces no output, got {} bytes: {:?}; stderr: {}",
        attach_result.stdout.len(),
        attach_result.stdout,
        String::from_utf8_lossy(&attach_result.stderr)
    );
}
