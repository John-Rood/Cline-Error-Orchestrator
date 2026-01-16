# clear_pending.ps1
# Clears pending error queues after investigation is complete.

param(
    [string]$Service,      # Service name to clear
    [switch]$All,          # Clear all pending queues
    [switch]$Force         # Skip confirmation
)

$ErrorActionPreference = "Stop"

# Get the script's directory and navigate to orchestrator root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OrchestratorRoot = Split-Path -Parent $ScriptDir
$PendingDir = Join-Path $OrchestratorRoot "data\pending"

# Validate parameters
if (-not $Service -and -not $All) {
    Write-Error "Specify -Service <name> or -All to clear pending errors."
    exit 1
}

# Get files to clear
if ($All) {
    $FilesToClear = Get-ChildItem -Path $PendingDir -Filter "*.json" -ErrorAction SilentlyContinue
    if ($FilesToClear.Count -eq 0) {
        Write-Host "No pending error files to clear."
        exit 0
    }
}
else {
    $PendingFile = Join-Path $PendingDir "$Service.json"
    if (-not (Test-Path $PendingFile)) {
        Write-Host "No pending errors for service: $Service"
        exit 0
    }
    $FilesToClear = @(Get-Item $PendingFile)
}

# Show what will be cleared
Write-Host "Files to clear:"
foreach ($File in $FilesToClear) {
    $ServiceName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $PendingData = Get-Content $File.FullName -Raw | ConvertFrom-Json
    $ErrorCount = $PendingData.errors.Count
    Write-Host "  $ServiceName : $ErrorCount error(s)"
}

# Confirm unless -Force
if (-not $Force) {
    $Confirm = Read-Host "Clear these pending error queues? (y/N)"
    if ($Confirm -ne 'y' -and $Confirm -ne 'Y') {
        Write-Host "Cancelled."
        exit 0
    }
}

# Clear the files
foreach ($File in $FilesToClear) {
    $ServiceName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    Remove-Item $File.FullName -Force
    Write-Host "Cleared: $ServiceName"
}

Write-Host "Done."
