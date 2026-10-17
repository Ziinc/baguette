//! Boots the embedded BEAM from an Elixir release.
//!
//! The arguments mirror what a release's `bin/<name> start` passes through
//! `erlexec`, so `sys.config`, `runtime.exs` and the boot script behave as in
//! any release. The host adds `-baguette_host <address>`, the address of its
//! `HostApi`, which `Baguette.Host` reads back with `:init.get_argument/1`.

use std::ffi::CString;
use std::path::{Path, PathBuf};

use baguette_abi::HostApi;

/// A release laid out by `mix release`.
pub struct Release {
    pub root: PathBuf,
    pub name: String,
    pub version: String,
    pub erts_version: String,
}

impl Release {
    /// The release at `$BAGUETTE_RELEASE_ROOT`, or the one this executable sits
    /// in (`<root>/bin/baguette_host`).
    pub fn locate() -> Result<Self, String> {
        let root = match std::env::var_os("BAGUETTE_RELEASE_ROOT") {
            Some(root) => PathBuf::from(root),
            None => std::env::current_exe()
                .map_err(|e| e.to_string())?
                .parent()
                .and_then(Path::parent)
                .ok_or("cannot find the release next to the host executable")?
                .to_path_buf(),
        };
        let root = root
            .canonicalize()
            .map_err(|e| format!("{}: {e}", root.display()))?;
        let start_erl = std::fs::read_to_string(root.join("releases/start_erl.data"))
            .map_err(|e| format!("{}/releases/start_erl.data: {e}", root.display()))?;
        let (erts_version, version) = start_erl
            .trim()
            .split_once(' ')
            .ok_or("malformed releases/start_erl.data")?;
        let name = std::fs::read_dir(root.join("releases").join(version))
            .map_err(|e| e.to_string())?
            .filter_map(|entry| {
                let path = entry.ok()?.path();
                (path.extension()? == "rel")
                    .then(|| path.file_stem()?.to_str().map(str::to_owned))?
            })
            .next()
            .ok_or("no .rel file in the release")?;
        Ok(Self {
            root,
            name,
            version: version.to_owned(),
            erts_version: erts_version.to_owned(),
        })
    }

    fn path(&self, relative: &str) -> String {
        self.root.join(relative).display().to_string()
    }
}

/// Starts the BEAM on a new thread. The BEAM halts the process when the
/// release stops.
pub fn start(release: Release, host: &'static HostApi) -> Result<(), String> {
    let releases = format!("releases/{}", release.version);
    let bindir = release.path(&format!("erts-{}/bin", release.erts_version));
    let home = std::env::var("HOME").unwrap_or_else(|_| release.path("tmp"));
    let cookie = std::fs::read_to_string(release.root.join("releases/COOKIE")).unwrap_or_default();

    // What the release start script exports for `Config.Provider` and friends.
    // SAFETY: called once from the main thread before the BEAM thread exists.
    unsafe {
        for (key, value) in [
            ("RELEASE_ROOT", release.path("")),
            ("RELEASE_NAME", release.name.clone()),
            ("RELEASE_VSN", release.version.clone()),
            ("RELEASE_COMMAND", "start".into()),
            ("RELEASE_MODE", "embedded".into()),
            ("RELEASE_PROG", "baguette_host".into()),
            (
                "RELEASE_SYS_CONFIG",
                release.path(&format!("{releases}/sys")),
            ),
            ("RELEASE_TMP", release.path("tmp")),
            ("RELEASE_COOKIE", cookie.trim().to_owned()),
            ("RELEASE_DISTRIBUTION", "none".into()),
            ("BINDIR", bindir.clone()),
            ("ROOTDIR", release.path("")),
            ("EMU", "beam".into()),
            ("PROGNAME", "erl".into()),
        ] {
            std::env::set_var(key, value);
        }
    }

    let address = (host as *const HostApi as usize).to_string();
    let args: Vec<String> = [
        "baguette_host",
        "--",
        "-root",
        &release.path(""),
        "-bindir",
        &bindir,
        "-progname",
        "erl",
        "--",
        "-home",
        &home,
        "--",
        "-noshell",
        "-elixir",
        "ansi_enabled",
        "false",
        "-s",
        "elixir",
        "start_cli",
        "-mode",
        "embedded",
        "-config",
        &release.path(&format!("{releases}/sys")),
        "-boot",
        &release.path(&format!("{releases}/start")),
        "-boot_var",
        "RELEASE_LIB",
        &release.path("lib"),
        "-baguette_host",
        &address,
        "--",
        "-extra",
        "--no-halt",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();

    std::thread::Builder::new()
        .name("beam".into())
        .spawn(move || run(args))
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(baguette_beam)]
fn run(args: Vec<String>) {
    unsafe extern "C" {
        fn erl_start(argc: std::ffi::c_int, argv: *mut *mut std::ffi::c_char);
    }
    let args: Vec<CString> = args.into_iter().map(|a| CString::new(a).unwrap()).collect();
    // `erl_start` keeps pointers into argv for the life of the VM.
    let argv: &'static mut [*mut std::ffi::c_char] = Vec::leak(
        args.into_iter()
            .map(|a| a.into_raw())
            .chain(std::iter::once(std::ptr::null_mut()))
            .collect(),
    );
    // SAFETY: argv is NUL-terminated and lives forever.
    unsafe { erl_start((argv.len() - 1) as std::ffi::c_int, argv.as_mut_ptr()) };
}

#[cfg(not(baguette_beam))]
fn run(_args: Vec<String>) {
    let _ = CString::default;
    eprintln!("baguette: this host was built without the BEAM (set BAGUETTE_LIBERLANG)");
}
