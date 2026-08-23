//! Regression pin: `SessionSpec.env`'s `TERM` must win over the
//! daemon's own inherited `TERM`, exactly like `session_id_env.rs`
//! pins the same "spec.env applied on top of the daemon's own
//! environment via repeated `Command::env` calls, later call wins"
//! mechanism for `CALYX_SESSION_ID`.
//!
//! This pins existing behavior rather than driving new code:
//! `session.rs`'s `spawn_session` applies every `spec.env` pair via
//! `cmd.env(key, value)` on a `Command` that otherwise inherits the
//! daemon process's own environment, and a later `.env()` call always
//! overrides an inherited value for the same key. That is already the
//! case today, unmodified. The other half of the surrounding
//! contract, that `attach`'s launchd route re-supplies a `TERM` at all
//! (since launchd's own job environment never provides one), is pinned
//! separately in `crates/cli/src/commands/terminal_env.rs`. This file
//! exists so the daemon-side half of that contract has an explicit,
//! permanent regression guard rather than an implicit assumption.
//!
//! Exactly one `#[test]` in this file: it mutates `TERM` via
//! `std::env::set_var`, which is process-wide, unsynchronized state;
//! isolation from every other test in the workspace relies on each
//! `tests/*.rs` file compiling to its own separate test binary
//! process, not on any lock shared with `session_id_env.rs` or any
//! other file.

mod common;

use proto::{ControlMsg, FrameReader, FrameType, SessionSpec};

#[test]
fn spec_env_term_overrides_the_daemons_own_inherited_term() {
    // SAFETY (of the test's own isolation, not the call itself):
    // this is the only test in this file's binary, and it runs before
    // any daemon thread is spawned below, so nothing else in this
    // process can observe `TERM` mid-mutation.
    std::env::set_var(
        "TERM",
        "xterm-baseline-value-the-daemon-itself-inherits-for-this-test",
    );

    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let id = "01J-p6-spec-env-term-override-test".to_string();
    let s = SessionSpec {
        id: id.clone(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "echo \"TERM=$TERM\"".to_string(),
        ]),
        env: vec![(
            "TERM".to_string(),
            "xterm-value-supplied-by-spec-env".to_string(),
        )],
        cols: 80,
        rows: 24,
    };

    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Attach {
            id: id.clone(),
            create: Some(s),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip");
    assert!(matches!(reply, ControlMsg::AttachOk { .. }));

    let mut reader = FrameReader::new(stream.try_clone().expect("clone for reader"));
    let mut acc = Vec::new();
    loop {
        let frame = reader
            .read_frame()
            .expect("read frame while waiting for the echoed TERM= line");
        if frame.frame_type == FrameType::Output || frame.frame_type == FrameType::Replay {
            acc.extend_from_slice(&frame.payload);
            if String::from_utf8_lossy(&acc).contains("TERM=") {
                break;
            }
        }
    }

    let output = String::from_utf8_lossy(&acc);
    assert!(
        output.contains("TERM=xterm-value-supplied-by-spec-env"),
        "spec.env's TERM should win over the daemon's own inherited TERM, got {output:?}"
    );
    assert!(
        !output.contains("TERM=xterm-baseline-value-the-daemon-itself-inherits-for-this-test"),
        "the daemon's own inherited TERM must not leak through when spec.env sets TERM, \
         got {output:?}"
    );
}
