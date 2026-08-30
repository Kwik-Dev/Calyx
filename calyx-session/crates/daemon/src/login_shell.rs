//! Builds the macOS `login(1)` session argv, matching the darwin
//! branch of ghostty's own `execCommand` in
//! `ghostty/src/termio/Exec.zig`, and its POSIX single-quote helper.
//!
//! `login(1)` forks: the parent keeps running as a root-euid session
//! leader, `waitpid`s the child, and always exits 0, so the daemon's
//! recorded child pid is login's own, and a default session's
//! `Exited { code }` is 0 unless login itself is signaled.
//!
//! `-p` preserves the calling process's environment except `HOME`,
//! `SHELL`, `LOGNAME`, `USER`, which login re-sets from the target
//! user's passwd entry (`PATH`/`TERM` are kept when already set), so
//! everything in `spec.env` and the daemon's `CALYX_SESSION_ID`
//! survives. `-l` prevents login's own chdir to `$HOME` (so
//! `spec.cwd` still holds) and suppresses login's own argv0 dash,
//! which bash's `exec -l` restores instead. `-q` mirrors
//! `~/.hushlogin`: the caller checks the home directory itself
//! because `login(1)` on macOS 14.3 and earlier looked for
//! `.hushlogin` in the current working directory instead. bash runs
//! with `--noprofile --norc` so no user startup file runs before the
//! final exec.
//!
//! `/usr/bin/login` requires fd 0 to already be the PTY slave, which
//! `spawn_session`'s `pre_exec` (setsid + `TIOCSCTTY`, applied after
//! Rust's stdio dup2) guarantees.
//!
//! Prepending `-` to argv0 alone is not used instead of `login(1)`
//! because `getlogin()`, the `SHELL`/`USER`/`LOGNAME` variables,
//! utmpx, and hushlogin handling would all differ from ordinary
//! ghostty panes.
//!
//! The shell to exec comes from [`choose_shell`]: the passwd entry
//! for the current uid, looked up through the same `nix::unistd::User`
//! call login itself effectively makes, is the one authoritative
//! source of a user's login shell (and what `login(1)` writes into
//! the session's own `SHELL` variable); `$SHELL` is honored first
//! when it is set and non-empty because it is the user's explicit
//! per-session choice, the same order ghostty uses. When `$SHELL`
//! names a path that does not exist or is not executable, that is
//! rejected at the daemon boundary so the failure reaches the client
//! as a spawn error, rather than surfacing as bash's `exec -l`
//! printing `not found` inside an already-started session while
//! `login` itself still exits 0.
//!
//! If the daemon cannot resolve the passwd entry for its own uid, it
//! cannot build a login(1) session at all (no username, no home
//! directory for `.hushlogin`, no passwd shell to fall back to). That
//! is the documented degraded state of a daemon that lost its
//! spawning app's jetsam coalition and can no longer reach
//! opendirectoryd (`crate::health`, `warn_user_lookup_may_be_broken`
//! in the CLI's `attach` command); the production launchd-owned
//! daemon never enters it. In that state the daemon starts `$SHELL`
//! directly, without `login(1)`, and logs a warning to its own
//! stderr; `$SHELL` unset in that state is still a hard error, since
//! there is then no shell of any kind to start.

#[cfg(any(target_os = "macos", test))]
use std::path::Path;

/// Builds `["/usr/bin/login", ["-q"], "-flp", username, "/bin/bash",
/// "--noprofile", "--norc", "-c", "exec -l '<shell>'"]`, matching
/// ghostty's own login-shell argv layout.
#[cfg(any(target_os = "macos", test))]
pub(crate) fn login_session_argv(username: &str, hushlogin: bool, shell: &str) -> Vec<String> {
    let mut argv = vec!["/usr/bin/login".to_string()];
    if hushlogin {
        argv.push("-q".to_string());
    }
    argv.push("-flp".to_string());
    argv.push(username.to_string());
    argv.push("/bin/bash".to_string());
    argv.push("--noprofile".to_string());
    argv.push("--norc".to_string());
    argv.push("-c".to_string());
    argv.push(format!("exec -l {}", shell_single_quote(shell)));
    argv
}

/// Wraps `s` in single quotes for a POSIX shell, escaping any
/// embedded single quote as `'\''`.
#[cfg(any(target_os = "macos", test))]
pub(crate) fn shell_single_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

/// Picks the shell to exec for a default session: `env_shell` (the
/// daemon's own `$SHELL`) when it is set and non-empty, otherwise
/// `passwd_shell` (the shell field of the current uid's passwd
/// entry).
///
/// A bare command name in `env_shell` (no `/`) is returned as-is
/// without consulting `is_executable`: it is resolved through the
/// session's `PATH` by bash's `exec -l`, the same PATH resolution
/// `Command::new` performs for a bare name. A path (containing `/`)
/// is checked with `is_executable` so a stale or
/// misspelled `$SHELL` is rejected here, at the daemon boundary,
/// rather than surfacing later as bash's `exec -l` printing `exec:
/// ...: not found` inside an already-started session while `login`
/// itself still exits 0.
#[cfg(any(target_os = "macos", test))]
pub(crate) fn choose_shell(
    env_shell: Option<&str>,
    passwd_shell: Option<&Path>,
    is_executable: impl Fn(&Path) -> bool,
) -> Result<String, String> {
    if let Some(shell) = env_shell.filter(|s| !s.is_empty()) {
        if shell.contains('/') {
            let path = Path::new(shell);
            if !is_executable(path) {
                return Err(format!(
                    "SHELL is set to {shell}, which is not an executable file"
                ));
            }
        }
        return Ok(shell.to_string());
    }

    match passwd_shell {
        Some(path) => path.to_str().map(str::to_string).ok_or_else(|| {
            format!(
                "the passwd entry's shell {} is not valid UTF-8",
                path.display()
            )
        }),
        None => Err(
            "cannot determine the user's shell: SHELL is unset and the passwd entry is \
             unavailable"
                .to_string(),
        ),
    }
}

