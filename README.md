# Cline Error Orchestrator

**Automated error detection, routing, and AI-powered investigation.**

This tool polls your cloud provider (GCP, AWS, etc.) for errors, deduplicates them, and **automatically launches VS Code with Cline** to investigate and fix issues in the correct repository—with zero manual intervention.

## What It Does

1. **Detects** errors in your logs (ERROR/CRITICAL) every 5 minutes
2. **Deduplicates** repeated errors so you don't get spammed
3. **Routes** the issue to the correct local codebase (e.g., backend vs frontend)
4. **Launches** VS Code and triggers Cline to investigate automatically
5. **Fixes** the issue (User Error, System Bug, or External Factor) and documents it

## Quick Start

### 1. Installation

Clone the repository and run the setup script:

```powershell
git clone https://github.com/John-Rood/Cline-Error-Orchestrator.git
cd Cline-Error-Orchestrator
```

### 2. Configuration

Create your configuration file:

```powershell
Copy-Item config\services.example.json config\services.json
```

Edit `config\services.json` to map your services to local folders:

```json
{
  "provider": "gcp",
  "gcp_project": "your-gcp-project-id",
  "services": {
    "my-backend-service": {
      "workspace": "C:/Projects/my-backend",
      "type": "backend"
    },
    "my-frontend-service": {
      "workspace": "C:/Projects/my-frontend",
      "type": "frontend"
    }
  }
}
```

### 3. Enable Automation

Install the scheduled task to start polling:

```powershell
.\scripts\setup_task_scheduler.ps1 -Install -AutoLaunch
```

That's it! When an error occurs in GCP, your computer will automatically open VS Code, launch Cline, and start fixing it.

## Key Scripts

- `poll_errors.ps1`: Polls GCP and queues new errors
- `launch_investigation.ps1`: Launches VS Code + Cline automation
- `status.ps1`: Shows current status and pending errors
- `run_now.ps1`: Manually trigger a poll immediately

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Cloud Provider CLI (e.g., [gcloud](https://cloud.google.com/sdk/docs/install) for GCP)
- VS Code with [Cline Extension](https://marketplace.visualstudio.com/items?itemName=saoudrizwan.claude-dev)

## Cloud Agnostic

This tool uses a provider plugin system. Currently ships with:
- **GCP** (via `providers/gcp.ps1`)

To add AWS or Azure support, simply create `scripts/providers/aws.ps1` that returns a list of error objects.

## License

MIT
