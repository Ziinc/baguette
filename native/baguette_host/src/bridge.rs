//! The host side of the host ↔ NIF ABI (see `baguette_abi`).

use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};

use baguette_abi::{ABI_VERSION, EventSink, HostApi};

/// A render for one window, as sent by Elixir.
pub struct RenderMsg {
    pub window: u32,
    pub json: Vec<u8>,
}

struct Bridge {
    renders: async_channel::Sender<RenderMsg>,
    sink: Mutex<Option<EventSink>>,
}

static BRIDGE: OnceLock<Bridge> = OnceLock::new();

/// Creates the bridge and returns the [`HostApi`] to hand to the BEAM, and the
/// receiver renders arrive on.
pub fn install() -> (&'static HostApi, async_channel::Receiver<RenderMsg>) {
    let (tx, rx) = async_channel::unbounded();
    let bridge = Bridge {
        renders: tx,
        sink: Mutex::new(None),
    };
    assert!(BRIDGE.set(bridge).is_ok(), "bridge installed twice");
    let api = Box::leak(Box::new(HostApi {
        abi_version: ABI_VERSION,
        ctx: std::ptr::null_mut(),
        render,
        set_event_sink,
    }));
    (api, rx)
}

extern "C" fn render(_ctx: *mut c_void, window: u32, json: *const u8, len: usize) {
    // SAFETY: the NIF passes a buffer valid for `len` bytes for this call.
    let json = unsafe { std::slice::from_raw_parts(json, len) }.to_vec();
    if let Some(bridge) = BRIDGE.get() {
        let _ = bridge.renders.try_send(RenderMsg { window, json });
    }
}

extern "C" fn set_event_sink(_ctx: *mut c_void, sink: EventSink) {
    if let Some(bridge) = BRIDGE.get() {
        *bridge.sink.lock().unwrap() = Some(sink);
    }
}

/// Sends a UI event to Elixir. Dropped when no process is attached yet.
pub fn emit(event: &baguette_view::Event) {
    let Some(sink) = BRIDGE.get().and_then(|b| *b.sink.lock().unwrap()) else {
        return;
    };
    let json = serde_json::to_string(event).expect("events serialize");
    (sink.call)(sink.ctx, json.as_ptr(), json.len());
}
