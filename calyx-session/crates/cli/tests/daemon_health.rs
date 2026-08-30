//! `ControlMsg::GetHealth` over a real, foreground, scratch-directory
//! daemon: a healthy daemon (its own `getpwuid(geteuid())` succeeds)
//! must reply `Health { user_lookup_ok: true }`.
//!
//! This does not exercise the CLI's subcommand surface (there is no
//! `calyx-session` subcommand for `GetHealth`; it is a probe the
//! launchd-owned attach path sends over a throwaway connection). It
//! instead talks the control-channel protocol directly against the
//! real `calyx-session daemon --foreground` binary, exactly as
//! `crates/daemon/tests/common/mod.rs`'s in-process harness does for
//! the daemon crate's own integration tests. `bin`/`wait_for_socket`
//! come from `tests/common/mod.rs`, shared across this crate's
//! integration tests; `roundtrip` stays local to this file, since no
//! other test here talks the control-channel protocol directly.
//!
//! `IO_TIMEOUT` bounds every read/write on the probe connection so a
//! daemon that accepts but never replies fails this test instead of
//! hanging the suite.

use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use proto::{
    decode_control, encode_control, ControlMsg, FrameReader, FrameType, FrameWriter,
    PROTOCOL_VERSION,
};

mod common;
use common::{bin, wait_for_socket, ChildGuard};

const IO_TIMEOUT: Duration = Duration::from_secs(5);

fn spawn_foreground_daemon(runtime_dir: &Path, state_dir: &Path) -> ChildGuard {
    let child = Command::new(bin())
        .args([
            "--runtime-dir".as_ref(),
            runtime_dir.as_os_str(),
            "--state-dir".as_ref(),
            state_dir.as_os_str(),
            "daemon".as_ref(),
            "--foreground".as_ref(),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn `calyx-session daemon --foreground`");
    let guard = ChildGuard(child);

    let socket_path = runtime_dir.join("sessiond.sock");
    assert!(
        wait_for_socket(&socket_path, Duration::from_secs(5)),
        "daemon --foreground should create {} within 5s",
        socket_path.display()
    );
    guard
}

/// Sends `msg` as a single `Control` frame and reads frames until a
/// non-`Event` `Control` frame arrives. Mirrors
/// `cli::commands::client::DaemonClient::request` and
/// `daemon`'s own `tests/common::roundtrip`.
fn roundtrip(stream: &UnixStream, msg: &ControlMsg) -> ControlMsg {
    let mut writer = FrameWriter::new(stream.try_clone().expect("clone stream for writer"));
    let payload = encode_control(msg).expect("encode control message");
    writer
        .write_frame(FrameType::Control, &payload)
        .expect("write control frame");
    let mut reader = FrameReader::new(stream.try_clone().expect("clone stream for reader"));
    loop {
        let frame = reader.read_frame().expect("read control reply frame");
        if frame.frame_type == FrameType::Control {
            let reply = decode_control(&frame.payload).expect("decode control reply");
            if matches!(reply, ControlMsg::Event(_)) {
                continue;
            }
            return reply;
        }
    }
}

#[test]
fn get_health_on_a_healthy_daemon_reports_user_lookup_ok_true() {
    let tempdir = tempfile::tempdir().expect("create scratch tempdir");
    let runtime_dir = tempdir.path().join("run");
    let state_dir = tempdir.path().join("state");
    let _guard = spawn_foreground_daemon(&runtime_dir, &state_dir);

    let socket_path = runtime_dir.join("sessiond.sock");
    let stream = UnixStream::connect(&socket_path).expect("connect to daemon socket");
    stream
        .set_read_timeout(Some(IO_TIMEOUT))
        .expect("set read timeout");
    stream
        .set_write_timeout(Some(IO_TIMEOUT))
        .expect("set write timeout");

    let hello_reply = roundtrip(
        &stream,
        &ControlMsg::Hello {
            version: PROTOCOL_VERSION,
        },
    );
    assert_eq!(
        hello_reply,
        ControlMsg::HelloOk {
            version: PROTOCOL_VERSION
        },
        "Hello handshake should succeed before probing health"
    );

    let health_reply = roundtrip(&stream, &ControlMsg::GetHealth);
    assert_eq!(
        health_reply,
        ControlMsg::Health {
            user_lookup_ok: true
        },
        "a freshly spawned, real-process daemon should report user_lookup_ok: true \
         (its own euid resolves via getpwuid under a normal test-runner process \
         context), got {health_reply:?}"
    );
}
