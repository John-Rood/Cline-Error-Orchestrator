param(
    [PSCustomObject]$Config,
    [datetime]$StartTime,
    [switch]$Verbose
)

$LogGroup = $Config.aws_log_group
$Region = $Config.aws_region

if (-not $LogGroup) {
    Write-Error "Missing 'aws_log_group' in configuration."
    return @()
}

if ($Verbose) {
    Write-Host "Fetching AWS logs for group: $LogGroup (Region: $Region)"
    Write-Host "Start time: $StartTime"
}

# AWS expects epoch milliseconds
$StartTimeMs = [int64](($StartTime - (Get-Date "1970-01-01 00:00:00Z")).TotalMilliseconds)

try {
    # Build AWS CLI command
    $AwsArgs = @(
        "logs", "filter-log-events",
        "--log-group-name", $LogGroup,
        "--start-time", $StartTimeMs,
        "--filter-pattern", "ERROR",
        "--output", "json"
    )
    
    if ($Region) {
        $AwsArgs += "--region"
        $AwsArgs += $Region
    }
    
    if ($Verbose) { Write-Host "Executing: aws $($AwsArgs -join ' ')" }
    
    # We use Start-Process to avoid shell parsing issues with complex args
    $Process = Start-Process -FilePath "aws" -ArgumentList $AwsArgs -NoNewWindow -PassThru -Wait -RedirectStandardOutput "aws_output.tmp" -RedirectStandardError "aws_error.tmp"
    
    if ($Process.ExitCode -ne 0) {
        $ErrorContent = Get-Content "aws_error.tmp" -Raw -ErrorAction SilentlyContinue
        Write-Error "AWS command failed: $ErrorContent"
        Remove-Item "aws_output.tmp", "aws_error.tmp" -ErrorAction SilentlyContinue
        return @()
    }
    
    $JsonOutput = Get-Content "aws_output.tmp" -Raw -ErrorAction SilentlyContinue
    Remove-Item "aws_output.tmp", "aws_error.tmp" -ErrorAction SilentlyContinue
    
    if ([string]::IsNullOrWhiteSpace($JsonOutput)) {
        return @()
    }
    
    $Events = $JsonOutput | ConvertFrom-Json
    if (-not $Events -or -not $Events.events) {
        return @()
    }
    
    # Map to standardized format
    $StandardizedLogs = @()
    foreach ($Event in $Events.events) {
        $StandardizedLogs += @{
            severity = "ERROR"
            timestamp = (Get-Date "1970-01-01 00:00:00Z").AddMilliseconds($Event.timestamp).ToString("o")
            textPayload = $Event.message
            resource = @{
                labels = @{
                    service_name = $Config.service_name_label  # Optional mapping if using log streams as service names
                }
            }
            # AWS specific context
            aws_log_stream = $Event.logStreamName
            aws_event_id = $Event.eventId
        }
    }
    
    return $StandardizedLogs
}
catch {
    Write-Error "Failed to query AWS logs: $_"
    return @()
}
