#![cfg(windows)]
use std::{env, ffi::OsString, fs, io, path::{Path, PathBuf}, process::{Command, ExitCode}};

fn browser_in(directory: &Path) -> io::Result<PathBuf> {
    let mut stack = vec![directory.to_path_buf()];
    let mut found = Vec::new();
    while let Some(dir) = stack.pop() {
        for item in fs::read_dir(dir)? {
            let item = item?;
            if item.file_type()?.is_dir() {
                stack.push(item.path());
            } else if item.file_type()?.is_file()
                && item.file_name().to_string_lossy().eq_ignore_ascii_case("brave.exe") {
                found.push(item.path());
            }
        }
    }
    match found.len() {
        1 => Ok(found.remove(0)),
        0 => Err(io::Error::new(io::ErrorKind::NotFound, "App/ contains no brave.exe")),
        _ => Err(io::Error::new(io::ErrorKind::InvalidData, "App/ contains multiple brave.exe files")),
    }
}

fn launch() -> Result<(), Box<dyn std::error::Error>> {
    // The launcher is movable: all paths are resolved relative to this executable.
    let executable = env::current_exe()?;
    let root = executable.parent().ok_or("Launcher has no parent directory")?;
    let browser = browser_in(&root.join("App"))?;
    let data = root.join("Data");
    let profile = data.join("Profile");
    let cache = data.join("Cache");
    let roaming = data.join("AppData").join("Roaming");
    let local = data.join("AppData").join("Local");
    for directory in [&profile, &cache, &roaming, &local] {
        fs::create_dir_all(directory)?;
    }

    // Security boundary: do not allow caller arguments to redirect browser data.
    let passthrough: Vec<OsString> = env::args_os().skip(1).collect();
    for argument in &passthrough {
        let text = argument.to_string_lossy().to_ascii_lowercase();
        if text == "--user-data-dir" || text.starts_with("--user-data-dir=")
            || text == "--disk-cache-dir" || text.starts_with("--disk-cache-dir=") {
            return Err("Custom profile/cache paths are disallowed".into());
        }
    }

    let mut child = Command::new(&browser)
        .current_dir(browser.parent().ok_or("Missing Brave parent path")?)
        .env("APPDATA", &roaming)
        .env("LOCALAPPDATA", &local)
        .arg(format!("--user-data-dir={}", profile.display()))
        .arg(format!("--disk-cache-dir={}", cache.display()))
        .arg("--no-default-browser-check")
        .arg("--disable-background-mode")
        .args(passthrough)
        .spawn()?;
    let status = child.wait()?;
    if !status.success() {
        return Err(format!("Brave exited with status {status}").into());
    }
    Ok(())
}

fn main() -> ExitCode {
    match launch() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Brave Portable: {error}");
            ExitCode::FAILURE
        }
    }
}
