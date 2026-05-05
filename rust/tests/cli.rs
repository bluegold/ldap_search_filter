use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_dir() -> PathBuf {
    let mut path = env::temp_dir();
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time before epoch")
        .as_nanos();
    path.push(format!("ldf-rust-tests-{}-{}", std::process::id(), unique));
    fs::create_dir_all(&path).expect("create temp dir");
    path
}

#[test]
fn cli_runs_csv_and_emits_phases() {
    let dir = temp_dir();
    let input = dir.join("sample.csv");
    fs::write(&input, "host,pass\nexample.com,true\nother,false\n").expect("write input");

    let output = Command::new(env!("CARGO_BIN_EXE_ldf"))
        .args([
            "--format",
            "csv",
            "(host=example.com)",
            input.to_str().unwrap(),
        ])
        .output()
        .expect("run binary");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).expect("stdout utf8");
    let stderr = String::from_utf8(output.stderr).expect("stderr utf8");
    assert_eq!(stdout.trim(), "{host: \"example.com\", pass: \"true\"}");
    assert!(stderr.contains("phase=boot"));
    assert!(stderr.contains("phase=ready"));
    assert!(stderr.contains("phase=done"));
}
