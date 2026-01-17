# poll_errors.ps1
# Polls GCP Cloud Logging for new ERROR and CRITICAL logs, deduplicates them,
# and writes new distinct errors to pending queues for investigation.

param(
    [switch]$AutoLaunch,        # Automatically launch investigation for first service with errors
    [switch]$LaunchAll,         # Launch investigation for all services with errors
    [switch]$Silent,            # Suppress desktop notifications
    [switch]$Verbose,           # Show detailed output
    [switch]$WhatIf,            # Dry run - don't write files or launch
    [int]$BufferMinutes = 1     # Extra minutes to look back beyond polling interval
)

$ErrorActionPreference = "Stop"

# Get the script's directory and navigate to orchestrator root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OrchestratorRoot = Split-Path -Parent $ScriptDir

# File paths for state tracking
$LastPollPath = Join-Path $OrchestratorRoot "data\last_poll.json"
$ErrorStatusPath = Join-Path $OrchestratorRoot "data\error_status.json"

# Load configuration
$ConfigPath = Join-Path $OrchestratorRoot "config\services.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    Write-Host "Copy config\services.example.json to config\services.json and customize it."
    exit 1
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$PollingIntervalMinutes = $Config.polling_interval_minutes
$Services = $Config.services
$Provider = if ($Config.provider) { $Config.provider } else { "gcp" }

if ($Verbose) {
    Write-Host "Configuration loaded:"
    Write-Host "  Provider: $Provider"
    Write-Host "  Polling Interval: $PollingIntervalMinutes minutes"
    Write-Host "  Services: $($Services.PSObject.Properties.Name -join ', ')"
}

# Calculate time window - use last poll time if available (handles sleep/wake)
# This ensures we don't miss errors that occurred while the computer was asleep
$DefaultLookbackMinutes = $PollingIntervalMinutes + $BufferMinutes
$StartTime = $null

if (Test-Path $LastPollPath) {
    try {
        $LastPollData = Get-Content $LastPollPath -Raw | ConvertFrom-Json
        $LastPollTime = [DateTime]::Parse($LastPollData.last_poll_time)
        
        # Calculate how long ago the last poll was
        $MinutesSinceLastPoll = ((Get-Date) - $LastPollTime).TotalMinutes
        
        if ($MinutesSinceLastPoll -gt $DefaultLookbackMinutes) {
            # We've been asleep or missed polls - look back to last poll time (plus buffer)
            $StartTime = $LastPollTime.AddMinutes(-$BufferMinutes).ToUniversalTime()
            if ($Verbose) { 
                Write-Host "Detected gap since last poll ($([Math]::Round($MinutesSinceLastPoll, 1)) min ago)"
                Write-Host "Looking back to last poll time: $StartTime"
            }
        }
    }
    catch {
        Write-Warning "Could not read last_poll.json, using default lookback: $_"
    }
}

# Fall back to default lookback if no last poll time or if within normal interval
if (-not $StartTime) {
    $StartTime = (Get-Date).AddMinutes(-$DefaultLookbackMinutes).ToUniversalTime()
    if ($Verbose) {
        Write-Host "Querying logs from: $StartTime (last $DefaultLookbackMinutes minutes)"
    }
}

# Load provider script
$ProviderScript = Join-Path $ScriptDir "providers\$Provider.ps1"
if (-not (Test-Path $ProviderScript)) {
    Write-Error "Provider script not found: $ProviderScript"
    exit 1
}

# Execute provider fetch
try {
    $LogEntries = & $ProviderScript -Config $Config -StartTime $StartTime -Verbose:$Verbose
    if ($Verbose) { Write-Host "Found $($LogEntries.Count) log entries" }
}
catch {
    Write-Error "Failed to execute provider script: $_"
    exit 1
}

# Note: Don't exit early here - we still need to check for stale pending files
$NoNewLogs = ($LogEntries.Count -eq 0)
if ($NoNewLogs) {
    if ($Verbose) { Write-Host "No new errors found in logs." }
}

# Function to normalize traceback line (remove variable parts)
function Normalize-TracebackLine {
    param([string]$Line)
    
    if ([string]::IsNullOrWhiteSpace($Line)) { return "" }
    
    $Normalized = $Line
    
    # Remove timestamps (various formats)
    $Normalized = $Normalized -replace '\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[.\d]*Z?', '[TIMESTAMP]'
    $Normalized = $Normalized -replace '\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}', '[TIMESTAMP]'
    
    # Remove UUIDs
    $Normalized = $Normalized -replace '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}', '[UUID]'
    
    # Remove request IDs, trace IDs (common patterns)
    $Normalized = $Normalized -replace 'request[_-]?id[=:]\s*\S+', 'request_id=[ID]'
    $Normalized = $Normalized -replace 'trace[_-]?id[=:]\s*\S+', 'trace_id=[ID]'
    $Normalized = $Normalized -replace 'correlation[_-]?id[=:]\s*\S+', 'correlation_id=[ID]'
    
    # Remove memory addresses
    $Normalized = $Normalized -replace '0x[a-fA-F0-9]+', '[ADDR]'
    
    # Remove object IDs (Python style)
    $Normalized = $Normalized -replace 'at 0x[a-fA-F0-9]+>', 'at [ADDR]>'
    $Normalized = $Normalized -replace 'object at [a-fA-F0-9]+', 'object at [ADDR]'
    
    # Remove line numbers (they change frequently)
    $Normalized = $Normalized -replace 'line \d+', 'line [N]'
    
    return $Normalized.Trim()
}

