use std::env;
use std::path::PathBuf;

fn main() {
    // GPUI embeds its own Windows manifest (DPI awareness, common controls
    // v6); a second one from Tauri fails the link (CVT1100). Moving to
    // Tauri's manifest instead is #27.
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .windows_attributes(tauri_build::WindowsAttributes::new_without_app_manifest()),
    )
    .expect("tauri-build");

    // `BAGUETTE_LIBERLANG` names a directory holding the BEAM: `liberlang.a`
    // (libbeam plus its internal libraries, from `scripts/build-liberlang.sh`)
    // for desktop, or `<target>/liberlang.so` for Android
    // (`scripts/build-liberlang-android.sh`). Without it the host still
    // builds, and shows a notice in place of the app.
    println!("cargo::rustc-check-cfg=cfg(baguette_beam)");
    println!("cargo::rustc-check-cfg=cfg(baguette_embedded_release)");
    embed_release();
    record_versions();
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        // The host loads the release's own `beam.smp.dll` at startup
        // (`beam::windows`), as `erl.exe` does: there is nothing to link.
        println!("cargo::rustc-cfg=baguette_beam");
        return;
    }
    let Some(dir) = baguette_env("BAGUETTE_LIBERLANG").map(PathBuf::from) else {
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
                Ok("macos") => {
                    // As on Linux: ld64 dead-strips the `enif_*` functions
                    // nothing in the host calls unless every global is kept.
                    println!("cargo::rustc-link-arg-bins=-Wl,-export_dynamic");
                    for lib in ["ncurses", "c++"] {
                        println!("cargo::rustc-link-lib={lib}");
                    }
                }
                // Xcode links the app (with `-export_dynamic`, which
                // `Baguette.Release.ios/1` adds), so only the BEAM's glue is
                // built here.
                Ok("ios") => ios_glue(&dir),
                _ => {}
            }
        }
    }
}

/// A Baguette variable, or the same with a `TAURI_` prefix: Tauri's iOS build
/// (Cargo run from Xcode) passes on only `TAURI_*`, `CARGO_*` and a few
/// others, so `Baguette.Release.ios/1` sets those.
fn baguette_env(name: &str) -> Option<std::ffi::OsString> {
    let tauri = format!("TAURI_{name}");
    println!("cargo::rerun-if-env-changed={name}");
    println!("cargo::rerun-if-env-changed={tauri}");
    env::var_os(name).or_else(|| env::var_os(tauri))
}

/// iOS loads no code but the app's, so every NIF is linked into it and listed
/// in ERTS's static NIF table, `erts_static_nif_tab`. `liberlang.a` leaves
/// that table (`driver_tab.o`) out and ships OTP's generated `driver_tab.c`
/// beside it; this compiles that table with Baguette's NIF added (a
/// dependency on iOS), and every `lib<name>.a` in `BAGUETTE_IOS_NIFS` (the
/// release's other NIFs, from `Baguette.Release.IosNifs`), which it links,
/// without OTP's headers.
///
/// The same file makes `fork()` fail, as the device sandbox does on a phone,
/// so the simulator boots the BEAM the way a phone does: ERTS forks
/// `erl_child_setup` at boot, but built for iOS it never starts an OS
/// process, so it never uses it. It also reads the system's DNS servers
/// (`baguette_nameservers`, for `Baguette.DNS`): iOS has no
/// `/etc/resolv.conf` for the BEAM's resolver, nor runs its `inet_gethost`.
fn ios_glue(liberlang: &std::path::Path) {
    let source = liberlang.join("driver_tab.c");
    println!("cargo::rerun-if-changed={}", source.display());
    let table = std::fs::read_to_string(&source)
        .unwrap_or_else(|e| panic!("{}: {e} (from build-liberlang-ios.sh)", source.display()));
    let mut nifs = vec!["baguette_nif".to_string()];
    if let Some(dir) = baguette_env("BAGUETTE_IOS_NIFS").map(PathBuf::from) {
        println!("cargo::rerun-if-changed={}", dir.display());
        println!("cargo::rustc-link-search=native={}", dir.display());
        let mut archives: Vec<String> = std::fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| {
                let name = entry.file_name().into_string().ok()?;
                Some(name.strip_prefix("lib")?.strip_suffix(".a")?.to_owned())
            })
            .collect();
        archives.sort();
        for name in archives {
            println!("cargo::rustc-link-lib=static={name}");
            nifs.push(name);
        }
    }
    let nifs: Vec<&str> = nifs.iter().map(String::as_str).collect();
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("baguette_ios_erts.c");
    std::fs::write(&out, ios_driver_tab(&table, &nifs)).unwrap();
    cc::Build::new().file(&out).compile("baguette_ios_erts");
    // `res_ninit` and friends, for `baguette_nameservers`.
    println!("cargo::rustc-link-lib=resolv");
}

