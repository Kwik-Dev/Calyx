//! Execution-based end-to-end test for the ghostty shell-integration
//! fix (see `crates/cli/src/commands/shell_integration.rs`'s module
//! doc for the full bug writeup): with `GHOSTTY_RESOURCES_DIR` present
//! in the attach client's own environment -- exactly what a real
//! ghostty tab sets, unconditionally, before spawning any command
//! (`ghostty/src/termio/Exec.zig`'s `Subprocess.init`) -- a session
//! created via `calyx-session attach --create` running an interactive
//! zsh should now emit ghostty's OSC 7 `kitty-shell-cwd` escape
//! sequence once the shell reaches its first prompt, via the REAL
//! bundled `shell-integration/zsh/{.zshenv,ghostty-integration}`
//! scripts. Those scripts are read from their submodule SOURCE
//! location (`ghostty/src/shell-integration/zsh/`), not a built
//! resources bundle (`zig-out/...`), so this test doesn't depend on a
//! prior `zig build` having run -- only on the `ghostty` submodule
//! being checked out, which `ghostty_zsh_resources_dir` asserts
//! explicitly (a real, actionable failure if it isn't, not a silent
//! skip).
//!
//! The spawned zsh's `ZDOTDIR` points at a scratch directory holding
//! only a comment-only `.zshrc`, not the developer's real dotfiles.
//! `resolve_shell_integration_env` (same module) relays whatever
//! `ZDOTDIR` the attach client sees as `GHOSTTY_ZSH_ZDOTDIR`, and the
//! bundled `.zshenv` restores `ZDOTDIR` to that value before zsh's own
//! startup sequence sources `$ZDOTDIR/.zshrc` -- so pointing that
//! relayed value at an empty scratch directory keeps the shell that
//! actually runs hermetic while the real ghostty integration scripts
//! (which don't depend on the user's rc files at all) still load and
//! emit OSC 7 from their precmd hook. Without this, the session's zsh
//! falls back to `$HOME/.zshrc`, and this developer's real one takes
//! several seconds to source, well past this test's 5s budget.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

mod common;
use common::{bin, drain_into, spawn_foreground_daemon, ChildGuard};

/// The real ghostty zsh shell-integration scripts, at their submodule
/// SOURCE location. Present in any checkout with the `ghostty`
/// submodule initialized, regardless of build state.
fn ghostty_zsh_resources_dir() -> PathBuf {
    let candidate = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../ghostty/src");
    let dir = candidate.canonicalize().unwrap_or_else(|e| {
        panic!(
            "resolve {} relative to the cli crate: {e}",
            candidate.display()
        )
    });
    let zshenv = dir.join("shell-integration/zsh/.zshenv");
    assert!(
        zshenv.is_file(),
        "expected the ghostty submodule's zsh shell-integration scripts at {}; \
         is the `ghostty` submodule checked out?",
        zshenv.display()
    );
    dir
}

#[test]
fn attach_create_with_ghostty_resources_dir_emits_osc7_for_an_interactive_zsh_session() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");

    let _daemon_guard = spawn_foreground_daemon(
        &runtime_dir,
        &state_dir,
        |cmd| {
            cmd.stdout(Stdio::null()).stderr(Stdio::null());
        },
        String::new,
    );

    let resources_dir = ghostty_zsh_resources_dir();

    // A scratch ZDOTDIR so the session's zsh reads a comment-only
    // .zshrc instead of this developer's real one: `.zshenv` (read
    // above) relays this value back in as `ZDOTDIR` once the bundled
    // integration's own setup is done, so zsh's normal startup
    // sequence sources `.zshrc` from here, not from `$HOME`.
    let zdotdir = tempdir.path().join("zdotdir");
    std::fs::create_dir(&zdotdir).expect("create scratch zdotdir");
    std::fs::write(
        zdotdir.join(".zshrc"),
        "# scratch .zshrc for shell_integration_attach test: intentionally empty\n",
    )
    .expect("write scratch .zshrc");

    let mut attach_child = Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args([
            "attach",
            "01J-p2-shell-integration-osc7",
            "--create",
            "--argv",
            "/bin/zsh",
        ])
        // Mirrors what a real ghostty tab sets in the attach client's
        // own environment before spawning it, plus a zsh-user $SHELL,
        // so `resolve_shell_integration_env`
        // (crates/cli/src/commands/shell_integration.rs) has exactly
        // what it needs to compute the zsh integration env for this
        // session.
        .env("GHOSTTY_RESOURCES_DIR", resources_dir.as_os_str())
        .env("SHELL", "/bin/zsh")
        .env("ZDOTDIR", zdotdir.as_os_str())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn `calyx-session attach --create`");
    let stdout = attach_child.stdout.take().expect("attach child stdout");
    let stderr = attach_child.stderr.take().expect("attach child stderr");
    let _attach_guard = ChildGuard(attach_child);

    // Read the attach client's stdout (the session's raw PTY output,
    // per `attach.rs`'s `bridge()`) on a background thread, since a
    // live interactive shell never closes it on its own; the main
    // thread polls a bounded snapshot instead of blocking on `read`.
    let acc = Arc::new(Mutex::new(Vec::<u8>::new()));
    drain_into(stdout, Arc::clone(&acc));
    // Drained so a failing attach client can't block on a full stderr
    // pipe; not asserted on directly, but kept around so a captured
    // error message can be attached to the eventual timeout failure
    // below for a clearer diagnosis.
    let stderr_acc = Arc::new(Mutex::new(Vec::<u8>::new()));
    drain_into(stderr, Arc::clone(&stderr_acc));

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let snapshot = acc.lock().unwrap_or_else(|p| p.into_inner()).clone();
        if snapshot.windows(4).any(|w| w == b"\x1b]7;") {
            break;
        }
        if Instant::now() >= deadline {
            let stderr_snapshot = stderr_acc.lock().unwrap_or_else(|p| p.into_inner()).clone();
            panic!(
                "expected an OSC 7 (\\x1b]7;kitty-shell-cwd://) escape sequence in \
                 the attached session's output within 5s, got stdout={:?} stderr={:?}",
                String::from_utf8_lossy(&snapshot),
                String::from_utf8_lossy(&stderr_snapshot)
            );
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}