# Function to compute error signature
function Get-ErrorSignature {
    param(
        [string]$Severity,
        [string]$ErrorType,
        [string]$FirstTracebackLine,
        [string]$AffectedFunction
    )
    
    $NormalizedTraceback = Normalize-TracebackLine -Line $FirstTracebackLine
    $Components = @($Severity, $ErrorType, $NormalizedTraceback, $AffectedFunction) -join "|"
    
    $SHA256 = [System.Security.Cryptography.SHA256]::Create()
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Components)
    $Hash = $SHA256.ComputeHash($Bytes)
    $Signature = [System.BitConverter]::ToString($Hash) -replace '-', ''
    
    return $Signature.ToLower()
}

# Function to extract error info from log entry
function Get-ErrorInfo {
    param($LogEntry)
    
    $Info = @{
        Severity = $LogEntry.severity
        ErrorType = "Unknown"
        Message = ""
        Traceback = ""
        FirstTracebackLine = ""
        AffectedFunction = ""
        ServiceName = ""
        RevisionName = ""
        Timestamp = $LogEntry.timestamp
        RawEntry = $LogEntry
    }
    
    # Extract service info
    if ($LogEntry.resource.labels) {
        $Info.ServiceName = $LogEntry.resource.labels.service_name
        $Info.RevisionName = $LogEntry.resource.labels.revision_name
    }
    
    # Extract message from textPayload or jsonPayload
    if ($LogEntry.textPayload) {
        $Info.Message = $LogEntry.textPayload
        $Info.Traceback = $LogEntry.textPayload
    }
    elseif ($LogEntry.jsonPayload) {
        if ($LogEntry.jsonPayload.message) {
            $Info.Message = $LogEntry.jsonPayload.message
        }
        if ($LogEntry.jsonPayload.traceback) {
            $Info.Traceback = $LogEntry.jsonPayload.traceback
        }
        elseif ($LogEntry.jsonPayload.stack_trace) {
            $Info.Traceback = $LogEntry.jsonPayload.stack_trace
        }
        elseif ($LogEntry.jsonPayload.exception) {
            $Info.Traceback = $LogEntry.jsonPayload.exception
        }
    }
    
    # Extract error type from message (look for common patterns)
    $ErrorTypePatterns = @(
        '(?<type>\w+Error):',
        '(?<type>\w+Exception):',
        '(?<type>\w+Failure):',
        'raise (?<type>\w+)',
        'throw new (?<type>\w+)'
    )
    
    foreach ($Pattern in $ErrorTypePatterns) {
        if ($Info.Message -match $Pattern) {
            $Info.ErrorType = $Matches['type']
            break
        }
        if ($Info.Traceback -match $Pattern) {
            $Info.ErrorType = $Matches['type']
            break
        }
    }
    
    # Get first traceback line
    if ($Info.Traceback) {
        $Lines = $Info.Traceback -split "`n" | Where-Object { $_.Trim() }
        if ($Lines.Count -gt 0) {
            $Info.FirstTracebackLine = $Lines[0]
        }
    }
    
    # Try to extract affected function/endpoint
    $EndpointPatterns = @(
        '(?<endpoint>/api/\S+)',
        'endpoint[=:]\s*(?<endpoint>\S+)',
        '(?<endpoint>def \w+)',
        '(?<endpoint>function \w+)'
    )
    
    $TextToSearch = "$($Info.Message) $($Info.Traceback)"
    foreach ($Pattern in $EndpointPatterns) {
        if ($TextToSearch -match $Pattern) {
            $Info.AffectedFunction = $Matches['endpoint']
            break
        }
    }
    
    return $Info
}

# Load seen errors
$SeenErrorsPath = Join-Path $OrchestratorRoot "data\seen_errors.json"
$SeenErrors = @{}

# Load error status tracking (pending/in_progress/done)
$ErrorStatus = @{}
if (Test-Path $ErrorStatusPath) {
    try {
        $ErrorStatusData = Get-Content $ErrorStatusPath -Raw | ConvertFrom-Json
        foreach ($Property in $ErrorStatusData.PSObject.Properties) {
            $ErrorStatus[$Property.Name] = $Property.Value
        }
        if ($Verbose) { Write-Host "Loaded $($ErrorStatus.Count) error status entries" }
    }
    catch {
        Write-Warning "Could not load error_status.json, starting fresh: $_"
        $ErrorStatus = @{}
    }
}

