//! LaunchAgent installation for the launchd-owned session daemon
//! (macOS only): a double-forked daemon inherits the spawning
//! Calyx.app's jetsam coalition, and once that app quits the daemon's
//! process context can no longer reach opendirectoryd, so `getpwuid`
//! fails for every shell it later spawns.
//!
//! Contract this module owns (pinned by this file's `#[cfg(test)]`
//! tests):
//!
//! - `render_plist(program, runtime_dir, state_dir)`: a pure function
//!   producing the LaunchAgent plist XML. Label `com.calyx.sessiond`;
//!   `ProgramArguments` invokes `program` with `--runtime-dir
//!   <runtime_dir> --state-dir <state_dir> daemon --foreground
//!   --adopt-existing`; `RunAtLoad`/`KeepAlive` false (started
//!   on-demand via `launchctl kickstart`); `SoftResourceLimits
//!   NumberOfFiles` 4096 (this machine's `launchctl limit maxfiles`
//!   soft cap of 256 is not enough for a session daemon holding a PTY
//!   master + wake pipe + history fd per session); `StandardOutPath`/
//!   `StandardErrorPath` at `<state_dir>/daemon.log` (parity with the
//!   direct-spawn path's `detach_stdio`). XML-escapes every path
//!   value, since a path can contain `&`, `<`, or `>`.
//! - `Launchctl`: the `launchctl` invocation, behind a trait so tests
//!   never exec the real binary or touch a real launchd job.
//! - `LaunchAgentInstaller<L: Launchctl>`: idempotent installer, split
//!   into a file-installation step and a launchd-loading step so a
//!   caller can decide *when* it's safe to touch the running job. Every
//!   one of these operations requires an `&InstallLock` (from
//!   `lock()`), so a caller controls exactly how much of the
//!   file-write-then-launchctl-call sequence is serialized against
//!   every other process touching this same LaunchAgent:
//!     - `lock()`: ensures `bin_dir` exists (mode `0700`) and takes a
//!       blocking exclusive flock on `<bin_dir>/.install.lock`, held by
//!       the returned `InstallLock` for as long as the caller keeps it
//!       alive. Two concurrent attaches (e.g. restoring several panes
//!       at once) must never interleave their `install_files` temp-file
//!       writes with each other's renames, nor interleave one's
//!       `bootout`/`bootstrap` window with another's `kickstart`,
//!       hence a single guard type covering both.
//!     - `install_files(lock, current_exe, runtime_dir, state_dir)`:
//!       holds a stable copy of `current_exe` (`<bin_dir>/calyx-session`),
//!       refreshed only when the source's `(len, mtime)` differs from
//!       the copy's, via an atomic same-directory rename (through a
//!       pid-unique temp file, mode and mtime finalized before the
//!       rename) so a running daemon's open inode is never invalidated
//!       and a concurrent installer in another process can never
//!       observe a half-written file. The copy's mtime is set to match
//!       the source's (`nix::sys::stat::utimensat`) before the rename,
//!       so a subsequent call with an unchanged source is a true
//!       no-op, not a copy made to look unchanged. Renders the plist
//!       for the stable copy and writes it (same atomic
//!       temp-then-rename pattern) to
//!       `<launch_agents_dir>/com.calyx.sessiond.plist` only if its
//!       content differs from what's already there (or nothing is
//!       there yet); a content-identical rewrite is skipped entirely
//!       (no write at all). Returns whether the plist changed
//!       (`InstallOutcome`); never calls `launchctl` itself.
//!     - `ensure_loaded(lock)`: loads the job if it isn't loaded yet
//!       (`bootstrap`, failure ignored -- the only way `bootstrap` on
//!       an already-loaded job fails is "already loaded", which is
//!       exactly the desired steady state, so there is nothing to
//!       distinguish and no need to shell out to `launchctl print` to
//!       tell the two cases apart). Never calls `bootout`, so it can
//!       never terminate a running daemon.
//!     - `reload(lock)`: `bootout` (failure ignored -- the job may not
//!       have been loaded) followed by `bootstrap`. This is the one
//!       operation that can kill a running daemon, so callers must
//!       only invoke it when they've already confirmed nothing is
//!       being killed that matters (see `commands::attach`'s
//!       `connect_via_launchd`: only when the socket is unreachable
//!       *and* the plist just changed).
//!     - `kickstart(lock)`: `launchctl kickstart -p`. If that fails
//!       (e.g. the job isn't loaded at all, because a user manually ran
//!       `bootout`), tries one `bootstrap`-and-retry, but tolerates a
//!       failure from that intervening `bootstrap` (by the time a
//!       caller reaches `kickstart`, `ensure_loaded` has almost always
//!       already loaded the job, so this `bootstrap` typically fails
//!       "already loaded"; only the retried `kickstart`'s own result
//!       decides success, and a caller that also fails the retry sees
//!       the ORIGINAL `kickstart` error, not the unrelated bootstrap
//!       one).
//!
//!   `current_exe` is an explicit parameter to `install_files` rather
//!   than read internally via `std::env::current_exe()`: the freshness
//!   tests below need to mutate a stand-in binary's own `(len,
//!   mtime)` between two `install_files` calls, which is impossible
//!   against the real running test binary's own executable. Production
//!   wiring passes `std::env::current_exe()?` at the call site.
//!
//! Every test below constructs `LaunchAgentInstaller` directly against
//! tempdir-scoped `launch_agents_dir`/`bin_dir` fields and a
//! call-recording `FakeLaunchctl`, per this crate's existing seam
//! requirement (`tests/adopt_existing.rs` and this module never touch
//! a real `~/Library/LaunchAgents` or `~/.calyx/bin`).

