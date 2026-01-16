# Cline Error Orchestrator

**Self-healing cloud services powered by AI.**

This tool creates a fully automated error resolution pipeline: detect errors → investigate with AI → fix the code → deploy a new instance. Your cloud services fix themselves while you sleep.

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SELF-HEALING LOOP                                │
│                                                                     │
│   ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐   │
│   │  DETECT  │────▶│INVESTIGATE────▶│   FIX    │────▶│  DEPLOY  │   │
│   │  errors  │     │  w/ Cline│     │  code    │     │  new ver │   │
│   └──────────┘     └──────────┘     └──────────┘     └──────────┘   │
│        │                                                   │        │
│        └───────────────────────────────────────────────────┘        │
│                         (repeat)                                    │
└─────────────────────────────────────────────────────────────────────┘
```

## What It Does

1. **Detects** errors in your logs (ERROR/CRITICAL) every 5 minutes
2. **Deduplicates** repeated errors so you don't get spammed
3. **Routes** the issue to the correct local codebase (e.g., backend vs frontend)
4. **Launches** VS Code and triggers Cline to investigate automatically
5. **Fixes** the issue (User Error, System Bug, or External Factor) and documents it
6. **Deploys** the fix by triggering your CI/CD workflow (e.g., `mit` workflow)

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

## Full Lifecycle: Self-Healing in Action

Here's how the complete automated loop works:

1. **Error Detected**: A user hits a bug in production. The error is logged.
2. **Orchestrator Polls**: Every 5 minutes, `poll_errors.ps1` checks cloud logs.
3. **Cline Launches**: VS Code opens in the correct repo, Cline receives the task.
4. **AI Investigates**: Cline reads logs, classifies the error, and writes a fix.
5. **CI/CD Triggers**: The investigation workflow calls your deploy workflow (e.g., `mit`).
6. **New Version Deploys**: Your cloud service is updated with the fix.
7. **Loop Repeats**: The orchestrator continues monitoring for new errors.

**Result**: Production errors get fixed and deployed automatically—no human intervention required.

### Setting Up CI/CD Integration

The investigation workflow (`workflows/investigate.md`) ends by calling your CI/CD workflow. Configure a deploy script in your service config:

```json
{
  "services": {
    "my-backend": {
      "workspace": "C:/Projects/my-backend",
      "deploy_script": "deploy.ps1"
    }
  }
}
```

Or use a Cline workflow like `mit` that handles commit → push → deploy.

## Cloud Agnostic

This tool works with any cloud provider. We ship with support for:

### 1. Google Cloud Platform (GCP)
Uses `gcloud logging read` to fetch Cloud Run/Cloud Functions errors.
- **Config**: `"provider": "gcp"`, `"gcp_project": "my-project"`

### 2. Amazon Web Services (AWS)
Uses `aws logs filter-log-events` to fetch CloudWatch logs.
- **Config**: `"provider": "aws"`, `"aws_log_group": "/aws/lambda/my-app"`, `"aws_region": "us-east-1"`

### 3. Microsoft Azure
Uses `az monitor log-analytics query` to fetch Application Insights errors.
- **Config**: `"provider": "azure"`, `"azure_workspace_id": "GUID"`, `"azure_resource_group": "my-rg"`

## License

MIT
