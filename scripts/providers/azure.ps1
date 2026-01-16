param(
    [PSCustomObject]$Config,
    [datetime]$StartTime,
    [switch]$Verbose
)

$WorkspaceId = $Config.azure_workspace_id
$ResourceGroup = $Config.azure_resource_group

if (-not $WorkspaceId) {
    Write-Error "Missing 'azure_workspace_id' in configuration."
    return @()
}

if ($Verbose) {
    Write-Host "Fetching Azure logs for workspace: $WorkspaceId"
    Write-Host "Start time: $StartTime"
}

# KQL Query
# We look for exceptions or errors in AppExceptions or plain text logs
$KqlQuery = "AppExceptions | where SeverityLevel >= 3 | where TimeGenerated >= datetime($($StartTime.ToString("yyyy-MM-ddTHH:mm:ssZ")))"

try {
    # Build az monitor command
    # Requires 'az' CLI and 'log-analytics' extension
    $AzArgs = @(
        "monitor", "log-analytics", "query",
        "--workspace", $WorkspaceId,
        "--analytics-query", $KqlQuery,
        "--output", "json"
    )
    
    if ($ResourceGroup) {
        $AzArgs += "--resource-group"
        $AzArgs += $ResourceGroup
    }
    
    if ($Verbose) { Write-Host "Executing: az $($AzArgs -join ' ')" }
    
    $Process = Start-Process -FilePath "az" -ArgumentList $AzArgs -NoNewWindow -PassThru -Wait -RedirectStandardOutput "az_output.tmp" -RedirectStandardError "az_error.tmp"
    
    if ($Process.ExitCode -ne 0) {
        $ErrorContent = Get-Content "az_error.tmp" -Raw -ErrorAction SilentlyContinue
        Write-Error "Azure command failed: $ErrorContent"
        Remove-Item "az_output.tmp", "az_error.tmp" -ErrorAction SilentlyContinue
        return @()
    }
    
    $JsonOutput = Get-Content "az_output.tmp" -Raw -ErrorAction SilentlyContinue
    Remove-Item "az_output.tmp", "az_error.tmp" -ErrorAction SilentlyContinue
    
    if ([string]::IsNullOrWhiteSpace($JsonOutput)) {
        return @()
    }
    
    $Logs = $JsonOutput | ConvertFrom-Json
    
    # Map to standardized format
    $StandardizedLogs = @()
    foreach ($Log in $Logs) {
        $StandardizedLogs += @{
            severity = "ERROR"
            timestamp = $Log.TimeGenerated
            textPayload = $Log.OuterMessage
            jsonPayload = @{
                exception = $Log.OuterMessage
                stack_trace = $Log.StackTrace
            }
            resource = @{
                labels = @{
                    service_name = $Log.AppName
                }
            }
            # Azure specific context
            azure_operation_id = $Log.OperationId
        }
    }
    
    return $StandardizedLogs
}
catch {
    Write-Error "Failed to query Azure logs: $_"
    return @()
}