use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use nix::fcntl::{Flock, FlockArg};
use nix::sys::stat::{utimensat, UtimensatFlags};
use nix::sys::time::TimeSpec;

/// LaunchAgent label, shared by the plist's own `Label` key and every
/// `launchctl` invocation naming this job (`gui/<uid>/<LABEL>`).
const LABEL: &str = "com.calyx.sessiond";

/// The `launchctl` invocation, behind a trait so tests never exec the
/// real binary or touch a real launchd job.
pub(crate) trait Launchctl {
    /// `launchctl bootstrap gui/<uid> <plist>`.
    fn bootstrap(&self, plist: &Path) -> io::Result<()>;
    /// `launchctl bootout gui/<uid>/<LABEL>`.
    fn bootout(&self) -> io::Result<()>;
    /// `launchctl kickstart -p gui/<uid>/<LABEL>`.
    fn kickstart(&self) -> io::Result<()>;
}

/// Runs `launchctl` via `Command::output()`, never `Command::status()`:
/// `connect_via_launchd` runs on the real pane's tty, before the raw
/// mode guard engages, so inheriting stdio (`status()`'s default) would
/// leak `kickstart -p`'s printed PID or a `bootout` failure line
/// straight into the user's terminal ahead of the session replay.
/// `output()` captures both stdout and stderr instead of discarding
/// them (`Stdio::null()`), because this module never falls back to a
/// direct daemon spawn on a `launchctl` failure: the caller needs
/// `launchctl`'s own stderr folded into the returned `io::Error` so the
/// user actually sees why it failed.
fn run_launchctl(args: &[&std::ffi::OsStr]) -> io::Result<()> {
    let output = std::process::Command::new("launchctl")
        .args(args)
        .output()?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(io::Error::other(format!(
            "launchctl {:?} exited with {}: {}",
            args,
            output.status,
            stderr.trim()
        )))
    }
}

/// Production `Launchctl`: execs the real `launchctl` binary against
/// this user's GUI domain (`gui/<uid>`, the domain a logged-in user's
/// LaunchAgents run in).
pub(crate) struct SystemLaunchctl {
    uid: u32,
}

impl SystemLaunchctl {
    pub(crate) fn new() -> SystemLaunchctl {
        SystemLaunchctl {
            uid: nix::unistd::getuid().as_raw(),
        }
    }

    fn service_target(&self) -> String {
        format!("gui/{}/{LABEL}", self.uid)
    }

    fn domain_target(&self) -> String {
        format!("gui/{}", self.uid)
    }
}

impl Launchctl for SystemLaunchctl {
    fn bootstrap(&self, plist: &Path) -> io::Result<()> {
        run_launchctl(&[
            "bootstrap".as_ref(),
            self.domain_target().as_ref(),
            plist.as_os_str(),
        ])
    }

    fn bootout(&self) -> io::Result<()> {
        run_launchctl(&["bootout".as_ref(), self.service_target().as_ref()])
    }

    fn kickstart(&self) -> io::Result<()> {
        run_launchctl(&[
            "kickstart".as_ref(),
            "-p".as_ref(),
            self.service_target().as_ref(),
        ])
    }
}

/// Escapes a path for use as a plist `<string>` value: `&` must be
/// escaped first so a later-inserted `&lt;`/`&gt;` doesn't itself get
/// re-escaped.
fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Renders the LaunchAgent plist XML. See the module doc for the full
/// contract (label, `ProgramArguments`, `RunAtLoad`/`KeepAlive`,
/// resource limit, log redirect).
pub(crate) fn render_plist(program: &Path, runtime_dir: &Path, state_dir: &Path) -> String {
    let program = xml_escape(&program.display().to_string());
    let runtime_dir_str = xml_escape(&runtime_dir.display().to_string());
    let state_dir_str = xml_escape(&state_dir.display().to_string());
    let log_path = xml_escape(&state_dir.join("daemon.log").display().to_string());

    let args = [
        program.as_str(),
        "--runtime-dir",
        runtime_dir_str.as_str(),
        "--state-dir",
        state_dir_str.as_str(),
        "daemon",
        "--foreground",
        "--adopt-existing",
    ];
    let program_arguments: String = args
        .iter()
        .map(|arg| format!("        <string>{arg}</string>\n"))
        .collect();

    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LABEL}</string>
    <key>ProgramArguments</key>
    <array>
{program_arguments}    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <false/>
    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>4096</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>{log_path}</string>
    <key>StandardErrorPath</key>
    <string>{log_path}</string>
</dict>
</plist>
"#
    )
}

/// Idempotent LaunchAgent installer. See the module doc for `install`'s
/// full contract.
pub(crate) struct LaunchAgentInstaller<L: Launchctl> {
    launch_agents_dir: PathBuf,
    bin_dir: PathBuf,
    launchctl: L,
}

