//! The C ABI between Baguette's host and its NIF.
//!
//! The host and the NIF are separate binaries that share one process: the
//! host links the BEAM and the BEAM loads the NIF. The host passes the address
//! of its [`HostApi`] to the BEAM on the command line (`-baguette_host <addr>`)
//! and the NIF reads it back from Elixir, so neither side needs the other's
//! symbols. Everything crossing the boundary is plain bytes (JSON).

use std::ffi::c_void;

/// Bumped whenever [`HostApi`] or [`EventSink`] changes shape.
pub const ABI_VERSION: u32 = 2;

/// Called by the host, on its UI thread, for every UI event.
pub type EventSinkFn = extern "C" fn(ctx: *mut c_void, json: *const u8, len: usize);

/// What the NIF hands the host so events can reach Elixir.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct EventSink {
    pub ctx: *mut c_void,
    pub call: EventSinkFn,
}

/// Functions the host exposes to the NIF. Every function is safe to call from
/// any thread.
#[repr(C)]
pub struct HostApi {
    pub abi_version: u32,
    pub ctx: *mut c_void,
    /// Replaces the view of window `window` with the JSON-encoded tree.
    pub render: extern "C" fn(ctx: *mut c_void, window: u32, json: *const u8, len: usize),
    /// Installs the sink events are delivered to. A later call replaces it.
    pub set_event_sink: extern "C" fn(ctx: *mut c_void, sink: EventSink),
    /// Checks the native component sets Elixir was compiled against (JSON,
    /// set name to manifest hash) against the host's. On a mismatch the
    /// host shows why, ignores renders and returns `false`.
    pub check_components: extern "C" fn(ctx: *mut c_void, json: *const u8, len: usize) -> bool,
}

// SAFETY: `HostApi` is only ever shared by address and its functions are
// required to be thread safe.
unsafe impl Send for HostApi {}
unsafe impl Sync for HostApi {}
unsafe impl Send for EventSink {}
unsafe impl Sync for EventSink {}
