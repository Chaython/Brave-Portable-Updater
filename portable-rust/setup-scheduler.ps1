<#
Register or remove a per-user Brave Portable Rust update task.
Run after setting Data/settings.json; the task starts the Rust launcher
with --update-only, so no browser window is opened.
#>
[CmdletBinding()]
param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$exe = Join-Path $root 'BravePortable.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Place this script beside BravePortable.exe: $exe"
}
$settingsFile = Join-Path $root 'Data\settings.json'
if (-not (Test-Path -LiteralPath $settingsFile)) {
    throw "Launch BravePortable.exe once to create $settingsFile"
}
$settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
$frequency = [string]$settings.update_frequency
if ($frequency -notin @('never','launch','daily','weekly')) {
    throw "Invalid update_frequency in $settingsFile"
}
$resolvedRoot = [IO.Path]::GetFullPath($root).TrimEnd([char]92).ToLowerInvariant()
$algorithm = [Security.Cryptography.SHA256]::Create()
try { $sha = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($resolvedRoot)) }
finally { $algorithm.Dispose() }
$id = ([BitConverter]::ToString($sha) -replace '-', '').Substring(0,16)
$name = "BravePortableRustUpdate-$id"
# Delete orphaned Rust tasks only when their target executable no longer exists.
Get-ScheduledTask -TaskName 'BravePortableRustUpdate-*' -ErrorAction SilentlyContinue | ForEach-Object {
    $oldTask = $_
    foreach ($oldAction in @($oldTask.Actions)) {
        $oldExe = [string]$oldAction.Execute
        if ($oldExe -and [IO.Path]::GetFileName($oldExe) -ieq 'BravePortable.exe' -and -not (Test-Path -LiteralPath $oldExe)) {
            Unregister-ScheduledTask -TaskName $oldTask.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            break
        }
    }
}
if ($Remove -or $frequency -eq 'never' -or -not $settings.scheduled_updates) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed task $name (if present)."
    exit 0
}
# Frequency 'launch' is handled within the launcher; no repeating scheduler task.
if ($frequency -eq 'launch') {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Updates will be checked on launch. No scheduled task needed."
    exit 0
}
# The Rust launcher, rather than a nested PowerShell command, is the task action.
$action = New-ScheduledTaskAction -Execute $exe -Argument '--update-only' -WorkingDirectory $root
$trigger = if ($frequency -eq 'weekly') {
    New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '12:00'
} else {
    New-ScheduledTaskTrigger -Daily -At '12:00'
}
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $taskSettings -Description 'Update extracted Brave binaries for portable Rust launcher' -Force | Out-Null
Write-Host "Registered $frequency update task: $name"
Write-Host "The task only runs when this user is logged on. Its EXE path is $exe."
