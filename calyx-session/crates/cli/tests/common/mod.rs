//! Shared helpers for this crate's `calyx-session` subprocess-based
//! integration tests: resolving the built binary, waiting for a
//! daemon's control socket to appear, killing a spawned child on
//! drop, and draining a live child's stdout/stderr on a background
//! thread.
//!
//! Each `tests/*.rs` file is its own compiled crate with its own
//! `mod common;`, and no single one of them calls every helper here,
//! so `dead_code` would otherwise warn per binary for helpers that
//! other test files do use.
#![allow(dead_code)]

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Child;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Resolves the `calyx-session` binary built for this test run.
pub fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_calyx-session"))
}

/// Polls for `path` to exist, up to `timeout`, returning whether it
/// appeared in time. Used to bound the wait for a daemon's control
/// socket instead of hanging the suite when a daemon fails to start.
pub fn wait_for_socket(path: &Path, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

/// Kills and reaps the wrapped child on drop, so a spawned daemon or
/// attach client never outlives its test even when an assertion
/// before the guard is dropped panics.
pub struct ChildGuard(pub Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Drains `reader` into `acc` on a background thread until EOF or an
/// error. A live session's pipes never close on their own, so the
/// main thread must never block a direct `read` on them.
pub fn drain_into(mut reader: impl Read + Send + 'static, acc: Arc<Mutex<Vec<u8>>>) {
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => acc
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .extend_from_slice(&buf[..n]),
            }
        }
    });
}
