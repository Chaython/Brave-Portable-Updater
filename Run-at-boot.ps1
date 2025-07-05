# Elevation check: relaunch as Administrator if needed
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Relaunching as Administrator..."
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Set the parameters
$TaskName = "BravePortableUpdate"
$TaskDescription = "Update brave portable at boot"

# Get the directory of this script
$CurrentScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Set the full path to download_brave.ps1
$TaskCommand = Join-Path $CurrentScriptDir "download_brave.ps1"

# Create the trigger and action
$TaskTrigger = New-ScheduledTaskTrigger -AtStartup
$TaskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$TaskCommand`""

# Register the task (will update if it exists)
Register-ScheduledTask -TaskName $TaskName -Description $TaskDescription -Trigger $TaskTrigger -Action $TaskAction -Force

Write-Host "Scheduled task '$TaskName' created/updated to run $TaskCommand at system startup."
