//! Builds the macOS `login(1)` session argv, matching the darwin
//! branch of ghostty's own `execCommand` in
//! `ghostty/src/termio/Exec.zig`. ghostty's darwin `execCommand`
//! interpolates its command string raw, as `exec -l {s}`; it has no
//! quoting helper because it passes a whole command line. Calyx passes
//! a pathname (`$SHELL`), so it single-quotes it here (see
//! [`shell_single_quote`]), which keeps a path containing spaces
//! working. A consequence: a `$SHELL` value containing a `/` must be
//! an absolute path to an executable regular file, and a bare name
//! (no `/`) must be a single word; either failure is rejected at the
//! daemon boundary so it reaches the client as a spawn error instead
//! of bash's `exec -l` printing `not found` inside an already-started
//! session while `login` itself still exits 0.
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
//! which bash's `exec -l` restores instead. `-q` is always passed
//! because this session is not a new login from the user's point of
//! view: the pane that runs the attach client was itself started
//! through `login(1)` by libghostty (or the user typed `attach` into a
//! terminal that already showed its own banner), so that login already
//! printed `Last login:` and honored `~/.hushlogin`; a banner here
//! would only report that pane-side login as the last one. bash runs
//! with `--noprofile --norc` so no user startup file runs before the
//! final exec.
//!
//! `/usr/bin/login` requires fd 0 to already be the PTY slave, which
//! `spawn_session`'s `pre_exec` (setsid + `TIOCSCTTY`, applied after
//! Rust's stdio dup2) guarantees.
//!
//! Prepending `-` to argv0 alone is not used instead of `login(1)`
//! because `getlogin()`, the `SHELL`/`USER`/`LOGNAME` variables, and
//! utmpx would all differ from ordinary ghostty panes.
//!
//! The shell to exec comes from [`choose_shell`]: the passwd entry
//! for the current uid, looked up through the same `nix::unistd::User`
//! call login itself effectively makes, is the one authoritative
//! source of a user's login shell (and what `login(1)` writes into
//! the session's own `SHELL` variable); `$SHELL` is honored first
//! when it is set and non-empty because it is the user's explicit
//! per-session choice, the same order ghostty uses. When `$SHELL`
//! contains a `/`, it must be an absolute path, and that path must
//! exist and be executable; either failure is rejected at the daemon
//! boundary so it reaches the client as a spawn error, rather than
//! surfacing as bash's `exec -l` printing `not found` inside an
//! already-started session while `login` itself still exits 0. The
//! passwd entry's shell is validated the same way: it must be an
//! absolute path that exists and is executable.
//!
//! If the daemon cannot resolve the passwd entry for its own uid, it
//! cannot build a login(1) session at all (no username, no passwd
//! shell to fall back to). That is the documented degraded state of a
//! daemon that lost its
//! spawning app's jetsam coalition and can no longer reach
//! opendirectoryd (`crate::health`, `warn_user_lookup_may_be_broken`
//! in the CLI's `attach` command); the production launchd-owned
//! daemon never enters it. In that state the daemon starts `$SHELL`
//! directly, without `login(1)`, and logs a warning to its own
//! stderr; `$SHELL` unset in that state is still a hard error, since
//! there is then no shell of any kind to start.

#[cfg(any(target_os = "macos", test))]
use std::path::Path;

