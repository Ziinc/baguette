//! Boots the embedded BEAM from an Elixir release.
//!
//! The arguments mirror what a release's `bin/<name> start` passes through
//! `erlexec`, so `sys.config`, `runtime.exs` and the boot script behave as in
//! any release. The host adds `-baguette_host <address>`, the address of its
//! `HostApi`, which `Baguette.Host` reads back with `:init.get_argument/1`.

use std::ffi::CString;
use std::path::PathBuf;

use baguette_abi::HostApi;

/// A release laid out by `mix release`.
pub struct Release {
    pub root: PathBuf,
    pub name: String,
    pub version: String,
    pub erts_version: String,
    pub window: WindowConfig,
}

/// The main window, from `releases/<vsn>/baguette.json`, which
/// `Baguette.Release.package/1` writes from the release's `baguette` options.
#[derive(serde::Deserialize)]
#[serde(default)]
pub struct WindowConfig {
    pub title: Option<String>,
    pub width: f64,
    pub height: f64,
}

impl Default for WindowConfig {
    fn default() -> Self {
        Self {
            title: None,
            width: 480.0,
            height: 360.0,
        }
    }
}

impl Release {
    /// The release at `$BAGUETTE_RELEASE_ROOT`, the one this executable sits
    /// in (`<root>/bin/<name>_app`, as `mix release` lays it out), or the one
    /// a Tauri bundle carries in its resources (`<resources>/release`).
    pub fn locate(resources: Option<PathBuf>) -> Result<Self, String> {
        let beside_exe = std::env::current_exe()
            .ok()
            .and_then(|exe| Some(exe.parent()?.parent()?.to_path_buf()));
        let root = match std::env::var_os("BAGUETTE_RELEASE_ROOT") {
            Some(root) => PathBuf::from(root),
            None => beside_exe
                .into_iter()
                .chain(resources.map(|dir| dir.join("release")))
                .find(|root| root.join("releases/start_erl.data").is_file())
                .ok_or("no release next to the executable or in its resources")?,
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
        let window = std::fs::read(root.join("releases").join(version).join("baguette.json"))
            .ok()
            .and_then(|json| {
                #[derive(serde::Deserialize)]
                struct Config {
                    window: WindowConfig,
                }
                serde_json::from_slice::<Config>(&json).ok()
            })
            .map(|config| config.window)
            .unwrap_or_default();
        Ok(Self {
            root,
            window,
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

    // A bundled release is read-only (`/usr/lib/<app>`), so scratch files go
    // to the system's temporary directory unless the release has its own.
    let tmp = match release.root.join("tmp") {
        dir if std::fs::create_dir_all(&dir).is_ok() => dir.display().to_string(),
        _ => std::env::temp_dir()
            .join(&release.name)
            .display()
            .to_string(),
    };

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
            ("RELEASE_TMP", tmp),
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
        // File names are UTF-8 whatever the locale (`+fnu`); phones have none.
        "-fnu",
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
