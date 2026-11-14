//! Baguette's runtime for levain: boots the embedded BEAM from an Elixir
//! release ([`Beam`], a [`levain::Runtime`]).
//!
//! The arguments mirror what a release's `bin/<name> start` passes through
//! `erlexec`, so `sys.config`, `runtime.exs` and the boot script behave as in
//! any release. The host adds `-baguette_host <address>`, the address of its
//! `HostApi`, which `Baguette.Host` reads back with `:init.get_argument/1`.

use std::ffi::CString;
use std::path::PathBuf;

use levain::levain_abi::HostApi;
use levain::{App, AppPaths, Runtime, WindowConfig, cli_from_app_json};

// iOS: Baguette's NIF is linked in, for the BEAM's static NIF table (build.rs).
#[cfg(target_os = "ios")]
use baguette_nif as _;

/// The BEAM, running the Elixir release levain's host finds.
#[derive(Default)]
pub struct Beam;

impl Runtime for Beam {
    fn locate(&self, paths: &AppPaths) -> Result<App, String> {
        #[cfg(not(mobile))]
        let release = Release::locate(paths.exe.as_deref(), paths.resources.clone())?;
        // A phone has no release directory to point at: the release ships
        // inside the host library and is unpacked into the app's data.
        #[cfg(mobile)]
        let release = {
            let data = paths.data.as_deref().ok_or("no app data directory")?;
            let root = levain::mobile::unpack(data, |_staging| {
                #[cfg(target_os = "android")]
                mobile::link_native(_staging, &levain::mobile::native_lib_dir()?)?;
                Ok(())
            })?;
            Release::locate_at(root)?
        };
        Ok(App {
            root: release.root,
            name: release.name,
            window: release.window,
            cli: release.cli,
        })
    }

    fn start(&self, app: App, api: &'static HostApi) -> Result<(), String> {
        start(Release::locate_at(app.root)?, api)
    }
}

/// A release laid out by `mix release`.
pub struct Release {
    pub root: PathBuf,
    pub name: String,
    pub version: String,
    pub window: WindowConfig,
    /// The command-line interface the release declares (`cli` in its
    /// `baguette.json`), if any.
    pub cli: Option<serde_json::Value>,
    /// Where `erl_child_setup` is, which the BEAM starts at boot (on Windows,
    /// `beam.smp.dll`, the BEAM itself; iOS has none: see `build.rs`).
    pub bindir: PathBuf,
}

/// Where the release may be, for the executable at `exe`: the release it
/// sits in (`<root>/bin/<name>_app`), or the resources of a bundle around
/// it. A precompiled host doesn't know its app's name, so Tauri's own
/// resource directory points elsewhere; the bundler's layout is found from
/// the executable's name instead: `/usr/bin/<name>_app` with
/// `/usr/lib/<name>/release` (deb, AppImage), and
/// `Contents/MacOS/<name>_app` with `Contents/Resources/release` (macOS).
pub(crate) fn release_candidates(exe: &std::path::Path) -> Vec<PathBuf> {
    let Some(bin) = exe.parent() else {
        return Vec::new();
    };
    let mut candidates: Vec<PathBuf> = bin.parent().into_iter().map(PathBuf::from).collect();
    if let (Some(prefix), Some(name)) = (bin.parent(), exe.file_name().and_then(|n| n.to_str())) {
        let app = name.strip_suffix("_app").unwrap_or(name);
        candidates.push(prefix.join("lib").join(app).join("release"));
        candidates.push(prefix.join("Resources").join("release"));
    }
    candidates
}

impl Release {
    /// The release at `$BAGUETTE_RELEASE_ROOT`, the one this executable sits
    /// in (`<root>/bin/<name>_app`, as `mix release` lays it out), or the one
    /// a Tauri bundle carries in its resources (`<resources>/release`).
    #[cfg(not(mobile))]
    pub fn locate(
        exe: Option<&std::path::Path>,
        resources: Option<PathBuf>,
    ) -> Result<Self, String> {
        let around_exe = exe.map(release_candidates).unwrap_or_default();
        let root = match std::env::var_os("BAGUETTE_RELEASE_ROOT") {
            Some(root) => PathBuf::from(root),
            None => around_exe
                .into_iter()
                .chain(resources.map(|dir| dir.join("release")))
                .find(|root| root.join("releases/start_erl.data").is_file())
                .ok_or("no release next to the executable or in its resources")?,
        };
        Self::locate_at(root)
    }

