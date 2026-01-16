# Error Orchestrator System Design

## 1. Background

Modern cloud architectures often involve multiple services deployed across Google Cloud Platform, all logging to a centralized Cloud Logging project. When errors occur across these distributed services, engineers face the challenge of identifying which service produced the error, locating the relevant codebase, and determining whether the error represents a genuine bug or external factors like user misconfiguration.

Currently, error detection relies on manual log inspection using the GCP Console or custom tooling. When errors occur, engineers must manually identify the source service, locate the relevant codebase on their local machine, investigate the root cause, and determine appropriate remediation. This manual process is time-consuming and error-prone, especially when errors span multiple services or when the same logical error manifests differently across services.

Not all errors indicate bugs in the codebase. Some errors are caused by user behavior (such as accessing an API from an incorrect domain), network issues, or third-party service degradation. The ideal response to these scenarios is graceful exception handling that returns helpful error messages to users while logging the occurrence for monitoring purposes, rather than treating every error as a critical system failure requiring code changes.

## 2. Summary

The Error Orchestrator is a standalone, service-agnostic tool that automatically polls GCP Cloud Logging every 5 minutes, identifies distinct new errors across all registered services, routes them to the appropriate codebase workspace, and triggers an AI-powered investigation workflow. The system maintains a configurable service registry mapping GCP service names to local workspace paths, enabling automatic workspace switching when investigating errors.

The investigation workflow distinguishes between genuine bugs, user-caused errors, and external factors. For user-caused errors, it recommends adding exception handlers that return helpful responses while logging the occurrence with a consistent event type (`AUTOMATED_PATCH_APPLIED`). All investigations and patches are documented in `AUTOMATED_PATCHES.md` files in each affected repository, followed by standard commit, push, and deploy workflows.

## 3. Requirements

### 3.1. Functional Requirements

1. Poll GCP Cloud Logging at configurable intervals for ERROR and CRITICAL level logs across all registered services within a specified GCP project.
2. Support multiple GCP projects through configuration, allowing monitoring of services across different cloud projects.
3. Deduplicate errors by computing a signature hash based on error type, message pattern, and affected function, ensuring repeated occurrences of the same error create only one investigation task.
4. Maintain a service registry configuration file that maps GCP service names to local workspace paths, service types, related services (backend/frontend pairs), and documentation paths.
5. Route errors to the correct workspace by parsing `resource.labels.service_name` from log entries and looking up the corresponding workspace path in the service registry.
6. Launch the configured IDE in the appropriate workspace and trigger the investigation workflow when new distinct errors are detected.
7. Distinguish between user-caused errors, genuine system bugs, and external factors during investigation, recommending appropriate remediation strategies for each.
8. For user-caused errors, recommend adding exception handlers that return structured error responses to clients and log with the `AUTOMATED_PATCH_APPLIED` event type for consistent monitoring.
9. Document all investigations and patches in a configurable documentation file (default: `docs/AUTOMATED_PATCHES.md`) in each affected repository.
10. Support cross-repository coordination when changes in one service require corresponding changes in related services.

### 3.2. Non-Functional Requirements

1. The orchestrator must be a standalone tool installable on any developer machine, independent of any specific project.
2. All configuration must be externalized to JSON files, with no hardcoded paths, service names, or project identifiers.
3. Error polling must complete within 30 seconds to avoid overlap with subsequent polling cycles.
4. The system must provide platform-appropriate desktop notifications when new errors are detected.
5. The system must work offline for investigation workflows, only requiring GCP connectivity during the polling phase.
6. The tool must be easily extensible to support additional cloud providers or logging systems in the future.

## 4. Recommended Path Forward

### 4.1. Steps

