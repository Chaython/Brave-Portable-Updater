//! Temporary, opt-in registry swapping. NOT virtualization.
//! Native Windows Brave and policy keys are temporarily replaced and then restored.
//! Files in Data/Registry permit manual recovery if a process crashes.
use std::{env, error::Error, ffi::OsStr, fs, io, os::windows::ffi::OsStrExt, path::{Path,PathBuf}, process::Command, ptr, time::Duration};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
#[link(name="kernel32")]
extern "system" {
    fn CreateMutexW(attributes:*mut core::ffi::c_void, initial_owner:i32, name:*const u16)->isize;
    fn WaitForSingleObject(handle:isize, milliseconds:u32)->u32;
    fn ReleaseMutex(handle:isize)->i32;
    fn CloseHandle(handle:isize)->i32;
    fn MoveFileExW(old:*const u16,new:*const u16,flags:u32)->i32;
}
#[link(name="advapi32")]
extern "system" {
    fn RegOpenKeyExW(key:isize,subkey:*const u16,options:u32,access:u32,result:*mut isize)->i32;
    fn RegCloseKey(key:isize)->i32;
}
const WAIT_OBJECT_0:u32=0; const WAIT_ABANDONED:u32=0x80; const WAIT_TIMEOUT:u32=0x102;
fn wide(s:&OsStr)->Vec<u16>{s.encode_wide().chain(std::iter::once(0)).collect()}
struct Mutex(isize);
impl Mutex {
    fn lock()->Result<Self>{
        // This named lock serializes participating sessions across folders in this user.
        // Match the existing PowerShell launcher's mutex naming convention.
        let output=Command::new("whoami.exe").arg("/user").arg("/fo").arg("csv").arg("/nh").output()?;
        if !output.status.success() {return Err("Cannot determine user SID for registry lock".into());}
        let identity=String::from_utf8_lossy(&output.stdout);
        let sid=identity.trim().trim_matches('"').split("\",\"").last().unwrap_or("").trim_matches('"').replace('-', "_");
        if !sid.starts_with("S_1_") {return Err("Invalid user SID for registry lock".into());}
        let name=wide(OsStr::new(&format!("Local\\BravePortableState_{sid}")));
        let handle=unsafe{CreateMutexW(ptr::null_mut(),0,name.as_ptr())};
        if handle==0{return Err(io::Error::last_os_error().into());}
        match unsafe{WaitForSingleObject(handle,0)} {
            WAIT_OBJECT_0|WAIT_ABANDONED=>Ok(Self(handle)),
            WAIT_TIMEOUT=>{unsafe{CloseHandle(handle);};Err("Another registry-swapping Brave session is active".into())}
            _=>{let err=io::Error::last_os_error();unsafe{CloseHandle(handle);};Err(err.into())}
        }
    }
}
impl Drop for Mutex {fn drop(&mut self){unsafe{ReleaseMutex(self.0);CloseHandle(self.0);}}}

const REGISTRY:&str=r"HKCU\Software\BraveSoftware";
const POLICY:&str=r"HKCU\Software\Policies\BraveSoftware\Brave";
#[derive(serde::Serialize,serde::Deserialize)]
struct State {keys:Vec<KeyState>}
#[derive(serde::Serialize,serde::Deserialize)]
struct KeyState {key:String, existed:bool, backup:String, portable:String}

fn reg(args:&[&str])->Result<()>{
    let status=Command::new("reg.exe").args(args).status()?;
    if status.success(){Ok(())}else{Err(format!("reg.exe {:?} failed: {status}",args).into())}
}
fn exists(key:&str)->Result<bool>{
    const HKCU:isize=0x80000001_u32 as i32 as isize;
    const KEY_READ:u32=0x20019;
    let relative=key.strip_prefix("HKCU\\").ok_or("Expected HKCU registry key")?;
    let wide_key=wide(OsStr::new(relative));
    let mut handle=0isize;
    let status=unsafe{RegOpenKeyExW(HKCU,wide_key.as_ptr(),0,KEY_READ,&mut handle)};
    match status {
        0=>{unsafe{RegCloseKey(handle);};Ok(true)},
        2=>Ok(false), // ERROR_FILE_NOT_FOUND; no localized text parsing
        code=>Err(io::Error::from_raw_os_error(code).into()),
    }
}

