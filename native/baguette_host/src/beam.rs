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
    pub window: WindowConfig,
    /// Where `erl_child_setup` is, which the BEAM starts at boot.
    pub bindir: PathBuf,
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
    #[cfg(not(target_os = "android"))]
    pub fn locate(resources: Option<PathBuf>) -> Result<Self, String> {
        let around_exe = std::env::current_exe()
            .map(|exe| release_candidates(&exe))
            .unwrap_or_default();
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
        // On Android the release's own ERTS binaries are the build machine's;
        // `android::unpack` puts the phone's `erl_child_setup` in `bin`.
        let bindir = if cfg!(target_os = "android") {
            root.join("bin")
        } else {
            root.join(format!("erts-{erts_version}/bin"))
        };
        Ok(Self {
            root,
            window,
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
    let home = std::env::var("HOME").unwrap_or_else(|_| release.path("tmp"));
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
            // Rustler NIFs look up `enif_*` in this library (see `android`).
            #[cfg(target_os = "android")]
            (
                "RUSTLER_BEAM_LIBRARY_PATH",
                android::native_lib_dir()?
                    .join("liberlang.so")
                    .display()
                    .to_string(),
            ),
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
        "-baguette_platform",
        std::env::consts::OS,
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
    #[cfg(not(target_os = "android"))]
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

/// Android: the release ships inside this library and is unpacked into the
/// app's data on first launch.
///
/// Android only runs executables from the app's native library directory and
/// links each library against what it lists, so the APK carries the BEAM as
/// `liberlang.so`, its port programs as `lib<name>.so` (`erl_child_setup`,
/// `inet_gethost`) and each NIF as `lib<name>.so` ([`shipped_name`]).
/// Unpacking links the release to them: `bin/<program>` and every
/// `priv/<name>.so` and `priv/native/<name>.so` become symlinks into that
/// directory.
#[cfg(target_os = "android")]
pub mod android {
    use std::path::{Path, PathBuf};

    #[cfg(baguette_embedded_release)]
    static ARCHIVE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/release.tar.gz"));
    #[cfg(not(baguette_embedded_release))]
    static ARCHIVE: &[u8] = &[];

    /// The directory Android installed this library in.
    pub fn native_lib_dir() -> Result<PathBuf, String> {
        let mut info: libc::Dl_info = unsafe { std::mem::zeroed() };
        // SAFETY: dladdr only reads the address and fills `info`.
        let found = unsafe { libc::dladdr(native_lib_dir as *const libc::c_void, &mut info) };
        if found == 0 || info.dli_fname.is_null() {
            return Err("cannot find the app's native library directory".into());
        }
        // SAFETY: dladdr returned a NUL-terminated path.
        let path = unsafe { std::ffi::CStr::from_ptr(info.dli_fname) };
        Path::new(&*path.to_string_lossy())
            .parent()
            .map(Path::to_path_buf)
            .ok_or_else(|| "the app's library has no directory".into())
    }

    /// Unpacks the embedded release under `data_dir`, once per release, and
    /// returns its root.
    pub fn unpack(data_dir: &Path) -> Result<PathBuf, String> {
        if ARCHIVE.is_empty() {
            return Err(
                "this app was built without an Elixir release (BAGUETTE_RELEASE_ARCHIVE)".into(),
            );
        }
        let root = data_dir.join(format!("release-{}", env!("BAGUETTE_RELEASE_HASH")));
        if !root.join("releases/start_erl.data").is_file() {
            let staging = data_dir.join("release-unpacking");
            let _ = std::fs::remove_dir_all(&staging);
            std::fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
            tar::Archive::new(flate2::read::GzDecoder::new(ARCHIVE))
                .unpack(&staging)
                .map_err(|e| format!("unpacking the release: {e}"))?;
            link_native(&staging, &native_lib_dir()?)?;
            let _ = std::fs::remove_dir_all(&root);
            std::fs::rename(&staging, &root).map_err(|e| e.to_string())?;
            // Earlier releases of this app.
            for entry in std::fs::read_dir(data_dir).into_iter().flatten().flatten() {
                let path = entry.path();
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with("release-") && path != root {
                    let _ = std::fs::remove_dir_all(path);
                }
            }
        }
        log::info!("baguette: release at {}", root.display());
        Ok(root)
    }

    /// Sends the BEAM's stdout and stderr (Logger, `IO.puts`, crash reports)
    /// to logcat under the `beam` tag; Android discards them otherwise.
    pub fn log_stdio() {
        let mut fds = [0; 2];
        // SAFETY: pipe fills two descriptors; dup2 points stdout and stderr at
        // its write end for the life of the process.
        unsafe {
            if libc::pipe(fds.as_mut_ptr()) != 0 {
                return;
            }
            libc::dup2(fds[1], 1);
            libc::dup2(fds[1], 2);
        }
        let read = fds[0];
        let _ = std::thread::Builder::new()
            .name("beam-log".into())
            .spawn(move || {
                use std::io::BufRead;
                use std::os::fd::FromRawFd;
                // SAFETY: the read end belongs to this thread alone.
                let file = unsafe { std::fs::File::from_raw_fd(read) };
                for line in std::io::BufReader::new(file).lines().map_while(Result::ok) {
                    log::info!(target: "beam", "{line}");
                }
            });
    }

    fn link_native(root: &Path, native: &Path) -> Result<(), String> {
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
