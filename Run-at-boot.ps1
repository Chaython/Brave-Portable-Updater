# Set the parameters
$TaskName = "BravePortableUpdate"
$TaskDescription = "Update brave portable at boot"
$TaskCommand = "\download_brave.ps1"
$TaskArguments = "\download_brave.ps1"
$TaskTrigger = New-ScheduledTaskTrigger -AtStartup

# Create the action
$TaskAction = New-ScheduledTaskAction -Execute $TaskCommand -Argument $TaskArguments

# Register the task
Register-ScheduledTask -TaskName $TaskName -Description $TaskDescription -Trigger $TaskTrigger -Action $TaskAction
