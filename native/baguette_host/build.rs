use std::env;
use std::path::PathBuf;

fn main() {
    tauri_build::build();

    // `BAGUETTE_LIBERLANG` names a directory holding the BEAM: `liberlang.a`
    // (libbeam plus its internal libraries, from `scripts/build-liberlang.sh`)
    // for desktop, or `<target>/liberlang.so` for Android
    // (`scripts/build-liberlang-android.sh`). Without it the host still
    // builds, and shows a notice in place of the app.
    println!("cargo::rerun-if-env-changed=BAGUETTE_LIBERLANG");
    println!("cargo::rustc-check-cfg=cfg(baguette_beam)");
    println!("cargo::rustc-check-cfg=cfg(baguette_embedded_release)");
    embed_release();
    record_versions();
    let Some(dir) = env::var_os("BAGUETTE_LIBERLANG").map(PathBuf::from) else {
        return;
    };
    let target = env::var("TARGET").unwrap();
    let dir = match dir.join(&target) {
        per_target if per_target.is_dir() => per_target,
        _ => dir,
    };
    println!("cargo::rustc-cfg=baguette_beam");
    println!("cargo::rustc-link-search=native={}", dir.display());
    match env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("android") => {
            // A shared library, so the NIFs Android loads later can link to it.
            let library = dir.join("liberlang.so");
            assert!(library.exists(), "{} does not exist", library.display());
            println!("cargo::rerun-if-changed={}", library.display());
            println!("cargo::rustc-link-lib=dylib=erlang");
        }
        os => {
            let archive = dir.join("liberlang.a");
            assert!(archive.exists(), "{} does not exist", archive.display());
            println!("cargo::rerun-if-changed={}", archive.display());
            println!("cargo::rustc-link-lib=static=erlang");
            match os {
                Ok("linux") => {
                    // NIFs resolve `enif_*` from the executable, as from beam.smp.
                    println!("cargo::rustc-link-arg-bins=-Wl,--export-dynamic");
                    for lib in ["tinfo", "util", "dl", "m", "rt", "pthread", "stdc++"] {
                        println!("cargo::rustc-link-lib={lib}");
                    }
                }
                Ok("macos") | Ok("ios") => {
                    for lib in ["ncurses", "c++"] {
                        println!("cargo::rustc-link-lib={lib}");
                    }
                }
                _ => {}
            }
        }
    }
}

/// On mobile the release ships inside the library: `BAGUETTE_RELEASE_ARCHIVE`
/// names a `.tar.gz` of it, which `beam::android` unpacks on first launch.
fn embed_release() {
    println!("cargo::rerun-if-env-changed=BAGUETTE_RELEASE_ARCHIVE");
    let Some(archive) = env::var_os("BAGUETTE_RELEASE_ARCHIVE").map(PathBuf::from) else {
        println!("cargo::rustc-env=BAGUETTE_RELEASE_HASH=none");
        return;
    };
    println!("cargo::rerun-if-changed={}", archive.display());
    let bytes = std::fs::read(&archive)
        .unwrap_or_else(|e| panic!("BAGUETTE_RELEASE_ARCHIVE {}: {e}", archive.display()));
    // FNV-1a: names the unpacked directory, so a new release unpacks afresh.
    let hash = bytes.iter().fold(0xcbf29ce484222325u64, |h, b| {
        (h ^ u64::from(*b)).wrapping_mul(0x100000001b3)
    });
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("release.tar.gz");
    std::fs::write(&out, bytes).unwrap();
    println!("cargo::rustc-env=BAGUETTE_RELEASE_HASH={hash:016x}");
    println!("cargo::rustc-cfg=baguette_embedded_release");
}

/// The GPUI and gpui-kit versions in Cargo.lock, which each component set's
/// manifest records (`components.rs`).
fn record_versions() {
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let lock = manifest.join("../Cargo.lock");
    println!("cargo::rerun-if-changed={}", lock.display());
    let lock = std::fs::read_to_string(&lock).unwrap_or_default();
    for (crate_name, var) in [
        ("gpui-pre", "BAGUETTE_GPUI_VERSION"),
        ("gpui-kit", "BAGUETTE_GPUI_KIT_VERSION"),
    ] {
        let version = locked_version(&lock, crate_name).unwrap_or("unknown");
        println!("cargo::rustc-env={var}={version}");
    }
}

fn locked_version<'a>(lock: &'a str, crate_name: &str) -> Option<&'a str> {
    let name = format!("name = \"{crate_name}\"\n");
    let at = lock.find(&name)? + name.len();
    lock[at..]
        .lines()
        .next()?
        .strip_prefix("version = \"")?
        .strip_suffix('"')
}