/// Resolves the argv for a default session (`spec.argv == None`). On
/// macOS this builds a real `login(1)` session for the current uid;
/// elsewhere it is `$SHELL` as-is, unchanged from prior behavior.
#[cfg(target_os = "macos")]
pub(crate) fn default_session_argv() -> Result<Vec<String>, String> {
    let env_shell = std::env::var("SHELL").ok();
    let is_executable = |p: &Path| nix::unistd::access(p, nix::unistd::AccessFlags::X_OK).is_ok();

    // `login(1)`'s own `-f` compares the caller's real uid with the
    // target user, so the real uid is the right key for this lookup
    // too.
    let uid = nix::unistd::getuid();

    let lookup = nix::unistd::User::from_uid(uid);
    match lookup {
        Ok(Some(user)) => {
            let shell = choose_shell(env_shell.as_deref(), Some(&user.shell), is_executable)?;
            let hushlogin = user.dir.join(".hushlogin").exists();
            Ok(login_session_argv(&user.name, hushlogin, &shell))
        }
        Ok(None) | Err(_) => {
            let why = match &lookup {
                Err(e) => e.to_string(),
                _ => "no passwd entry for this uid".to_string(),
            };
            eprintln!(
                "calyx-sessiond: cannot look up the passwd entry for uid {uid}: {why}; starting \
                 the shell without login(1)"
            );
            Ok(vec![choose_shell(
                env_shell.as_deref(),
                None,
                is_executable,
            )?])
        }
    }
}

/// Resolves the argv for a default session (`spec.argv == None`) on
/// non-macOS platforms: `$SHELL` as-is, unchanged from prior
/// behavior.
#[cfg(not(target_os = "macos"))]
pub(crate) fn default_session_argv() -> Result<Vec<String>, String> {
    Ok(vec![
        std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn login_session_argv_without_hushlogin_matches_ghostty_layout() {
        let argv = login_session_argv("testuser", false, "/bin/zsh");
        assert_eq!(
            argv,
            vec![
                "/usr/bin/login".to_string(),
                "-flp".to_string(),
                "testuser".to_string(),
                "/bin/bash".to_string(),
                "--noprofile".to_string(),
                "--norc".to_string(),
                "-c".to_string(),
                "exec -l '/bin/zsh'".to_string(),
            ]
        );
        assert_eq!(argv.len(), 8);
    }

    #[test]
    fn login_session_argv_with_hushlogin_inserts_dash_q_at_index_1() {
        let argv = login_session_argv("testuser", true, "/bin/zsh");
        assert_eq!(
            argv,
            vec![
                "/usr/bin/login".to_string(),
                "-q".to_string(),
                "-flp".to_string(),
                "testuser".to_string(),
                "/bin/bash".to_string(),
                "--noprofile".to_string(),
                "--norc".to_string(),
                "-c".to_string(),
                "exec -l '/bin/zsh'".to_string(),
            ]
        );
        assert_eq!(argv.len(), 9);
        assert_eq!(argv[1], "-q");
    }

    #[test]
    fn shell_single_quote_escapes_embedded_single_quotes() {
        assert_eq!(shell_single_quote("/bin/zsh"), "'/bin/zsh'");
        assert_eq!(
            shell_single_quote("/opt/it's here/zsh"),
            "'/opt/it'\\''s here/zsh'"
        );
        let argv = login_session_argv("u", false, "/opt/it's here/zsh");
        assert_eq!(
            argv.last().map(String::as_str),
            Some("exec -l '/opt/it'\\''s here/zsh'")
        );
    }

    #[test]
    fn choose_shell_prefers_env_when_set_and_executable() {
        let result = choose_shell(Some("/bin/zsh"), Some(Path::new("/bin/bash")), |p| {
            p == Path::new("/bin/zsh")
        });
        assert_eq!(result, Ok("/bin/zsh".to_string()));
    }

    #[test]
    fn choose_shell_rejects_env_path_that_is_not_executable() {
        let result = choose_shell(Some("/bin/zsh"), None, |_| false);
        assert_eq!(
            result,
            Err("SHELL is set to /bin/zsh, which is not an executable file".to_string())
        );
    }

    #[test]
    fn choose_shell_returns_bare_command_name_without_consulting_predicate() {
        let result = choose_shell(Some("zsh"), None, |_| {
            panic!("is_executable must not be consulted for a bare command name")
        });
        assert_eq!(result, Ok("zsh".to_string()));
    }

    #[test]
    fn choose_shell_falls_back_to_passwd_shell_when_env_unset() {
        let result = choose_shell(None, Some(Path::new("/bin/bash")), |_| true);
        assert_eq!(result, Ok("/bin/bash".to_string()));
    }

    #[test]
    fn choose_shell_falls_back_to_passwd_shell_when_env_empty() {
        let result = choose_shell(Some(""), Some(Path::new("/bin/bash")), |_| true);
        assert_eq!(result, Ok("/bin/bash".to_string()));
    }

    #[test]
    fn choose_shell_errors_when_env_unset_and_no_passwd_shell() {
        let result = choose_shell(None, None, |_| true);
        assert_eq!(
            result,
            Err(
                "cannot determine the user's shell: SHELL is unset and the passwd entry is \
                 unavailable"
                    .to_string()
            )
        );
    }
}
