#![cfg(windows)]
// Windows/MSIX full-trust entry point; registry virtualization is provided by
// Windows package identity, not by API hooks or registry export/import.
use std::{
    env,
    ffi::OsString,
    fs,
    io,
    path::{Path, PathBuf},
    process::{Command, ExitCode},
};

fn find_browser(root: &Path) -> io::Result<PathBuf> {
    let mut pending = vec![root.to_path_buf()];
    let mut found = Vec::new();
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let ty = entry.file_type()?;
            if ty.is_dir() {
                pending.push(entry.path());
            } else if ty.is_file() && entry.file_name().to_string_lossy().eq_ignore_ascii_case("brave.exe") {
                found.push(entry.path());
            }
        }
    }
    match found.len() {
        1 => Ok(found.remove(0)),
        0 => Err(io::Error::new(io::ErrorKind::NotFound, "No brave.exe in package App folder")),
        _ => Err(io::Error::new(io::ErrorKind::InvalidData, "Multiple brave.exe files in package App folder")),
    }
}
fn launch() -> Result<(), Box<dyn std::error::Error>> {
    let launcher = env::current_exe()?;
    let package_root = launcher.parent().ok_or("Missing launcher directory")?;
    let brave = find_browser(&package_root.join("App"))?;
    let local = PathBuf::from(env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA is unavailable")?);
    // MSIX virtualizes supported per-user AppData writes for packaged desktop apps.
    // These directories are deliberately outside the read-only package installation.
    let storage = local.join("BravePortableMsix");
    let profile = storage.join("Profile");
    let cache = storage.join("Cache");
    fs::create_dir_all(&profile)?;
    fs::create_dir_all(&cache)?;
    let forwarded: Vec<OsString> = env::args_os().skip(1).collect();
    for argument in &forwarded {
        let text = argument.to_string_lossy().to_ascii_lowercase();
        if text == "--user-data-dir" || text.starts_with("--user-data-dir=") ||
            text == "--disk-cache-dir" || text.starts_with("--disk-cache-dir=") {
            return Err("Profile/cache override is prohibited in MSIX mode".into());
        }
    }
    let mut command = Command::new(&brave);
    command.current_dir(brave.parent().ok_or("Invalid Brave path")?)
        .arg(format!("--user-data-dir={}", profile.display()))
        .arg(format!("--disk-cache-dir={}", cache.display()))
        .arg("--no-default-browser-check")
        .arg("--disable-background-mode")
        .args(&forwarded);
    let mut child = command.spawn()?;
    let result = child.wait()?;
    if !result.success() {
        return Err(format!("Brave exited with status {result}").into());
    }
    Ok(())
}
fn main() -> ExitCode {
    match launch() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Brave Portable MSIX: {error}");
            ExitCode::FAILURE
        }
    }
}
