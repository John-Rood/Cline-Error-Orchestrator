# launch_investigation.ps1
# Launches VS Code in the correct workspace and automatically triggers Cline
# with an investigation prompt using keyboard simulation (SendKeys).

param(
    [string]$Service,           # Service name to investigate (required unless -ListServices)
    [string]$Lookback = "",     # Lookback window for log query (e.g., "24h", "7d"). If set, queries logs directly
    
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

# Handle -Lookback: Query logs directly with specified time window
$PendingFile = Join-Path $OrchestratorRoot "data\pending\$Service.json"

if ($Lookback) {
    Write-Host "=== Querying Logs with Lookback: $Lookback ==="
    
    # Parse lookback window (e.g., "24h", "7d", "12h", "3d")
    $LookbackMinutes = 0
    if ($Lookback -match '^(\d+)h$') {
        $LookbackMinutes = [int]$Matches[1] * 60
    }
    elseif ($Lookback -match '^(\d+)d$') {
        $LookbackMinutes = [int]$Matches[1] * 60 * 24
    }
    else {
        Write-Error "Invalid lookback format: $Lookback. Use format like '24h' (hours) or '7d' (days)."
        exit 1
    }
    
    Write-Host "Looking back $LookbackMinutes minutes..."
    
    # Calculate start time
    $StartTime = (Get-Date).AddMinutes(-$LookbackMinutes).ToUniversalTime()
    
    # Load and execute provider script
    $Provider = if ($Config.provider) { $Config.provider } else { "gcp" }
    $ProviderScript = Join-Path $ScriptDir "providers\$Provider.ps1"
    
    if (-not (Test-Path $ProviderScript)) {
        Write-Error "Provider script not found: $ProviderScript"
        exit 1
    }
    
    try {
        $LogEntries = & $ProviderScript -Config $Config -StartTime $StartTime -Verbose
        Write-Host "Found $($LogEntries.Count) log entries"
    }
    catch {
        Write-Error "Failed to query logs: $_"
        exit 1
    }
    
    # Filter to only this service
    $ServiceLogs = $LogEntries | Where-Object { 
        $_.resource.labels.service_name -eq $Service 
    }
    
    if ($ServiceLogs.Count -eq 0) {
        Write-Host "No errors found for service '$Service' in the last $Lookback"
        exit 0
    }
    
    Write-Host "Found $($ServiceLogs.Count) errors for service '$Service'"
    
    # Convert to pending format
    $Now = Get-Date -Format "o"
    $Errors = @()
    
    foreach ($Entry in $ServiceLogs) {
        $Message = if ($Entry.textPayload) { $Entry.textPayload } else { "" }
        $ErrorType = "Unknown"
        
        # Extract error type
        if ($Message -match '(?<type>\w+Error):') { $ErrorType = $Matches['type'] }
        elseif ($Message -match '(?<type>\w+Exception):') { $ErrorType = $Matches['type'] }
        
        $Errors += @{
            signature = [guid]::NewGuid().ToString()
            first_seen = $Now
            occurrence_count = 1
            severity = $Entry.severity
            error_type = $ErrorType
            message = $Message
            traceback = $Message
            resource_labels = @{
                service_name = $Service
                revision_name = $Entry.resource.labels.revision_name
            }
            sample_log_entry = $Entry
        }
    }
    
    # Write pending file
    $PendingData = @{
        service = $Service
        generated_at = $Now
        lookback_query = $Lookback
        errors = $Errors
    }
    $PendingData | ConvertTo-Json -Depth 20 | Set-Content $PendingFile
    Write-Host "Created pending file with $($Errors.Count) errors from $Lookback lookback"
}

# Check for pending errors
if (-not (Test-Path $PendingFile)) {
    Write-Host "No pending errors for service: $Service"
    Write-Host "Tip: Use -Lookback 24h to query recent logs"
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

# 1. Copy prompt to clipboard FIRST (before any window switching)
Write-Host "Copying investigation prompt to clipboard..."
Set-Clipboard -Value $Prompt

# 2. Open VS Code in the service workspace
Start-Process $IdeCommand -ArgumentList "`"$WorkspacePath`""

# 3. Wait for VS Code to fully load (longer wait for reliability)
Write-Host "Waiting $WaitTime seconds for VS Code to load..."
Start-Sleep -Seconds $WaitTime

# 4. Load SendKeys API
Add-Type -AssemblyName System.Windows.Forms

# 5. Bring VS Code to foreground using multiple methods
Write-Host "Activating VS Code window..."
$WshShell = New-Object -ComObject WScript.Shell

# Try to activate by window title - try several variations
$Activated = $WshShell.AppActivate("Visual Studio Code")
if (-not $Activated) {
    $Activated = $WshShell.AppActivate("Code")
}
Start-Sleep -Seconds 1

# 6. Send Ctrl+' to focus Cline chat input
Write-Host "Focusing Cline input (Ctrl+')..."
[System.Windows.Forms.SendKeys]::SendWait("^'")
Start-Sleep -Seconds 1

# 7. Click in the input area by sending Tab to ensure focus
Write-Host "Ensuring focus in input..."
[System.Windows.Forms.SendKeys]::SendWait("{TAB}")
Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait("+{TAB}")  # Shift+Tab back
Start-Sleep -Milliseconds 500

# 8. Paste using Ctrl+V
Write-Host "Pasting prompt from clipboard..."
[System.Windows.Forms.SendKeys]::SendWait("^v")
Start-Sleep -Seconds 1

# 9. Press Enter to submit
Write-Host "Submitting task..."
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

Write-Host ""
Write-Host "=== Investigation Started ==="
Write-Host "Cline should now be investigating the errors."
Write-Host ""
Write-Host "After investigation is complete, run:"
Write-Host "  .\launch_investigation.ps1 -Service $Service -ClearPending"
Write-Host "to clear the pending errors."
