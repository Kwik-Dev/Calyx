#![cfg(target_os = "macos")]

//! End-to-end test for the macOS default session shell being a real
//! `login(1)` session (matching ghostty's own `Exec.zig` login-shell
//! path), exercised through `calyx-session attach --create` with no
//! `--argv` at all, so `session.rs` resolves the executable itself.
//!
//! `ZDOTDIR` is the seam this test uses to observe what actually ran:
//! `resolve_shell_integration_env`
//! (`crates/cli/src/commands/shell_integration.rs`) relays the attach
//! client's own `ZDOTDIR` verbatim into `SessionSpec.env` whenever
//! `GHOSTTY_RESOURCES_DIR` is absent from that client's environment
//! and its `SHELL` is zsh; `login -p` leaves an already-set `ZDOTDIR`
//! untouched (it only overwrites `HOME`, `SHELL`, `LOGNAME`, `USER`
//! from the user record); and zsh reads `$ZDOTDIR/.zprofile` only when
//! it starts as a login shell, which is exactly the behavior under
//! test. `HOME` cannot serve this role instead: `login(1)` overwrites
//! `HOME` from the user record regardless of what the daemon or the
//! attach client had, and `resolve_terminal_env`
//! (`crates/cli/src/commands/terminal_env.rs`) never forwards `HOME`
//! from the attach client in the first place, so there would be no way
//! to point a login shell's startup file at a scratch tempdir at all.
//!
//! The daemon's own `SHELL` and the current uid's passwd shell are
//! both `/bin/zsh` in this environment, so a marker built from `SHELL`
//! alone cannot distinguish which one the session actually execs. To
//! tell them apart, the daemon's `SHELL` here is a symlink
//! `<tempdir>/bin/zsh -> /bin/zsh` (the basename must stay `zsh`
//! because `is_zsh` in `shell_integration.rs` matches on basename) and
//! the marker also records `ZSH_ARGZERO`: bash's `exec -l` in
//! `login_session_argv` prefixes a dash to the shell path exactly as
//! given, so a session that exec'd the daemon's `$SHELL` reports
//! `ZSH_ARGZERO=-<tempdir>/bin/zsh`, while `SHELL` itself is always
//! what `login(1)` sets from the passwd entry
//! (`nix::unistd::User::from_uid(getuid()).shell`), regardless of
//! which path was exec'd.

use std::fs;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

mod common;
use common::{bin, drain_into, wait_for_socket, ChildGuard};

