#![cfg(windows)]
use std::{env, ffi::{OsString, OsStr}, fs, io, path::{Path, PathBuf}, process::{Command, ExitCode}, time::{SystemTime, UNIX_EPOCH}};
use std::os::windows::ffi::OsStrExt;
use std::io::Write;

#[link(name = "user32")]
extern "system" { fn MessageBoxW(hwnd: isize, text: *const u16, caption: *const u16, kind: u32) -> i32; }

fn wide(value: &OsStr) -> Vec<u16> { value.encode_wide().chain(std::iter::once(0)).collect() }
fn notify_error(message: &str) {
    let body = wide(OsStr::new(message));
    let title = wide(OsStr::new("Brave Portable - Launch failed"));
    unsafe { MessageBoxW(0, body.as_ptr(), title.as_ptr(), 0x10); }
}
fn append_log(root: &Path, message: &str) {
    let folder = root.join("Data").join("Logs");
    if fs::create_dir_all(&folder).is_err() { return; }
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(folder.join("launcher.log")) {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let _ = writeln!(file, "[{stamp}] {message}");
    }
}

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
    let browser = browser_in(&root.join("App")).map_err(|e| format!("Cannot locate Brave in {}: {e}. Place BravePortable.exe beside an App folder containing the extracted Brave files.", root.display()))?;
    append_log(root, &format!("Launching browser at {}", browser.display()));
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
    append_log(root, &format!("Brave started with PID {}", child.id()));
    let status = child.wait()?;
    append_log(root, &format!("Brave initial process exited: {status}"));
    if !status.success() {
        return Err(format!("Brave exited with status {status}").into());
    }
    Ok(())
}

fn main() -> ExitCode {
    match launch() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            let message = format!("Brave Portable: {error}");
            eprintln!("{message}");
            if let Ok(exe) = env::current_exe() {
                if let Some(root) = exe.parent() { append_log(root, &message); }
            }
            notify_error(&message);
            ExitCode::FAILURE
        }
    }
}
