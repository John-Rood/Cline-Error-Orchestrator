# run_now.ps1
# Manually triggers an error polling cycle.
# This is a convenience wrapper around poll_errors.ps1

param(
    [switch]$AutoLaunch,        # Automatically launch investigation for first service with errors
    [switch]$LaunchAll,         # Launch investigation for all services with errors
    [switch]$Silent,            # Suppress desktop notifications
    [switch]$Verbose,           # Show detailed output
    [switch]$WhatIf             # Dry run - don't write files or launch
)

# Get the script's directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Build arguments
$Arguments = @()
if ($AutoLaunch) { $Arguments += "-AutoLaunch" }
if ($LaunchAll) { $Arguments += "-LaunchAll" }
if ($Silent) { $Arguments += "-Silent" }
if ($Verbose) { $Arguments += "-Verbose" }
if ($WhatIf) { $Arguments += "-WhatIf" }

# Run poll_errors.ps1
$PollScript = Join-Path $ScriptDir "poll_errors.ps1"
& $PollScript @Arguments
