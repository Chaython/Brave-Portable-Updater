<#
.SYNOPSIS
    Start Brave with a self-contained profile and cache.
.DESCRIPTION
    Does not modify HKCU Brave keys, default-browser registrations, or group policies.
    Chromium flags isolate browser profile/cache; APPDATA and LOCALAPPDATA are
    redirected for child processes. This is not an OS-level sandbox.
    Historical -NoRegistry and -NoPolicy flags are accepted for compatibility.
.PARAMETER NoWait
    Return immediately after launching Brave.
.PARAMETER BraveArgs
    Additional Brave arguments such as URLs or --incognito.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$BraveArgs,
    [switch]$NoRegistry,
    [switch]$NoPolicy,
    [switch]$NoWait
)
$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$appDir = Join-Path $scriptDir 'app'
$dataDir = Join-Path $scriptDir 'Data'
$profileDir = Join-Path $dataDir 'profile'
$cacheDir = Join-Path $dataDir 'cache'
$roamingDir = Join-Path $dataDir 'AppData\Roaming'
$localDir = Join-Path $dataDir 'AppData\Local'

$executables = @(Get-ChildItem -LiteralPath $appDir -Filter 'brave.exe' -Recurse -File -ErrorAction SilentlyContinue)
if ($executables.Count -ne 1) {
    throw "Expected exactly one brave.exe under '$appDir' (found $($executables.Count)). Run the updater or remove obsolete binaries."
}
$braveExe = $executables[0].FullName
foreach ($folder in @($profileDir, $cacheDir, $roamingDir, $localDir)) {
    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
}
$env:APPDATA = $roamingDir
$env:LOCALAPPDATA = $localDir

# Always enforce the portable profile arguments AFTER caller-supplied flags.
# This prevents a trailing --user-data-dir supplied by mistake from escaping the portable profile.
$forwarded = @()
foreach ($arg in @($BraveArgs)) {
    if ($arg -match '^(?i)--(?:user-data-dir|disk-cache-dir)(?:=|$)') {
        throw 'Profile and cache paths are controlled by the portable launcher. Remove custom --user-data-dir / --disk-cache-dir arguments.'
    }
    $forwarded += $arg
}
$argsToPass = @(
    "--user-data-dir=$profileDir"
    "--disk-cache-dir=$cacheDir"
    '--no-default-browser-check'
    '--disable-background-mode'
) + $forwarded

# Start-Process accepts a joined ArgumentList; quote bare paths, URLs with spaces,
# and all remaining arguments to preserve their boundaries.
function Quote-WindowsArgument([string]$value) {
    if ($value -eq '') { return '""' }
    if ($value -notmatch '[\s"]') { return $value }
    $escaped = $value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}
$argumentString = ($argsToPass | ForEach-Object { Quote-WindowsArgument $_ }) -join ' '
Write-Host "Launching portable Brave: $braveExe"
Write-Host "Profile: $profileDir"
Write-Host 'Brave registry and group-policy state will be captured for this session.'
# Capture portable Brave registry and policies, restoring the user's previous
# keys at the end. Backups are retained to assist with manual recovery.
$regDir = Join-Path $dataDir 'registry'
New-Item -ItemType Directory -Path $regDir -Force | Out-Null
$keys = @(
    @{ Native='HKCU\Software\BraveSoftware'; PS='HKCU:\Software\BraveSoftware'; Portable='portable.reg'; Backup='before.reg'; Enabled=(-not $NoRegistry) },
    @{ Native='HKCU\Software\Policies\BraveSoftware\Brave'; PS='HKCU:\Software\Policies\BraveSoftware\Brave'; Portable='portable-policy.reg'; Backup='before-policy.reg'; Enabled=(-not $NoPolicy) }
)
$mutex = $null
$locked = $false
$started = $false
$proc = $null
$journal = Join-Path $regDir 'active-session.json'

function Export-Key($key, $file) {
    $tmp = "$file.$([guid]::NewGuid().ToString('N')).tmp"
    & reg.exe export $key $tmp /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Export failed: $key" }
    Move-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
}
function Import-Key($file) {
    & reg.exe import $file | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Import failed: $file" }
}
function Remove-Key($path) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    }
}
if ($NoWait -and (-not $NoRegistry -or -not $NoPolicy)) {
    throw 'For -NoWait, supply both -NoRegistry and -NoPolicy; state capture requires waiting for Brave to exit.'
}
try {
    if (-not $NoRegistry -or -not $NoPolicy) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.Replace('-', '_')
        $mutex = New-Object Threading.Mutex($false, "Local\BravePortableState_$sid")
        try { $locked = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another Brave portable session owns the registry.' }
        if (Test-Path -LiteralPath $journal) {
            throw "Previous session did not finish; recover using backups in $regDir before launching."
        }
        if (@(Get-CimInstance Win32_Process -Filter "Name='brave.exe'" -ErrorAction Stop).Count -gt 0) {
            throw 'Close other Brave processes before activating registry/group-policy capture.'
        }
        $snapshot = @()
        foreach ($key in $keys) {
            if (-not $key.Enabled) { continue }
            $exists = Test-Path -LiteralPath $key.PS
            $backup = Join-Path $regDir $key.Backup
            if ($exists) { Export-Key $key.Native $backup }
            $snapshot += @{ Name=$key.PS; Existed=[bool]$exists }
        }
        $snapshot | ConvertTo-Json | Set-Content -LiteralPath $journal -Encoding UTF8 -ErrorAction Stop
        $started = $true
        foreach ($key in $keys) {
            if (-not $key.Enabled) { continue }
            Remove-Key $key.PS
            $portable = Join-Path $regDir $key.Portable
            if (Test-Path -LiteralPath $portable) { Import-Key $portable }
        }
        if (-not $NoPolicy) {
            $policy = 'HKCU:\Software\Policies\BraveSoftware\Brave'
            New-Item -Path $policy -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $policy -Name 'UserDataDir' -Value $profileDir -PropertyType String -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $policy -Name 'DiskCacheDir' -Value $cacheDir -PropertyType String -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $policy -Name 'BackgroundModeEnabled' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $policy -Name 'DefaultBrowserSettingEnabled' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }
    }
    $proc = Start-Process -FilePath $braveExe -WorkingDirectory $scriptDir -ArgumentList $argumentString -PassThru -ErrorAction Stop
    if (-not $NoWait) {
        $proc.WaitForExit()
        $root = [IO.Path]::GetFullPath($appDir).TrimEnd([char]92) + [char]92
        do {
            $running = @(Get-CimInstance Win32_Process -Filter "Name='brave.exe'" -ErrorAction Stop |
                Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
            if ($running.Count) { Start-Sleep -Milliseconds 500 }
        } while ($running.Count)
    }
} finally {
    if ($proc) { $proc.Dispose() }
    if ($started) {
        $restored = $false
        try {
            foreach ($key in $keys) {
                if (-not $key.Enabled) { continue }
                $portable = Join-Path $regDir $key.Portable
                if (Test-Path -LiteralPath $key.PS) { Export-Key $key.Native $portable }
            }
            foreach ($key in $keys) {
                if (-not $key.Enabled) { continue }
                Remove-Key $key.PS
                $record = @($snapshot | Where-Object { $_.Name -eq $key.PS })[0]
                if ($record.Existed) { Import-Key (Join-Path $regDir $key.Backup) }
            }
            $restored = $true
        } finally {
            if ($restored) { Remove-Item -LiteralPath $journal -Force -ErrorAction Stop }
            else { Write-Warning "Restoration incomplete; recovery snapshots preserved in $regDir" }
        }
    }
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
