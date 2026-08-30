//! Regression test for the daemon inheriting its whole process
//! environment from whichever client first spawned it, then handing
//! that environment down to every session shell it spawns for the
//! rest of its life, across Calyx restarts. Confirmed on a real
//! machine: a long-running daemon held `GHOSTTY_RESOURCES_DIR`
//! pointing into a stale DerivedData debug build while the installed
//! app had long since moved to `/Applications`.
//!
//! `POISONED_ENV` intentionally mirrors `SCRUBBED_ENV_VARS`
//! (`crates/cli/src/commands/daemon.rs`): this file's job is to prove
//! the scrub mechanism works end to end through a real subprocess
//! (the actual `env::remove_var` loop, the actual daemon-to-session
//! inheritance chain, `new`'s actual empty `SessionSpec.env`), which
//! no unit test can exercise. Whether `SCRUBBED_ENV_VARS` is itself
//! complete, meaning it covers every key `resolve_shell_integration_env`
//! can push, is pinned separately by `daemon.rs`'s own
//! `scrubbed_env_vars_covers_every_key_resolve_shell_integration_env_can_push`
//! unit test, which calls that function directly. Only a same-crate
//! unit test can do that: `crates/cli` has no library target, so this
//! external, subprocess-based integration test has no way to call
//! into `cli`'s own internals at all.
//!
//! `crates/daemon/src/session.rs`'s `spawn_session` already removes
//! `CALYX_SURFACE_ID` at the per-spawn site (`cmd.env_remove(...)`,
//! covering the case where the daemon's own inherited copy is stale
//! because a session can be reattached to a different pane), so this
//! test's assertion for that one variable is a non-regression check,
//! not new coverage. For the other variables poisoned below, the
//! scrub in `commands::daemon::run` (`SCRUBBED_ENV_VARS`) is the only
//! thing standing between them and a spawned session's shell, which
//! is exactly what this test exercises end to end.
//!
//! `common::ScratchDaemon` (crates/daemon/tests/common/mod.rs) cannot
//! exercise this: it runs `Daemon::bind` on a thread of the test
//! process itself, so "the daemon's environment" would just be the
//! test binary's own environment. This spawns the real
//! `calyx-session daemon --foreground` binary instead, with specific
//! variables overridden on that child process, so the daemon's own
//! process environment and this test process's environment are
//! genuinely separate address spaces.
//!
//! `calyx-session new`'s `SessionSpec.env` (see
//! `commands::new::build_spec`) carries `resolve_terminal_env`, read
//! from the `new` invocation's own client process, not the daemon's:
//! `TERM`/`TERMINFO`/`LANG`/`PATH`/etc reach the session shell from
//! whichever process ran `calyx-session new`, overriding whatever the
//! daemon itself happened to inherit for those same keys. Every other
//! variable this test poisons is either scrubbed (`POISONED_ENV`) or,
//! for keys `resolve_terminal_env` never touches, falls through
//! unchanged from the daemon's own inherited environment, which is
//! exactly the leak path this test proves is closed for THOSE keys.
//! This test's one session is also created with no `--argv` at all, so
//! `spec.argv` is `None` and `session.rs` must resolve the executable
//! to run from `$SHELL` itself: `SHELL` is pointed at an executable
//! dumper script (`write_dumper_shell`) rather than a nonexistent
//! path, so this genuinely exercises that default-argv resolution
//! instead of only proving `SHELL` is inherited (an explicit `--argv`
//! session would prove just the latter, since `session.rs` never reads
//! `$SHELL` once `spec.argv` is `Some`). On macOS that default-argv
//! path now runs the dumper through a real `login(1)` session, which
//! overwrites the `SHELL` variable the dumper itself observes with the
//! current account's passwd-entry shell; `dumper_shell_path` still
//! decides what `login`'s `exec -l` ultimately execs, so the dumper
//! still runs and still writes its dump, but its own `$SHELL` no
//! longer equals `dumper_shell_path` on that platform.
//!
//! `TERMINFO` is forwarded by `resolve_terminal_env`, so this test sets
//! it explicitly on the `new` invocation itself (`CLIENT_TERMINFO`,
//! distinct from the daemon's own poisoned copy, `KNOWN_TERMINFO`) and
//! asserts the session shell sees the client's value, not the
//! daemon's: proof the client-supplied copy actually reaches the
//! shell rather than merely not crashing. `GHOSTTY_BIN_DIR` and
//! `XDG_DATA_DIRS` are deliberately absent from both `POISONED_ENV` and
//! `resolve_terminal_env`'s own key list, so this test asserts the
//! daemon-inheritance fall-through for both instead: they DO survive
//! into the session shell with the exact value set on the daemon.
//! `GHOSTTY_BIN_DIR` survives for one reason: nothing on any path a
//! session shell can take ever re-supplies it, so scrubbing it would
//! be a pure loss, not a fix, even though the daemon's own inherited
//! copy can go stale.
//! `XDG_DATA_DIRS` survives for a different reason: its inherited copy
//! carries the user's own real entries alongside whatever Calyx or
//! ghostty appended, not just a stale pointer with nothing else riding
//! along.

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