/// Builds `["/usr/bin/login", "-q", "-flp", username, "/bin/bash",
/// "--noprofile", "--norc", "-c", "exec -l '<shell>'"]`, matching
/// ghostty's own login-shell argv layout with `-q` always present.
#[cfg(any(target_os = "macos", test))]
pub(crate) fn login_session_argv(username: &str, shell: &str) -> Vec<String> {
    vec![
        "/usr/bin/login".to_string(),
        "-q".to_string(),
        "-flp".to_string(),
        username.to_string(),
        "/bin/bash".to_string(),
        "--noprofile".to_string(),
        "--norc".to_string(),
        "-c".to_string(),
        format!("exec -l {}", shell_single_quote(shell)),
    ]
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
/// without consulting `is_executable`, provided it is a single word:
/// it is resolved through the session's `PATH` by bash's `exec -l`,
/// the same PATH resolution `Command::new` performs for a bare name.
/// A bare name containing whitespace is rejected (without consulting
/// `is_executable`), since `exec -l` would otherwise split it into a
/// command and arguments. A path (containing `/`) must be absolute
/// (checked without consulting `is_executable`) and pass
/// `is_executable`, so a relative, stale, or misspelled `$SHELL` is
/// rejected here, at the daemon boundary, rather than surfacing later
/// as bash's `exec -l` printing `exec: ...: not found` inside an
/// already-started session while `login` itself still exits 0.
/// `passwd_shell` is validated the same way: it must be an absolute
/// path that passes `is_executable`, or `choose_shell` returns `Err`
/// naming the path, for the same reason.
#[cfg(any(target_os = "macos", test))]
pub(crate) fn choose_shell(
    env_shell: Option<&str>,
    passwd_shell: Option<&Path>,
    is_executable: impl Fn(&Path) -> bool,
) -> Result<String, String> {
    if let Some(shell) = env_shell.filter(|s| !s.is_empty()) {
        if shell.contains('/') {
            let path = Path::new(shell);
            if !path.is_absolute() {
                return Err(format!(
                    "SHELL is set to {shell}, which is not an absolute path; SHELL must be an \
                     absolute path"
                ));
            }
            if !is_executable(path) {
                return Err(format!(
                    "SHELL is set to {shell}, which is not an executable file"
                ));
            }
        } else if shell.contains(char::is_whitespace) {
            return Err(format!(
                "SHELL is set to {shell}, which contains whitespace; SHELL must be a single \
                 command name or an absolute path"
            ));
        }
        return Ok(shell.to_string());
    }

    match passwd_shell {
        Some(path) => {
            if !path.is_absolute() {
                return Err(format!(
                    "the passwd entry's login shell {} is not an absolute path",
                    path.display()
                ));
            }
            if !is_executable(path) {
                return Err(format!(
                    "the passwd entry's login shell {} is not an executable file",
                    path.display()
                ));
            }
            path.to_str().map(str::to_string).ok_or_else(|| {
                format!(
                    "the passwd entry's shell {} is not valid UTF-8",
                    path.display()
                )
            })
        }
        None => Err(
            "cannot determine the user's shell: SHELL is unset and the passwd entry is \
             unavailable"
                .to_string(),
        ),
    }
}

/// True only for a regular file (symlinks followed) that the current
/// process may execute.
#[cfg(any(target_os = "macos", test))]
pub(crate) fn is_executable_file(path: &Path) -> bool {
    let is_regular_file = std::fs::metadata(path)
        .map(|meta| meta.is_file())
        .unwrap_or(false);
    is_regular_file && nix::unistd::access(path, nix::unistd::AccessFlags::X_OK).is_ok()
}

/// Resolves the argv for a default session (`spec.argv == None`). On
/// macOS this builds a real `login(1)` session for the current uid;
/// elsewhere it is `$SHELL` as-is, unchanged from prior behavior.
#[cfg(target_os = "macos")]
pub(crate) fn default_session_argv() -> Result<Vec<String>, String> {
    let env_shell = std::env::var("SHELL").ok();

    // `login(1)`'s own `-f` compares the caller's real uid with the
    // target user, so the real uid is the right key for this lookup
    // too.
    let uid = nix::unistd::getuid();

    let lookup = nix::unistd::User::from_uid(uid);
    match lookup {
        Ok(Some(user)) => {
            let shell = choose_shell(env_shell.as_deref(), Some(&user.shell), is_executable_file)?;
            Ok(login_session_argv(&user.name, &shell))
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
                is_executable_file,
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
    fn login_session_argv_matches_ghostty_layout_and_is_always_quiet() {
        let argv = login_session_argv("testuser", "/bin/zsh");
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
        let argv = login_session_argv("u", "/opt/it's here/zsh");
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

    #[test]
    fn choose_shell_rejects_relative_env_path_without_consulting_predicate() {
        let result = choose_shell(Some("bin/zsh"), None, |_| {
            panic!("is_executable must not be consulted for a relative path")
        });
        let err = result.expect_err("a relative SHELL path must be rejected");
        assert!(
            err.contains("bin/zsh"),
            "error message should name the offending value, got: {err}"
        );
        assert!(
            err.contains("absolute"),
            "error message should say the path must be absolute, got: {err}"
        );
    }

    #[test]
    fn choose_shell_rejects_bare_name_with_whitespace_without_consulting_predicate() {
        let result = choose_shell(Some("zsh -l"), None, |_| {
            panic!("is_executable must not be consulted for a bare name")
        });
        let err = result.expect_err("a SHELL value with whitespace must be rejected");
        assert!(
            err.contains("zsh -l"),
            "error message should name the offending value, got: {err}"
        );
        assert!(
            err.contains("absolute"),
            "error message should say SHELL must be a single command name or an absolute path, \
             got: {err}"
        );
    }

    #[test]
    fn choose_shell_accepts_absolute_env_path_unchanged() {
        let result = choose_shell(Some("/bin/zsh"), None, |_| true);
        assert_eq!(result, Ok("/bin/zsh".to_string()));
    }

    #[test]
    fn choose_shell_rejects_passwd_shell_that_is_not_executable() {
        let result = choose_shell(None, Some(Path::new("/bin/bash")), |_| false);
        assert_eq!(
            result,
            Err("the passwd entry's login shell /bin/bash is not an executable file".to_string())
        );
    }

    #[test]
    fn choose_shell_accepts_absolute_executable_passwd_shell() {
        let result = choose_shell(None, Some(Path::new("/bin/bash")), |_| true);
        assert_eq!(result, Ok("/bin/bash".to_string()));
    }

    #[test]
    fn choose_shell_rejects_passwd_shell_that_is_not_absolute() {
        let result = choose_shell(None, Some(Path::new("bin/bash")), |_| true);
        assert_eq!(
            result,
            Err("the passwd entry's login shell bin/bash is not an absolute path".to_string())
        );
    }

    #[test]
    fn is_executable_file_is_false_for_a_directory() {
        let dir = tempfile::tempdir().expect("create scratch tempdir");
        assert!(!is_executable_file(dir.path()));
    }

    #[test]
    fn is_executable_file_is_false_for_a_non_executable_file() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().expect("create scratch tempdir");
        let file_path = dir.path().join("not-executable");
        std::fs::write(&file_path, b"#!/bin/sh\n").expect("write scratch file");
        std::fs::set_permissions(&file_path, std::fs::Permissions::from_mode(0o644))
            .expect("set scratch file permissions");
        assert!(!is_executable_file(&file_path));
    }

    #[test]
    fn is_executable_file_is_true_for_an_executable_file() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().expect("create scratch tempdir");
        let file_path = dir.path().join("executable");
        std::fs::write(&file_path, b"#!/bin/sh\n").expect("write scratch file");
        std::fs::set_permissions(&file_path, std::fs::Permissions::from_mode(0o755))
            .expect("set scratch file permissions");
        assert!(is_executable_file(&file_path));
    }
}
