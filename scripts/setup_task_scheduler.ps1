# setup_task_scheduler.ps1
# Configures Windows Task Scheduler to run error polling automatically.
# Requires Administrator privileges for some operations.

param(
    [switch]$Install,      # Install the scheduled task
    [switch]$Uninstall,    # Remove the scheduled task
    [switch]$Status,       # Show current task status
    [switch]$AutoLaunch    # Include -AutoLaunch flag when polling
)

$ErrorActionPreference = "Stop"
$TaskName = "ErrorOrchestrator-Poll"

# Get the script's directory and navigate to orchestrator root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OrchestratorRoot = Split-Path -Parent $ScriptDir

# Load configuration for interval
$ConfigPath = Join-Path $OrchestratorRoot "config\services.json"
if (Test-Path $ConfigPath) {
    $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $IntervalMinutes = $Config.polling_interval_minutes
    if (-not $IntervalMinutes) { $IntervalMinutes = 5 }
}
else {
    $IntervalMinutes = 5
}

# Handle -Status
if ($Status) {
    try {
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($Task) {
            Write-Host "Task: $TaskName"
            Write-Host "State: $($Task.State)"
            
            $TaskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
            Write-Host "Last Run: $($TaskInfo.LastRunTime)"
            Write-Host "Last Result: $($TaskInfo.LastTaskResult)"
            Write-Host "Next Run: $($TaskInfo.NextRunTime)"
            
            $Trigger = $Task.Triggers | Select-Object -First 1
            Write-Host "Interval: Every $($Trigger.Repetition.Interval) (Duration: $($Trigger.Repetition.Duration))"
        }
        else {
            Write-Host "Task '$TaskName' is not installed."
        }
    }
    catch {
        Write-Host "Task '$TaskName' is not installed or access denied."
    }
    exit 0
}

# Handle -Uninstall
if ($Uninstall) {
    try {
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($Task) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Task '$TaskName' has been removed."
        }
        else {
            Write-Host "Task '$TaskName' was not installed."
        }
    }
    catch {
        Write-Error "Failed to uninstall task: $_"
        Write-Host "You may need to run this script as Administrator."
    }
    exit 0
}

# Handle -Install
if ($Install) {
    # Check if config exists
    if (-not (Test-Path $ConfigPath)) {
        Write-Error "Configuration file not found: $ConfigPath"
        Write-Host "Create config\services.json before installing the scheduled task."
        exit 1
    }
    
    # Build the action
    $PollScript = Join-Path $ScriptDir "poll_errors.ps1"
    $Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PollScript`""
    if ($AutoLaunch) {
        $Arguments += " -AutoLaunch"
    }
    
    Write-Host "Installing scheduled task: $TaskName"
    Write-Host "Interval: Every $IntervalMinutes minutes"
    Write-Host "Script: $PollScript"
    Write-Host "Auto-launch: $AutoLaunch"
    
    try {
        # Check if task already exists
        $ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($ExistingTask) {
            $Confirm = Read-Host "Task already exists. Update it? (y/N)"
            if ($Confirm -ne 'y' -and $Confirm -ne 'Y') {
                Write-Host "Cancelled."
                exit 0
            }
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
        
        # Create the action
        $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $Arguments -WorkingDirectory $OrchestratorRoot
        
        # Create a trigger that runs every N minutes indefinitely
        # Use 365 days as duration (effectively indefinite, will need renewal if task runs that long)
        $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 365)
        
        # Task settings
        $Settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RunOnlyIfNetworkAvailable `
            -MultipleInstances IgnoreNew
        
        # Create the task
        $Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        
        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $Action `
            -Trigger $Trigger `
            -Settings $Settings `
            -Principal $Principal `
            -Description "Error Orchestrator - Polls GCP logs for errors and triggers AI investigation" | Out-Null
        
        Write-Host ""
        Write-Host "Task '$TaskName' installed successfully!"
        Write-Host ""
        Write-Host "The task will run every $IntervalMinutes minutes."
        Write-Host "Use '.\setup_task_scheduler.ps1 -Status' to check status."
        Write-Host "Use '.\setup_task_scheduler.ps1 -Uninstall' to remove."
    }
    catch {
        Write-Error "Failed to install task: $_"
        Write-Host ""
        Write-Host "If you get 'Access denied', try running PowerShell as Administrator."
    }
    exit 0
}

# No action specified - show help
Write-Host "Error Orchestrator Task Scheduler Setup"
Write-Host ""
Write-Host "Usage:"
Write-Host "  .\setup_task_scheduler.ps1 -Install      Install the scheduled task"
Write-Host "  .\setup_task_scheduler.ps1 -Install -AutoLaunch  Install with auto-launch enabled"
Write-Host "  .\setup_task_scheduler.ps1 -Uninstall    Remove the scheduled task"
Write-Host "  .\setup_task_scheduler.ps1 -Status       Show current task status"
Write-Host ""
Write-Host "Current configuration:"
Write-Host "  Polling interval: $IntervalMinutes minutes"
Write-Host "  Config file: $ConfigPath"