/// Variables poisoned on the daemon's own process environment before
/// it starts: `SCRUBBED_ENV_VARS`'s own members
/// (crates/cli/src/commands/daemon.rs), which this test proves the
/// real scrub mechanism removes before they can reach a spawned
/// session's shell. See this file's own module doc comment for why
/// `TERMINFO`, `GHOSTTY_BIN_DIR`, and `XDG_DATA_DIRS`, each of which
/// that const's own doc comment covers by prose but none of which is
/// a member, are poisoned separately below (`KNOWN_TERMINFO`,
/// `KNOWN_GHOSTTY_BIN_DIR`, `KNOWN_XDG_DATA_DIRS`) instead of here.
const POISONED_ENV: &[(&str, &str)] = &[
    (
        "GHOSTTY_RESOURCES_DIR",
        "poisoned-inherited-ghostty-resources-dir",
    ),
    ("ZDOTDIR", "poisoned-inherited-zdotdir"),
    (
        "GHOSTTY_ZSH_ZDOTDIR",
        "poisoned-inherited-ghostty-zsh-zdotdir",
    ),
    (
        "GHOSTTY_SHELL_FEATURES",
        "poisoned-inherited-ghostty-shell-features",
    ),
    ("CALYX_ZSH_ZDOTDIR", "poisoned-inherited-calyx-zsh-zdotdir"),
    ("CALYX_SURFACE_ID", "poisoned-inherited-surface-id"),
];

/// Poisoned on the daemon's own process environment, exactly like
/// `POISONED_ENV`'s members, but `new`'s `resolve_terminal_env` DOES
/// forward `TERMINFO` from the `new` invocation's own client process
/// (`CLIENT_TERMINFO`, set explicitly on that one invocation below), so
/// this value must be overridden in the session shell, never seen
/// there. It exists only to prove the override actually happens
/// (rather than the client's value merely also being present).
const KNOWN_TERMINFO: &str = "poisoned-but-must-be-overridden-terminfo";

/// Set on the `new` invocation itself (not the daemon): the value
/// `resolve_terminal_env` should forward into the session shell,
/// overriding the daemon's own stale `KNOWN_TERMINFO`.
const CLIENT_TERMINFO: &str = "resupplied-by-new-client-terminfo";

/// `new` never puts `GHOSTTY_BIN_DIR` into `SessionSpec.env`
/// (`resolve_terminal_env`'s key list doesn't include it), and
/// `SCRUBBED_ENV_VARS` deliberately leaves it out of the scrub too
/// (see that const's own doc comment): nothing re-supplies a fresh
/// value on any path a session shell can take, so a value the daemon
/// inherited for it, however stale, must still reach the session
/// shell unchanged rather than being dropped.
const KNOWN_GHOSTTY_BIN_DIR: &str = "poisoned-but-must-survive-ghostty-bin-dir";

/// `resolve_shell_integration_env` forwards `XDG_DATA_DIRS` verbatim
/// whenever the attaching client's own env has it, but `SCRUBBED_ENV_VARS`
/// deliberately leaves it out of the scrub (see that const's own doc
/// comment): it must keep reaching a `new`-created session's shell
/// unchanged.
const KNOWN_XDG_DATA_DIRS: &str = "poisoned-but-must-survive-xdg-data-dirs";

struct DaemonGuard(Child);

impl Drop for DaemonGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_calyx-session"))
}

/// Writes an executable script at `<dir>/dumper-shell` that dumps
/// this process's environment to `dump_path` (via `/usr/bin/env`,
/// mirroring the shape every other test in this crate reads) and
/// exits 0. Pointed at by `$SHELL` on the daemon so `new`, called
/// with no `--argv`, genuinely exercises `session.rs`'s default-argv
/// resolution (`spawn_session` reads `$SHELL` only when `spec.argv`
/// is `None`) rather than a path that would fail to spawn at all. On
/// macOS this executable is what `login(1)`'s `exec -l` ultimately
/// runs, not what the dumper's own `$SHELL` observes once it runs;
/// see the `SHELL` assertion below for that distinction.
fn write_dumper_shell(dir: &Path, dump_path: &Path) -> PathBuf {
    let script_path = dir.join("dumper-shell");
    let script = format!("#!/bin/sh\n/usr/bin/env > '{}'\n", dump_path.display());
    fs::write(&script_path, script).expect("write dumper shell script");
    let mut perms = fs::metadata(&script_path)
        .expect("stat dumper shell script")
        .permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&script_path, perms).expect("chmod dumper shell script executable");
    script_path
}

