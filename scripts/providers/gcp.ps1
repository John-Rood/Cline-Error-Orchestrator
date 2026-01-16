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
$Filter = "severity>=ERROR AND resource.type=`"cloud_run_revision`" AND timestamp>=`"$($StartTime.ToString("yyyy-MM-ddTHH:mm:ssZ"))`""

try {
    $GcloudCmd = "gcloud logging read `"$Filter`" --project=$GcpProject --format=json --limit=500"
    if ($Verbose) { Write-Host "Executing: $GcloudCmd" }
    
    $LogOutput = Invoke-Expression $GcloudCmd 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "gcloud command failed: $LogOutput"
        return @()
    }
    
    # Parse JSON output
    if ([string]::IsNullOrWhiteSpace($LogOutput) -or $LogOutput -eq "[]") {
        return @()
    }
    
    $LogEntries = $LogOutput | ConvertFrom-Json
    return $LogEntries
}
catch {
    Write-Error "Failed to query GCP logs: $_"
    return @()
}
