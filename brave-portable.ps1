<#
.SYNOPSIS
    Self-contained portable launcher for Brave with registry management
    and group-policy hijacking.

.DESCRIPTION
    Replaces the portapps.io brave-portable.exe wrapper. Makes Brave fully
    portable through four layers of redirection:

      1. ENVIRONMENT VARIABLES
         APPDATA and LOCALAPPDATA are redirected into Data\AppData\... so
         Brave (and every child process it spawns) writes support files
         into the Data folder instead of %USERPROFILE%\AppData.

      2. COMMAND-LINE FLAGS
         --user-data-dir and --disk-cache-dir point at Data\profile and
         Data\cache. --no-default-browser-check and --disable-background-mode
         keep it self-contained.

      3. GROUP POLICY HIJACKING  (unless -NoPolicy)
         Brave (like Chromium) reads policies from
         HKCU\Software\Policies\BraveSoftware\Brave. We inject:
           UserDataDir                   = Data\profile
           DiskCacheDir                  = Data\cache
           BackgroundModeEnabled         = 0
           DefaultBrowserSettingEnabled  = 0
           SyncDisabled                  = 1
         These enforce portable behaviour even for helper processes that
         might not inherit the command-line flags. They are removed again
         after Brave exits.

      4. REGISTRY BACKUP / RESTORE / CLEANUP  (unless -NoRegistry)
         Brave writes to HKCU\Software\BraveSoftware\* (window placement,
         metrics, version beacon, etc.). To keep that state portable AND
         not clobber a real Brave install, on every launch we:
           a. (once) back up any existing real-install registry to
              Data\registry\real-install-backup.reg as a safety copy.
           b. snapshot the current live HKCU\Software\BraveSoftware to a
              temp pre-session.reg.
           c. delete the live key (clean slate).
           d. import Data\registry\brave-portable.reg (the portable state
              saved at the end of the previous session, if any).
         After Brave exits we:
           e. export the live HKCU\Software\BraveSoftware back to
              Data\registry\brave-portable.reg (persisting this session).
           f. delete the live key.
           g. delete the injected policy keys.
           h. clean up stray default-browser / app-paths keys.
           i. re-import pre-session.reg (restoring whatever was there
              before we started -- real install state, or nothing).
         Net result: while Brave runs it sees its own portable registry;
         after it closes the live registry is exactly as it was before.

         The script WAITS for Brave to exit so cleanup can run. Use
         -NoWait to fire-and-forget (cleanup is skipped, with a warning).

.PARAMETER BraveArgs
    Extra arguments forwarded verbatim to brave.exe (--incognito, URLs...).

.PARAMETER NoRegistry
    Skip the registry backup/restore/cleanup layer. Env + flags + policy
    still apply. Use this only if you don't care about registry portability.

.PARAMETER NoPolicy
    Skip group-policy injection. Env + flags + registry still apply.
    (Policy injection is best-effort anyway: if HKCU\Software\Policies is
    ACL-locked and the write is denied, the script warns and continues
    with the other three layers. Pass -NoPolicy to suppress those warnings.)

.PARAMETER NoWait
    Launch Brave and return immediately. WARNING: registry cleanup and
    policy removal are skipped, so live BraveSoftware / policy keys will
    remain until the next clean launch. Avoid unless you know why.

.EXAMPLE
    .\brave-portable.ps1
    Full portable launch: env + flags + policy + registry, waits for exit.

.EXAMPLE
    .\brave-portable.ps1 --incognito
    Portable launch in incognito mode.

.EXAMPLE
    .\brave-portable.ps1 https://example.com
    Portable launch opening a URL.
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$BraveArgs,
    [switch]$NoRegistry,
    [switch]$NoPolicy,
    [switch]$NoWait
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$AppDir    = Join-Path $ScriptDir "app"
$DataDir   = Join-Path $ScriptDir "Data"
$RegDir    = Join-Path $DataDir "registry"

# --- REGISTRY PATHS ---
#  PowerShell provider form (HKCU:\...) for Test-Path / Set-ItemProperty
#  and native form (HKCU\...) for reg.exe export / import.
$BraveRegKeyPs     = "HKCU:\Software\BraveSoftware"
$BraveRegKeyNative = "HKCU\Software\BraveSoftware"
$PolicyRegKeyPs    = "HKCU:\Software\Policies\BraveSoftware\Brave"
$PolicyParentPs    = "HKCU:\Software\Policies\BraveSoftware"
$PolicyRootPs      = "HKCU:\Software\Policies"

# Stray keys Brave may create if it ever tries to register as default browser.
$StrayKeysPs = @(
    "HKCU:\Software\Clients\StartMenuInternet\BraveBrowser",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\brave.exe",
    "HKCU:\Software\RegisteredApplications"
)