if (Test-Path $SeenErrorsPath) {
    try {
        $SeenErrorsData = Get-Content $SeenErrorsPath -Raw | ConvertFrom-Json
        foreach ($Property in $SeenErrorsData.PSObject.Properties) {
            $SeenErrors[$Property.Name] = $Property.Value
        }
        if ($Verbose) { Write-Host "Loaded $($SeenErrors.Count) seen error signatures" }
    }
    catch {
        Write-Warning "Could not load seen_errors.json, starting fresh: $_"
        $SeenErrors = @{}
    }
}

# Process log entries
$NewErrorsByService = @{}
$UpdatedSignatures = @{}
$Now = Get-Date -Format "o"

foreach ($Entry in $LogEntries) {
    $ErrorInfo = Get-ErrorInfo -LogEntry $Entry
    
    # Skip if service not in our registry
    $ServiceName = $ErrorInfo.ServiceName
    if (-not $Services.PSObject.Properties[$ServiceName]) {
        if ($Verbose) { Write-Host "Skipping unregistered service: $ServiceName" }
        continue
    }
    
    # Compute signature
    $Signature = Get-ErrorSignature `
        -Severity $ErrorInfo.Severity `
        -ErrorType $ErrorInfo.ErrorType `
        -FirstTracebackLine $ErrorInfo.FirstTracebackLine `
        -AffectedFunction $ErrorInfo.AffectedFunction
    
    # Check if this is a new error
    if ($SeenErrors.ContainsKey($Signature)) {
        # Update last_seen and count
        $SeenErrors[$Signature].last_seen = $Now
        $SeenErrors[$Signature].occurrence_count++
        $UpdatedSignatures[$Signature] = $true
        if ($Verbose) { Write-Host "Known error (count: $($SeenErrors[$Signature].occurrence_count)): $($ErrorInfo.ErrorType) in $ServiceName" }
    }
    else {
        # New distinct error!
        if ($Verbose) { Write-Host "NEW ERROR: $($ErrorInfo.ErrorType) in $ServiceName" }
        
        # Add to seen errors
        $SeenErrors[$Signature] = @{
            first_seen = $Now
            last_seen = $Now
            occurrence_count = 1
            service_name = $ServiceName
            error_type = $ErrorInfo.ErrorType
        }
        $UpdatedSignatures[$Signature] = $true
        
        # Add to pending queue for this service
        if (-not $NewErrorsByService.ContainsKey($ServiceName)) {
            $NewErrorsByService[$ServiceName] = @()
        }
        
        $NewErrorsByService[$ServiceName] += @{
            signature = $Signature
            first_seen = $Now
            occurrence_count = 1
            severity = $ErrorInfo.Severity
            error_type = $ErrorInfo.ErrorType
            message = $ErrorInfo.Message
            traceback = $ErrorInfo.Traceback
            resource_labels = @{
                service_name = $ServiceName
                revision_name = $ErrorInfo.RevisionName
            }
            sample_log_entry = $ErrorInfo.RawEntry
        }
        
        # Track error status with timestamps (pending/in_progress/done)
        # This prevents race conditions when multiple AI instances work on errors
        $ErrorStatus[$Signature] = @{
            status = "pending"
            service = $ServiceName
            error_type = $ErrorInfo.ErrorType
            timestamps = @{
                created_at = $Now
                started_at = $null
                completed_at = $null
            }
        }
    }
}

# Summary
$TotalNewErrors = ($NewErrorsByService.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
$LaunchScript = Join-Path $ScriptDir "launch_investigation.ps1"
$ServicesToLaunch = @()

# Check for stale pending files FIRST (before any early exit)
# These may be failed/disrupted investigations that need to be re-launched
$StaleThresholdMinutes = 10
$PendingDir = Join-Path $OrchestratorRoot "data\pending"
$StalePendingFiles = Get-ChildItem -Path $PendingDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
    $AgeMinutes = ((Get-Date) - $_.LastWriteTime).TotalMinutes
    $AgeMinutes -gt $StaleThresholdMinutes
}

foreach ($StaleFile in $StalePendingFiles) {
    $StaleService = [System.IO.Path]::GetFileNameWithoutExtension($StaleFile.Name)
    $AgeMinutes = [Math]::Round(((Get-Date) - $StaleFile.LastWriteTime).TotalMinutes, 1)
    Write-Host "Stale pending file found: $StaleService (${AgeMinutes} min old) - will re-launch investigation"
    $ServicesToLaunch += $StaleService
}

