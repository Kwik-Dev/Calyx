//! Health probe backing `ControlMsg::GetHealth`/`Health` (see
//! `proto::control`'s doc comment on those variants for why this
//! exists): a double-forked daemon that has lost its spawning app's
//! jetsam coalition can no longer reach opendirectoryd, so
//! `getpwuid(geteuid())` on itself starts failing.

/// `true` if this process can still resolve its own effective uid to a
/// user record.
pub(crate) fn user_lookup_ok() -> bool {
    matches!(
        nix::unistd::User::from_uid(nix::unistd::geteuid()),
        Ok(Some(_))
    )
}
