fn main() {
    // `--manifest [set]` prints the registered native components, all or one
    // set's, for `Baguette.Components` (`mix baguette.components`).
    let args: Vec<String> = std::env::args().collect();
    if let Some(at) = args.iter().position(|arg| arg == "--manifest") {
        use baguette_host_lib::components;
        let manifest = match args.get(at + 1) {
            Some(set) => components::manifest_of(set).unwrap_or_else(|| {
                eprintln!("no component set `{set}` in this host");
                std::process::exit(1)
            }),
            None => components::manifest(components::sets()),
        };
        println!("{manifest:#}");
        return;
    }
    baguette_host_lib::run();
}
