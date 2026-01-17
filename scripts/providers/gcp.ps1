param(
    [PSCustomObject]$Config,
    [datetime]$StartTime,
    [switch]$Verbose
)

$GcpProject = $Config.gcp_project

if ($Verbose) {
    Write-Host "Fetching GCP logs for project: $GcpProject"
    Write-Host "Start time: $StartTime"
}

# Build gcloud filter - only ERROR and CRITICAL from Cloud Run
# Use a simpler format for timestamp that gcloud can parse
$TimestampStr = $StartTime.ToString("yyyy-MM-dd")
$Filter = 'severity>=ERROR AND resource.type="cloud_run_revision" AND timestamp>="' + $TimestampStr + '"'

try {
    if ($Verbose) { Write-Host "Filter: $Filter" }
    
    # Find gcloud - check common paths
    $GcloudPath = $null
    $PossiblePaths = @(
        "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
        "C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
        "C:\Program Files\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"
    )
    
    foreach ($Path in $PossiblePaths) {
        if (Test-Path $Path) {
            $GcloudPath = $Path
            break
        }
    }
    
    if (-not $GcloudPath) {
        # Try to find in PATH
        $GcloudPath = (Get-Command gcloud -ErrorAction SilentlyContinue).Source
    }
    
    if (-not $GcloudPath) {
        Write-Error "gcloud not found. Please install Google Cloud SDK."
        return @()
    }
    
    if ($Verbose) { Write-Host "Using gcloud at: $GcloudPath" }
    
    # Execute gcloud command - pass filter as single quoted string
    $LogOutput = & $GcloudPath logging read $Filter --project=$GcpProject --format=json --limit=500 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        $ErrorStr = $LogOutput -join "`n"
        Write-Error "gcloud command failed: $ErrorStr"
        return @()
    }
    
    # Parse JSON output
    $OutputStr = $LogOutput -join "`n"
    if ([string]::IsNullOrWhiteSpace($OutputStr) -or $OutputStr -eq "[]") {
        return @()
    }
    
    $LogEntries = $OutputStr | ConvertFrom-Json
    return $LogEntries
}
catch {
    Write-Error "Failed to query GCP logs: $_"
    return @()
}
