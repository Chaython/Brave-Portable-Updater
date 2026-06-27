<#
.SYNOPSIS
    Registers (or removes) a Windows Scheduled Task that runs the Brave
    Portable updater at system startup.

.DESCRIPTION
    Creates a scheduled task named "BravePortableUpdate" that launches
    download_brave.ps1 at boot, passing through the chosen -Edition so that the
    scheduled task always updates the edition you actually want (instead of
    silently falling back to nightly). Output of the task is appended to
    brave-update.log next to this script for easy debugging.

    The script automatically re-launches itself elevated (as Administrator) and
    forwards every parameter, so -Edition and -Remove survive the elevation
    hop.

.PARAMETER Edition
    Brave edition the scheduled task should update: nightly, beta, or stable.
    Default: nightly.

.PARAMETER Remove
    Unregister the scheduled task instead of creating it.

.EXAMPLE
    .\run_at_boot.ps1
    Creates/updates the task to update the nightly edition at boot.

.EXAMPLE
    .\run_at_boot.ps1 -Edition beta
    Creates/updates the task to update the beta edition at boot.

.EXAMPLE
    .\run_at_boot.ps1 -Remove
    Removes the scheduled task.
#>
param(
    [ValidateSet("nightly", "beta", "stable")]
    [string]$Edition = "nightly",
    [switch]$Remove
)

# --- ELEVATION CHECK: relaunch as Administrator, forwarding all parameters ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Relaunching as Administrator..."
    $relaunchArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    $relaunchArgs += @("-Edition", $Edition)
    if ($Remove) { $relaunchArgs += "-Remove" }
    Start-Process powershell -ArgumentList $relaunchArgs -Verb RunAs
    exit
}

# --- CONFIGURATION ---
$TaskName        = "BravePortableUpdate"
$TaskDescription = "Update Brave Portable ($Edition edition) at boot"
$CurrentScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$TaskCommand      = Join-Path $CurrentScriptDir "download_brave.ps1"
$LogFile          = Join-Path $CurrentScriptDir "brave-update.log"

# --- REMOVE MODE ---
if ($Remove) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "Scheduled task '$TaskName' has been removed."
    } catch {
        Write-Host "Scheduled task '$TaskName' was not found (nothing to remove)."
    }
    exit 0
}

# --- BUILD THE TASK ACTION ---
# Use -Command (instead of -File) so we can redirect all output streams to a
# log file. The edition is forwarded to download_brave.ps1 so the task always
# updates the channel the user selected.
$innerCommand = "& '$TaskCommand' -Edition $Edition *>> '$LogFile'"
$TaskArgument  = "-NoProfile -ExecutionPolicy Bypass -Command `"$innerCommand`""

$TaskTrigger = New-ScheduledTaskTrigger -AtStartup
$TaskAction  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument $TaskArgument `
    -WorkingDirectory $CurrentScriptDir

# Run with highest privileges so BITS / process termination work reliably.
$TaskPrincipal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Highest

$TaskSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

# --- REGISTER THE TASK (Force overwrites an existing task of the same name) ---
Register-ScheduledTask `
    -TaskName $TaskName `
    -Description $TaskDescription `
    -Trigger $TaskTrigger `
    -Action $TaskAction `
    -Principal $TaskPrincipal `
    -Settings $TaskSettings `
    -Force | Out-Null

Write-Host "Scheduled task '$TaskName' created/updated."
Write-Host "  Command : $TaskCommand"
Write-Host "  Edition : $Edition"
Write-Host "  Log     : $LogFile"
Write-Host "Run '.\run_at_boot.ps1 -Remove' to uninstall the task."
