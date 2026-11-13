use std::env;

fn main() {
    // GPUI embeds its own Windows manifest (DPI awareness, common controls
    // v6); a second one from Tauri fails the link (CVT1100). Moving to
    // Tauri's manifest instead is #27.
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .windows_attributes(tauri_build::WindowsAttributes::new_without_app_manifest()),
    )
    .expect("tauri-build");

    // With a linked BEAM (`BAGUETTE_LIBERLANG`, see baguette_beam's
    // build.rs), NIFs resolve `enif_*` from the executable, as from
    // beam.smp. Link arguments for binaries only apply from their own
    // crate's build script.
    println!("cargo::rerun-if-env-changed=BAGUETTE_LIBERLANG");
    println!("cargo::rerun-if-env-changed=TAURI_BAGUETTE_LIBERLANG");
    if env::var_os("BAGUETTE_LIBERLANG")
        .or_else(|| env::var_os("TAURI_BAGUETTE_LIBERLANG"))
        .is_none()
    {
        return;
    }
    match env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("linux") => println!("cargo::rustc-link-arg-bins=-Wl,--export-dynamic"),
        // As on Linux: ld64 dead-strips the `enif_*` functions nothing in
        // the host calls unless every global is kept.
        Ok("macos") => println!("cargo::rustc-link-arg-bins=-Wl,-export_dynamic"),
        _ => {}
    }
}
