# Push Workflow

This workflow audits changes, commits them, pushes to git, and optionally deploys.

## Steps

1. **Audit the work** - Ensure all planned tasks were implemented correctly
2. **Check for bugs** - Look for syntax errors, typos, logic issues. If found, fix them and re-audit
3. **Commit** - Create a descriptive commit with title and body
4. **Push** - Push to remote (use timeout to avoid hanging)
5. **Deploy** - If a deploy script exists, run it

## Execution

### Step 1: Audit

Review all changes made. Verify:
- All planned features are implemented
- No unfinished TODO comments left behind
- Code compiles/runs without errors

### Step 2: Bug Check

Scan for common issues:
- Syntax errors
- Missing imports
- Undefined variables
- Logic errors

If issues found → fix them → return to Step 1.

### Step 3: Commit

```powershell
git add -A
git commit -m "Title: Brief summary" -m "Body: Detailed description of changes"
```

### Step 4: Push

```powershell
Start-Process -NoNewWindow -Wait -FilePath "git" -ArgumentList "push origin main" -PassThru | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
```

### Step 5: Deploy (if applicable)

If the workspace has a `deploy.ps1` script:
```powershell
.\deploy.ps1
```
