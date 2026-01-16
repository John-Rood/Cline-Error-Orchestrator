# status.ps1
# Shows current status of the Error Orchestrator system.

$ErrorActionPreference = "Stop"

# Get the script's directory and navigate to orchestrator root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OrchestratorRoot = Split-Path -Parent $ScriptDir

Write-Host "=== Error Orchestrator Status ==="
Write-Host ""

# Configuration
$ConfigPath = Join-Path $OrchestratorRoot "config\services.json"
if (Test-Path $ConfigPath) {
    $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    Write-Host "Configuration: LOADED"
    Write-Host "  GCP Project: $($Config.gcp_project)"
    Write-Host "  Polling Interval: $($Config.polling_interval_minutes) minutes"
    Write-Host "  Services: $($Config.services.PSObject.Properties.Count)"
    foreach ($ServiceProp in $Config.services.PSObject.Properties) {
        Write-Host "    - $($ServiceProp.Name) -> $($ServiceProp.Value.workspace)"
    }
}
else {
    Write-Host "Configuration: NOT FOUND"
    Write-Host "  Copy config\services.example.json to config\services.json"
}
Write-Host ""

# Scheduled Task
Write-Host "Scheduled Task:"
$TaskName = "ErrorOrchestrator-Poll"
try {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Task) {
        Write-Host "  Status: $($Task.State)"
        $TaskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host "  Last Run: $($TaskInfo.LastRunTime)"
        Write-Host "  Next Run: $($TaskInfo.NextRunTime)"
    }
    else {
        Write-Host "  Status: NOT INSTALLED"
        Write-Host "  Run: .\setup_task_scheduler.ps1 -Install"
    }
}
catch {
    Write-Host "  Status: UNKNOWN (access denied?)"
}
Write-Host ""

# Pending Errors
Write-Host "Pending Errors:"
$PendingDir = Join-Path $OrchestratorRoot "data\pending"
$PendingFiles = Get-ChildItem -Path $PendingDir -Filter "*.json" -ErrorAction SilentlyContinue
if ($PendingFiles.Count -eq 0) {
    Write-Host "  None"
}
else {
    $TotalErrors = 0
    foreach ($File in $PendingFiles) {
        $ServiceName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        $PendingData = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $ErrorCount = $PendingData.errors.Count
        $TotalErrors += $ErrorCount
        $ErrorTypes = ($PendingData.errors | ForEach-Object { $_.error_type } | Select-Object -Unique) -join ", "
        Write-Host "  $ServiceName : $ErrorCount error(s) ($ErrorTypes)"
    }
    Write-Host "  TOTAL: $TotalErrors error(s) awaiting investigation"
}
Write-Host ""

# Seen Errors
Write-Host "Seen Errors (deduplication):"
$SeenErrorsPath = Join-Path $OrchestratorRoot "data\seen_errors.json"
if (Test-Path $SeenErrorsPath) {
    $SeenErrors = Get-Content $SeenErrorsPath -Raw | ConvertFrom-Json
    $SignatureCount = $SeenErrors.PSObject.Properties.Count
    Write-Host "  Total signatures: $SignatureCount"
    
    # Show recent ones
    $Recent = $SeenErrors.PSObject.Properties | 
        Sort-Object { $_.Value.last_seen } -Descending | 
        Select-Object -First 5
    
    if ($Recent.Count -gt 0) {
        Write-Host "  Recent errors:"
        foreach ($Entry in $Recent) {
            Write-Host "    - $($Entry.Value.error_type) in $($Entry.Value.service_name) (count: $($Entry.Value.occurrence_count))"
        }
    }
}
else {
    Write-Host "  No errors seen yet"
}
Write-Host ""

Write-Host "=== Quick Actions ==="
Write-Host "  Manual poll:      .\scripts\run_now.ps1"
Write-Host "  List pending:     .\scripts\launch_investigation.ps1 -ListServices"
Write-Host "  Investigate:      .\scripts\launch_investigation.ps1 -Service <name>"
Write-Host "  Clear pending:    .\scripts\clear_pending.ps1 -Service <name>"
