use std::env;
use std::io::{self, Write};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let mut stdout = io::stdout().lock();
    let mut stderr = io::stderr().lock();

    if let Err(message) = ldf::run_with_io(&args, &mut stdout, &mut stderr) {
        let _ = writeln!(stderr, "{}", message);
        std::process::exit(1);
    }
}