# --- PORTABLE STATE FILES ---
$PortableRegFile    = Join-Path $RegDir "brave-portable.reg"
$PreSessionRegFile  = Join-Path $RegDir "pre-session.reg"
$RealInstallBackup  = Join-Path $RegDir "real-install-backup.reg"

# ============================================================
#  LOCATE brave.exe UNDER app\
# ============================================================
$braveExe = Get-ChildItem -Path $AppDir -Recurse -Filter "brave.exe" -File -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $braveExe) {
    Write-Error "brave.exe was not found under '$AppDir'. Run download_brave.ps1 first."
    exit 1
}

# ============================================================
#  CREATE THE PORTABLE DATA FOLDERS
# ============================================================
$profileDir     = Join-Path $DataDir "profile"
$cacheDir       = Join-Path $DataDir "cache"
$appdataRoaming = Join-Path $DataDir "AppData\Roaming"
$appdataLocal   = Join-Path $DataDir "AppData\Local"
foreach ($d in @($profileDir, $cacheDir, $appdataRoaming, $appdataLocal, $RegDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

# ============================================================
#  LAYER 1: REDIRECT APPDATA ENV VARS
#  brave.exe and every child process inherits these.
# ============================================================
$env:APPDATA      = $appdataRoaming
$env:LOCALAPPDATA = $appdataLocal

# ============================================================
#  LAYER 2: COMMAND-LINE FLAGS
# ============================================================
$argList = @(
    "--user-data-dir=`"$profileDir`"",
    "--disk-cache-dir=`"$cacheDir`"",
    "--no-default-browser-check",
    "--disable-background-mode"
)
if ($BraveArgs) { $argList += $BraveArgs }
$argString = $argList -join " "

# ============================================================
#  LAYER 4: REGISTRY BACKUP / RESTORE  (pre-launch)
# ============================================================
$registryManaged = $false
if (-not $NoRegistry) {

    # (a) One-time safety backup of a real Brave install's registry, in case
    #     the user has Brave installed system-wide and we're about to touch
    #     HKCU\Software\BraveSoftware. Only created on the very first run.
    if ((-not (Test-Path $PortableRegFile)) -and
        (Test-Path $BraveRegKeyPs) -and
        (-not (Test-Path $RealInstallBackup))) {
        & reg.exe export $BraveRegKeyNative "$RealInstallBackup" /y 2>$null | Out-Null
        if (Test-Path $RealInstallBackup) {
            Write-Host "[registry] One-time backup of existing Brave install -> real-install-backup.reg"
        }
    }

    # (b) Snapshot whatever is in the live key right now (real-install state,
    #     leftover portable state, or nothing) so we can restore it after.
    if (Test-Path $BraveRegKeyPs) {
        & reg.exe export $BraveRegKeyNative "$PreSessionRegFile" /y 2>$null | Out-Null
        Write-Host "[registry] Snapshotted live state -> pre-session.reg"
    } else {
        if (Test-Path $PreSessionRegFile) { Remove-Item $PreSessionRegFile -Force -ErrorAction SilentlyContinue }
    }

    # (c) Delete the live key for a clean slate.
    if (Test-Path $BraveRegKeyPs) {
        Remove-Item -Path $BraveRegKeyPs -Recurse -Force -ErrorAction SilentlyContinue
    }

    # (d) Import portable state from the previous session (if any).
    if (Test-Path $PortableRegFile) {
        & reg.exe import "$PortableRegFile" 2>$null | Out-Null
        Write-Host "[registry] Restored portable state <- brave-portable.reg"
    }

    $registryManaged = $true
} else {
    Write-Host "[registry] Skipped (-NoRegistry)."
}

# ============================================================
#  LAYER 3: GROUP POLICY HIJACKING
#  Inject policies under HKCU\Software\Policies\BraveSoftware\Brave.
#  These are respected by Brave and all its helper processes, enforcing
#  portable behaviour even without relying solely on command-line flags.
#
#  NOTE: HKCU\Software\Policies is often ACL-locked on Windows (read-only
#  for the current user, even when elevated on some setups). Injection is
#  BEST-EFFORT: if it is denied we warn and continue -- the other three
#  layers (env vars, command-line flags, registry management) still keep
#  Brave fully portable. Policy injection is belt-and-suspenders for
#  helper processes that might not inherit the flags.
# ============================================================
$policyInjected = $false
if (-not $NoPolicy) {
    try {
        if (-not (Test-Path $PolicyRegKeyPs)) {
            New-Item -Path $PolicyRegKeyPs -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $PolicyRegKeyPs -Name "UserDataDir"                  -Value $profileDir -Type String  -ErrorAction Stop
        Set-ItemProperty -Path $PolicyRegKeyPs -Name "DiskCacheDir"                 -Value $cacheDir   -Type String  -ErrorAction Stop
        Set-ItemProperty -Path $PolicyRegKeyPs -Name "BackgroundModeEnabled"        -Value 0           -Type DWord   -ErrorAction Stop
        Set-ItemProperty -Path $PolicyRegKeyPs -Name "DefaultBrowserSettingEnabled" -Value 0           -Type DWord   -ErrorAction Stop
        Set-ItemProperty -Path $PolicyRegKeyPs -Name "SyncDisabled"                 -Value 1           -Type DWord   -ErrorAction Stop
        $policyInjected = $true
        Write-Host "[policy] Injected group policies -> HKCU\Software\Policies\BraveSoftware\Brave"
    } catch {
        Write-Warning "[policy] Could not inject group policies: $($_.Exception.Message.Trim())"
        Write-Warning "[policy] HKCU\Software\Policies is often read-only for the current user."
        Write-Warning "[policy] To enable policy hijacking, run this script as Administrator (right-click -> Run as administrator),"
        Write-Warning "[policy] or pass -NoPolicy to suppress this message."
        Write-Warning "[policy] Continuing WITHOUT policies -- Brave is still portable via env vars + flags + registry management."
    }
} else {
    Write-Host "[policy] Skipped (-NoPolicy)."
}

# ============================================================
#  LAUNCH BRAVE
# ============================================================
Write-Host ""
Write-Host "Launching Brave (portable sandbox)..."
Write-Host "  exe      : $($braveExe.FullName)"
Write-Host "  profile  : $profileDir"
Write-Host "  cache    : $cacheDir"
Write-Host "  appdata  : $appdataLocal"
Write-Host "  registry : $(if ($registryManaged) { 'managed (backup/restore/cleanup)' } else { 'unmanaged' })"
Write-Host "  policy   : $(if ($policyInjected) { 'injected' } elseif (-not $NoPolicy) { 'denied (see warnings above) -- using env+flags+registry only' } else { 'skipped (-NoPolicy)' })"
Write-Host ""

if ($NoWait) {
    Start-Process -FilePath $braveExe.FullName -ArgumentList $argString -WorkingDirectory $ScriptDir
    Write-Warning "-NoWait: Brave launched without waiting. Registry cleanup and policy removal are SKIPPED. Live BraveSoftware / policy keys will remain until the next clean launch."
    exit 0
}

# --- WAIT FOR BRAVE TO EXIT, THEN CLEAN UP ---
try {
    $proc = Start-Process -FilePath $braveExe.FullName -ArgumentList $argString -WorkingDirectory $ScriptDir -PassThru
    Write-Host "Brave PID: $($proc.Id). This window will stay open until Brave exits so registry cleanup can run."
    $proc.WaitForExit()
    Write-Host ""
    Write-Host "Brave exited (code $($proc.ExitCode)). Running cleanup..."
} finally {

    # --- CLEANUP: only meaningful if we waited for exit ---

    # (e) Persist this session's portable registry state.
    if ($registryManaged -and (Test-Path $BraveRegKeyPs)) {
        & reg.exe export $BraveRegKeyNative "$PortableRegFile" /y 2>$null | Out-Null
        Write-Host "[registry] Saved portable state -> brave-portable.reg"
        # (f) Delete the live key.
        Remove-Item -Path $BraveRegKeyPs -Recurse -Force -ErrorAction SilentlyContinue
    }

    # (g) Remove the injected policy keys -- but ONLY if we actually
    #     injected them. If injection was denied there is nothing of ours
    #     to remove, and attempting to delete HKCU\Software\Policies\...
    #     would just throw the same permission error again.
    if ($policyInjected) {
        if (Test-Path $PolicyParentPs) {
            Remove-Item -Path $PolicyParentPs -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Also remove the empty Policies root if nothing else is using it.
        $policyChildren = @(Get-ChildItem -Path $PolicyRootPs -ErrorAction SilentlyContinue)
        if ($policyChildren.Count -eq 0) {
            Remove-Item -Path $PolicyRootPs -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "[policy] Removed injected group policies."
    }

    # (h) Clean up stray default-browser / app-paths keys Brave may have made.
    foreach ($k in $StrayKeysPs) {
        # RegisteredApplications holds many apps; only remove the Brave value,
        # not the whole key.
        if ($k -eq "HKCU:\Software\RegisteredApplications") {
            $ra = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
            if ($ra) {
                $braveProps = $ra.PSObject.Properties | Where-Object { $_.Name -match "Brave" }
                foreach ($p in $braveProps) {
                    Remove-ItemProperty -Path $k -Name $p.Name -ErrorAction SilentlyContinue
                }
            }
        } else {
            if (Test-Path $k) {
                Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # (i) Restore the pre-session registry state (real install or empty).
    if ($registryManaged -and (Test-Path $PreSessionRegFile)) {
        & reg.exe import "$PreSessionRegFile" 2>$null | Out-Null
        Remove-Item $PreSessionRegFile -Force -ErrorAction SilentlyContinue
        Write-Host "[registry] Restored pre-session live state."
    }

    Write-Host "Cleanup complete. The live registry is back to its pre-launch state."
}