```
[DIAGRAM PLACEHOLDER - Add architecture/flow diagram here]

┌─────────────────────────────────────────────────────────────────────┐
│                     Error Orchestrator Flow                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────┐    ┌─────────────────┐    ┌──────────────────┐    │
│  │ Task         │───▶│ poll_errors.ps1 │──▶│ gcloud logging   │    │
│  │ Scheduler    │    │                 │    │ read             │    │
│  │ (5 min)      │    └────────┬────────┘    └──────────────────┘    │
│  └──────────────┘             │                                     │
│                               ▼                                     │
│                    ┌─────────────────────┐                          │
│                    │ Compute error hash  │                          │
│                    │ (deduplication)     │                          │
│                    └──────────┬──────────┘                          │
│                               │                                     │
│                    ┌──────────▼──────────┐                          │
│                    │ Check seen_errors   │                          │
│                    │ (new distinct?)     │                          │
│                    └──────────┬──────────┘                          │
│                               │                                     │
│              ┌────────────────┴────────────────┐                    │
│              │ Yes                             │ No                 │
│              ▼                                 ▼                    │
│   ┌─────────────────────┐           ┌──────────────────┐            │
│   │ Lookup workspace in │           │ Exit (no action) │            │
│   │ services.json       │           └──────────────────┘            │
│   └──────────┬──────────┘                                           │
│              │                                                      │
│              ▼                                                      │
│   ┌─────────────────────┐                                           │
│   │ Write to pending/   │                                           │
│   │ <service>.json      │                                           │
│   └──────────┬──────────┘                                           │
│              │                                                      │
│              ▼                                                      │
│   ┌─────────────────────┐    ┌──────────────────────────────────┐   │
│   │ Desktop notification│───▶│ IDE <workspace_path>             │   │
│   │ + launch IDE        │    │ AI: /investigate                 │   │
│   └─────────────────────┘    └──────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

1. Create the error orchestrator as a standalone tool with its own repository structure, including configuration, data, scripts, and workflow directories.
2. Implement the `services.json` configuration file that maps GCP service names to workspace paths, service types, related services, and documentation paths, with support for multiple GCP projects.
3. Implement `poll_errors.ps1` PowerShell script that uses `gcloud logging read` to fetch recent ERROR/CRITICAL logs, computes error signature hashes, and compares against `seen_errors.json` for deduplication.
4. Implement `launch_investigation.ps1` script that reads `pending/<service>.json`, opens the configured IDE in the correct workspace, and prepares context for AI investigation.
5. Create `workflows/investigate.md` as an AI workflow template that reads pending errors, uses available tools for deep log analysis, determines error classification, and recommends appropriate patches.
6. Create `setup_task_scheduler.ps1` script to configure the system's task scheduler for automated polling intervals.
7. Create an `AUTOMATED_PATCHES.md` template that users copy to their service repositories.

### 4.2. Discussion

The CLI-based polling approach using `gcloud logging read` was chosen over extending MCP servers or building custom cloud integrations for several reasons. CLI scripts are easier to schedule via system task schedulers, require no additional process management, can be moved to any system with gcloud CLI installed, and work with existing GCP authentication flows.

Error deduplication uses a signature hash computed from severity, error type (exception class), the first line of the stack trace, and the affected endpoint or function name. This approach ensures that the same error occurring 100 times generates only one investigation task, while genuinely different errors (even if superficially similar) create separate tasks.

The separation between `seen_errors.json` (all-time history of processed errors) and `pending/<service>.json` (errors awaiting investigation) enables tracking which errors have been processed versus which are awaiting action. This two-file approach prevents re-investigating already-handled errors while maintaining a clear queue of pending work.

## 5. Alternate Path Forward

```
[DIAGRAM PLACEHOLDER - Add alternative architecture diagram here]

Push-based architecture using GCP Pub/Sub:
  GCP Log Alert → Pub/Sub → Cloud Function → Webhook → Local Server
```

An alternative approach would use GCP's native alerting capabilities with log-based alerts triggering Pub/Sub messages, which invoke a Cloud Function that posts to a local webhook endpoint. This webhook would be served by a continuously running local server, exposed via ngrok or Cloudflare Tunnel.

This push-based approach was not chosen for several reasons. It requires maintaining a persistent tunnel to the local machine, which introduces security considerations and reliability challenges. The Cloud Function adds deployment complexity and GCP costs. Each user would need to configure their own cloud infrastructure. Additionally, the 5-minute polling interval is sufficient for the expected error frequency, and the polling approach works entirely offline except during the brief polling phase.

## 6. Discussion

The trade-off between polling and push-based approaches centers on latency versus complexity. Polling introduces up to 5 minutes of latency between error occurrence and notification, which is acceptable for development workflows. Push-based approaches offer near-instant notification but require significantly more infrastructure per user.

A key risk is the potential for false positive investigations when external factors cause errors (such as network issues or cloud service degradation). The investigation workflow must be designed to recognize these patterns and recommend monitoring rather than code changes. The `AUTOMATED_PATCH_APPLIED` logging pattern provides visibility into system behavior without masking legitimate issues.

Cross-repository coordination between related services (such as a backend API and its frontend client) introduces workflow complexity. When a backend change adds a new error response type, the frontend must be updated to handle it gracefully. The service registry's `related_frontend` and `related_backend` fields enable the investigation workflow to flag when cross-repo changes are needed and guide the developer through both repositories.

The tool is designed to be IDE-agnostic, though initial implementation focuses on VS Code. The launch script can be extended to support other editors by adding IDE configuration to the services registry or a separate settings file.

## 7. Open Questions

1. Should the polling interval be configurable per-service, or is a global interval sufficient for all services?
2. How long should error signatures be retained in `seen_errors.json` before being considered "new" again (error signature TTL)?
3. Should the system support alerting channels beyond desktop notifications (email, Slack, Discord)?
4. What is the appropriate threshold for grouping similar errors versus treating them as distinct (hash collision tolerance)?
5. Should the tool support non-GCP cloud providers (AWS CloudWatch, Azure Monitor) in the initial release or defer to future versions?

## 8. References

1. GCP Cloud Logging documentation: https://cloud.google.com/logging/docs
2. gcloud logging read command reference: https://cloud.google.com/sdk/gcloud/reference/logging/read
3. Windows Task Scheduler documentation: https://docs.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-start-page

## 9. Appendix

### 9.1. Service Registry Schema

The `services.json` configuration file defines the mapping between GCP services and local workspaces. This file is user-specific and should be customized for each developer's environment:

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
    },
    "your-frontend-service": {
      "workspace": "C:/path/to/your/frontend",
      "type": "frontend",
      "related_backend": "your-backend-service",
      "patches_doc": "docs/AUTOMATED_PATCHES.md",
      "deploy_script": null
    }
  }
}
```