impl LaunchAgentInstaller<SystemLaunchctl> {
    /// The real installer: `$HOME/Library/LaunchAgents` and
    /// `$HOME/.calyx/bin`.
    pub(crate) fn system() -> io::Result<LaunchAgentInstaller<SystemLaunchctl>> {
        let home = std::env::var_os("HOME").ok_or_else(|| {
            io::Error::other("HOME must be set to install the calyx-session LaunchAgent")
        })?;
        let home = PathBuf::from(home);
        Ok(LaunchAgentInstaller {
            launch_agents_dir: home.join("Library").join("LaunchAgents"),
            bin_dir: home.join(".calyx").join("bin"),
            launchctl: SystemLaunchctl::new(),
        })
    }
}

/// Whether `install_files` changed the on-disk plist. `reload()` (which
/// can kill a running daemon via `bootout`) must only be considered
/// when this is `PlistUpdated`, and even then only once the caller has
/// also confirmed the socket is unreachable; see `commands::attach`'s
/// `connect_via_launchd`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum InstallOutcome {
    Unchanged,
    PlistUpdated,
}

/// Holds the process-exclusive install lock (`<bin_dir>/.install.lock`)
/// for as long as it is kept alive. `LaunchAgentInstaller::lock`
/// returns one; every other method that touches installed files or
/// calls `launchctl` requires a reference to it, so a caller decides
/// exactly which sequence of those calls is serialized against every
/// other process's use of this same LaunchAgent.
pub(crate) struct InstallLock {
    _flock: Flock<std::fs::File>,
}

impl<L: Launchctl> LaunchAgentInstaller<L> {
    fn plist_path(&self) -> PathBuf {
        self.launch_agents_dir.join(format!("{LABEL}.plist"))
    }

    fn stable_copy_path(&self) -> PathBuf {
        self.bin_dir.join("calyx-session")
    }

    fn install_lock_path(&self) -> PathBuf {
        self.bin_dir.join(".install.lock")
    }

    /// Creates `bin_dir` (mode `0700`) if needed and takes a blocking
    /// exclusive flock on `<bin_dir>/.install.lock`, held by the
    /// returned guard for as long as the caller keeps it alive. Every
    /// other method on this installer requires an `&InstallLock`, so a
    /// caller decides exactly how much of the file-write-then-launchctl
    /// sequence stays serialized against every other process touching
    /// this same LaunchAgent (two attaches racing to install, e.g.
    /// several panes restoring at once, must never interleave their
    /// temp-file renames, nor interleave one's `bootout`/`bootstrap`
    /// window with another's `kickstart`).
    pub(crate) fn lock(&self) -> io::Result<InstallLock> {
        std::fs::create_dir_all(&self.bin_dir)?;
        std::fs::set_permissions(&self.bin_dir, std::fs::Permissions::from_mode(0o700))?;

        let lock_file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.install_lock_path())?;
        let flock = Flock::lock(lock_file, FlockArg::LockExclusive)
            .map_err(|(_file, errno)| io::Error::from(errno))?;
        Ok(InstallLock { _flock: flock })
    }

    /// Ensures `bin_dir` holds a stable copy of `current_exe` and
    /// `launch_agents_dir` holds a plist pointing at it, without ever
    /// calling `launchctl`. See the module doc for the full contract.
    pub(crate) fn install_files(
        &self,
        _lock: &InstallLock,
        current_exe: &Path,
        runtime_dir: &Path,
        state_dir: &Path,
    ) -> io::Result<InstallOutcome> {
        std::fs::create_dir_all(&self.launch_agents_dir)?;

        self.refresh_stable_copy(current_exe)?;

        let plist = render_plist(&self.stable_copy_path(), runtime_dir, state_dir);
        let plist_path = self.plist_path();
        let unchanged = std::fs::read_to_string(&plist_path)
            .map(|existing| existing == plist)
            .unwrap_or(false);
        if unchanged {
            return Ok(InstallOutcome::Unchanged);
        }

        let tmp_plist = self
            .launch_agents_dir
            .join(tmp_file_name(&format!("{LABEL}.plist")));
        std::fs::write(&tmp_plist, &plist)?;
        std::fs::rename(&tmp_plist, &plist_path)?;
        Ok(InstallOutcome::PlistUpdated)
    }

    /// Loads the job if it isn't loaded yet. Never calls `bootout`, so
    /// this can never terminate a running daemon: the only way
    /// `bootstrap` fails against an already-loaded job is "already
    /// loaded", which is silently treated as success rather than
    /// disambiguated via `launchctl print` (whose output format this
    /// module deliberately never parses).
    pub(crate) fn ensure_loaded(&self, _lock: &InstallLock) -> io::Result<()> {
        let _ = self.launchctl.bootstrap(&self.plist_path());
        Ok(())
    }

    /// `bootout` (failure ignored: the job may not have been loaded)
    /// followed by `bootstrap`. Can terminate a running daemon; callers
    /// must only invoke this once they've confirmed doing so is safe.
    pub(crate) fn reload(&self, _lock: &InstallLock) -> io::Result<()> {
        let _ = self.launchctl.bootout();
        self.launchctl.bootstrap(&self.plist_path())
    }

    /// Refreshes `bin_dir/calyx-session` from `current_exe` only when
    /// their `(len, mtime)` differ, via an atomic same-directory
    /// rename through a pid-unique temp file (mode and mtime finalized
    /// before the rename, so a concurrent freshness check never
    /// observes a mid-write mtime) so a running daemon's open inode is
    /// never invalidated.
    fn refresh_stable_copy(&self, current_exe: &Path) -> io::Result<()> {
        let source_meta = std::fs::metadata(current_exe)?;
        let stable_copy = self.stable_copy_path();

        if let Ok(copy_meta) = std::fs::metadata(&stable_copy) {
            if copy_meta.len() == source_meta.len()
                && mtime_ts(&copy_meta) == mtime_ts(&source_meta)
            {
                return Ok(());
            }
        }

        let tmp_path = self.bin_dir.join(tmp_file_name(".calyx-session"));
        std::fs::copy(current_exe, &tmp_path)?;
        std::fs::set_permissions(&tmp_path, std::fs::Permissions::from_mode(0o755))?;
        let ts = mtime_ts(&source_meta);
        utimensat(
            nix::fcntl::AT_FDCWD,
            &tmp_path,
            &ts,
            &ts,
            UtimensatFlags::FollowSymlink,
        )
        .map_err(io::Error::from)?;
        std::fs::rename(&tmp_path, &stable_copy)?;
        Ok(())
    }

    /// `launchctl kickstart`, with one retry: if the job isn't loaded
    /// (e.g. a user manually ran `bootout`), `bootstrap` it once and
    /// retry `kickstart` once more before giving up. The intervening
    /// `bootstrap`'s own failure is tolerated (`let _ =`): a caller
    /// always calls `ensure_loaded` (which itself bootstraps) before
    /// ever reaching `kickstart`, so by the time this retry runs the
    /// job is essentially always already loaded, and `bootstrap`
    /// against an already-loaded job fails "already loaded" -- a
    /// failure this retry exists to route around, not surface. If the
    /// retried `kickstart` also fails, the ORIGINAL `kickstart` error is
    /// returned, not the unrelated bootstrap one, so a caller sees the
    /// real cause instead of a misleading "already loaded".
    pub(crate) fn kickstart(&self, _lock: &InstallLock) -> io::Result<()> {
        match self.launchctl.kickstart() {
            Ok(()) => Ok(()),
            Err(first) => {
                let _ = self.launchctl.bootstrap(&self.plist_path());
                self.launchctl.kickstart().map_err(|_| first)
            }
        }
    }
}

