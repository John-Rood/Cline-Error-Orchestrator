# Cline Error Orchestrator

**Self-healing cloud services powered by AI.**

This tool creates a fully automated error resolution pipeline: detect errors → investigate with AI → fix the code → deploy a new instance. Your cloud services fix themselves while you sleep.

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SELF-HEALING LOOP                                │
│                                                                     │
│   ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐   │
│   │  DETECT  │─────▶│INVESTIGATE───▶│   FIX    │────▶│  DEPLOY  │   │
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
6. **Deploys** the fix by triggering your CI/CD workflow (e.g., `push` workflow)

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

Edit `config\services.json` to map your **cloud services** to **local codebases**:

```json
{
  "provider": "gcp",
  "gcp_project": "your-gcp-project-id",
  "services": {
    "my-backend-service": {
      "workspace": "C:/Projects/my-backend",
      "workflow": "investigate.md",
      "deploy_script": "deploy.ps1"
    },
    "my-api-service": {
      "workspace": "C:/Projects/my-api",
      "workflow": "investigate.md",
      "deploy_script": null
    }
  }
}
```

#### How Service Mapping Works

Your cloud services (e.g., Cloud Run, Lambda, App Service) write logs when errors occur. Each log entry includes a **service name** that identifies which deployed instance threw the error.

The config file maps those service names to your local codebase:

```
Cloud Service Name  →  Local Codebase
───────────────────────────────────────
"my-backend-service"  →  C:/Projects/my-backend
"my-frontend-service" →  C:/Projects/my-frontend
```

When the orchestrator detects an error from `my-backend-service`, it knows to open `C:/Projects/my-backend` in VS Code so Cline can fix the actual source code.

#### Custom Workflows Per Service

By default, the orchestrator uses `investigate.md` as the Cline workflow. But you can define a **custom workflow** for each service:

```json
{
  "services": {
    "my-backend-service": {
      "workspace": "C:/Projects/my-backend",
      "workflow": "investigate.md"
    },
    "my-frontend-service": {
      "workspace": "C:/Projects/my-frontend",
      "workflow": "investigate-frontend.md"
    }
  }
}
```

This is useful when different services need different investigation strategies. For example:
- A backend might need database checks
- A frontend might need browser console analysis
- A microservice might have unique deployment steps

Place custom workflows in your Cline workflows directory or include them with the service repo.

#### Automatic Documentation

The investigation workflow automatically creates `docs/AUTOMATED_PATCHES.md` in your service workspace if it doesn't exist. This file tracks all patches made by the orchestrator, using the template from `templates/AUTOMATED_PATCHES.md`.

You don't need to pre-create any files—Cline handles it automatically on the first investigation.

### 3. Install Workflows

Copy the workflows to your Cline workflows directory:

```powershell
Copy-Item workflows\*.md "$env:USERPROFILE\Documents\Cline\Workflows\"
```

This installs:
- `investigate.md` - The main error investigation workflow
- `push.md` - The CI/CD workflow (audit → commit → push → deploy)

### 4. Enable Automation

Install the scheduled task to start polling:

```powershell
.\scripts\setup_task_scheduler.ps1 -Install -AutoLaunch
```

That's it! When an error occurs, your computer will automatically open VS Code, launch Cline, and start fixing it.

## Key Scripts

- `poll_errors.ps1`: Polls your cloud provider and queues new errors
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
5. **CI/CD Triggers**: The investigation workflow calls your deploy workflow (e.g., `push`).
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

Or use a Cline workflow like `push` that handles commit → push → deploy.

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