**Example with multiple services:**

```json
{
  "gcp_project": "my-gcp-project-123",
  "polling_interval_minutes": 5,
  "ide_command": "code",
  "services": {
    "api-backend": {
      "workspace": "C:/projects/my-api",
      "type": "backend",
      "related_frontend": "web-frontend",
      "patches_doc": "docs/AUTOMATED_PATCHES.md",
      "deploy_script": "deploy.ps1"
    },
    "web-frontend": {
      "workspace": "C:/projects/my-frontend",
      "type": "frontend",
      "related_backend": "api-backend",
      "patches_doc": "docs/AUTOMATED_PATCHES.md"
    },
    "worker-service": {
      "workspace": "C:/projects/my-worker",
      "type": "backend",
      "patches_doc": "docs/AUTOMATED_PATCHES.md",
      "deploy_script": "deploy.sh"
    },
    "analytics-service": {
      "workspace": "C:/projects/analytics",
      "type": "backend",
      "patches_doc": "docs/AUTOMATED_PATCHES.md"
    }
  }
}
```

### 9.2. Error Signature Algorithm

Error signatures are computed using the following algorithm to ensure consistent deduplication:

```
signature = SHA256(
  severity + "|" +
  error_type + "|" +
  normalize(first_traceback_line) + "|" +
  affected_endpoint_or_function
)
```

The `normalize()` function removes variable components from the traceback line:
1. Timestamps in any format
2. Request IDs, trace IDs, and correlation IDs
3. Memory addresses and object IDs
4. User-specific data (emails, usernames, IDs)

This ensures that multiple occurrences of the same error produce identical signatures regardless of when they occurred or which user triggered them.

### 9.3. AUTOMATED_PATCHES.md Format

Each service repository should contain an `AUTOMATED_PATCHES.md` file (location configurable via `patches_doc` in services.json). Each patch entry follows this format:

```markdown
## AP-YYYY-NNN | YYYY-MM-DD HH:MM:SS

**Error:** [Brief error description]

**Verdict:** [User Error | System Bug | External Factor]

**Investigation:** [Summary of root cause analysis]

**Patch:** [Description of changes made, or "None - monitoring only"]

**Related Service Change:** [Yes/No - description if yes]

**Files Modified:**
1. [file1.py] - [brief description]
2. [file2.tsx] - [brief description]

**Event Type:** AUTOMATED_PATCH_APPLIED

---
```

### 9.4. Consistent Logging Pattern

All automated patches should log using this pattern for consistent monitoring across services:

**Python:**
```python
import logging

logger = logging.getLogger(__name__)

logger.warning("AUTOMATED_PATCH_APPLIED", extra={
    "patch_id": "AP-2026-001",
    "original_error": "InvalidOriginError",
    "error_classification": "user_error",
    "action_taken": "exception_handler_added",
    "affected_endpoint": "/api/endpoint",
    "related_service_change_required": True,
    "user_message_returned": "Helpful message for the user"
})
```

**Node.js:**
```javascript
const logger = require('./logger');

logger.warn('AUTOMATED_PATCH_APPLIED', {
    patch_id: 'AP-2026-001',
    original_error: 'InvalidOriginError',
    error_classification: 'user_error',
    action_taken: 'exception_handler_added',
    affected_endpoint: '/api/endpoint',
    related_service_change_required: true,
    user_message_returned: 'Helpful message for the user'
});
```

### 9.5. Launching Cline with Investigation Context

Cline can be fully automated using keyboard simulation. The `launch_investigation.ps1` script uses Windows SendKeys API to:
1. Open VS Code in the correct workspace
2. Focus Cline's chat input using the `Ctrl+'` keybinding
3. Type the investigation prompt
4. Press Enter to start the task

**Fully Automated Approach (Zero Manual Steps):**

```powershell
# launch_investigation.ps1