fn mtime_ts(meta: &std::fs::Metadata) -> TimeSpec {
    TimeSpec::new(meta.mtime(), meta.mtime_nsec())
}

/// A pid-unique temp-file name for the given `prefix`, used for both
/// the stable binary copy and the plist: two concurrent installers in
/// different processes (e.g. two attaches racing to restore panes)
/// must never write through the same temp path, even though the
/// `InstallLock` flock already serializes writers within a single
/// process's view of one `bin_dir`/`launch_agents_dir` pair.
fn tmp_file_name(prefix: &str) -> String {
    format!("{prefix}.{}.tmp", std::process::id())
}

#[cfg(test)]
mod tests {
    use std::io;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::path::Path;
    use std::sync::Mutex;
    use std::thread;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use nix::sys::stat::{utimensat, UtimensatFlags};
    use nix::sys::time::TimeSpec;

    use super::*;

    /// Records every call it receives instead of exec'ing a real
    /// `launchctl`, so these tests can never affect a real launchd
    /// job. `kickstart_failures_remaining`/`bootstrap_should_fail` let a
    /// test script a transient failure (e.g. "the job isn't loaded
    /// yet") on the next N `kickstart` calls, or make every `bootstrap`
    /// call fail (e.g. "already loaded"), to pin `kickstart`'s own
    /// retry-and-error-surfacing contract.
    struct FakeLaunchctl {
        bootstrap_calls: Mutex<Vec<std::path::PathBuf>>,
        bootout_calls: Mutex<u32>,
        kickstart_calls: Mutex<u32>,
        kickstart_failures_remaining: Mutex<u32>,
        bootstrap_should_fail: bool,
    }

    impl FakeLaunchctl {
        fn new() -> FakeLaunchctl {
            FakeLaunchctl {
                bootstrap_calls: Mutex::new(Vec::new()),
                bootout_calls: Mutex::new(0),
                kickstart_calls: Mutex::new(0),
                kickstart_failures_remaining: Mutex::new(0),
                bootstrap_should_fail: false,
            }
        }

        /// The next `n` calls to `kickstart` fail; calls after that
        /// succeed normally.
        fn with_kickstart_failures(self, n: u32) -> FakeLaunchctl {
            *self.kickstart_failures_remaining.lock().unwrap() = n;
            self
        }

        /// Every call to `bootstrap` fails.
        fn with_failing_bootstrap(mut self) -> FakeLaunchctl {
            self.bootstrap_should_fail = true;
            self
        }
    }

