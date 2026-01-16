# Error Orchestrator Implementation Plan

## Overview

This implementation plan breaks down the Error Orchestrator System Design into actionable tasks with dependencies and effort estimations. The Error Orchestrator is a standalone, service-agnostic tool that polls GCP Cloud Logging, identifies distinct errors across any registered services, routes them to appropriate workspaces, and triggers AI-powered investigation workflows.

**Environment Constraints:**
1. All scripts should be written in PowerShell for Windows Task Scheduler compatibility (with bash equivalents for Linux/Mac as a future enhancement)
2. The system is a standalone tool designed to work with any GCP project and any number of services
3. AI workflows should be designed for use with Cline or similar AI coding assistants
4. Configuration must be fully externalized with no hardcoded service names or paths

---

## Phase 1: Foundation and Configuration

### Task 1.1: Create Error Orchestrator Directory Structure

**Description:** Create the folder structure for the error orchestrator repository. This establishes the foundation for all subsequent components and defines the organizational pattern for the tool.

**Estimation:** 1 dev day

**Dependencies:** None

**Deliverables:** Repository directory structure

**Checklist:**
- [ ] Create `config/` directory for configuration files
- [ ] Create `config/services.example.json` as a template
- [ ] Create `data/` directory for runtime data storage
- [ ] Create `data/pending/` directory for pending error queues
- [ ] Create `scripts/` directory for PowerShell scripts
- [ ] Create `workflows/` directory for AI workflow definitions
- [ ] Create `templates/` directory for files users copy to their repos
- [ ] Create `README.md` with installation and usage documentation
- [ ] Add `.gitkeep` files to empty directories
- [ ] Create `.gitignore` to exclude `config/services.json` (user-specific) and `data/*.json`

---

### Task 1.2: Implement Service Registry Configuration

**Description:** Create the `services.json` configuration schema and example file that maps GCP service names to local workspace paths, service types, related services, and documentation paths. This configuration drives all routing decisions in the orchestrator.

**Estimation:** 1 dev day

**Dependencies:** Task 1.1

**Deliverables:** `config/services.example.json`, configuration documentation

**Checklist:**
- [ ] Create `services.example.json` with schema matching design specification
- [ ] Include placeholder entries for backend and frontend service examples
- [ ] Configure `related_frontend` and `related_backend` relationship examples
- [ ] Add `patches_doc` path configuration
- [ ] Add `deploy_script` path configuration
- [ ] Add `gcp_project` configuration field
- [ ] Add `polling_interval_minutes` configuration field
- [ ] Add `ide_command` configuration field (default: "code")
- [ ] Document all configuration options in README
- [ ] Create JSON schema file for validation (optional)

---

### Task 1.3: Create AUTOMATED_PATCHES.md Template

**Description:** Create the AUTOMATED_PATCHES.md template file that users will copy to their service repositories. This template documents all automated error investigations and patches made by the system.

**Estimation:** 1 dev day

**Dependencies:** None

**Deliverables:** `templates/AUTOMATED_PATCHES.md`

**Checklist:**
- [ ] Create `templates/AUTOMATED_PATCHES.md` with header and format documentation
- [ ] Include patch ID naming convention (AP-YYYY-NNN)
- [ ] Include template for new entries with all required fields
- [ ] Document the three verdict types (User Error, System Bug, External Factor)
- [ ] Include example entry showing expected format
- [ ] Add instructions for how to use the template in the file header
- [ ] Document in README how users should copy this to their repos

---

## Phase 2: Core Polling Infrastructure

### Task 2.1: Implement Error Signature Algorithm

**Description:** Implement the error signature hashing algorithm as a PowerShell function. This function computes a unique signature for each error based on severity, error type, normalized traceback, and affected function, enabling accurate deduplication across any service.

**Estimation:** 2 dev days

**Dependencies:** Task 1.1

**Deliverables:** `Get-ErrorSignature` function within `poll_errors.ps1`

