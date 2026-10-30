fn main() {
    // Prints the registered native components for `Baguette.Components`.
    if std::env::args().any(|arg| arg == "--manifest") {
        let manifest =
            baguette_host_lib::components::manifest(baguette_host_lib::components::sets());
        println!("{manifest:#}");
        return;
    }
    baguette_host_lib::run();
}
