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
    let status=Command::new("reg.exe").args(["query",key]).output()?;
    match status.status.code(){
        Some(0)=>Ok(true),
        Some(1) if { let message=format!("{} {}",String::from_utf8_lossy(&status.stdout),String::from_utf8_lossy(&status.stderr)).to_ascii_lowercase(); message.contains("unable to find") || message.contains("cannot find") } => Ok(false),
        _=>Err(format!("Could not query registry key {key}: {}",String::from_utf8_lossy(&status.stderr)).into()),
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
        for key in &self.state.keys {
            let output=self.folder.join(&key.portable);
            match exists(&key.key) {
                Ok(true)=>{if let Err(e)=export(&key.key,&output){capture_error=Some(e.to_string());}},
                Ok(false)=>{let _=fs::remove_file(&output);},
                Err(e)=>capture_error=Some(e.to_string()),
            }
        }
        let restored=self.restore_host();
        if restored.is_ok(){fs::remove_file(&self.journal)?;}
        restored?;
        if let Some(error)=capture_error {return Err(format!("Portable registry capture failed: {error}").into());}
        Ok(())
    }
}