    /// The release at `root`.
    pub fn locate_at(root: PathBuf) -> Result<Self, String> {
        let root = root
            .canonicalize()
            .map(plain_path)
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
        let app_json = std::fs::read(root.join("releases").join(version).join("baguette.json"));
        let window = app_json
            .as_deref()
            .map(WindowConfig::from_app_json)
            .unwrap_or_default();
        let cli = app_json.as_deref().ok().and_then(cli_from_app_json);
        // On a phone the release's own ERTS binaries are the build machine's;
        // `mobile::unpack` puts Android's `erl_child_setup` in `bin`.
        let bindir = if cfg!(mobile) {
            root.join("bin")
        } else {
            root.join(format!("erts-{erts_version}/bin"))
        };
        Ok(Self {
            root,
            window,
            cli,
            bindir,
            name,
            version: version.to_owned(),
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
    let bindir = release.bindir.display().to_string();
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_else(|_| release.path("tmp"));
    let cookie = std::fs::read_to_string(release.root.join("releases/COOKIE")).unwrap_or_default();

    // A bundled release is read-only (`/usr/lib/<app>`), so scratch files go
    // to the system's temporary directory unless the release has its own.
    let tmp = match release.root.join("tmp") {
        dir if dir.is_dir() => dir,
        _ => std::env::temp_dir().join(&release.name),
    }
    .display()
    .to_string();

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
            // Rustler NIFs look up `enif_*` in this library (see `mobile`).
            #[cfg(target_os = "android")]
            (
                "RUSTLER_BEAM_LIBRARY_PATH",
                levain::mobile::native_lib_dir()?
                    .join("liberlang.so")
                    .display()
                    .to_string(),
            ),
        ] {
            std::env::set_var(key, value);
        }
    }

    let address = (host as *const HostApi as usize).to_string();
    #[cfg_attr(not(target_os = "ios"), allow(unused_mut))]
    let mut args: Vec<String> = [
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
        "-baguette_platform",
        std::env::consts::OS,
        "--",
        "-extra",
        "--no-halt",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    // No terminal to read: a simulator's console is one, which the BEAM
    // would otherwise poll.
    #[cfg(target_os = "ios")]
    if let Some(at) = args.iter().position(|a| a == "-noshell") {
        args.insert(at + 1, "-noinput".into());
    }
    // iOS: the system's DNS servers, for `Baguette.DNS`.
    #[cfg(all(target_os = "ios", baguette_beam))]
    if let Some(at) = args.iter().position(|a| a == "-baguette_platform") {
        let servers = ios_nameservers();
        levain::log_line(&format!("baguette: nameservers {servers}"));
        if !servers.is_empty() {
            args.insert(at, servers);
            args.insert(at, "-baguette_nameservers".into());
        }
    }

    std::thread::Builder::new()
        .name("beam".into())
        .spawn(move || run(args))
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(baguette_beam)]
fn run(args: Vec<String>) {
    #[cfg(not(any(target_os = "android", windows)))]
    unsafe extern "C" {
        fn erl_start(argc: std::ffi::c_int, argv: *mut *mut std::ffi::c_char);
    }
    // On Android the BEAM is a shared library, whose own symbols are hidden;
    // `liberlang_start` is its exported entry point.
    #[cfg(target_os = "android")]
    unsafe extern "C" {
        #[link_name = "liberlang_start"]
        fn erl_start(argc: std::ffi::c_int, argv: *mut *mut std::ffi::c_char);
    }
    #[cfg(windows)]
    use windows::erl_start;
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

/// `canonicalize` on Windows gives verbatim paths (`\\?\C:\...`), which
/// the BEAM's file name handling doesn't take.
fn plain_path(path: PathBuf) -> PathBuf {
    #[cfg(windows)]
    if let Some(plain) = path.to_str().and_then(|p| p.strip_prefix(r"\\?\"))
        && !plain.starts_with(r"UNC\")
    {
        return PathBuf::from(plain);
    }
    path
}

/// Windows: the host loads the release's own BEAM, `beam.smp.dll`, and starts
/// it as `erl.exe` does (`erts/etc/win32/win_erlexec.c`). NIFs get `enif_*`
/// from the callback table the BEAM hands them when it loads them, so nothing
/// is linked into the host.
#[cfg(windows)]
mod windows {
    use std::ffi::{c_char, c_int, c_void};
    use std::os::windows::ffi::OsStrExt;

    type Module = *mut c_void;

    // Look for the DLL's own dependencies in its directory.
    const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x8;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LoadLibraryExW(name: *const u16, file: *mut c_void, flags: u32) -> Module;
        fn GetProcAddress(module: Module, name: *const c_char) -> *mut c_void;
        fn GetLastError() -> u32;
    }

    /// Loads `$BINDIR/beam.smp.dll` (`start` sets `BINDIR`) and runs the BEAM.
    pub unsafe fn erl_start(argc: c_int, argv: *mut *mut c_char) {
        let Some(bindir) = std::env::var_os("BINDIR") else {
            return levain::log_line("baguette: BINDIR is not set");
        };
        let dll = std::path::Path::new(&bindir).join("beam.smp.dll");
        let wide: Vec<u16> = dll.as_os_str().encode_wide().chain([0]).collect();
        // SAFETY: a NUL-terminated wide path; the module stays loaded for
        // the life of the process.
        unsafe {
            let module = LoadLibraryExW(
                wide.as_ptr(),
                std::ptr::null_mut(),
                LOAD_WITH_ALTERED_SEARCH_PATH,
            );
            if module.is_null() {
                let error = GetLastError();
                return levain::log_line(&format!(
                    "baguette: loading {}: error {error}",
                    dll.display()
                ));
            }
            let init = GetProcAddress(module, c"sys_primitive_init".as_ptr());
            let start = GetProcAddress(module, c"erl_start".as_ptr());
            if init.is_null() || start.is_null() {
                return levain::log_line(&format!("baguette: {} has no erl_start", dll.display()));
            }
            let init: unsafe extern "C" fn(Module) = std::mem::transmute(init);
            let start: unsafe extern "C" fn(c_int, *mut *mut c_char) = std::mem::transmute(start);
            init(module);
            start(argc, argv);
        }
    }
}

/// The system's DNS servers, comma-separated (`build.rs` compiles the C).
#[cfg(all(target_os = "ios", baguette_beam))]
fn ios_nameservers() -> String {
    unsafe extern "C" {
        fn baguette_nameservers(out: *mut std::ffi::c_char, len: usize) -> std::ffi::c_int;
    }
    let mut buf = [0u8; 512];
    // SAFETY: the C writes at most `len` bytes, NUL-terminated.
    let count = unsafe { baguette_nameservers(buf.as_mut_ptr().cast(), buf.len()) };
    if count <= 0 {
        return String::new();
    }
    std::ffi::CStr::from_bytes_until_nul(&buf)
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

#[cfg(not(baguette_beam))]
fn run(_args: Vec<String>) {
    let _ = CString::default;
    levain::log_line("baguette: this host was built without the BEAM (set BAGUETTE_LIBERLANG)");
}

/// The name a release's NIF `<stem>.so` ships under in the APK:
/// `lib<name>.so`, where the name drops a leading `lib` and a precompiled
/// NIF's `-v<version>-nif-<abi>-<triple>` suffix, so
/// `libexplorer-v0.13.0-nif-2.15-x86_64-unknown-linux-gnu` ships as
/// `libexplorer.so`. `Baguette.Release.AndroidNifs.jni_name/1` names the
/// files it puts in the APK by the same rule.
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub fn shipped_name(stem: &str) -> String {
    let name = stem.strip_prefix("lib").unwrap_or(stem);
    let end = name
        .match_indices("-v")
        .find(|(i, _)| name[i + 2..].starts_with(|c: char| c.is_ascii_digit()))
        .map_or(name.len(), |(i, _)| i);
    format!("lib{}.so", &name[..end])
}

/// Android only runs executables from the app's native library directory and
/// links each library against what it lists, so the APK carries the BEAM as
/// `liberlang.so`, its port programs as `lib<name>.so` (`erl_child_setup`,
/// `inet_gethost`) and each NIF as `lib<name>.so` ([`shipped_name`]).
/// Unpacking links the release to them: `bin/<program>` and every
/// `priv/<name>.so` and `priv/native/<name>.so` become symlinks into that
/// directory. iOS runs no programs and links every NIF into the app.
#[cfg(target_os = "android")]
mod mobile {
    use std::path::{Path, PathBuf};

    pub fn link_native(root: &Path, native: &Path) -> Result<(), String> {
        let link = |target: PathBuf, at: PathBuf| -> Result<(), String> {
            let _ = std::fs::remove_file(&at);
            std::os::unix::fs::symlink(&target, &at)
                .map_err(|e| format!("linking {} to {}: {e}", at.display(), target.display()))
        };
        std::fs::create_dir_all(root.join("bin")).map_err(|e| e.to_string())?;
        for program in ["erl_child_setup", "inet_gethost"] {
            link(
                native.join(format!("lib{program}.so")),
                root.join("bin").join(program),
            )?;
        }
        for app in std::fs::read_dir(root.join("lib"))
            .map_err(|e| e.to_string())?
            .flatten()
        {
            // Rustler NIFs live in `priv/native`, elixir_make ones in `priv`.
            let dirs = [app.path().join("priv"), app.path().join("priv/native")];
            for nif in dirs.iter().flat_map(std::fs::read_dir).flatten().flatten() {
                let path = nif.path();
                if !path.is_file() {
                    continue;
                }
                let (Some(stem), Some("so")) = (
                    path.file_stem().and_then(|s| s.to_str()),
                    path.extension().and_then(|s| s.to_str()),
                ) else {
                    continue;
                };
                let name = super::shipped_name(stem);
                let shipped = native.join(&name);
                if shipped.is_file() {
                    link(shipped, path.clone())?;
                } else {
                    log::warn!("baguette: no {name} in the app for {}", path.display());
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {

    #[test]
    fn finds_the_release_beside_or_around_the_executable() {
        let at = |exe: &str| release_candidates(std::path::Path::new(exe));
        assert_eq!(
            at("/x/rel/firehose/bin/firehose_app"),
            [
                PathBuf::from("/x/rel/firehose"),
                PathBuf::from("/x/rel/firehose/lib/firehose/release"),
                PathBuf::from("/x/rel/firehose/Resources/release"),
            ]
        );
        assert!(at("/usr/bin/firehose_app").contains(&PathBuf::from("/usr/lib/firehose/release")));
        assert!(
            at("/A/Firehose.app/Contents/MacOS/firehose_app")
                .contains(&PathBuf::from("/A/Firehose.app/Contents/Resources/release"))
        );
    }

    use super::*;

    /// A release directory holding only what `locate_at` reads.
    fn release_with(app_json: Option<&str>) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "baguette-beam-test-{}-{}",
            std::process::id(),
            app_json.map_or(0, str::len)
        ));
        let version = root.join("releases/0.1.0");
        std::fs::create_dir_all(&version).unwrap();
        std::fs::write(root.join("releases/start_erl.data"), "14.0 0.1.0").unwrap();
        std::fs::write(version.join("demo.rel"), "").unwrap();
        if let Some(json) = app_json {
            std::fs::write(version.join("baguette.json"), json).unwrap();
        }
        root
    }

    #[test]
    fn a_release_reads_window_and_cli_from_baguette_json() {
        let json = r#"{"window": {"title": "Demo"}, "cli": {"subcommands": {"sum": {}}}}"#;
        let release = Release::locate_at(release_with(Some(json))).unwrap();
        assert_eq!(release.window.title.as_deref(), Some("Demo"));
        assert_eq!(
            release.cli,
            Some(serde_json::json!({"subcommands": {"sum": {}}}))
        );
    }

    #[test]
    fn a_release_without_cli_or_baguette_json_declares_none() {
        let release = Release::locate_at(release_with(Some(r#"{"window": {}}"#))).unwrap();
        assert_eq!(release.cli, None);
        let release = Release::locate_at(release_with(None)).unwrap();
        assert_eq!(release.cli, None);
    }

    #[test]
    fn nifs_ship_as_lib_and_their_rust_library_name() {
        assert_eq!(shipped_name("sqlite3_nif"), "libsqlite3_nif.so");
        assert_eq!(shipped_name("baguette_nif"), "libbaguette_nif.so");
        assert_eq!(shipped_name("libixpipe_sqlite"), "libixpipe_sqlite.so");
        assert_eq!(
            shipped_name("libexplorer-v0.13.0-nif-2.15-x86_64-unknown-linux-gnu"),
            "libexplorer.so"
        );
    }
}
