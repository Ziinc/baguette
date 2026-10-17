use std::env;
use std::path::PathBuf;

fn main() {
    tauri_build::build();

    // `BAGUETTE_LIBERLANG` names a directory holding `liberlang.a`: the BEAM
    // (libbeam plus its internal libraries) as one static archive, built by
    // `scripts/build-liberlang.sh`. Without it the host still builds, and shows
    // a notice in place of the app.
    println!("cargo::rerun-if-env-changed=BAGUETTE_LIBERLANG");
    println!("cargo::rustc-check-cfg=cfg(baguette_beam)");
    let Some(dir) = env::var_os("BAGUETTE_LIBERLANG").map(PathBuf::from) else {
        return;
    };
    let archive = dir.join("liberlang.a");
    assert!(archive.exists(), "{} does not exist", archive.display());
    println!("cargo::rerun-if-changed={}", archive.display());
    println!("cargo::rustc-cfg=baguette_beam");
    println!("cargo::rustc-link-search=native={}", dir.display());
    println!("cargo::rustc-link-lib=static=erlang");
    match env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("linux") => {
            // NIFs resolve `enif_*` from the executable, as they would from beam.smp.
            println!("cargo::rustc-link-arg-bins=-Wl,--export-dynamic");
            for lib in ["tinfo", "util", "dl", "m", "rt", "pthread", "stdc++"] {
                println!("cargo::rustc-link-lib={lib}");
            }
        }
        Ok("android") => {
            for lib in ["dl", "m", "log", "c++_shared"] {
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
