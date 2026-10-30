//! Baguette's NIF: forwards rendered trees to the host and UI events back to
//! the Elixir process that attached.

use std::ffi::c_void;
use std::sync::OnceLock;

use baguette_abi::{ABI_VERSION, EventSink, HostApi};
use rustler::{Binary, Encoder, Env, LocalPid, NifResult, OwnedBinary, OwnedEnv};

mod atoms {
    rustler::atoms! {
        ok,
        baguette_event,
        already_attached,
        abi_mismatch,
        components_mismatch,
        not_attached,
    }
}

struct Attached {
    host: &'static HostApi,
    pid: LocalPid,
}

static ATTACHED: OnceLock<Attached> = OnceLock::new();

extern "C" fn deliver(_ctx: *mut c_void, json: *const u8, len: usize) {
    let Some(attached) = ATTACHED.get() else {
        return;
    };
    // SAFETY: the host passes a buffer valid for `len` bytes for this call.
    let bytes = unsafe { std::slice::from_raw_parts(json, len) };
    let Some(mut binary) = OwnedBinary::new(len) else {
        return;
    };
    binary.as_mut_slice().copy_from_slice(bytes);
    let mut env = OwnedEnv::new();
    let _ = env.send_and_clear(&attached.pid, |env| {
        (atoms::baguette_event(), binary.release(env)).encode(env)
    });
}

/// Binds the host at `address` to the calling process, which then receives
/// `{:baguette_event, json}` for every UI event. Only one process may attach.
/// `components` (JSON, set name to manifest hash) are the native component
/// sets Elixir was compiled against; the host refuses ones it has otherwise.
#[rustler::nif]
fn attach(env: Env, address: u64, components: Binary) -> NifResult<rustler::Atom> {
    // SAFETY: the host put the address of its `'static` HostApi on the BEAM
    // command line; Elixir passes it through unchanged.
    let host = unsafe { &*(address as usize as *const HostApi) };
    if host.abi_version != ABI_VERSION {
        return Err(rustler::Error::Term(Box::new(atoms::abi_mismatch())));
    }
    if !(host.check_components)(host.ctx, components.as_ptr(), components.len()) {
        return Err(rustler::Error::Term(Box::new(atoms::components_mismatch())));
    }
    let attached = Attached {
        host,
        pid: env.pid(),
    };
    if ATTACHED.set(attached).is_err() {
        return Err(rustler::Error::Term(Box::new(atoms::already_attached())));
    }
    (host.set_event_sink)(
        host.ctx,
        EventSink {
            ctx: std::ptr::null_mut(),
            call: deliver,
        },
    );
    Ok(atoms::ok())
}

/// Sends the host a platform call; its reply arrives as an event.
#[rustler::nif]
fn call(json: Binary) -> NifResult<rustler::Atom> {
    let Some(attached) = ATTACHED.get() else {
        return Err(rustler::Error::Term(Box::new(atoms::not_attached())));
    };
    (attached.host.call)(attached.host.ctx, json.as_ptr(), json.len());
    Ok(atoms::ok())
}

/// Replaces window `window`'s view with the JSON tree in `json`.
#[rustler::nif]
fn render(window: u32, json: Binary) -> NifResult<rustler::Atom> {
    let Some(attached) = ATTACHED.get() else {
        return Err(rustler::Error::Term(Box::new(atoms::not_attached())));
    };
    (attached.host.render)(attached.host.ctx, window, json.as_ptr(), json.len());
    Ok(atoms::ok())
}

rustler::init!("Elixir.Baguette.Native");