**Checklist:**
- [ ] Implement `Get-ErrorSignature` function in PowerShell
- [ ] Extract severity from log entry
- [ ] Extract error type (exception class) from log entry
- [ ] Extract and normalize first line of traceback
- [ ] Implement `Normalize-TracebackLine` helper function
- [ ] Remove timestamps from traceback (multiple formats)
- [ ] Remove request IDs, trace IDs, correlation IDs
- [ ] Remove memory addresses and object IDs
- [ ] Extract affected endpoint or function name from log context
- [ ] Compute SHA256 hash of concatenated components
- [ ] Write unit tests for signature consistency
- [ ] Test with sample error logs from various services

---

### Task 2.2: Implement GCP Log Polling Script

**Description:** Create the main `poll_errors.ps1` PowerShell script that uses `gcloud logging read` to fetch recent ERROR and CRITICAL logs from the configured GCP project, parses the results, and prepares them for deduplication processing.

**Estimation:** 3 dev days

**Dependencies:** Task 1.2, Task 2.1

**Deliverables:** `scripts/poll_errors.ps1`

**Checklist:**
- [ ] Load configuration from `config/services.json`
- [ ] Validate configuration file exists and is valid JSON
- [ ] Build `gcloud logging read` filter for ERROR and CRITICAL severity
- [ ] Set time window to polling interval (configurable minutes + buffer)
- [ ] Execute gcloud command with `--project` flag from config
- [ ] Capture and parse JSON output
- [ ] Handle gcloud CLI errors gracefully (authentication, network, etc.)
- [ ] Extract required fields from log entries
- [ ] Group errors by service using `resource.labels.service_name`
- [ ] Filter to only services registered in configuration
- [ ] Log unregistered services to console for visibility
- [ ] Compute error signatures for each entry
- [ ] Add verbose logging for debugging
- [ ] Add `-Verbose` and `-Debug` parameter support
- [ ] Test with live GCP logs from multiple services

---

### Task 2.3: Implement Error Deduplication Logic

**Description:** Implement the deduplication logic that compares new error signatures against the `seen_errors.json` file and identifies truly new, distinct errors. Update the seen errors file with newly processed signatures.

**Estimation:** 2 dev days

**Dependencies:** Task 2.1, Task 2.2

**Deliverables:** Deduplication logic in `poll_errors.ps1`, `data/seen_errors.json` schema

**Checklist:**
- [ ] Define `seen_errors.json` schema with signature hash as key
- [ ] Include first_seen timestamp per signature
- [ ] Include last_seen timestamp per signature
- [ ] Include occurrence_count per signature
- [ ] Include service_name per signature for context
- [ ] Implement `Get-SeenErrors` function to load seen signatures
- [ ] Handle missing or corrupt file gracefully (treat as empty)
- [ ] Implement `Test-NewError` function to check if signature is new
- [ ] Implement `Add-SeenError` function to record new signatures
- [ ] Update last_seen and occurrence_count for existing signatures
- [ ] Filter incoming errors to only new, distinct ones
- [ ] Save updated `seen_errors.json` after processing
- [ ] Add optional TTL parameter for signature expiration (days)
- [ ] Implement `Clear-ExpiredErrors` function for TTL cleanup
- [ ] Handle file locking for concurrent access safety

---

### Task 2.4: Implement Pending Error Queue Management

**Description:** Implement the logic to write new distinct errors to service-specific pending files (`pending/<service>.json`). These files serve as the investigation queue for each service and are consumed by the investigation workflow.

**Estimation:** 2 dev days

**Dependencies:** Task 2.3

**Deliverables:** Queue management in `poll_errors.ps1`, `data/pending/` file schema

**Checklist:**
- [ ] Define pending error file schema
- [ ] Implement `Write-PendingErrors` function
- [ ] Group new errors by service name
- [ ] Create or append to `pending/<service>.json` for each service with errors
- [ ] Include all required fields per error (signature, timestamp, count, traceback, etc.)
- [ ] Include full sample log entry for investigation context
- [ ] Track occurrence count for repeated errors within polling window
- [ ] Implement `Get-PendingErrors` function for reading queues
- [ ] Implement `Clear-PendingErrors` function for post-investigation cleanup
- [ ] Accept service name parameter for selective clearing
- [ ] Add file locking for safe concurrent access
- [ ] Handle edge case of empty error list (no file created)

