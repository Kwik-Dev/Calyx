//! A real, backgrounded daemon A (started the ordinary way, via
//! `calyx-session daemon`) serving a live `/bin/cat` session, then a
//! second `calyx-session daemon --foreground --adopt-existing`
//! invocation against the SAME `--runtime-dir`/`--state-dir`: instead
//! of colliding with A's single-daemon flock and exiting as a
//! duplicate (the ordinary-path contract `daemon_lock_regression.rs`
//! pins), it must connect to A as a client, drive `PrepareHandoff`,
//! and become the new daemon serving the SAME socket path with A's
//! session still alive. A's own process must then be gone (a
//! successful handoff's old-daemon side exits once it hands off, per
//! `daemon::handoff`'s module doc).
//!
//! The polling loop below is bounded (`Instant::now() < deadline`), so
//! any failure along the way (B never connecting to A, A refusing
//! `PrepareHandoff`, or the handoff receiver dying mid-adoption) turns
//! into an ordinary, clearly-reported test failure rather than a hang.
//!
//! A's real serving pid (needed to prove it exits) is not directly
//! available: `calyx-session daemon` double-forks into a detached
//! grandchild that this test process never gets a `Child` handle for.
//! It is instead located via `ps`, matching on this test's own unique
//! `--runtime-dir` scratch path in the process's command line (unique
//! per test run, and excluding the `--adopt-existing` invocation's own
//! matching command line so the two are never confused).

use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

mod common;
use common::{bin, wait_for_socket, ChildGuard};

fn run_cli(runtime_dir: &Path, state_dir: &Path, args: &[&str]) -> Output {
    Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args(args)
        .stdin(Stdio::null())
        .output()
        .unwrap_or_else(|e| panic!("run `calyx-session {}`: {e}", args.join(" ")))
}

/// Finds daemon A's real (post-double-fork) pid by matching `ps`'s
/// command-line listing against this test's unique `runtime_dir`
/// scratch path, excluding any `--adopt-existing` invocation's own
/// (differently-flagged) command line.
fn find_daemon_a_pid(runtime_dir: &Path) -> Option<i32> {
    let output = Command::new("ps")
        .args(["-axo", "pid=,command="])
        .output()
        .ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let needle = runtime_dir.to_str()?;
    for line in stdout.lines() {
        if line.contains(needle) && line.contains("daemon") && !line.contains("--adopt-existing") {
            let pid_str = line.split_whitespace().next()?;
            if let Ok(pid) = pid_str.parse::<i32>() {
                return Some(pid);
            }
        }
    }
    None
}

fn process_alive(pid: i32) -> bool {
    // SAFETY: kill(pid, 0) sends no signal; it only probes existence
    // and permission, which this test (same uid, its own child tree)
    // always has.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Terminates daemon A on drop. A is a detached, double-forked
/// grandchild this test process never gets a `Child` handle for (see
/// `find_daemon_a_pid`), so there is no `wait()` to do here, and this
/// must run even if an assertion before adoption completes fails: A
/// holds a live `/bin/cat` session and never idle-exits on its own, so
/// without this it would leak indefinitely past this test's tempdir
/// being removed.
struct DaemonAGuard(i32);

impl Drop for DaemonAGuard {
    fn drop(&mut self) {
        // SAFETY: sends SIGTERM only; probes/terminates a pid this
        // test process itself just located via `ps` in its own uid.
        unsafe {
            libc::kill(self.0, libc::SIGTERM);
        }
    }
}

#[test]
fn adopt_existing_takes_over_a_running_daemons_sessions_and_the_old_process_exits() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let socket_path = runtime_dir.join("sessiond.sock");

    // Daemon A: the ordinary, backgrounded start.
    let start_a = run_cli(&runtime_dir, &state_dir, &["daemon"]);
    assert!(
        start_a.status.success(),
        "starting daemon A should succeed, got {start_a:?}"
    );
    assert!(
        wait_for_socket(&socket_path, Duration::from_secs(5)),
        "daemon A should create {} within 5s",
        socket_path.display()
    );

    let pid_a = {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(pid) = find_daemon_a_pid(&runtime_dir) {
                break pid;
            }
            assert!(
                Instant::now() < deadline,
                "could not locate daemon A's real (post-double-fork) pid via `ps` within 5s"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    };
    let _guard_a = DaemonAGuard(pid_a);

    // A live session against A.
    let new_result = run_cli(&runtime_dir, &state_dir, &["new", "--argv", "/bin/cat"]);
    assert!(
        new_result.status.success(),
        "creating a session against daemon A should succeed, got {new_result:?}"
    );
    let session_id = String::from_utf8_lossy(&new_result.stdout)
        .trim()
        .to_string();
    assert!(
        !session_id.is_empty(),
        "new should print the created session's id"
    );

    // Daemon B: `daemon --foreground --adopt-existing` against the
    // SAME runtime/state dirs, as a genuine child process (not
    // `run_cli`, which waits for exit: this must stay running).
    let child_b = Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args(["daemon", "--foreground", "--adopt-existing"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn `calyx-session daemon --foreground --adopt-existing`");
    let _guard_b = ChildGuard(child_b);

    // Bounded poll: the session must still be visible over the SAME
    // socket path, and A's original pid must be gone.
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let ls = run_cli(&runtime_dir, &state_dir, &["ls", "--json"]);
        let session_still_visible =
            ls.status.success() && String::from_utf8_lossy(&ls.stdout).contains(&session_id);
        let a_gone = !process_alive(pid_a);

        if session_still_visible && a_gone {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "adopt-existing did not complete within 10s: session_still_visible={session_still_visible}, \
             a_gone={a_gone} (pid_a={pid_a}); likely cause: daemon B failed to connect to A \
             or A refused PrepareHandoff, or the handoff receiver failed partway through \
             adoption and B exited before ever taking over the socket; check B's captured \
             stdout/stderr for the actual error"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}
