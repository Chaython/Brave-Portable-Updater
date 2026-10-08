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


#[derive(serde::Deserialize)]
struct Release {
    name: String,
    tag_name: String,
    #[serde(default)]
    prerelease: bool,
    assets: Vec<ReleaseAsset>,
}
#[derive(serde::Deserialize)]
struct ReleaseAsset {
    name: String,
    browser_download_url: String,
    digest: Option<String>,
    size: u64,
}
struct DownloadOptions {
    edition: String,
    force_update: bool,
    no_download: bool,
    passthrough: Vec<OsString>,
}
fn parse_options() -> Result<DownloadOptions, Box<dyn std::error::Error>> {
    let mut edition = "stable".to_owned();
    let mut force_update = false;
    let mut no_download = false;
    let mut passthrough = Vec::new();
    let mut args = env::args_os().skip(1);
    let mut forwarding = false;
    while let Some(arg) = args.next() {
        let value = arg.to_string_lossy();
        if !forwarding && value == "--" { forwarding = true; continue; }
        if !forwarding && value == "--update" { force_update = true; continue; }
        if !forwarding && value == "--no-download" { no_download = true; continue; }
        if !forwarding && value == "--edition" {
            edition = args.next().ok_or("--edition requires stable, beta or nightly")?
                .to_string_lossy().to_ascii_lowercase();
            continue;
        }
        if !forwarding && value.starts_with("--edition=") {
            edition = value[10..].to_ascii_lowercase();
            continue;
        }
        passthrough.push(arg);
    }
    if !matches!(edition.as_str(), "stable" | "beta" | "nightly") {
        return Err("Edition must be stable, beta or nightly".into());
    }
    if force_update && no_download { return Err("--update conflicts with --no-download".into()); }
    Ok(DownloadOptions { edition, force_update, no_download, passthrough })
}