if ($TotalNewErrors -eq 0 -and $ServicesToLaunch.Count -eq 0) {
    if ($Verbose) { Write-Host "No new distinct errors found and no stale pending files." }
    
    if (-not $WhatIf) {
        # Save updated seen_errors (for counts/timestamps)
        if ($UpdatedSignatures.Count -gt 0) {
            $SeenErrors | ConvertTo-Json -Depth 10 | Set-Content $SeenErrorsPath
        }
        
        # Always save last poll timestamp - critical for sleep/wake tracking
        # If computer sleeps and wakes up, we'll look back to this time
        $LastPollData = @{
            last_poll_time = $Now
            errors_found = 0
        }
        $LastPollData | ConvertTo-Json | Set-Content $LastPollPath
        if ($Verbose) { Write-Host "Updated last poll time: $Now" }
    }
    Write-Host "Done. No actions needed."
    exit 0
}

if ($TotalNewErrors -eq 0) {
    if ($Verbose) { Write-Host "No new distinct errors, but found stale pending files to retry." }
}

Write-Host "Found $TotalNewErrors new distinct error(s) across $($NewErrorsByService.Count) service(s):"
foreach ($ServiceName in $NewErrorsByService.Keys) {
    $Errors = $NewErrorsByService[$ServiceName]
    $ErrorTypes = ($Errors | ForEach-Object { $_.error_type } | Select-Object -Unique) -join ", "
    Write-Host "  $ServiceName : $($Errors.Count) errors ($ErrorTypes)"
}

# Write pending files and save state files
if (-not $WhatIf) {
    # Save seen errors
    $SeenErrors | ConvertTo-Json -Depth 10 | Set-Content $SeenErrorsPath
    
    # Save error status tracking (pending/in_progress/done with timestamps)
    $ErrorStatus | ConvertTo-Json -Depth 10 | Set-Content $ErrorStatusPath
    if ($Verbose) { Write-Host "Updated error status file: $ErrorStatusPath" }
    
    # Save last poll timestamp - this handles sleep/wake scenarios
    # On wake, we'll look back to this time instead of just the polling interval
    $LastPollData = @{
        last_poll_time = $Now
        errors_found = $TotalNewErrors
    }
    $LastPollData | ConvertTo-Json | Set-Content $LastPollPath
    if ($Verbose) { Write-Host "Updated last poll time: $Now" }
    
    # Write pending files for each service
    foreach ($ServiceName in $NewErrorsByService.Keys) {
        $PendingPath = Join-Path $OrchestratorRoot "data\pending\$ServiceName.json"
        $PendingData = @{
            service = $ServiceName
            generated_at = $Now
            errors = $NewErrorsByService[$ServiceName]
        }
        $PendingData | ConvertTo-Json -Depth 20 | Set-Content $PendingPath
        if ($Verbose) { Write-Host "Wrote pending file: $PendingPath" }
    }
}

# Show notification
if (-not $Silent) {
    try {
        # Try BurntToast first
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast
            $ServiceList = $NewErrorsByService.Keys -join ", "
            New-BurntToastNotification -Text "Error Orchestrator", "$TotalNewErrors new error(s) in: $ServiceList" -Sound "Default"
        }
        else {
            # Fallback to basic notification
            Add-Type -AssemblyName System.Windows.Forms
            $Balloon = New-Object System.Windows.Forms.NotifyIcon
            $Balloon.Icon = [System.Drawing.SystemIcons]::Warning
            $Balloon.BalloonTipIcon = "Warning"
            $Balloon.BalloonTipTitle = "Error Orchestrator"
            $Balloon.BalloonTipText = "$TotalNewErrors new error(s) detected"
            $Balloon.Visible = $true
            $Balloon.ShowBalloonTip(5000)
            Start-Sleep -Seconds 1
            $Balloon.Dispose()
        }
    }
    catch {
        Write-Warning "Could not show notification: $_"
    }
}

# Auto-launch: Add new errors to launch list (stale files were already added above)
if ($AutoLaunch -or $LaunchAll) {
    if ($LaunchAll) {
        foreach ($ServiceName in $NewErrorsByService.Keys) {
            if ($ServiceName -notin $ServicesToLaunch) {
                $ServicesToLaunch += $ServiceName
            }
        }
    }
    else {
        # Launch for first new service only (if any)
        $FirstService = $NewErrorsByService.Keys | Select-Object -First 1
        if ($FirstService -and $FirstService -notin $ServicesToLaunch) {
            $ServicesToLaunch += $FirstService
        }
    }
}

# Launch investigations for all services in the list
foreach ($ServiceName in $ServicesToLaunch) {
    Write-Host "Launching investigation for: $ServiceName"
    & $LaunchScript -Service $ServiceName
    Start-Sleep -Seconds 5  # Give some time between launches
}

Write-Host "Done. Run 'launch_investigation.ps1 -Service <name>' to investigate."
