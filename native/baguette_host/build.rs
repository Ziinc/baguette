use std::env;

fn main() {
    levain_build::build();

    // With a linked BEAM (`BAGUETTE_LIBERLANG`, see baguette_beam's
    // build.rs), NIFs resolve `enif_*` from the executable, as from
    // beam.smp. Link arguments for binaries only apply from their own
    // crate's build script.
    if levain_build::env_var("BAGUETTE_LIBERLANG").is_none() {
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