fn release_asset(client: &reqwest::blocking::Client, edition: &str)
    -> Result<(String, ReleaseAsset), Box<dyn std::error::Error>>
{
    let channel = match edition { "stable" => "Release v", "beta" => "Beta v", _ => "Nightly v" };
    for page in 1..=10 {
        let url = format!("https://api.github.com/repos/brave/brave-browser/releases?per_page=100&page={page}");
        let releases: Vec<Release> = client.get(url).send()?.error_for_status()?.json()?;
        let count = releases.len();
        for release in releases {
            if !release.name.starts_with(channel) { continue; }
            if edition == "stable" && (release.prerelease ||
                release.name.to_ascii_lowercase().contains("candidate")) { continue; }
            let expected = format!("brave-{}-win32-x64.zip", release.tag_name);
            if let Some(asset) = release.assets.into_iter().find(|a| a.name == expected) {
                return Ok((release.tag_name, asset));
            }
        }
        if count < 100 { break; }
    }
    Err(format!("No {edition} Brave Windows x64 ZIP found in recent GitHub releases").into())
}
fn verify_archive(path: &Path, digest: &str) -> Result<(), Box<dyn std::error::Error>> {
    use sha2::{Digest, Sha256};
    let expected = digest.strip_prefix("sha256:")
        .ok_or("Brave release is missing a usable SHA-256 digest; refusing to install")?;
    if expected.len() != 64 || !expected.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("Invalid release SHA-256 digest".into());
    }
    let mut hash = Sha256::new();
    let mut file = fs::File::open(path)?;
    // Avoid a 1 MiB stack allocation on Windows (default thread stack ~1 MiB).
    let mut chunk = [0u8; 32 * 1024];
    loop {
        let count = io::Read::read(&mut file, &mut chunk)?;
        if count == 0 { break; }
        hash.update(&chunk[..count]);
    }
    let actual = format!("{:x}", hash.finalize());
    if !actual.eq_ignore_ascii_case(expected) {
        return Err("Downloaded Brave archive failed SHA-256 verification".into());
    }
    Ok(())
}
fn unpack_zip(archive: &Path, destination: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let mut zip = zip::ZipArchive::new(fs::File::open(archive)?)?;
    for index in 0..zip.len() {
        let mut entry = zip.by_index(index)?;
        let safe = entry.enclosed_name().ok_or("Unsafe path in Brave ZIP")?.to_path_buf();
        if entry.unix_mode().map(|mode| mode & 0o170000 == 0o120000).unwrap_or(false) {
            return Err("Symlinks are not supported in the Brave archive".into());
        }
        let output = destination.join(safe);
        if entry.is_dir() {
            fs::create_dir_all(&output)?;
        } else {
            if let Some(parent) = output.parent() { fs::create_dir_all(parent)?; }
            let mut file = fs::File::create(&output)?;
            io::copy(&mut entry, &mut file)?;
        }
    }
    browser_in(destination)?;
    Ok(())
}
fn ensure_browser(root: &Path, options: &DownloadOptions) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let app = root.join("App");
    let existing = browser_in(&app).ok();
    if existing.is_some() && !options.force_update { return Ok(existing.unwrap()); }
    if options.no_download { return Err("App/ has no valid Brave installation and downloads are disabled".into()); }

    append_log(root, &format!("Looking up Brave {} release", options.edition));
    let client = reqwest::blocking::Client::builder()
        .user_agent("Brave-Portable-Rust/0.1")
        .timeout(std::time::Duration::from_secs(900))
        .build()?;
    let (version, asset) = release_asset(&client, &options.edition)?;
    if asset.size == 0 || asset.size > 2_000_000_000 {
        return Err("Unreasonable Brave download size".into());
    }
    let digest = asset.digest.ok_or("Release lacks SHA-256 digest; download aborted")?;
    let url = reqwest::Url::parse(&asset.browser_download_url)?;
    if url.scheme() != "https" || url.host_str() != Some("github.com") {
        return Err("Unexpected Brave release download host".into());
    }
    let id = format!("{}-{}", std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos());
    let archive = root.join(format!(".brave-{id}.zip"));
    let staging = root.join(format!(".app-staging-{id}"));
    let backup = root.join(format!(".app-backup-{id}"));
    append_log(root, &format!("Downloading {} ({version}, {} bytes)", asset.name, asset.size));
    let install = (|| -> Result<(), Box<dyn std::error::Error>> {
        let mut response = client.get(url).send()?.error_for_status()?;
        let mut output = fs::File::create(&archive)?;
        let length = io::copy(&mut response, &mut output)?;
        output.sync_all()?;
        if length != asset.size { return Err(format!("Expected {} bytes, downloaded {length}", asset.size).into()); }
        verify_archive(&archive, &digest)?;
        fs::create_dir(&staging)?;
        unpack_zip(&archive, &staging)?;
        fs::write(staging.join(".brave-portable-version"), format!("{}|{version}", options.edition))?;
        if app.exists() { fs::rename(&app, &backup)?; }
        if let Err(error) = fs::rename(&staging, &app) {
            if backup.exists() {
                let _ = fs::rename(&backup, &app);
            }
            return Err(error.into());
        }
        if backup.exists() {
            if let Err(error) = fs::remove_dir_all(&backup) {
                append_log(root, &format!("Previous Brave backup retained at {}: {error}", backup.display()));
            }
        }
        Ok(())
    })();
    let _ = fs::remove_file(&archive);
    if staging.exists() { let _ = fs::remove_dir_all(&staging); }
    install?;
    append_log(root, &format!("Installed Brave {version} in {}", app.display()));
    Ok(browser_in(&app)?)
}

fn launch() -> Result<(), Box<dyn std::error::Error>> {
    // The launcher is movable: all paths are resolved relative to this executable.
    let executable = env::current_exe()?;
    let root = executable.parent().ok_or("Launcher has no parent directory")?;
    let options = parse_options()?;
    let browser = ensure_browser(root, &options)?;
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
    let passthrough = options.passthrough;
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
