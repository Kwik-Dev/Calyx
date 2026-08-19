//! Regression test: a session shell must never see `CALYX_SURFACE_ID`,
//! whether it arrives via `SessionSpec.env` or is inherited from the
//! calyx-session daemon's own process environment. The calyx-session
//! daemon is long-lived and spawns every session's shell as its own
//! child process, so a `CALYX_SURFACE_ID` inherited from whichever
//! pane first started the daemon leaks into every session that daemon
//! spawns afterward, across Calyx restarts, giving every pane the
//! daemon's own stale surface UUID. `spawn_session` must remove
//! `CALYX_SURFACE_ID` from the child's environment after applying
//! `spec.env`.
//!
//! Both sources are covered from a single `#[test]`: the inherited
//! case needs `std::env::set_var` on this test process, which mutates
//! process-wide state, so it must never run concurrently with another
//! test thread that reads or writes the same variable. Each
//! `tests/*.rs` file compiles to its own separate Cargo test binary
//! (a separate OS process), so this mutation can never race a test
//! defined in another file regardless of thread count; what it *can*
//! race is another `#[test]` in this same file, since cargo runs
//! `#[test]` functions from one binary concurrently on different
//! threads by default. Keeping exactly one `#[test]` here removes that
//! hazard entirely: there is no other test thread in this binary to
//! race with.
//!
//! The inherited-path case sets `CALYX_SURFACE_ID` itself before
//! spawning the daemon rather than relying on the developer's own
//! terminal already lacking the variable, so this coverage does not
//! depend on the ambient shell environment.

mod common;

use std::time::{Duration, Instant};

use proto::{ControlMsg, FrameReader, FrameType, SessionSpec};

/// Overall bound on a single frame-accumulation loop while waiting for
/// the echoed `SID=[...]` line, so a session that never emits the
/// needle fails the test instead of hanging `cargo test` forever.
/// `common::IO_TIMEOUT` only bounds a single `read_frame` call, not
/// the loop around it.
const ACCUMULATE_TIMEOUT: Duration = Duration::from_secs(10);

/// Attaches a session that echoes `CALYX_SURFACE_ID` with `env` applied
/// via `SessionSpec.env`, accumulates frames until the echoed
/// `SID=[...]` line is complete, and returns everything accumulated so
/// far. Fails the test if the needle never arrives within
/// `ACCUMULATE_TIMEOUT`.
fn echo_surface_id(daemon: &common::ScratchDaemon, id: &str, env: Vec<(String, String)>) -> String {
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let spec = SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "echo \"SID=[$CALYX_SURFACE_ID]\"".to_string(),
        ]),
        env,
        cols: 80,
        rows: 24,
    };

    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Attach {
            id: id.to_string(),
            create: Some(spec),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip");
    assert!(matches!(reply, ControlMsg::AttachOk { .. }));

    let mut reader = FrameReader::new(stream.try_clone().expect("clone for reader"));
    let mut acc = Vec::new();
    let deadline = Instant::now() + ACCUMULATE_TIMEOUT;
    while Instant::now() < deadline {
        let frame = reader
            .read_frame()
            .expect("read frame while waiting for the echoed SID= line");
        if frame.frame_type == FrameType::Output || frame.frame_type == FrameType::Replay {
            acc.extend_from_slice(&frame.payload);
            let so_far = String::from_utf8_lossy(&acc);
            if let Some(start) = so_far.find("SID=[") {
                if so_far[start..].contains(']') {
                    return String::from_utf8_lossy(&acc).into_owned();
                }
            }
        }
    }
    panic!(
        "timed out after {ACCUMULATE_TIMEOUT:?} waiting for the echoed SID=[...] line; \
         accumulated so far: {:?}",
        String::from_utf8_lossy(&acc)
    );
}

#[test]
fn session_shell_never_sees_calyx_surface_id() {
    // Case 1: spec.env tries to set CALYX_SURFACE_ID directly.
    let daemon = common::ScratchDaemon::spawn();
    let output = echo_surface_id(
        &daemon,
        "surface-id-scrub-test-spec-env",
        vec![("CALYX_SURFACE_ID".to_string(), "bogus".to_string())],
    );
    assert!(
        output.contains("SID=[]"),
        "CALYX_SURFACE_ID must not leak into a session shell from spec.env, got {output:?}"
    );
    assert!(
        !output.contains("SID=[bogus]"),
        "spec.env's CALYX_SURFACE_ID value must be scrubbed, got {output:?}"
    );

    // Case 2: CALYX_SURFACE_ID is inherited from the daemon's own
    // process environment, exactly as it would be from whichever pane
    // first spawned a real calyx-session daemon. `ScratchDaemon::spawn`
    // runs `Daemon::bind(..).run_until_idle()` on a background thread
    // of this same process (see common::ScratchDaemon), and
    // `spawn_session` forks/execs synchronously while handling the
    // `Attach` message below, before it replies `AttachOk` (see
    // `conn.rs`'s Attach handler), so the variable only needs to stay
    // set through `echo_surface_id`'s round-trip, not for the rest of
    // the test process's life.
    //
    // Sound to call without a lock: this file has exactly one
    // `#[test]` (see module doc), so no other test thread in this
    // binary can observe or contend with the mutation. Not `unsafe`
    // here because this workspace is edition 2021; `std::env::set_var`
    // and `remove_var` only became `unsafe fn` starting edition 2024.
    std::env::set_var("CALYX_SURFACE_ID", "inherited-bogus");
    let daemon = common::ScratchDaemon::spawn();
    let output = echo_surface_id(&daemon, "surface-id-scrub-test-inherited", Vec::new());
    std::env::remove_var("CALYX_SURFACE_ID");
    assert!(
        output.contains("SID=[]"),
        "CALYX_SURFACE_ID must not leak into a session shell from the daemon's own \
         inherited environment, got {output:?}"
    );
    assert!(
        !output.contains("SID=[inherited-bogus]"),
        "an inherited CALYX_SURFACE_ID must be scrubbed too, not just one from spec.env, \
         got {output:?}"
    );
}