    impl Launchctl for FakeLaunchctl {
        fn bootstrap(&self, plist: &Path) -> io::Result<()> {
            self.bootstrap_calls
                .lock()
                .unwrap()
                .push(plist.to_path_buf());
            if self.bootstrap_should_fail {
                return Err(io::Error::other("fake bootstrap failure: already loaded"));
            }
            Ok(())
        }

        fn bootout(&self) -> io::Result<()> {
            *self.bootout_calls.lock().unwrap() += 1;
            Ok(())
        }

        fn kickstart(&self) -> io::Result<()> {
            let mut remaining = self.kickstart_failures_remaining.lock().unwrap();
            if *remaining > 0 {
                *remaining -= 1;
                return Err(io::Error::other("fake kickstart failure: no such service"));
            }
            drop(remaining);
            *self.kickstart_calls.lock().unwrap() += 1;
            Ok(())
        }
    }

    /// A tempdir-scoped fixture: `launch_agents_dir`/`bin_dir` for the
    /// installer's own outputs, plus a stand-in `src_dir/calyx-session`
    /// playing the role `std::env::current_exe()` plays in production.
    struct Fixture {
        _tempdir: tempfile::TempDir,
        launch_agents_dir: std::path::PathBuf,
        bin_dir: std::path::PathBuf,
        current_exe: std::path::PathBuf,
    }

    fn fixture(source_contents: &[u8]) -> Fixture {
        let tempdir = tempfile::tempdir().expect("create scratch tempdir");
        let launch_agents_dir = tempdir.path().join("LaunchAgents");
        let bin_dir = tempdir.path().join("bin");
        let src_dir = tempdir.path().join("src");
        std::fs::create_dir_all(&src_dir).expect("create scratch src dir");
        let current_exe = src_dir.join("calyx-session");
        std::fs::write(&current_exe, source_contents).expect("write stand-in source binary");
        Fixture {
            _tempdir: tempdir,
            launch_agents_dir,
            bin_dir,
            current_exe,
        }
    }

    fn installer(fx: &Fixture) -> LaunchAgentInstaller<FakeLaunchctl> {
        LaunchAgentInstaller {
            launch_agents_dir: fx.launch_agents_dir.clone(),
            bin_dir: fx.bin_dir.clone(),
            launchctl: FakeLaunchctl::new(),
        }
    }

    fn plist_path(fx: &Fixture) -> std::path::PathBuf {
        fx.launch_agents_dir.join("com.calyx.sessiond.plist")
    }

    fn set_mtime(path: &Path, when: SystemTime) {
        let since_epoch = when
            .duration_since(UNIX_EPOCH)
            .expect("test mtime should be after the epoch");
        let ts = TimeSpec::new(
            since_epoch.as_secs() as i64,
            since_epoch.subsec_nanos() as i64,
        );
        // `nix::fcntl::AT_FDCWD`, not `None`: nix 0.31's `utimensat`
        // takes a `Fd: AsFd` dirfd directly (no `Option` overload), so
        // `path` being absolute (dirfd ignored either way) still needs
        // a real `AsFd` value here.
        utimensat(
            nix::fcntl::AT_FDCWD,
            path,
            &ts,
            &ts,
            UtimensatFlags::FollowSymlink,
        )
        .expect("set mtime on stand-in binary");
    }

    /// The full plist contract: label, `ProgramArguments` pointing at
    /// the stable copy with the required flags, `RunAtLoad`/`KeepAlive`
    /// off, the resource limit, and the log redirect.
    #[test]
    fn install_writes_a_plist_matching_the_full_launchd_contract() {
        let fx = fixture(b"original binary contents");
        let runtime_dir = fx._tempdir.path().join("run");
        let state_dir = fx._tempdir.path().join("state");

        let inst = installer(&fx);
        let lock = inst.lock().expect("take install lock");
        inst.install_files(&lock, &fx.current_exe, &runtime_dir, &state_dir)
            .expect("install_files should succeed");

        let plist = std::fs::read_to_string(plist_path(&fx)).expect("read installed plist");
        let stable_copy = fx.bin_dir.join("calyx-session");
        let stable_copy_str = stable_copy.to_str().expect("stable copy path is utf-8");
        let runtime_str = runtime_dir.to_str().expect("runtime dir path is utf-8");
        let state_str = state_dir.to_str().expect("state dir path is utf-8");

        assert!(
            plist.contains("<key>Label</key>")
                && plist.contains("<string>com.calyx.sessiond</string>"),
            "plist should declare Label com.calyx.sessiond, got:\n{plist}"
        );
        assert!(
            plist.contains(stable_copy_str),
            "ProgramArguments should invoke the stable copy at {stable_copy_str}, got:\n{plist}"
        );
        assert!(
            plist.contains(runtime_str) && plist.contains(state_str),
            "ProgramArguments should pass --runtime-dir/--state-dir, got:\n{plist}"
        );
        assert!(
            plist.contains("--foreground") && plist.contains("--adopt-existing"),
            "ProgramArguments should include `daemon --foreground --adopt-existing`, got:\n{plist}"
        );
        // Whitespace-stripped so key/value adjacency can be checked
        // regardless of the exact indentation/newlines the renderer
        // uses between a `<key>` tag and its value tag.
        let squashed: String = plist.chars().filter(|c| !c.is_whitespace()).collect();
        assert!(
            squashed.contains("<key>RunAtLoad</key><false/>"),
            "RunAtLoad must be false (kickstart-driven, on-demand start): asserting \
             the key's own value tag, not merely that `<false/>` occurs somewhere \
             else in the plist, got:\n{plist}"
        );
        assert!(
            squashed.contains("<key>KeepAlive</key><false/>"),
            "KeepAlive must be false (launchd never restarts this job on its own; \
             kickstart is the only start trigger), got:\n{plist}"
        );
        assert!(
            plist.contains("<key>NumberOfFiles</key>") && plist.contains("<integer>4096</integer>"),
            "SoftResourceLimits/NumberOfFiles must be 4096 (this machine's default \
             soft cap of 256 is not enough for a session daemon), got:\n{plist}"
        );
        let expected_log = state_dir.join("daemon.log");
        let expected_log_str = expected_log.to_str().expect("log path is utf-8");
        assert!(
            plist.contains("<key>StandardOutPath</key>")
                && plist.contains("<key>StandardErrorPath</key>"),
            "plist should declare both StandardOutPath and StandardErrorPath, got:\n{plist}"
        );
        assert_eq!(
            plist.matches(expected_log_str).count(),
            2,
            "both StandardOutPath and StandardErrorPath should point at \
             <state_dir>/daemon.log ({expected_log_str} should occur exactly twice, \
             once per key, not merely once for one of the two), got:\n{plist}"
        );
    }

