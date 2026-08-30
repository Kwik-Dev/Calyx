//! Length-prefixed framing over any `std::io::Read`/`Write` stream
//! (deliberately not tied to tokio: the daemon is the only crate that
//! needs async I/O, and it can drive these blocking readers/writers
//! from a dedicated thread or `spawn_blocking`).
//!
//! Wire format per frame: `u32` length in little-endian (the byte count
//! of the frame-type byte *plus* the payload that follows it), then one
//! `u8` frame-type byte, then the payload itself.

use std::io::{self, Read, Write};

use crate::error::ProtoError;

/// Upper bound on a single frame's `type byte + payload` length, chosen
/// to be comfortably larger than any single control message or a
/// generous PTY output chunk while still bounding a malicious/buggy
/// peer's ability to force an unbounded allocation.
pub const MAX_FRAME_LEN: u32 = 16 * 1024 * 1024;

/// RIS (`\x1bc`) restores default modes, screens and tab stops, and
/// `\x1b[3J` drops scrollback, which RIS alone leaves intact.
///
/// The daemon's Replay renderer (`shim/src/gvt.zig`) writes these bytes
/// first in every Replay payload rendered for a mirror terminal that
/// has been fed at least one byte, committing the attach's takeover of
/// the pane. A mirror that has never been fed renders an empty Replay
/// instead, because there is nothing to reconstruct, and the pane then
/// keeps whatever its host wrote before the attach (on macOS, the
/// `Last login:` banner of the `login(1)` wrapper libghostty starts
/// every pane command through), the same way a Ghostty pane keeps that
/// banner above the shell's first output. Such an attach also leaves
/// the target terminal's cursor and modes exactly where its host left
/// them, so the pane's rows sit below the mirror's by the height of
/// what the host wrote (the banner) until the first absolute cursor
/// positioning or full-screen redraw, and a later attach renders the
/// mirror's own rows without that offset; a terminal that an earlier
/// program left in a non-default mode (alternate screen, mouse
/// tracking) is not reset by such an attach, just as starting a shell
/// in it would not reset it.
///
/// `crates/daemon/tests/attach.rs` pins both the prefix for a fed
/// mirror and the empty payload for a never-fed one.
pub const BLANK_SLATE: &[u8] = b"\x1bc\x1b[3J";

/// Identifies what a frame's payload contains.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum FrameType {
    /// CBOR-encoded [`crate::ControlMsg`].
    Control = 1,
    /// Raw bytes typed by an attached client, destined for the PTY.
    Input = 2,
    /// Raw bytes the PTY produced, destined for attached clients.
    Output = 3,
    /// Raw bytes reconstructing a session's current state on attach,
    /// sent once immediately after `AttachOk` and before any `Output`.
    /// The payload begins with [`BLANK_SLATE`] when the session's
    /// mirror terminal has been fed at least one byte, and is empty
    /// when it has not.
    Replay = 4,
}

impl FrameType {
    /// Maps a wire byte back to a `FrameType`, or `None` if it matches
    /// none of the defined variants (callers must turn that into a
    /// clean protocol error, never a panic or a silent default).
    pub fn from_u8(byte: u8) -> Option<FrameType> {
        match byte {
            1 => Some(FrameType::Control),
            2 => Some(FrameType::Input),
            3 => Some(FrameType::Output),
            4 => Some(FrameType::Replay),
            _ => None,
        }
    }
}

/// A single decoded frame: its type plus the raw payload that followed
/// the type byte (the length prefix itself is not retained).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub frame_type: FrameType,
    pub payload: Vec<u8>,
}

/// Reads whole frames off of any `Read` stream, buffering partial reads
/// internally so callers never need to worry about a frame arriving
/// split across multiple `read` calls (e.g. one byte at a time, as a
/// slow pipe might deliver it).
pub struct FrameReader<R> {
    inner: R,
}

impl<R: Read> FrameReader<R> {
    pub fn new(inner: R) -> Self {
        Self { inner }
    }

    /// Reads and returns the next whole frame, blocking until it has
    /// arrived in full.
    ///
    /// Must reject (via `Err`, never a panic) a declared length over
    /// [`MAX_FRAME_LEN`] and a type byte that doesn't match any
    /// [`FrameType`] variant: both are attacker/bug-controlled and must
    /// not be trusted to size an allocation or select known-safe
    /// behavior.
    pub fn read_frame(&mut self) -> Result<Frame, ProtoError> {
        let mut len_buf = [0u8; 4];
        self.inner.read_exact(&mut len_buf)?;
        let len = u32::from_le_bytes(len_buf);
        if len > MAX_FRAME_LEN {
            return Err(ProtoError::FrameTooLarge {
                len,
                max: MAX_FRAME_LEN,
            });
        }
        if len == 0 {
            return Err(ProtoError::Io(io::Error::new(
                io::ErrorKind::InvalidData,
                "frame length 0 leaves no room for the frame-type byte",
            )));
        }

        let mut type_buf = [0u8; 1];
        self.inner.read_exact(&mut type_buf)?;
        let frame_type =
            FrameType::from_u8(type_buf[0]).ok_or(ProtoError::UnknownFrameType(type_buf[0]))?;

        let mut payload = vec![0u8; (len - 1) as usize];
        self.inner.read_exact(&mut payload)?;
        Ok(Frame {
            frame_type,
            payload,
        })
    }
}

/// Writes whole frames to any `Write` stream.
pub struct FrameWriter<W> {
    inner: W,
}

impl<W: Write> FrameWriter<W> {
    pub fn new(inner: W) -> Self {
        Self { inner }
    }

    /// Writes one frame: a `u32` LE length (`1 + payload.len()`), the
    /// frame-type byte, then `payload`. Returns `Err` rather than
    /// panicking if `payload` is large enough that `1 + payload.len()`
    /// would not fit in a `u32` or would exceed [`MAX_FRAME_LEN`].
    pub fn write_frame(&mut self, frame_type: FrameType, payload: &[u8]) -> Result<(), ProtoError> {
        let total = payload.len().saturating_add(1);
        if total > MAX_FRAME_LEN as usize {
            return Err(ProtoError::FrameTooLarge {
                len: u32::try_from(total).unwrap_or(u32::MAX),
                max: MAX_FRAME_LEN,
            });
        }
        self.inner.write_all(&(total as u32).to_le_bytes())?;
        self.inner.write_all(&[frame_type as u8])?;
        self.inner.write_all(payload)?;
        self.inner.flush()?;
        Ok(())
    }
}
