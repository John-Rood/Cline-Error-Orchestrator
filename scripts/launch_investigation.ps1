# launch_investigation.ps1
# Launches VS Code in the correct workspace and automatically triggers Cline
# with an investigation prompt using keyboard simulation (SendKeys).

param(
    [string]$Service,           # Service name to investigate (required unless -ListServices)
    
    [int]$WaitTime = 3,         # Seconds to wait for VS Code to load
    [switch]$NoLaunch,          # Don't launch IDE, just print info
    [switch]$ListServices,      # List all services with pending errors
    [switch]$ClearPending       # Clear pending errors for this service after viewing
)

$ErrorActionPreference = "Stop"

# Get the script's directory and navigate to orchestrator root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OrchestratorRoot = Split-Path -Parent $ScriptDir

# Load configuration
$ConfigPath = Join-Path $OrchestratorRoot "config\services.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    Write-Host "Copy config\services.example.json to config\services.json and customize it."
    exit 1
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$Services = $Config.services
$IdeCommand = if ($Config.ide_command) { $Config.ide_command } else { "code" }

# Handle -ListServices
if ($ListServices) {
    $PendingDir = Join-Path $OrchestratorRoot "data\pending"
    $PendingFiles = Get-ChildItem -Path $PendingDir -Filter "*.json" -ErrorAction SilentlyContinue
    
    if ($PendingFiles.Count -eq 0) {
        Write-Host "No pending errors for any service."
        exit 0
    }
    
    Write-Host "Services with pending errors:"
    foreach ($File in $PendingFiles) {
        $ServiceName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        $PendingData = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $ErrorCount = $PendingData.errors.Count
        $ErrorTypes = ($PendingData.errors | ForEach-Object { $_.error_type } | Select-Object -Unique) -join ", "
        Write-Host "  $ServiceName : $ErrorCount error(s) ($ErrorTypes)"
    }
    exit 0
}

# Require -Service if not listing
if (-not $Service) {
    Write-Error "Please specify -Service <name> or use -ListServices to see available services."
    Write-Host "Usage: .\launch_investigation.ps1 -Service <service-name>"
    Write-Host "       .\launch_investigation.ps1 -ListServices"
    exit 1
}

# Validate service exists in configuration
if (-not $Services.PSObject.Properties[$Service]) {
    Write-Error "Service '$Service' not found in configuration."
    Write-Host "Available services: $($Services.PSObject.Properties.Name -join ', ')"
    exit 1
}

$ServiceConfig = $Services.$Service
$WorkspacePath = $ServiceConfig.workspace
$CustomWorkflow = if ($ServiceConfig.workflow) { $ServiceConfig.workflow } else { "investigate.md" }

# Validate workspace exists
if (-not (Test-Path $WorkspacePath)) {
    Write-Error "Workspace path does not exist: $WorkspacePath"
    exit 1
}

# Check for pending errors
$PendingFile = Join-Path $OrchestratorRoot "data\pending\$Service.json"
if (-not (Test-Path $PendingFile)) {
    Write-Host "No pending errors for service: $Service"
    exit 0
}

# Load pending errors
$PendingData = Get-Content $PendingFile -Raw | ConvertFrom-Json
$ErrorCount = $PendingData.errors.Count
$ErrorTypes = ($PendingData.errors | ForEach-Object { $_.error_type } | Select-Object -Unique) -join ", "

Write-Host "=== Investigation Summary ==="
Write-Host "Service: $Service"
Write-Host "Workspace: $WorkspacePath"
Write-Host "Pending Errors: $ErrorCount"
Write-Host "Error Types: $ErrorTypes"
Write-Host "Pending File: $PendingFile"
Write-Host ""

# Show error details
Write-Host "=== Errors to Investigate ==="
$i = 1
foreach ($ErrorItem in $PendingData.errors) {
    Write-Host "$i. [$($ErrorItem.severity)] $($ErrorItem.error_type)"
    Write-Host "   Message: $($ErrorItem.message.Substring(0, [Math]::Min(100, $ErrorItem.message.Length)))..."
    Write-Host "   First seen: $($ErrorItem.first_seen)"
    Write-Host ""
    $i++
}

# Handle -ClearPending
if ($ClearPending) {
    Remove-Item $PendingFile -Force
    Write-Host "Cleared pending errors for: $Service"
    exit 0
}

# Handle -NoLaunch
if ($NoLaunch) {
    Write-Host "NoLaunch specified. Run without -NoLaunch to start investigation."
    exit 0
}

# Build the investigation prompt using custom workflow if defined
$Prompt = @"
/$CustomWorkflow

Investigate $ErrorCount new error(s) in service: $Service
Error types: $ErrorTypes
Pending errors file: $PendingFile

Read the pending errors file, analyze each distinct error, classify as User Error/System Bug/External Factor, and recommend appropriate patches. Document findings in AUTOMATED_PATCHES.md, then run the push workflow.
"@

Write-Host "=== Launching Investigation ==="
Write-Host "Opening VS Code in: $WorkspacePath"

# 1. Open VS Code in the service workspace
Start-Process $IdeCommand -ArgumentList "`"$WorkspacePath`""

# 2. Wait for VS Code to fully load
Write-Host "Waiting $WaitTime seconds for VS Code to load..."
Start-Sleep -Seconds $WaitTime

# 3. Load SendKeys API
Add-Type -AssemblyName System.Windows.Forms

# 4. Bring VS Code to foreground (helps ensure SendKeys work)
# Note: This may not always work perfectly depending on Windows settings
$WshShell = New-Object -ComObject WScript.Shell
$WshShell.AppActivate("Visual Studio Code")
Start-Sleep -Milliseconds 500

# 5. Send Ctrl+' to focus Cline chat input
Write-Host "Focusing Cline input (Ctrl+')..."
[System.Windows.Forms.SendKeys]::SendWait("^'")
Start-Sleep -Milliseconds 500

# 6. Type the investigation prompt
# SendKeys has special characters that need escaping: + ^ % ~ ( ) { }
# We'll replace them with their escaped versions
Write-Host "Typing investigation prompt..."
$EscapedPrompt = $Prompt -replace '\+', '{+}' `
                         -replace '\^', '{^}' `
                         -replace '%', '{%}' `
                         -replace '~', '{~}' `
                         -replace '\(', '{(}' `
                         -replace '\)', '{)}' `
                         -replace '\{', '{{}' `
                         -replace '\}', '{}}' `
                         -replace "`n", '{ENTER}' `
                         -replace "`r", ''

# SendKeys doesn't handle very long strings well, so we'll send it in chunks
$ChunkSize = 100
for ($i = 0; $i -lt $EscapedPrompt.Length; $i += $ChunkSize) {
    $Chunk = $EscapedPrompt.Substring($i, [Math]::Min($ChunkSize, $EscapedPrompt.Length - $i))
    [System.Windows.Forms.SendKeys]::SendWait($Chunk)
    Start-Sleep -Milliseconds 50
}

# 7. Press Enter to submit
Write-Host "Submitting task..."
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

Write-Host ""
Write-Host "=== Investigation Started ==="
Write-Host "Cline should now be investigating the errors."
Write-Host ""
Write-Host "After investigation is complete, run:"
Write-Host "  .\launch_investigation.ps1 -Service $Service -ClearPending"
Write-Host "to clear the pending errors."
