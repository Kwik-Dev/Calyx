//! Integration tests for `vt::Terminal::render_replay()` on a mirror
//! that has never been fed a byte.
//!
//! Core property under test: a mirror only needs a Replay payload once
//! it actually carries session output. `resize` alone does not count as
//! feeding, and a zero-length `feed` does not count either; only a real
//! byte having reached the terminal makes `render_replay()` emit the
//! RIS + `\x1b[3J` reset sequence that rebuilds the mirror's state on a
//! target terminal that is not blank (RIS restores default modes,
//! screens and tab stops; `3J` drops scrollback).

use vt::Terminal;

const SCROLLBACK_BYTES: u32 = 8 * 1024 * 1024;

#[test]
fn render_replay_of_a_never_fed_terminal_is_empty() {
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");
    let replay = t
        .render_replay()
        .expect("render replay from a fresh terminal");
    assert_eq!(
        replay,
        Vec::<u8>::new(),
        "a terminal that has never been fed a byte should render an empty \
         replay, got {replay:?}"
    );
}

#[test]
fn render_replay_after_a_resize_alone_is_still_empty() {
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");
    t.resize(100, 30).expect("resize terminal");
    let replay = t
        .render_replay()
        .expect("render replay after a resize with no feed");
    assert_eq!(
        replay,
        Vec::<u8>::new(),
        "a resize alone must not count as feeding the terminal; replay \
         should still be empty, got {replay:?}"
    );
}

#[test]
fn render_replay_after_a_zero_length_feed_is_still_empty() {
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");
    t.feed(b"").expect("feed zero bytes");
    let replay = t
        .render_replay()
        .expect("render replay after a zero-length feed");
    assert_eq!(
        replay,
        Vec::<u8>::new(),
        "a zero-length feed must not count as feeding the terminal; replay \
         should still be empty, got {replay:?}"
    );
}

#[test]
fn render_replay_after_one_fed_byte_starts_with_the_blank_slate_sequence() {
    // Once a terminal has been fed any byte, its replay must still begin with
    // the RIS + 3J reset sequence, so the replay rebuilds the mirror's
    // state on a target terminal that is not blank. The `vt` crate has
    // no dependency on `proto`, so the prefix is written out literally
    // here; `crates/daemon/tests/attach.rs` pins the same prefix against
    // `proto::BLANK_SLATE`.
    let mut t = Terminal::new(80, 24, SCROLLBACK_BYTES).expect("create terminal");
    t.feed(b"x").expect("feed one byte");
    let replay = t
        .render_replay()
        .expect("render replay after feeding one byte");
    assert!(
        replay.starts_with(b"\x1bc\x1b[3J"),
        "replay after any feed should start with the blank-slate reset \
         sequence, got {replay:?}"
    );
}