#[test]
fn attach_create_with_no_argv_runs_a_real_login_session_on_macos() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let zdotdir = tempdir.path().join("zdotdir");
    let distinctive_bin = tempdir.path().join("distinctive-bin");
    let marker_path = tempdir.path().join("marker.txt");
    let daemon_log_path = tempdir.path().join("daemon.log");

    fs::create_dir_all(&runtime_dir).expect("create runtime dir");
    fs::create_dir_all(&state_dir).expect("create state dir");
    fs::create_dir_all(&zdotdir).expect("create zdotdir");
    fs::create_dir_all(&distinctive_bin).expect("create distinctive-bin dir");
    assert!(
        !marker_path.exists(),
        "marker must not exist before the session runs"
    );

    // A symlink so its basename stays "zsh" (`is_zsh` matches on
    // basename) while its path is distinguishable from the real
    // `/bin/zsh`, letting the marker's `ZSH_ARGZERO` prove which path
    // was actually exec'd.
    let shell_bin = tempdir.path().join("bin");
    fs::create_dir_all(&shell_bin).expect("create shell bin dir");
    let symlinked_shell = shell_bin.join("zsh");
    std::os::unix::fs::symlink("/bin/zsh", &symlinked_shell).expect("symlink zsh");

    // Written in zsh syntax: `[[ -o login ]]` is true only when this
    // shell instance was actually started as a login shell, which is
    // the one fact this whole test exists to observe.
    let zprofile = format!(
        "{{\n\
         \x20 login=$([[ -o login ]] && print yes || print no)\n\
         \x20 print -r -- \"login=$login\"\n\
         \x20 print -r -- \"PATH=$PATH\"\n\
         \x20 print -r -- \"TERM=$TERM\"\n\
         \x20 print -r -- \"CALYX_SESSION_ID=$CALYX_SESSION_ID\"\n\
         \x20 print -r -- \"SHELL=$SHELL\"\n\
         \x20 print -r -- \"USER=$USER\"\n\
         \x20 print -r -- \"pid=$$ ppid=$PPID\"\n\
         \x20 print -r -- \"ZSH_ARGZERO=$ZSH_ARGZERO\"\n\
         \x20 print -r -- \"PWD=$PWD\"\n\
         }} > \"{marker}\"\n\
         exit 0\n",
        marker = marker_path.display()
    );
    fs::write(zdotdir.join(".zprofile"), zprofile).expect("write .zprofile");

    let daemon_stdout_log = fs::File::create(&daemon_log_path).expect("create daemon log file");
    let daemon_stderr_log = daemon_stdout_log
        .try_clone()
        .expect("clone daemon log file handle");

    let daemon_child = Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args(["daemon", "--foreground"])
        .env("SHELL", &symlinked_shell)
        .stdout(daemon_stdout_log)
        .stderr(daemon_stderr_log)
        .spawn()
        .expect("spawn `calyx-session daemon --foreground`");
    let _daemon_guard = ChildGuard(daemon_child);

    let socket_path = runtime_dir.join("sessiond.sock");
    if !wait_for_socket(&socket_path, Duration::from_secs(5)) {
        let log = fs::read_to_string(&daemon_log_path).unwrap_or_default();
        panic!(
            "daemon --foreground should create {} within 5s; daemon stdout/stderr:\n{log}",
            socket_path.display()
        );
    }

    let session_id = "01J-p2-login-shell-default";
    let session_path = format!(
        "{}:/usr/bin:/bin",
        distinctive_bin.to_str().expect("distinctive-bin utf8")
    );

    let mut attach_child = Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args([
            "attach",
            session_id,
            "--create",
            "--cwd",
            tempdir.path().to_str().unwrap(),
        ])
        .env("SHELL", &symlinked_shell)
        .env("ZDOTDIR", &zdotdir)
        .env_remove("GHOSTTY_RESOURCES_DIR")
        .env_remove("CALYX_ZSH_ZDOTDIR")
        .env("TERM", "calyx-login-shell-test")
        .env("PATH", &session_path)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn `calyx-session attach --create`");
    let stdout = attach_child.stdout.take().expect("attach child stdout");
    let stderr = attach_child.stderr.take().expect("attach child stderr");
    let _attach_guard = ChildGuard(attach_child);

    let stdout_acc = Arc::new(Mutex::new(Vec::<u8>::new()));
    drain_into(stdout, Arc::clone(&stdout_acc));
    let stderr_acc = Arc::new(Mutex::new(Vec::<u8>::new()));
    drain_into(stderr, Arc::clone(&stderr_acc));

    let deadline = Instant::now() + Duration::from_secs(5);
    while !marker_path.exists() {
        if Instant::now() >= deadline {
            let out = stdout_acc.lock().unwrap_or_else(|p| p.into_inner()).clone();
            let err = stderr_acc.lock().unwrap_or_else(|p| p.into_inner()).clone();
            let daemon_log = fs::read_to_string(&daemon_log_path).unwrap_or_default();
            panic!(
                "expected {} to appear within 5s (a real macOS login(1) session should \
                 have started zsh as a login shell, running .zprofile from ZDOTDIR); \
                 attach stdout={:?} stderr={:?}; daemon log:\n{daemon_log}",
                marker_path.display(),
                String::from_utf8_lossy(&out),
                String::from_utf8_lossy(&err),
            );
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    let marker = fs::read_to_string(&marker_path)
        .unwrap_or_else(|e| panic!("read {}: {e}", marker_path.display()));
    let mut fields = std::collections::BTreeMap::new();
    for line in marker.lines() {
        if let Some((k, v)) = line.split_once('=') {
            fields.insert(k.to_string(), v.to_string());
        }
    }

    assert_eq!(
        fields.get("login").map(String::as_str),
        Some("yes"),
        "the session shell must have started as a login shell, got marker: {marker:?}"
    );

    let path_field = fields.get("PATH").cloned().unwrap_or_default();
    assert!(
        path_field
            .split(':')
            .any(|p| p == distinctive_bin.to_str().unwrap()),
        "PATH must still contain the attach client's distinctive entry {}, got PATH={path_field:?} \
         (marker: {marker:?})",
        distinctive_bin.display()
    );

    assert_eq!(
        fields.get("TERM").map(String::as_str),
        Some("calyx-login-shell-test"),
        "TERM must reach the session shell unchanged, got marker: {marker:?}"
    );

    assert_eq!(
        fields.get("CALYX_SESSION_ID").map(String::as_str),
        Some(session_id),
        "CALYX_SESSION_ID must reach the session shell, got marker: {marker:?}"
    );

    let passwd_entry = nix::unistd::User::from_uid(nix::unistd::getuid())
        .expect("look up the current uid's passwd entry")
        .expect("the current uid must have a passwd entry");
    assert_eq!(
        fields.get("USER").map(String::as_str),
        Some(passwd_entry.name.as_str()),
        "USER must be set by login(1) from the current user's own passwd entry, got marker: \
         {marker:?}"
    );

    let expected_argzero = format!("-{}", symlinked_shell.display());
    assert_eq!(
        fields.get("ZSH_ARGZERO").map(String::as_str),
        Some(expected_argzero.as_str()),
        "ZSH_ARGZERO must show bash's `exec -l` execed the daemon's own $SHELL \
         ({}) with a dash prefixed, not the passwd entry's shell, got marker: {marker:?}",
        symlinked_shell.display()
    );

    let expected_shell = passwd_entry
        .shell
        .to_str()
        .expect("passwd shell is valid UTF-8")
        .to_string();
    assert_eq!(
        fields.get("SHELL").map(String::as_str),
        Some(expected_shell.as_str()),
        "SHELL must be set by login(1) from the current user's own passwd entry \
         (nix::unistd::User::from_uid(getuid()).shell), not the daemon's own $SHELL, got \
         marker: {marker:?}"
    );

    // `login(1)`'s `-l` flag is what suppresses its own chdir to
    // `$HOME`, so this is the assertion that would catch `-l` being
    // dropped from `login_session_argv`'s `-flp` cluster. `TMPDIR` on
    // macOS lives under `/var/folders`, a symlink to
    // `/private/var/folders`, so both sides are canonicalized before
    // comparing.
    let pwd_field = fields.get("PWD").cloned().unwrap_or_default();
    let pwd_canonical = std::path::Path::new(&pwd_field)
        .canonicalize()
        .unwrap_or_else(|e| panic!("canonicalize PWD={pwd_field:?}: {e}"));
    let tempdir_canonical = tempdir
        .path()
        .canonicalize()
        .unwrap_or_else(|e| panic!("canonicalize tempdir={:?}: {e}", tempdir.path()));
    assert_eq!(
        pwd_canonical, tempdir_canonical,
        "the session's cwd must stay at --cwd's tempdir instead of login(1) chdir'ing to \
         $HOME, got marker: {marker:?}"
    );
}
