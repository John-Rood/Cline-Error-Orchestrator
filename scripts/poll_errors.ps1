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

# Load configuration
$ConfigPath = Join-Path $OrchestratorRoot "config\services.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    Write-Host "Copy config\services.example.json to config\services.json and customize it."
    exit 1
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$GcpProject = $Config.gcp_project
$PollingIntervalMinutes = $Config.polling_interval_minutes
$Services = $Config.services

if ($Verbose) {
    Write-Host "Configuration loaded:"
    Write-Host "  GCP Project: $GcpProject"
    Write-Host "  Polling Interval: $PollingIntervalMinutes minutes"
    Write-Host "  Services: $($Services.PSObject.Properties.Name -join ', ')"
}

# Calculate time window
$LookbackMinutes = $PollingIntervalMinutes + $BufferMinutes
$StartTime = (Get-Date).AddMinutes(-$LookbackMinutes).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

if ($Verbose) {
    Write-Host "Querying logs from: $StartTime (last $LookbackMinutes minutes)"
}

# Build gcloud filter - only ERROR and CRITICAL from Cloud Run
$Filter = "severity>=ERROR AND resource.type=`"cloud_run_revision`" AND timestamp>=`"$StartTime`""

# Execute gcloud logging read
try {
    $GcloudCmd = "gcloud logging read `"$Filter`" --project=$GcpProject --format=json --limit=500"
    if ($Verbose) { Write-Host "Executing: $GcloudCmd" }
    
    $LogOutput = Invoke-Expression $GcloudCmd 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "gcloud command failed: $LogOutput"
        exit 1
    }
    
    # Parse JSON output
    if ([string]::IsNullOrWhiteSpace($LogOutput) -or $LogOutput -eq "[]") {
        if ($Verbose) { Write-Host "No errors found in the last $LookbackMinutes minutes." }
        exit 0
    }
    
    $LogEntries = $LogOutput | ConvertFrom-Json
    if ($Verbose) { Write-Host "Found $($LogEntries.Count) log entries" }
}
catch {
    Write-Error "Failed to query GCP logs: $_"
    exit 1
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
    }
}

# Summary
$TotalNewErrors = ($NewErrorsByService.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
if ($TotalNewErrors -eq 0) {
    if ($Verbose) { Write-Host "No new distinct errors found." }
    
    # Still save updated seen_errors (for counts/timestamps)
    if (-not $WhatIf -and $UpdatedSignatures.Count -gt 0) {
        $SeenErrors | ConvertTo-Json -Depth 10 | Set-Content $SeenErrorsPath
    }
    exit 0
}

Write-Host "Found $TotalNewErrors new distinct error(s) across $($NewErrorsByService.Count) service(s):"
foreach ($ServiceName in $NewErrorsByService.Keys) {
    $Errors = $NewErrorsByService[$ServiceName]
    $ErrorTypes = ($Errors | ForEach-Object { $_.error_type } | Select-Object -Unique) -join ", "
    Write-Host "  $ServiceName : $($Errors.Count) errors ($ErrorTypes)"
}

# Write pending files and save seen_errors
if (-not $WhatIf) {
    # Save seen errors
    $SeenErrors | ConvertTo-Json -Depth 10 | Set-Content $SeenErrorsPath
    
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

# Auto-launch if requested
if ($AutoLaunch -or $LaunchAll) {
    $LaunchScript = Join-Path $ScriptDir "launch_investigation.ps1"
    
    if ($LaunchAll) {
        foreach ($ServiceName in $NewErrorsByService.Keys) {
            Write-Host "Launching investigation for: $ServiceName"
            & $LaunchScript -Service $ServiceName
            Start-Sleep -Seconds 5  # Give some time between launches
        }
    }
    else {
        # Launch for first service only
        $FirstService = $NewErrorsByService.Keys | Select-Object -First 1
        Write-Host "Launching investigation for: $FirstService"
        & $LaunchScript -Service $FirstService
    }
}

Write-Host "Done. Run 'launch_investigation.ps1 -Service <name>' to investigate."