/// OTP's `driver_tab.c` with `nifs` added to its static NIF table and its
/// ERTS headers replaced by the few definitions it uses.
fn ios_driver_tab(table: &str, nifs: &[&str]) -> String {
    let body: String = table
        .lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .map(|line| format!("{line}\n"))
        .collect();
    let end = "    {NULL}\n};\n";
    let at = body
        .rfind(end)
        .expect("driver_tab.c has no erts_static_nif_tab");
    let (head, tail) = body.split_at(at);
    let entries: String = nifs
        .iter()
        .map(|n| format!("    {{&{n}_nif_init, 1, THE_NON_VALUE, NULL}},\n"))
        .collect();
    let prototypes: String = nifs
        .iter()
        .map(|n| format!("void *{n}_nif_init(void);\n"))
        .collect();
    format!(
        r#"/* Generated by baguette_host's build.rs from OTP's driver_tab.c. */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <resolv.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>

typedef struct erl_drv_entry ErlDrvEntry;
typedef struct enif_entry_t ErlNifEntry;
typedef uintptr_t Eterm;
#define THE_NON_VALUE ((Eterm)0)
typedef struct {{ ErlDrvEntry *de; int taint; }} ErtsStaticDriver;
typedef struct {{
    void *(*const nif_init)(void);
    const int taint;
    Eterm mod_atom;
    ErlNifEntry *entry;
}} ErtsStaticNif;

pid_t fork(void) {{
    fprintf(stderr, "baguette: fork() refused\n");
    errno = EPERM;
    return -1;
}}

/* The system's DNS servers, comma-separated, into `out`; how many. */
int baguette_nameservers(char *out, size_t len) {{
    struct __res_state state;
    union res_sockaddr_union servers[MAXNS];
    int count, i;
    size_t used = 0;
    memset(&state, 0, sizeof state);
    out[0] = 0;
    if (res_ninit(&state) != 0) return -1;
    count = res_getservers(&state, servers, MAXNS);
    for (i = 0; i < count; i++) {{
        char ip[INET6_ADDRSTRLEN] = "";
        if (servers[i].sin.sin_family == AF_INET)
            inet_ntop(AF_INET, &servers[i].sin.sin_addr, ip, sizeof ip);
        else if (servers[i].sin6.sin6_family == AF_INET6)
            inet_ntop(AF_INET6, &servers[i].sin6.sin6_addr, ip, sizeof ip);
        if (ip[0] && used + strlen(ip) + 2 < len)
            used += (size_t)snprintf(out + used, len - used, "%s%s", used ? "," : "", ip);
    }}
    res_ndestroy(&state);
    return count;
}}

{prototypes}{head}{entries}{tail}"#
    )
}

/// On mobile the release ships inside the library: `BAGUETTE_RELEASE_ARCHIVE`
/// names a `.tar.gz` of it, which `beam::android` unpacks on first launch.
fn embed_release() {
    let Some(archive) = baguette_env("BAGUETTE_RELEASE_ARCHIVE").map(PathBuf::from) else {
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
