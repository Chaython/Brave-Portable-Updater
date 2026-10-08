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
Write-Host 'Windows Brave registry and browser policies will not be modified.'
$proc = Start-Process -FilePath $braveExe -WorkingDirectory $scriptDir -ArgumentList $argumentString -PassThru -ErrorAction Stop
if ($NoWait) { $proc.Dispose(); return }
try {
    $proc.WaitForExit()
    $root = [IO.Path]::GetFullPath($appDir).TrimEnd([char]92) + [char]92
    do {
        $running = @(Get-CimInstance Win32_Process -Filter "Name = 'brave.exe'" -ErrorAction Stop |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
        if ($running.Count -gt 0) { Start-Sleep -Milliseconds 500 }
    } while ($running.Count -gt 0)
} finally {
    $proc.Dispose()
}