param(
    [Parameter(Mandatory=$true)]
    [string]$Service
)

# Load configuration
$config = Get-Content "config/services.json" | ConvertFrom-Json
$serviceConfig = $config.services.$Service

if (-not $serviceConfig) {
    Write-Error "Service '$Service' not found in configuration"
    exit 1
}

$workspacePath = $serviceConfig.workspace
$pendingFile = "data/pending/$Service.json"
$orchestratorPath = $PSScriptRoot | Split-Path -Parent

# 1. Open VS Code in the service workspace
code $workspacePath

# 2. Wait for VS Code to fully load (adjust timing as needed)
Start-Sleep -Seconds 3

# 3. Load SendKeys API
Add-Type -AssemblyName System.Windows.Forms

# 4. Send Ctrl+' to focus Cline chat input
[System.Windows.Forms.SendKeys]::SendWait("^'")
Start-Sleep -Milliseconds 500

# 5. Build the investigation prompt
$pendingErrors = Get-Content "$orchestratorPath\$pendingFile" | ConvertFrom-Json
$errorCount = $pendingErrors.errors.Count
$errorTypes = ($pendingErrors.errors | ForEach-Object { $_.error_type } | Select-Object -Unique) -join ", "

$prompt = @"
/investigate.md

Investigate $errorCount new error(s) in service: $Service
Error types: $errorTypes
Pending errors file: $orchestratorPath\$pendingFile

Read the pending errors file, analyze each distinct error, classify as User Error/System Bug/External Factor, and recommend appropriate patches. Document findings in AUTOMATED_PATCHES.md, then run the mit workflow.
"@

# 6. Type the investigation prompt (escape special characters for SendKeys)
$escapedPrompt = $prompt -replace '[+^%~(){}]', '{$0}'
[System.Windows.Forms.SendKeys]::SendWait($escapedPrompt)
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

Write-Host "Investigation started for service: $Service"
Write-Host "Errors to investigate: $errorCount"
Write-Host "Error types: $errorTypes"
```

**Example Generated Prompt:**

When the script runs for `api-backend` with 2 pending errors, Cline receives:

```
/investigate.md

Investigate 2 new error(s) in service: api-backend
Error types: KeyError, InvalidOriginError
Pending errors file: C:\path\to\cline-error-orchestrator\data\pending\api-backend.json

Read the pending errors file, analyze each distinct error, classify as User Error/System Bug/External Factor, and recommend appropriate patches. Document findings in AUTOMATED_PATCHES.md, then run the mit workflow.
```

**How It Works:**

1. **`code $workspacePath`** - Opens VS Code with the service's codebase as the workspace
2. **`Start-Sleep -Seconds 3`** - Waits for VS Code and Cline extension to fully initialize
3. **`SendKeys("^'")`** - Simulates pressing `Ctrl+'`, which is Cline's keybinding for `cline.focusChatInput`
4. **`SendKeys($prompt)`** - Types the investigation workflow command into Cline's input
5. **`SendKeys("{ENTER}")`** - Presses Enter to submit and start the task

**Complete Automated Flow:**
```
poll_errors.ps1 detects error
        ↓
launch_investigation.ps1 -Service "api-backend"
        ↓
VS Code opens in service workspace (automatic)
        ↓
Ctrl+' focuses Cline input (automatic via SendKeys)
        ↓
"/investigate.md <pending_file>" typed (automatic via SendKeys)
        ↓
Enter pressed, task starts (automatic via SendKeys)
        ↓
Cline executes investigation workflow (fully automated!)
```

**Important Notes:**

1. **Timing**: The 3-second wait may need adjustment based on system speed. VS Code and Cline must be fully loaded before SendKeys will work.
2. **Focus**: VS Code must have window focus for SendKeys to work. The script may need to bring VS Code to foreground.
3. **Keybinding**: This relies on Cline's default `Ctrl+'` keybinding. If users have customized this, they'll need to update the script.
4. **Windows Only**: SendKeys is a Windows-specific API. Linux/Mac would need different automation (xdotool, AppleScript, etc.)

---

### 9.6. Pending Error File Format

Each `pending/<service>.json` file contains errors awaiting investigation:

```json
{
  "service": "service-name",
  "generated_at": "2026-01-16T13:30:00Z",
  "errors": [
    {
      "signature": "abc123def456...",
      "first_seen": "2026-01-16T13:25:00Z",
      "occurrence_count": 5,
      "severity": "ERROR",
      "error_type": "KeyError",
      "message": "KeyError: 'user_id'",
      "traceback": "Full traceback here...",
      "resource_labels": {
        "service_name": "service-name",
        "revision_name": "service-name-00042-abc"
      },
      "sample_log_entry": { }
    }
  ]
}
```