fn wait_for_socket(path: &Path, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

fn run_cli(runtime_dir: &Path, state_dir: &Path, args: &[&str]) -> Output {
    run_cli_with_env(runtime_dir, state_dir, args, &[])
}

/// Like `run_cli`, but sets `env` on the subprocess itself: needed for
/// the `new` invocation below, whose own client-side environment (not
/// the daemon's) is what `resolve_terminal_env` reads `TERMINFO` from.
/// Without pinning this explicitly, the assertion on that key would
/// silently depend on whether the machine running the test happens to
/// have `TERMINFO` set in its own ambient environment.
fn run_cli_with_env(
    runtime_dir: &Path,
    state_dir: &Path,
    args: &[&str],
    env: &[(&str, &str)],
) -> Output {
    let mut cmd = Command::new(bin());
    cmd.args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args(args)
        .stdin(Stdio::null());
    for &(key, value) in env {
        cmd.env(key, value);
    }
    cmd.output()
        .unwrap_or_else(|e| panic!("run `calyx-session {}`: {e}", args.join(" ")))
}

/// Parses `KEY=value` lines, the shape `/usr/bin/env` with no
/// arguments prints, into a lookup map.
fn parse_env_dump(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter_map(|line| line.split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[test]
fn session_shell_never_sees_the_daemons_inherited_pane_scoped_env() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    // Declared before `_daemon_guard` below: locals drop in reverse
    // declaration order, so the daemon is killed first and this
    // directory (holding its socket, lock file, and dumper script) is
    // removed second, on every exit path including a panicking
    // assertion.
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let dump_path = tempdir.path().join("dump.txt");
    let daemon_log_path = tempdir.path().join("daemon.log");
    let dumper_shell_path = write_dumper_shell(tempdir.path(), &dump_path);

    let daemon_stdout_log = fs::File::create(&daemon_log_path).expect("create daemon log file");
    let daemon_stderr_log = daemon_stdout_log
        .try_clone()
        .expect("clone daemon log file handle");

    let mut daemon_cmd = Command::new(bin());
    daemon_cmd
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args(["daemon", "--foreground"])
        .env("SHELL", &dumper_shell_path)
        .env("TERMINFO", KNOWN_TERMINFO)
        .env("GHOSTTY_BIN_DIR", KNOWN_GHOSTTY_BIN_DIR)
        .env("XDG_DATA_DIRS", KNOWN_XDG_DATA_DIRS)
        .stdout(daemon_stdout_log)
        .stderr(daemon_stderr_log);
    for &(key, value) in POISONED_ENV {
        daemon_cmd.env(key, value);
    }
    let daemon_child = daemon_cmd
        .spawn()
        .expect("spawn `calyx-session daemon --foreground`");
    let _daemon_guard = DaemonGuard(daemon_child);

    let socket_path = runtime_dir.join("sessiond.sock");
    if !wait_for_socket(&socket_path, Duration::from_secs(5)) {
        // Stdout/stderr are redirected to `daemon_log_path` (rather
        // than `Stdio::null()`) for exactly this: a bind failure would
        // otherwise surface only as this opaque timeout, with
        // `main.rs`'s own `eprintln!("calyx-session: {e}")` for the
        // real cause sitting unread in a discarded pipe.
        let log = fs::read_to_string(&daemon_log_path).unwrap_or_default();
        panic!(
            "daemon --foreground should create {} within 5s; daemon stdout/stderr:\n{log}",
            socket_path.display()
        );
    }

    // `new`, not `attach`, and with no `--argv` at all: every variable
    // its shell ends up seeing either came from `resolve_terminal_env`,
    // read from THIS invocation's own client process (`TERMINFO` is
    // set explicitly here, to `CLIENT_TERMINFO`, to pin that it
    // overrides the daemon's own stale copy), or fell through
    // unchanged from the daemon's own process environment, poisoned
    // above, for every other key. `spec.argv` is `None`, so
    // `session.rs` must resolve the executable to run from `$SHELL`
    // itself (`dumper_shell_path`), genuinely exercising that
    // default-argv path rather than merely asserting SHELL survives.
    let new_result = run_cli_with_env(
        &runtime_dir,
        &state_dir,
        &["new"],
        &[("TERMINFO", CLIENT_TERMINFO)],
    );
    assert!(
        new_result.status.success(),
        "new should succeed, got {new_result:?}"
    );
    let id = String::from_utf8_lossy(&new_result.stdout)
        .trim()
        .to_string();
    assert!(!id.is_empty(), "new should print the created session's id");

    // `new` only creates the session and returns immediately; it does
    // not wait for the argv to run. Poll until the session leaves the
    // live registry, proving its `env > file` write already completed
    // before reading the file below.
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let ls_live = run_cli(&runtime_dir, &state_dir, &["ls", "--json"]);
        assert!(
            ls_live.status.success(),
            "ls --json should succeed, got {ls_live:?}"
        );
        let sessions: Vec<serde_json::Value> =
            serde_json::from_slice(&ls_live.stdout).expect("ls --json output should be valid JSON");
        let still_live = sessions
            .iter()
            .any(|s| s.get("id").and_then(|v| v.as_str()) == Some(id.as_str()));
        if !still_live {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "session {id} should exit within 5s, still in ls --json: {sessions:?}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    let dumped = fs::read_to_string(&dump_path)
        .unwrap_or_else(|e| panic!("read {}: {e}", dump_path.display()));
    let dumped_env = parse_env_dump(&dumped);

    for &(key, _) in POISONED_ENV {
        assert!(
            !dumped_env.contains_key(key),
            "{key} must not leak from the daemon's own inherited process \
             environment into a session shell it spawns, got value {:?} in \
             dumped env: {dumped:?}",
            dumped_env.get(key)
        );
    }

    #[cfg(target_os = "macos")]
    let expected_shell = nix::unistd::User::from_uid(nix::unistd::getuid())
        .expect("look up the current uid's passwd entry")
        .expect("the current uid must have a passwd entry")
        .shell
        .to_str()
        .expect("account shell path is valid utf8")
        .to_string();
    #[cfg(not(target_os = "macos"))]
    let expected_shell = dumper_shell_path
        .to_str()
        .expect("dumper shell path is valid utf8")
        .to_string();

    assert_eq!(
        dumped_env.get("SHELL").map(String::as_str),
        Some(expected_shell.as_str()),
        "the daemon's own $SHELL still decides what runs when a session has no --argv: on \
         macOS this session's default-argv path now runs the dumper THROUGH a login(1) session \
         (`login -flp` -> bash -> `exec -l '<dumper_shell_path>'`, and since the dumper is a \
         `#!/bin/sh` script, the kernel runs it through /bin/sh regardless of the dash argv0 \
         `exec -l` gives it), so the SHELL variable the dumper itself observes is the one \
         login(1) sets from the current account's passwd entry, not dumper_shell_path (which \
         only decides what the login session ultimately execs). On other platforms session.rs \
         still runs dumper_shell_path directly with no login(1) involved, so SHELL there is \
         still dumper_shell_path unchanged. Got dumped env: {dumped:?}"
    );

    assert_eq!(
        dumped_env.get("TERMINFO").map(String::as_str),
        Some(CLIENT_TERMINFO),
        "TERMINFO must reach a `new`-created session's shell as the value supplied by the \
         `new` invocation's own client process (resolve_terminal_env), not the daemon's own \
         inherited (and here, deliberately poisoned) copy: a launchd-owned daemon's job \
         environment never has TERMINFO at all, so this client-side re-supply is the only way \
         a session shell gets one. Got dumped env: {dumped:?}"
    );

    assert_eq!(
        dumped_env.get("GHOSTTY_BIN_DIR").map(String::as_str),
        Some(KNOWN_GHOSTTY_BIN_DIR),
        "GHOSTTY_BIN_DIR must still reach a `new`-created session's shell after the scrub, for \
         the identical reason as TERMINFO above: nothing re-supplies it on any path a session \
         shell can take, so scrubbing it would be a pure loss, not a fix. Got dumped env: \
         {dumped:?}"
    );

    assert_eq!(
        dumped_env.get("XDG_DATA_DIRS").map(String::as_str),
        Some(KNOWN_XDG_DATA_DIRS),
        "XDG_DATA_DIRS must still reach a `new`-created session's shell after the scrub: it is \
         deliberately left out of SCRUBBED_ENV_VARS (crates/cli/src/commands/daemon.rs) because \
         it is a search-path list carrying the user's own real entries, not a single-valued \
         pointer that goes stale. Got dumped env: {dumped:?}"
    );
}