    /// `install` must copy `current_exe` into `bin_dir/calyx-session`
    /// (mode 0755) rather than pointing the plist at a Sparkle-mutable
    /// app-bundle path.
    #[test]
    fn install_copies_current_exe_into_bin_dir_as_a_stable_executable_copy() {
        let fx = fixture(b"original binary contents");
        let runtime_dir = fx._tempdir.path().join("run");
        let state_dir = fx._tempdir.path().join("state");

        let inst = installer(&fx);
        let lock = inst.lock().expect("take install lock");
        inst.install_files(&lock, &fx.current_exe, &runtime_dir, &state_dir)
            .expect("install_files should succeed");

        let stable_copy = fx.bin_dir.join("calyx-session");
        let copied = std::fs::read(&stable_copy).expect("read stable copy");
        assert_eq!(copied, b"original binary contents");
        let mode = std::fs::metadata(&stable_copy)
            .expect("stat stable copy")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o755, "stable copy should be mode 0755, got {mode:o}");
    }

    /// Idempotency: `install_files` never calls `launchctl` at all (the
    /// whole point of splitting it from `ensure_loaded`/`reload`), and a
    /// second call with nothing changed reports `Unchanged` and leaves
    /// the plist's content and mtime untouched.
    #[test]
    fn install_files_called_twice_unchanged_returns_unchanged_and_does_not_rewrite_the_plist() {
        let fx = fixture(b"original binary contents");
        let runtime_dir = fx._tempdir.path().join("run");
        let state_dir = fx._tempdir.path().join("state");
        let inst = installer(&fx);
        let lock = inst.lock().expect("take install lock");

        let first_outcome = inst
            .install_files(&lock, &fx.current_exe, &runtime_dir, &state_dir)
            .expect("first install_files should succeed");
        assert_eq!(
            first_outcome,
            InstallOutcome::PlistUpdated,
            "the first call (no prior plist) should report PlistUpdated"
        );
        let plist_path = plist_path(&fx);
        let first_contents =
            std::fs::read_to_string(&plist_path).expect("read plist after first install_files");
        let first_mtime = std::fs::metadata(&plist_path)
            .expect("stat plist after first install_files")
            .modified()
            .expect("plist mtime after first install_files");
        assert_eq!(
            inst.launchctl.bootstrap_calls.lock().unwrap().len(),
            0,
            "install_files must never call launchctl itself"
        );
        assert_eq!(
            *inst.launchctl.bootout_calls.lock().unwrap(),
            0,
            "install_files must never call launchctl itself"
        );

        let second_outcome = inst
            .install_files(&lock, &fx.current_exe, &runtime_dir, &state_dir)
            .expect("second install_files should succeed");
        let second_contents =
            std::fs::read_to_string(&plist_path).expect("read plist after second install_files");
        let second_mtime = std::fs::metadata(&plist_path)
            .expect("stat plist after second install_files")
            .modified()
            .expect("plist mtime after second install_files");

        assert_eq!(
            second_outcome,
            InstallOutcome::Unchanged,
            "an unchanged second call should report Unchanged"
        );
        assert_eq!(
            first_contents, second_contents,
            "an unchanged install_files must not rewrite the plist's content"
        );
        assert_eq!(
            first_mtime, second_mtime,
            "an unchanged install_files must not touch the plist file at all (mtime unchanged)"
        );
    }

    /// `ensure_loaded` must call `bootstrap` but never `bootout`: it can
    /// never terminate a running daemon.
    #[test]
    fn ensure_loaded_bootstraps_and_never_calls_bootout() {
        let fx = fixture(b"original binary contents");
        let runtime_dir = fx._tempdir.path().join("run");
        let state_dir = fx._tempdir.path().join("state");
        let inst = installer(&fx);
        let lock = inst.lock().expect("take install lock");
        inst.install_files(&lock, &fx.current_exe, &runtime_dir, &state_dir)
            .expect("install_files should succeed");

        inst.ensure_loaded(&lock)
            .expect("ensure_loaded should succeed");

        assert_eq!(
            inst.launchctl.bootstrap_calls.lock().unwrap().len(),
            1,
            "ensure_loaded should bootstrap exactly once"
        );
        assert_eq!(
            *inst.launchctl.bootout_calls.lock().unwrap(),
            0,
            "ensure_loaded must never call bootout"
        );
    }

    /// `reload` must call both `bootout` and `bootstrap`: this is the
    /// one operation allowed to terminate a running daemon, so callers
    /// (`commands::attach::connect_via_launchd`) gate it behind
    /// `should_reload_before_kickstart`.
    #[test]
    fn reload_calls_both_bootout_and_bootstrap() {
        let fx = fixture(b"original binary contents");
        let runtime_dir = fx._tempdir.path().join("run");
        let state_dir = fx._tempdir.path().join("state");
        let inst = installer(&fx);
        let lock = inst.lock().expect("take install lock");
        inst.install_files(&lock, &fx.current_exe, &runtime_dir, &state_dir)
            .expect("install_files should succeed");

        inst.reload(&lock).expect("reload should succeed");

        assert_eq!(
            inst.launchctl.bootstrap_calls.lock().unwrap().len(),
            1,
            "reload should bootstrap exactly once"
        );
        assert_eq!(
            *inst.launchctl.bootout_calls.lock().unwrap(),
            1,
            "reload should bootout exactly once"
        );
    }

    /// `lock()` must serialize concurrent installers within the same
    /// process via a blocking exclusive flock on `bin_dir/.install.lock`:
    /// a second `lock()` call must block while a lock holder is still
    /// alive, and proceed only once that holder is dropped. This is
    /// what makes it safe to hold one `InstallLock` across
    /// `install_files`, `ensure_loaded`/`reload`, and `kickstart`
    /// together (R1's requirement that the whole launchd interaction,
    /// not just the file writes, be serialized against another
    /// process).
    #[test]
    fn lock_blocks_while_another_holder_has_the_install_lock() {
        let fx = fixture(b"original binary contents");
        let inst = std::sync::Arc::new(installer(&fx));
        // Ensure bin_dir (and thus the lock file's parent) exists
        // before this test's manual lock acquisition below.
        std::fs::create_dir_all(&fx.bin_dir).expect("create scratch bin dir");

        let lock_path = fx.bin_dir.join(".install.lock");
        let lock_file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&lock_path)
            .expect("open scratch install lock file");
        let held_lock =
            Flock::lock(lock_file, FlockArg::LockExclusive).expect("acquire scratch install lock");

        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let inst_thread = std::sync::Arc::clone(&inst);
        thread::spawn(move || {
            inst_thread
                .lock()
                .expect("lock() should eventually succeed once the held lock is released");
            done_tx.send(()).expect("send completion signal");
        });

        assert_eq!(
            done_rx.recv_timeout(Duration::from_millis(200)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout),
            "lock() must still be blocked on the install lock while it's held"
        );

        drop(held_lock);
        done_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("lock() should complete promptly once the lock is released");
    }

    /// Temp file names must be unique per process (include the pid), so
    /// two concurrent installer processes racing to install never write
    /// through the same temp path.
    #[test]
    fn tmp_file_name_includes_the_current_pid() {
        let name = tmp_file_name("calyx-session");
        assert!(
            name.contains(&std::process::id().to_string()),
            "temp file name should include the current pid, got {name:?}"
        );
    }

    /// A stale stable copy (its `(len, mtime)` differs from the
    /// source) must be refreshed, and the refreshed copy's mtime must
    /// be set to match the source's.
    #[test]
    fn install_files_refreshes_the_stable_copy_when_the_source_binary_changes() {
        let fx = fixture(b"original binary contents");
        let runtime_dir = fx._tempdir.path().join("run");
        let state_dir = fx._tempdir.path().join("state");
        let inst = installer(&fx);
        let lock = inst.lock().expect("take install lock");

        inst.install_files(&lock, &fx.current_exe, &runtime_dir, &state_dir)
            .expect("first install_files should succeed");

        // Change both length and mtime of the "source binary".
        std::fs::write(
            &fx.current_exe,
            b"a materially different, longer binary payload",
        )
        .expect("rewrite stand-in source binary");
        let new_mtime = SystemTime::now() + Duration::from_secs(120);
        set_mtime(&fx.current_exe, new_mtime);

        inst.install_files(&lock, &fx.current_exe, &runtime_dir, &state_dir)
            .expect("second install_files should succeed");

        let stable_copy = fx.bin_dir.join("calyx-session");
        let copied = std::fs::read(&stable_copy).expect("read refreshed stable copy");
        assert_eq!(
            copied, b"a materially different, longer binary payload",
            "the stable copy should be refreshed with the new source contents"
        );
        let copy_mtime = std::fs::metadata(&stable_copy)
            .expect("stat refreshed stable copy")
            .modified()
            .expect("refreshed stable copy mtime");
        let source_mtime = std::fs::metadata(&fx.current_exe)
            .expect("stat source after mtime change")
            .modified()
            .expect("source mtime after change");
        assert_eq!(
            copy_mtime, source_mtime,
            "the refreshed stable copy's mtime should be set to match the source's, \
             so a later install call with the same source sees no further difference"
        );
    }

    /// When the source binary's `(len, mtime)` are unchanged, `install`
    /// must not recreate the stable copy at all. Proven via inode
    /// identity: the documented refresh mechanism is an atomic
    /// same-directory rename, which replaces the inode, so an
    /// unchanged inode across two `install` calls proves no rewrite
    /// happened (rather than merely "a rewrite happened to produce
    /// identical bytes").
    #[test]
    fn install_files_does_not_recreate_the_stable_copy_when_the_source_is_unchanged() {
        let fx = fixture(b"original binary contents");
        let runtime_dir = fx._tempdir.path().join("run");
        let state_dir = fx._tempdir.path().join("state");
        let inst = installer(&fx);
        let lock = inst.lock().expect("take install lock");

        inst.install_files(&lock, &fx.current_exe, &runtime_dir, &state_dir)
            .expect("first install_files should succeed");
        let stable_copy = fx.bin_dir.join("calyx-session");
        let first_ino = std::fs::metadata(&stable_copy)
            .expect("stat stable copy after first install")
            .ino();

        inst.install_files(&lock, &fx.current_exe, &runtime_dir, &state_dir)
            .expect("second install_files should succeed");
        let second_ino = std::fs::metadata(&stable_copy)
            .expect("stat stable copy after second install")
            .ino();

        assert_eq!(
            first_ino, second_ino,
            "the stable copy's inode must be unchanged when the source binary is \
             unchanged, proving install did not rewrite (atomically rename a fresh \
             file over) an up-to-date copy"
        );
    }

    /// A caller always calls `ensure_loaded` (which bootstraps) before
    /// `kickstart`, so by the time `kickstart`'s own retry runs, the job
    /// is already loaded and its `bootstrap` typically fails "already
    /// loaded". `kickstart` must tolerate that failure and still
    /// succeed once the retried `kickstart` itself succeeds.
    #[test]
    fn kickstart_retry_tolerates_a_failing_bootstrap_and_still_succeeds() {
        let fx = fixture(b"original binary contents");
        let inst = LaunchAgentInstaller {
            launch_agents_dir: fx.launch_agents_dir.clone(),
            bin_dir: fx.bin_dir.clone(),
            launchctl: FakeLaunchctl::new()
                .with_kickstart_failures(1)
                .with_failing_bootstrap(),
        };
        let lock = inst.lock().expect("take install lock");

        inst.kickstart(&lock).expect(
            "kickstart should succeed once the retried kickstart succeeds, even though \
             the intervening bootstrap failed",
        );
    }

    /// If the retried `kickstart` also fails, the caller must see the
    /// ORIGINAL `kickstart` error, not the unrelated `bootstrap` one:
    /// otherwise a user is shown a misleading cause ("already loaded")
    /// for what is actually a `kickstart` failure.
    #[test]
    fn kickstart_surfaces_its_own_error_when_the_retry_also_fails() {
        let fx = fixture(b"original binary contents");
        let inst = LaunchAgentInstaller {
            launch_agents_dir: fx.launch_agents_dir.clone(),
            bin_dir: fx.bin_dir.clone(),
            launchctl: FakeLaunchctl::new()
                .with_kickstart_failures(2)
                .with_failing_bootstrap(),
        };
        let lock = inst.lock().expect("take install lock");

        let err = inst
            .kickstart(&lock)
            .expect_err("kickstart should fail when both attempts fail");
        assert!(
            err.to_string().contains("fake kickstart failure"),
            "the surfaced error should be kickstart's own, not bootstrap's, got: {err}"
        );
    }

    /// XML special characters in any of the three path inputs must be
    /// escaped, not passed through raw (a raw `&`/`<`/`>` inside a
    /// plist string value is malformed XML).
    #[test]
    fn render_plist_escapes_xml_special_characters_in_every_path() {
        let program = Path::new("/tmp/a&b/calyx-session");
        let runtime_dir = Path::new("/tmp/run<1>/dir");
        let state_dir = Path::new("/tmp/state&2</dir");

        let plist = render_plist(program, runtime_dir, state_dir);

        assert!(
            plist.contains("/tmp/a&amp;b/calyx-session"),
            "the program path's `&` must be escaped as `&amp;`, got:\n{plist}"
        );
        assert!(
            !plist.contains("/tmp/a&b/calyx-session"),
            "the program path must never appear with a raw, unescaped `&`, got:\n{plist}"
        );
        assert!(
            plist.contains("/tmp/run&lt;1&gt;/dir"),
            "the runtime dir path's `<`/`>` must be escaped as `&lt;`/`&gt;`, got:\n{plist}"
        );
        assert!(
            !plist.contains("/tmp/run<1>/dir"),
            "the runtime dir path must never appear with raw, unescaped `<`/`>` \
             (as opposed to plist's own `<key>`/`<string>` tags), got:\n{plist}"
        );
        assert!(
            plist.contains("/tmp/state&amp;2&lt;/dir"),
            "the state dir path's `&`/`<` must both be escaped, got:\n{plist}"
        );
    }
}
