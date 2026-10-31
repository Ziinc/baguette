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
            None => components::sets()
                .iter()
                .map(|set| components::manifest(set, components::Versions::BUILT))
                .collect(),
        };
        println!("{manifest:#}");
        return;
    }
    #[cfg(feature = "render")]
    if args.get(1).is_some_and(|arg| arg == "--render") {
        if let Err(error) = render(&args[2..]) {
            eprintln!("baguette_host --render: {error:#}");
            std::process::exit(1);
        }
        return;
    }
    baguette_host_lib::run();
}

/// `--render frame.json out.png [--width px] [--height px]`: draws a frame
/// offscreen to a PNG (the `render` feature, for `Baguette.Test.render_png`).
#[cfg(feature = "render")]
fn render(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let usage = "usage: baguette_host --render frame.json out.png [--width px] [--height px]";
    let [frame, out, options @ ..] = args else {
        return Err(usage.into());
    };
    let (mut width, mut height) = (800., 600.);
    for option in options.chunks(2) {
        let value = || -> Result<f32, Box<dyn std::error::Error>> {
            let value = option.get(1).ok_or(usage)?;
            Ok(value
                .parse()
                .map_err(|_| format!("{value}: not a number"))?)
        };
        match option[0].as_str() {
            "--width" => width = value()?,
            "--height" => height = value()?,
            _ => return Err(usage.into()),
        }
    }
    let json = std::fs::read(frame).map_err(|e| format!("reading {frame}: {e}"))?;
    let png = baguette_host_lib::render::png(&json, width, height)?;
    std::fs::write(out, png).map_err(|e| format!("writing {out}: {e}"))?;
    Ok(())
}
