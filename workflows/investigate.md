# Error Investigation Workflow

This workflow investigates pending errors detected by the Error Orchestrator system.

## When This Workflow Runs

This workflow is triggered automatically by the Error Orchestrator when new distinct errors are detected. The launch prompt will include:
1. Number of errors to investigate
2. Service name
3. Error types detected
4. Path to the pending errors file

## Steps

1. **Initialize docs/AUTOMATED_PATCHES.md** if it doesn't exist:
   - Check if `docs/AUTOMATED_PATCHES.md` exists in this workspace
   - If not, copy the template from `<orchestrator-path>\templates\AUTOMATED_PATCHES.md`
   - This file tracks all automated patches made to this service
2. **Read the pending errors file** specified in the launch prompt (e.g., `<orchestrator-path>\data\pending\<service>.json`)
3. **For each distinct error**, use the gcloud-logs MCP tools to fetch additional context:
   - Surrounding logs (before and after the error)
   - Related requests from the same user/session
   - Similar errors from the past
4. **Classify each error** into one of three categories:
   - **User Error**: Something the user did wrong (wrong URL, invalid input, unauthorized access attempt)
   - **System Bug**: Actual defect in our code that needs fixing
   - **External Factor**: Network issues, third-party service failures, GCP outages
5. **Verify the error still exists** before implementing any fix:
   - Check if the affected code has changed since the error timestamp
   - Use `git log --since="<error_timestamp>" -- <affected_file>` to see recent commits
   - If the code was already modified, the error may already be fixed
   - If already fixed: Document as "Already Resolved" in AUTOMATED_PATCHES.md and skip to step 9
   - Only proceed with a fix if the problematic code still exists
6. **Implement the appropriate response** for each error:
   - **User Error**: Add exception handler that returns a helpful error message, log with AUTOMATED_PATCH_APPLIED
   - **System Bug**: Fix the actual bug in the code, log with AUTOMATED_PATCH_APPLIED
   - **External Factor**: Add monitoring/alerting, no code changes needed, document for awareness
7. **For ALL patches**: Add consistent logging with `AUTOMATED_PATCH_APPLIED` event type
8. **Update docs/AUTOMATED_PATCHES.md** in this workspace with investigation findings and patches made
9. **Check for related service changes**: If backend changes require frontend updates, note this
10. **Run the push workflow** to audit, commit, push, and deploy changes

## Investigation Guidelines

### Determining Error Classification

Ask these questions:

**Is it a User Error?**
1. Did the error occur because of invalid user input or misconfiguration?
2. Did the user access from the wrong URL/domain?
3. Did the user send malformed requests?
4. Is this an unauthorized access attempt?

**Is it a System Bug?**
1. Would a legitimate user following our documentation hit this error?
2. Is there a null pointer, missing validation, or logic error?
3. Is the error reproducible with valid inputs?

**Is it an External Factor?**
1. Is this a network timeout or connection failure?
2. Did a third-party API fail?
3. Is there a GCP service degradation?
4. Does the error correlate with infrastructure issues?

**Important**: If the user caused it but our code crashed instead of handling it gracefully → classify as User Error but add defensive code to handle it gracefully.

### Exception Handler Pattern

For user-caused errors, add exception handlers that:
1. Catch the specific error
2. Log with AUTOMATED_PATCH_APPLIED event type
3. Return a helpful error response to the client
4. Don't crash the server

**Python Example:**
```python
try:
    # risky operation
except SpecificError as e:
    logger.warning("AUTOMATED_PATCH_APPLIED", extra={
        "patch_id": "AP-2026-XXX",
        "original_error": str(e),
        "error_classification": "user_error",
        "action_taken": "exception_handler_added",
        "affected_endpoint": "/api/endpoint",
        "related_service_change_required": False,
        "user_message_returned": "Helpful message for user"
    })
    raise HTTPException(status_code=400, detail={
        "error": "specific_error_type",
        "message": "Helpful message for user",
        "user_action_required": True
    })
```

**Node.js Example:**
```javascript
try {
    // risky operation
} catch (error) {
    if (error instanceof SpecificError) {
        logger.warn('AUTOMATED_PATCH_APPLIED', {
            patch_id: 'AP-2026-XXX',
            original_error: error.message,
            error_classification: 'user_error',
            action_taken: 'exception_handler_added',
            affected_endpoint: '/api/endpoint',
            related_service_change_required: false,
            user_message_returned: 'Helpful message for user'
        });
        return res.status(400).json({
            error: 'specific_error_type',
            message: 'Helpful message for user',
            user_action_required: true
        });
    }
    throw error;
}
```

### AUTOMATED_PATCHES.md Entry Format

After investigation, add an entry to `docs/AUTOMATED_PATCHES.md`:

```markdown
## AP-YYYY-NNN | YYYY-MM-DD HH:MM:SS

**Error:** Brief description of what was failing

**Verdict:** User Error | System Bug | External Factor

**Investigation:** Summary of root cause analysis - what you found, why it happened

**Patch:** Description of code changes made, or "None - monitoring only" for external factors

**Related Service Change:** Yes/No - if yes, describe what the related service needs to do

**Files Modified:**
1. path/to/file1.py - brief description of change
2. path/to/file2.py - brief description of change

**Event Type:** AUTOMATED_PATCH_APPLIED

---
```

### Logging Event Schema

All automated patches MUST log this structure for consistent monitoring:

```python
logger.warning("AUTOMATED_PATCH_APPLIED", extra={
    "patch_id": "AP-YYYY-NNN",                    # Unique ID: AP-<year>-<sequential number>
    "original_error": "...",                      # The error message that triggered investigation
    "error_classification": "user_error|system_bug|external_factor",
    "action_taken": "...",                        # What was done (e.g., "exception_handler_added", "null_check_added", "monitoring_added")
    "affected_endpoint": "/api/...",              # API route if applicable
    "related_service_change_required": True,      # Boolean: does related service need update?
    "user_message_returned": "..."                # The message returned to the user, if any
})
```

## After Investigation

1. **Verify patches work**: Ensure all code changes compile/run correctly
2. **Check for errors**: Look for syntax errors, import issues, etc.
3. **Run MIT workflow**: This will:
   - Audit the changes
   - Commit with descriptive message
   - Push to remote
   - Deploy if deploy script is configured
4. **If related service change is needed**: Inform user to open that workspace and run a follow-up investigation

## Pending Error File Format

The pending errors file contains this structure:

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

Use this information to understand:
- `error_type`: The exception class that was raised
- `message`: The error message
- `traceback`: The full stack trace for debugging
- `occurrence_count`: How many times this error occurred (helps prioritize)
- `sample_log_entry`: Raw log data for additional context