---

## Phase 3: Notification and Launch System

### Task 3.1: Implement Desktop Notifications

**Description:** Add Windows toast notification capability to alert the developer when new distinct errors are detected. Notifications should include service name, error count, and provide actionable information.

**Estimation:** 1 dev day

**Dependencies:** Task 2.4

**Deliverables:** Notification logic in `poll_errors.ps1`

**Checklist:**
- [ ] Research notification options (BurntToast module vs native)
- [ ] Implement `Show-ErrorNotification` function
- [ ] Include service name and error count in notification title
- [ ] Include brief error summary in notification body (first error message)
- [ ] Handle case of multiple services with errors (summary notification)
- [ ] Add notification sound for urgency (configurable)
- [ ] Add `-Silent` flag to suppress notifications
- [ ] Test notification appearance and behavior
- [ ] Document BurntToast installation requirement if used
- [ ] Add fallback to Write-Host if notification module unavailable

---

### Task 3.2: Implement Investigation Launch Script

**Description:** Create `launch_investigation.ps1` script that fully automates launching Cline with an investigation task. Uses Windows SendKeys API to simulate keyboard input: opens VS Code in the correct workspace, focuses Cline's chat input using `Ctrl+'` keybinding, types the investigation prompt, and presses Enter to start the task. Zero manual steps required.

**Estimation:** 2 dev days

**Dependencies:** Task 1.2, Task 2.4

**Deliverables:** `scripts/launch_investigation.ps1`

**Checklist:**
- [ ] Accept `-Service` parameter for service name
- [ ] Load configuration from `config/services.json`
- [ ] Validate service exists in configuration
- [ ] Read pending errors from `data/pending/<service>.json`
- [ ] Validate workspace path exists
- [ ] Launch VS Code in service workspace: `code "<workspace_path>"`
- [ ] Wait for VS Code to fully load: `Start-Sleep -Seconds 3` (configurable)
- [ ] Load SendKeys API: `Add-Type -AssemblyName System.Windows.Forms`
- [ ] Focus Cline input: `[System.Windows.Forms.SendKeys]::SendWait("^'")`
- [ ] Wait for Cline to focus: `Start-Sleep -Milliseconds 500`
- [ ] Type investigation prompt: `[System.Windows.Forms.SendKeys]::SendWait($prompt)`
- [ ] Submit task: `[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")`
- [ ] Add `-WaitTime` parameter to adjust VS Code load wait time
- [ ] Print summary of pending errors (count, types) to console
- [ ] Handle case where no pending errors exist for service
- [ ] Add `-NoLaunch` flag for headless mode (testing/scripting)
- [ ] Add `-ListServices` flag to show all services with pending errors
- [ ] Return appropriate exit codes for scripting
- [ ] Document that this is Windows-only (SendKeys limitation)

---

### Task 3.3: Integrate Launch with Polling Script

**Description:** Connect the polling script to the launch script so that when new errors are detected, the system automatically shows a notification and optionally launches investigation in the appropriate workspace.

**Estimation:** 1 dev day

**Dependencies:** Task 3.1, Task 3.2

**Deliverables:** Integration in `poll_errors.ps1`

**Checklist:**
- [ ] Add `-AutoLaunch` flag to polling script
- [ ] Call notification function when new errors detected
- [ ] Call launch script when `-AutoLaunch` is enabled
- [ ] Handle multiple services with errors (prompt user or launch first)
- [ ] Add `-LaunchAll` flag to launch all services sequentially
- [ ] Document different invocation modes in script help
- [ ] Add `-WhatIf` parameter support for dry-run testing
- [ ] Test complete flow from poll to launch

---

## Phase 4: Investigation Workflow

### Task 4.1: Create AI Investigation Workflow

**Description:** Create the AI workflow file that guides the AI through the investigation process, including reading pending errors, analyzing logs, classifying errors, and recommending patches. This workflow is designed for use with Cline or similar AI coding assistants.

**Estimation:** 3 dev days

**Dependencies:** Task 2.4

**Deliverables:** `workflows/investigate.md`

**Checklist:**
- [ ] Create workflow file with clear step-by-step instructions
- [ ] Step 1: Identify pending errors file path based on current workspace
- [ ] Step 2: Read pending errors from the appropriate file
- [ ] Step 3: For each error, gather additional context from logs if MCP available
- [ ] Step 4: Analyze error to classify as User Error, System Bug, or External Factor
- [ ] Step 5: For User Errors, recommend exception handler with helpful response
- [ ] Step 6: For System Bugs, investigate root cause and recommend fix
- [ ] Step 7: For External Factors, recommend monitoring without code changes
- [ ] Step 8: Document findings in AUTOMATED_PATCHES.md
- [ ] Step 9: Implement recommended patches if approved
- [ ] Step 10: Add AUTOMATED_PATCH_APPLIED logging to patches
- [ ] Step 11: Run commit/push/deploy workflow
- [ ] Step 12: Check if related service changes needed, provide guidance
- [ ] Include decision tree for error classification
- [ ] Include examples of good exception handling patterns
- [ ] Include examples of good logging patterns (Python, Node.js)
- [ ] Document how to handle cross-service changes

---

### Task 4.2: Create Post-Investigation Cleanup Script

**Description:** Create a script to clear pending errors after investigation is complete. This prevents re-investigation of already-handled errors.

**Estimation:** 1 dev day

**Dependencies:** Task 2.4, Task 4.1

**Deliverables:** `scripts/clear_pending.ps1`

**Checklist:**
- [ ] Accept `-Service` parameter for service name
- [ ] Accept `-All` flag to clear all pending queues
- [ ] Confirm before clearing (unless `-Force` specified)
- [ ] Remove `data/pending/<service>.json` file
- [ ] Print summary of what was cleared
- [ ] Handle case where file doesn't exist gracefully
- [ ] Add to investigation workflow instructions

---

## Phase 5: Task Scheduler Setup

### Task 5.1: Create Task Scheduler Setup Script

**Description:** Create a PowerShell script that configures Windows Task Scheduler to run the polling script at the configured interval. This automates the error monitoring process.

**Estimation:** 2 dev days

**Dependencies:** Task 3.3

**Deliverables:** `scripts/setup_task_scheduler.ps1`

**Checklist:**
- [ ] Read polling interval from `config/services.json`
- [ ] Create scheduled task named "ErrorOrchestrator-Poll"
- [ ] Set trigger to run at configured interval (default: 5 minutes)
- [ ] Set action to run `poll_errors.ps1` with notification enabled
- [ ] Configure to run whether user is logged in or not
- [ ] Set execution policy and working directory
- [ ] Request admin privileges if needed
- [ ] Implement `Install-ErrorOrchestrator` function for setup
- [ ] Implement `Uninstall-ErrorOrchestrator` function for cleanup
- [ ] Implement `Get-ErrorOrchestratorStatus` function to check status
- [ ] Handle existing task (prompt to update or error)
- [ ] Test task creation and execution
- [ ] Add task description for visibility in Task Scheduler UI

---

### Task 5.2: Create Manual Operation Scripts

**Description:** Create convenience scripts for manually triggering error polling and checking status outside of the scheduled task. Useful for testing, on-demand checks, and debugging.

**Estimation:** 1 dev day

**Dependencies:** Task 3.3

**Deliverables:** `scripts/run_now.ps1`, `scripts/status.ps1`

**Checklist:**
- [ ] Create `run_now.ps1` to manually trigger a poll cycle
- [ ] Forward all parameters to `poll_errors.ps1`
- [ ] Create `status.ps1` to show current system status
- [ ] Display scheduled task status (running, next run time)
- [ ] Display count of pending errors by service
- [ ] Display recent seen errors (last N)
- [ ] Display configuration summary
- [ ] Add help documentation to each script
- [ ] Test manual execution workflow

---

## Phase 6: Documentation and Testing

### Task 6.1: Create Comprehensive README

**Description:** Create detailed README documentation for the error orchestrator, including installation instructions, configuration guide, usage examples, and troubleshooting information.

**Estimation:** 2 dev days

**Dependencies:** All previous tasks

**Deliverables:** `README.md`

**Checklist:**
- [ ] Write overview and features section
- [ ] Document prerequisites (gcloud CLI, PowerShell, VS Code/IDE)
- [ ] Write installation instructions (clone, configure, install)
- [ ] Document configuration file format with examples
- [ ] Explain how to add new services
- [ ] Document usage for scheduled operation
- [ ] Document usage for manual operation
- [ ] Document investigation workflow usage
- [ ] Add troubleshooting section for common issues
- [ ] Document error signature algorithm for transparency
- [ ] Add architecture diagram reference
- [ ] Document how to add services to the registry
- [ ] Document cross-service coordination workflow
- [ ] Add FAQ section
- [ ] Add contributing guidelines

---

### Task 6.2: End-to-End Testing

**Description:** Perform comprehensive end-to-end testing of the entire error orchestrator system, from polling through investigation and cleanup. Test with real GCP services to validate the complete workflow.

**Estimation:** 2 dev days

**Dependencies:** All previous tasks

**Checklist:**
- [ ] Test configuration loading with valid config
- [ ] Test configuration loading with invalid/missing config
- [ ] Test polling with no errors (should exit quietly)
- [ ] Test polling with new errors (should notify and queue)
- [ ] Test deduplication (repeated errors should not create new tasks)
- [ ] Test service routing (errors go to correct workspace)
- [ ] Test notification appearance
- [ ] Test IDE launch with correct workspace
- [ ] Test investigation workflow with sample error
- [ ] Test AUTOMATED_PATCHES.md entry creation
- [ ] Test pending error cleanup
- [ ] Test Task Scheduler operation over 30+ minutes
- [ ] Test with multiple services in config
- [ ] Test with unregistered service in logs (should log, not crash)
- [ ] Document any bugs found and fixes applied

---

## Dependency Graph

```
Phase 1: Foundation
  1.1 Directory Structure ─────┬───────────────────────────────────────┐
                               │                                       │
  1.2 Service Registry ────────┼──────────────────────────┐           │
       (depends on 1.1)        │                          │           │
                               │                          │           │
  1.3 PATCHES Template ────────┼──────────────────────────┼───────────┤
       (no dependencies)       │                          │           │
                               │                          │           │
Phase 2: Core Polling          │                          │           │
  2.1 Error Signature ─────────┤                          │           │
       (depends on 1.1)        │                          │           │
                               │                          │           │
  2.2 Polling Script ──────────┤                          │           │
       (depends on 1.2, 2.1)   │                          │           │
                               │                          │           │
  2.3 Deduplication ───────────┤                          │           │
       (depends on 2.1, 2.2)   │                          │           │
                               │                          │           │
  2.4 Pending Queue ───────────┼──────────────────────────┤           │
       (depends on 2.3)        │                          │           │
                               │                          │           │
Phase 3: Notification          │                          │           │
  3.1 Notifications ───────────┤                          │           │
       (depends on 2.4)        │                          │           │
                               │                          │           │
  3.2 Launch Script ───────────┤                          │           │
       (depends on 1.2, 2.4)   │                          │           │
                               │                          │           │
  3.3 Integration ─────────────┼──────────────────────────┤           │
       (depends on 3.1, 3.2)   │                          │           │
                               │                          │           │
Phase 4: Investigation         │                          │           │
  4.1 AI Workflow ─────────────┼──────────────────────────┼───────────┤
       (depends on 2.4)        │                          │           │
                               │                          │           │
  4.2 Cleanup Script ──────────┤                          │           │
       (depends on 2.4, 4.1)   │                          │           │
                               │                          │           │
Phase 5: Task Scheduler        │                          │           │
  5.1 Setup Script ────────────┤                          │           │
       (depends on 3.3)        │                          │           │
                               │                          │           │
  5.2 Manual Scripts ──────────┤                          │           │
       (depends on 3.3)        │                          │           │
                               │                          │           │
Phase 6: Documentation         │                          │           │
  6.1 README ──────────────────┼──────────────────────────┼───────────┘
       (depends on all)        │                          │
                               │                          │
  6.2 E2E Testing ─────────────┴──────────────────────────┘
       (depends on all)
```

---

## Effort Summary

| Phase | Tasks | Total Dev Days |
|-------|-------|----------------|
| Phase 1: Foundation and Configuration | 3 | 3 days |
| Phase 2: Core Polling Infrastructure | 4 | 9 days |
| Phase 3: Notification and Launch System | 3 | 4 days |
| Phase 4: Investigation Workflow | 2 | 4 days |
| Phase 5: Task Scheduler Setup | 2 | 3 days |
| Phase 6: Documentation and Testing | 2 | 4 days |

**Total Estimated Effort:** 27 dev days

**Note:** Phases 1-3 form the critical path and must be completed sequentially. Phase 4 can begin once Task 2.4 is complete. Phases 5-6 can be parallelized once Phase 3 is complete.

---

## Milestones

| Milestone | Target Tasks | Success Criteria |
|-----------|--------------|------------------|
| M1: Infrastructure Ready | 1.1-1.3 | Directory structure created, example config in place, template ready |
| M2: Polling Functional | 2.1-2.4 | Script can poll any configured GCP project, deduplicate errors, and write to pending queue |
| M3: Notification Working | 3.1-3.3 | Desktop notifications appear, IDE launches in correct workspace for any service |
| M4: Investigation Complete | 4.1-4.2 | AI can read pending errors and execute investigation workflow, cleanup works |
| M5: Fully Automated | 5.1-5.2 | Task Scheduler runs polling at configured interval without manual intervention |
| M6: Production Ready | 6.1-6.2 | Documentation complete, all E2E tests pass with multiple services |

---

## Risk Mitigation Tasks (Optional)

### Task R.1: GCP CLI Authentication Spike

**Description:** Verify that `gcloud logging read` works correctly with various authentication setups (user credentials, service accounts, multiple projects) and identify any potential issues with permissions or token refresh.

**Estimation:** 1 dev day

**Dependencies:** None

**Checklist:**
- [ ] Test `gcloud logging read` command with user credentials
- [ ] Test with service account authentication
- [ ] Test with multiple GCP projects
- [ ] Verify authentication persists across sessions
- [ ] Document required IAM permissions (Logs Viewer role)
- [ ] Test behavior when authentication expires
- [ ] Document troubleshooting steps for auth issues

---

### Task R.2: Notification Library Evaluation

**Description:** Evaluate PowerShell toast notification options (BurntToast module vs native Windows APIs) and select the most reliable approach for the target environment.

**Estimation:** 1 dev day

**Dependencies:** None

**Checklist:**
- [ ] Test BurntToast module installation and usage
- [ ] Test native PowerShell toast notifications
- [ ] Compare reliability and features
- [ ] Test on different Windows versions
- [ ] Document chosen approach and rationale
- [ ] Document installation requirements for users

---

### Task R.3: Cross-Platform Considerations Spike

**Description:** Evaluate requirements for supporting macOS and Linux in future versions. Identify what would need to change in the current design.

**Estimation:** 1 dev day

**Dependencies:** None

**Checklist:**
- [ ] Document bash equivalents for PowerShell scripts
- [ ] Research cron job setup for Linux/Mac
- [ ] Research notification options for Linux/Mac
- [ ] Document platform-specific considerations
- [ ] Update design doc with cross-platform notes
