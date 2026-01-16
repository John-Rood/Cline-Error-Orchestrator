# Cline Error Orchestrator

Automated error detection, routing, and AI-powered investigation using Cline for GCP Cloud Run services.

## Overview

The Cline Error Orchestrator automatically:
1. **Polls** GCP Cloud Logging for ERROR and CRITICAL logs every 5 minutes
2. **Deduplicates** errors using signature hashing to avoid repeat investigations
3. **Routes** errors to the correct service workspace based on configuration
4. **Launches** VS Code with Cline to investigate automatically (zero manual steps!)
5. **Documents** findings in `AUTOMATED_PATCHES.md` and deploys fixes

## Quick Start

### 1. Configure Services

Copy the example configuration and customize:

```powershell
Copy-Item config\services.example.json config\services.json
```

Edit `config\services.json` to map your GCP services to local workspaces:

```json
{
  "gcp_project": "your-gcp-project-id",
  "polling_interval_minutes": 5,
  "ide_command": "code",
  "services": {
    "your-backend-service": {
      "workspace": "C:/path/to/your/backend",
      "type": "backend",
      "related_frontend": "your-frontend-service",
      "patches_doc": "docs/AUTOMATED_PATCHES.md",
      "deploy_script": "deploy.ps1"
    }
  }
}
```

### 2. Copy AUTOMATED_PATCHES.md Template

Copy the template to each service repository:

```powershell
Copy-Item templates\AUTOMATED_PATCHES.md C:\path\to\your\backend\docs\AUTOMATED_PATCHES.md
```

### 3. Install Scheduled Task

```powershell
.\scripts\setup_task_scheduler.ps1 -Install
```

For fully automated investigation launch:

```powershell
.\scripts\setup_task_scheduler.ps1 -Install -AutoLaunch
```

### 4. Check Status

```powershell
.\scripts\status.ps1
```

## Scripts

| Script | Description |
|--------|-------------|
| `poll_errors.ps1` | Polls GCP logs, deduplicates, writes pending queues |
| `launch_investigation.ps1` | Opens VS Code + auto-launches Cline with investigation |
| `clear_pending.ps1` | Clears pending errors after investigation |
| `setup_task_scheduler.ps1` | Installs/removes Windows Task Scheduler job |
| `status.ps1` | Shows current system status |
| `run_now.ps1` | Manual trigger for polling |

## Usage

### Manual Polling

```powershell
# Poll for errors
.\scripts\run_now.ps1 -Verbose

# Poll and auto-launch Cline investigation
.\scripts\run_now.ps1 -AutoLaunch
```

### Investigation

```powershell
# List services with pending errors
.\scripts\launch_investigation.ps1 -ListServices

# View pending errors without launching
.\scripts\launch_investigation.ps1 -Service your-service -NoLaunch

# Launch Cline investigation
.\scripts\launch_investigation.ps1 -Service your-service

# Clear pending after investigation
.\scripts\launch_investigation.ps1 -Service your-service -ClearPending
```

### Task Scheduler

```powershell
# Install scheduled polling
.\scripts\setup_task_scheduler.ps1 -Install

# Check status
.\scripts\setup_task_scheduler.ps1 -Status

# Uninstall
.\scripts\setup_task_scheduler.ps1 -Uninstall
```

## How It Works

### Error Deduplication

Errors are deduplicated using a signature hash computed from:
- Severity level
- Error type (exception class)
- First line of traceback (normalized)
- Affected endpoint/function

This ensures the same error occurring 100 times creates only one investigation task.

### Automated Cline Launch

The `launch_investigation.ps1` script uses Windows SendKeys API to:
1. Open VS Code in the correct workspace
2. Focus Cline's chat input (`Ctrl+'`)
3. Type the investigation prompt
4. Press Enter to start the task

This achieves fully automated AI investigation with **zero manual steps**.

### Investigation Workflow

Cline follows the `/investigate.md` workflow which:
1. Reads the pending errors file
2. Fetches additional context from GCP logs (via MCP)
3. Classifies each error:
   - **User Error**: Add exception handler, return helpful message
   - **System Bug**: Fix the actual bug
   - **External Factor**: Document for monitoring, no code changes
4. Documents findings in `AUTOMATED_PATCHES.md`
5. Runs the `mit` workflow (commit, push, deploy)

## Prerequisites

- **Windows 10/11** with PowerShell 5.1+
- **gcloud CLI** authenticated with your GCP project
- **VS Code** with [Cline extension](https://marketplace.visualstudio.com/items?itemName=saoudrizwan.claude-dev) installed
- **GCP IAM**: Logs Viewer role on your project

### Verify gcloud Authentication

```powershell
gcloud auth login
gcloud config set project your-gcp-project-id
gcloud logging read "severity>=ERROR" --limit=1
```

## Directory Structure

```
cline_error_orchestrator/
├── config/
│   ├── services.example.json    # Configuration template
│   └── services.json            # Your configuration (git-ignored)
├── data/
│   ├── pending/                 # Error queues per service
│   └── seen_errors.json         # Deduplication database
├── scripts/
│   ├── poll_errors.ps1          # Main polling script
│   ├── launch_investigation.ps1 # Cline launcher
│   ├── clear_pending.ps1        # Cleanup script
│   ├── setup_task_scheduler.ps1 # Scheduler setup
│   ├── status.ps1               # Status display
│   └── run_now.ps1              # Manual trigger
├── templates/
│   └── AUTOMATED_PATCHES.md     # Template for service repos
├── workflows/
│   └── investigate.md           # Cline investigation workflow
├── ERROR_ORCHESTRATOR_DESIGN.md
└── ERROR_ORCHESTRATOR_IMPLEMENTATION_PLAN.md
```

## Troubleshooting

### "Configuration file not found"

Copy and customize the example configuration:
```powershell
Copy-Item config\services.example.json config\services.json
```

### "gcloud command failed"

Ensure you're authenticated:
```powershell
gcloud auth login
gcloud config set project your-gcp-project-id
```

### SendKeys not working / Cline not receiving prompt

- VS Code must have window focus
- Try increasing `-WaitTime` parameter (default: 3 seconds)
- Ensure Cline is installed and `Ctrl+'` keybinding works
- Run VS Code in non-admin mode if you're running scripts as admin

### Task Scheduler access denied

Run PowerShell as Administrator for task installation.

## Configuration Reference

### services.json

| Field | Description |
|-------|-------------|
| `gcp_project` | GCP project ID for log queries |
| `polling_interval_minutes` | How often to poll (default: 5) |
| `ide_command` | IDE command (default: "code") |
| `services.<name>.workspace` | Local path to service codebase |
| `services.<name>.type` | "backend" or "frontend" |
| `services.<name>.related_frontend` | Name of related frontend service |
| `services.<name>.related_backend` | Name of related backend service |
| `services.<name>.patches_doc` | Path to AUTOMATED_PATCHES.md |
| `services.<name>.deploy_script` | Path to deploy script (optional) |

## How Cline Gets Triggered

The magic happens through keyboard simulation:

```powershell
# 1. Open VS Code in workspace
Start-Process code -ArgumentList "C:\path\to\workspace"

# 2. Wait for VS Code to load
Start-Sleep -Seconds 3

# 3. Focus Cline input (Ctrl+')
[System.Windows.Forms.SendKeys]::SendWait("^'")

# 4. Type the investigation prompt
[System.Windows.Forms.SendKeys]::SendWait("/investigate.md...")

# 5. Press Enter to submit
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
```

This allows the Cline Error Orchestrator to launch Cline with a specific task without any manual intervention!

## License

MIT