fn export(key:&str,path:&Path)->Result<()>{
    let destination=path.to_str().ok_or("Registry backup path isn't valid Unicode")?;
    let tmp=path.with_extension("tmp.reg");
    reg(&["export",key,tmp.to_str().ok_or("Invalid temporary backup path")?,"/y"])?;
    let source_wide=wide(tmp.as_os_str());
    let dest_wide=wide(OsStr::new(destination));
    // Win32 atomic replacement supports repeat portable captures on Windows.
    if unsafe{MoveFileExW(source_wide.as_ptr(),dest_wide.as_ptr(),0x1|0x8)}==0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(())
}
fn import(path:&Path)->Result<()>{
    reg(&["import",path.to_str().ok_or("Invalid import path")?])
}
fn delete(key:&str)->Result<()>{
    if exists(key)? {reg(&["delete",key,"/f"])?;}
    Ok(())
}
fn ensure_no_brave()->Result<()>{
    let output=Command::new("tasklist.exe")
        .args(["/FI","IMAGENAME eq brave.exe","/FO","CSV","/NH"]).output()?;
    if !output.status.success(){return Err("Cannot check Brave processes before registry swap".into());}
    if String::from_utf8_lossy(&output.stdout).lines()
        .any(|line|line.trim_start().to_ascii_lowercase().starts_with("\"brave.exe\"")){
        return Err("Close all Brave processes before registry-swapping mode".into());
    }
    Ok(())
}
pub fn wait_for_brave_exit()->Result<()> {
    let started=std::time::Instant::now();
    loop {
        if started.elapsed()>Duration::from_secs(6*60*60) {return Err("Timed out waiting for Brave to exit; registry remains swapped for manual recovery".into());}
        match ensure_no_brave() {
            Ok(()) => return Ok(()),
            Err(error) if error.to_string() == "Close all Brave processes before registry-swapping mode" => {
                std::thread::sleep(Duration::from_millis(800));
            }
            Err(error) => return Err(error),
        }
    }
}
/// Explicit recovery only: never restore host keys while Brave is running.
pub fn recover(root:&Path)->Result<()> {
    let _lock=Mutex::lock()?;
    ensure_no_brave()?;
    let folder=root.join("Data").join("Registry");
    let journal=folder.join("active-session.json");
    if !journal.exists() {return Err("No interrupted registry session to recover".into());}
    let state:State=serde_json::from_slice(&fs::read(&journal)?)?;
    let mut seen=std::collections::HashSet::new();
    if state.keys.len()>2 || state.keys.iter().any(|entry| !seen.insert(entry.key.clone())) {return Err("Recovery journal has duplicate or excessive keys".into());}
    if state.keys.is_empty() {return Err("Recovery journal has no registry keys".into());}
    for entry in &state.keys {
        if entry.key != REGISTRY && entry.key != POLICY {return Err("Recovery journal contains an unexpected registry key".into());}
        if (entry.key==REGISTRY && entry.portable!="portable-brave.reg") || (entry.key==POLICY && entry.portable!="portable-policy.reg") {return Err("Recovery journal has an invalid portable snapshot mapping".into());}
        if entry.existed {
            if Path::new(&entry.backup).components().count()!=1 {return Err("Invalid recovery backup name".into());}
            let backup=folder.join(&entry.backup);
            if !backup.is_file() {return Err(format!("Recovery backup missing: {}", backup.display()).into());}
            let canonical_folder=fs::canonicalize(&folder)?;
            let canonical_backup=fs::canonicalize(&backup)?;
            if !canonical_backup.starts_with(&canonical_folder) {return Err("Recovery backup escapes registry folder".into());}
        }
    }
    // Save the current live keys before restoring the older snapshot.
    let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos();
    for entry in &state.keys {
        if exists(&entry.key)? {
            let name=if entry.key==REGISTRY {"brave"} else {"policy"};
            export(&entry.key,&folder.join(format!("before-manual-recovery-{stamp}-{name}.reg")))?;
        }
    }
    // Preserve the journal if any restore step fails so recovery can be retried.
    let mut errors=Vec::new();
    for entry in &state.keys {
        if let Err(e)=delete(&entry.key) {errors.push(format!("Delete {}: {e}",entry.key));continue;}
        if entry.existed {
            if let Err(e)=import(&folder.join(&entry.backup)) {errors.push(format!("Restore {}: {e}",entry.key));}
        }
    }
    if !errors.is_empty() {return Err(errors.join("; ").into());}
    fs::remove_file(&journal)?;
    Ok(())
}
pub struct Session {folder:PathBuf,journal:PathBuf,state:State,_lock:Mutex}
impl Session {
    pub fn start(root:&Path,profile:&Path,cache:&Path,include_registry:bool,include_policy:bool)->Result<Self>{
        let lock=Mutex::lock()?;
        // Avoid modifying host keys when a prior portable session is unfinished.
        ensure_no_brave()?;
        let folder=root.join("Data").join("Registry");
        fs::create_dir_all(&folder)?;
        let journal=folder.join("active-session.json");
        if journal.exists(){
            return Err(format!("Interrupted registry swap: {journal:?}. Do not launch until original keys are recovered using the pre-session backups.").into());
        }
        let mut state=State{keys:Vec::new()};
        let suffix = format!("{}-{}",std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos());
        for (key,backup,portable) in [
            (REGISTRY,"host-brave.reg","portable-brave.reg"),
            (POLICY,"host-policy.reg","portable-policy.reg"),
        ]{
            if (key==REGISTRY && !include_registry) || (key==POLICY && !include_policy) {continue;}
            let present=exists(key)?;
            let backup_name=format!("{suffix}-{backup}");
            if present {export(key,&folder.join(&backup_name))?;}
            state.keys.push(KeyState{key:key.into(),existed:present,backup:backup_name,portable:portable.into()});
        }
        // Journal MUST exist before modifying either live key.
        fs::write(&journal,serde_json::to_vec_pretty(&state)?)?;
        let session=Self{folder,journal,state,_lock:lock};
        if let Err(error)=session.activate(profile,cache,include_policy){
            // On partial activation, restore immediately; preserve journal when this fails.
            if session.restore_host().is_ok(){
                let _=fs::remove_file(&session.journal);
            }
            return Err(error);
        }
        Ok(session)
    }
    fn activate(&self,profile:&Path,cache:&Path,include_policy:bool)->Result<()>{
        for key in &self.state.keys {
            delete(&key.key)?;
            let file=self.folder.join(&key.portable);
            if file.exists(){import(&file)?;}
        }
        if !include_policy {return Ok(());}
        // Portable policies override portable settings, NEVER existing host policies.
        // Both are restored at end of session.
        for (name,value) in [
            ("UserDataDir",profile.to_str().ok_or("Invalid profile path")?),
            ("DiskCacheDir",cache.to_str().ok_or("Invalid cache path")?),
        ]{
            reg(&["add",POLICY,"/v",name,"/t","REG_SZ","/d",value,"/f"])?;
        }
        for name in ["BackgroundModeEnabled","DefaultBrowserSettingEnabled"]{
            reg(&["add",POLICY,"/v",name,"/t","REG_DWORD","/d","0","/f"])?;
        }
        Ok(())
    }
    fn restore_host(&self)->Result<()>{
        // Try both restores even when the first fails, but never remove the journal on errors.
        let mut failures=Vec::new();
        for key in &self.state.keys {
            if let Err(e)=delete(&key.key){failures.push(format!("delete {}: {e}",key.key));continue;}
            if key.existed {
                if let Err(e)=import(&self.folder.join(&key.backup)){
                    failures.push(format!("restore {}: {e}",key.key));
                }
            }
        }
        if failures.is_empty(){Ok(())}else{Err(failures.join("; ").into())}
    }
    pub fn finish(self)->Result<()>{
        let mut capture_error=None;
        let mut pending=Vec::<(PathBuf,PathBuf)>::new();
        for key in &self.state.keys {
            let output=self.folder.join(&key.portable);
            let staged=output.with_extension("pending.reg");
            match exists(&key.key) {
                Ok(true)=>{if let Err(e)=export(&key.key,&staged){capture_error=Some(e.to_string());}else{pending.push((staged,output));}},
                Ok(false)=>{ pending.push((PathBuf::new(),output)); },
                Err(e)=>capture_error=Some(e.to_string()),
            }
        }
        let restored=self.restore_host();
        restored?;
        if let Some(error)=capture_error {return Err(format!("Portable registry capture failed; previous snapshots preserved: {error}").into());}
        // Preserve the preceding generation so an interrupted multi-file commit
        // is recoverable without silently accepting a mixed snapshot set.
        let rollback=self.folder.join("snapshot-rollback");
        if rollback.exists() {return Err("Unresolved portable snapshot rollback directory".into());}
        fs::create_dir(&rollback)?;
        let mut manifest=Vec::new();
        for (_,output) in &pending {
            let name=output.file_name().ok_or("Invalid snapshot file")?;
            let existed=output.exists();
            if existed {fs::copy(output,rollback.join(name))?;}
            manifest.push((output.clone(),existed));
        }
        let commit = (|| -> Result<()> {
            for (staged,output) in &pending {
                if staged.as_os_str().is_empty() {
                    if output.exists() {fs::remove_file(output)?;}
                } else {
                    let src=wide(staged.as_os_str());
                    let dst=wide(output.as_os_str());
                    if unsafe{MoveFileExW(src.as_ptr(),dst.as_ptr(),0x1|0x8)}==0 {
                        return Err(io::Error::last_os_error().into());
                    }
                }
            }
            Ok(())
        })();
        if let Err(error)=commit {
            // The rollback directory and journal remain if recovery fails.
            for (output,existed) in &manifest {
                if *existed {fs::copy(rollback.join(output.file_name().ok_or("Invalid snapshot name")?),output)?;}
                else if output.exists() {fs::remove_file(output)?;}
            }
            fs::remove_dir_all(&rollback)?;
            return Err(error);
        }
        fs::remove_dir_all(&rollback)?;
        fs::remove_file(&self.journal)?;
        Ok(())
    }
}
