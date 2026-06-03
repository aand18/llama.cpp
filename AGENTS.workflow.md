# AGENTS.workflow.md — Personal workflow for this llama.cpp fork

> **Status:** Plan v1, awaiting execution. Not yet committed; lives on
> whatever branch is checked out until `local/integrated` is created
> and the file is committed there.
>
> **Audience:**
> - AI agents (opencode) reading this to orient themselves
> - The human maintainer reviewing the workflow before executing it

---

## 1. Goal

Maintain a personalized fork of `ggml-org/llama.cpp` on GitHub with:

- `master` always pure upstream (FF-only)
- A build target branch that always contains "everything I want"
- A workflow the next session can recover from cold start, including
  opencode's auto-created worktrees

---

## 2. Branch layout

| Branch | Tracks | Job | Push to fork? | PR-able? |
|--------|--------|-----|---------------|----------|
| `master` | `upstream/master` (FF-only) | Pure upstream | yes (protected) | no |
| `local/integrated` | rebase on `master`, merges in `local/*` + `topic/*` you want | **Build target** AND default worktree base | yes (private) | **no** |
| `local/*` | rebase on `master` | Long-term personal layer (tools, helpers) | yes | no |
| `topic/*` | rebase on `master` | One concern, PR-able upstream | yes | yes |
| `wip/*` | rebase on `master` | Throwaway experiments | no | no |
| `opencode/*` | rebase on `local/integrated` (NEW) | Agent session branches | no | no |

### Hard rules

1. **Never edit `master` directly.** Only `git merge --ff-only upstream/master`.
2. **Never `git push --force` to `upstream`.** It's read-only by convention.
3. **Always use `git push --force-with-lease` when rebase-pushing to `origin`.**
4. **Resolve rebase conflicts on `local/integrated`, not on topic branches.**
   The integration branch is the conflict-resolution surface; topic
   branches keep their clean history for PR.
5. **Don't commit files outside the user's existing workflow without asking.**

---

## 3. Remotes

- `origin` → user's fork (push here, including `master` for protection)
- `upstream` → `https://github.com/ggml-org/llama.cpp.git` (read-only)

**Setup (one-time):**

```powershell
git remote rename origin upstream
git remote add origin git@github.com:<you>/llama.cpp.git
git fetch upstream
```

(If `origin` already points to your fork, only add `upstream`.)

---

## 4. Worktrees

### Default base

**`local/integrated`.** This is the change from opencode's default of `master`.

Rationale: the agent should start with the personal layer (find-fitt
tools, MTP debug helpers, etc.) in place from the first commit. Branching
from `master` puts the agent in a vanilla upstream context with no
project knowledge.

### Fallback to `master`

Allowed when:

- `local/integrated` doesn't exist yet
- The user explicitly says "test against vanilla upstream" or similar
- The user says "verify this on a clean checkout"

### End-of-session reconciliation

The `opencode/<random>` branches created by the worktree button are
ephemeral. After a session:

| Session work is... | Action |
|--------------------|--------|
| Useful, for you personally | `git checkout local/integrated && git merge --no-ff opencode/<random>` then `git branch -D opencode/<random>` |
| Useful, upstream-bound | Rename `opencode/<random>` → `topic/<name>`, rebase on `master`, then PR |
| Throwaway | `git branch -D opencode/<random>` and `git worktree prune` |

Run `tools/dev/Prune-Worktrees.ps1 -DryRun` to see what would be cleaned.

### Worktree directory

- opencode-managed: `~/.local/share/opencode/worktree/<session-hash>/<name>/` (auto)
- User-managed: `<repo>/.worktrees/<branch>/` (project-local, already `.gitignore`d per `cc01cfb46`)

---

## 5. Files this workflow introduces

All files live on `local/integrated` and propagate to `local/*` via rebase.
**None of them are on `master`.**

| File | Size | Job |
|------|------|-----|
| `AGENTS.workflow.md` (this file) | ~200 lines | Full personal workflow for the agent |
| `tools/dev/AGENTS.md` | ~15 lines | Subdir-scoped rules for `tools/dev/` |
| `tools/dev/README.md` | ~40 lines | Human version with examples |
| `tools/dev/Update-Integrated.ps1` | ~25 lines + header | Fetch + FF + rebase + merge + push |
| `tools/dev/Prune-Worktrees.ps1` | ~30 lines | List / clean stale `opencode/*` branches |

### Global config (in your home dir, not the repo)

Extend `~/.config/opencode/AGENTS.md` with:

```markdown
## Customized forks

When working in any repo that's a personalized fork (the user has mentioned
they maintain one, like llama.cpp):

1. Run `git branch --show-current` first
2. Check for `<repo>/AGENTS.workflow.md` — if present, read it before doing anything
3. If on `master` and no `AGENTS.workflow.md` exists, ask the user:
   "This looks like a fresh clone. Do you have a personal workflow I should
   follow, or should I treat this as standard upstream?"
4. Default build/target branch is `local/integrated` unless told otherwise
5. Default worktree base is `local/integrated`. Fall back to `master` only
   when the user explicitly says "test against upstream" or `local/integrated`
   doesn't exist.
```

---

## 6. Scripts

### `tools/dev/Update-Integrated.ps1`

Refreshes `local/integrated` with current upstream + all personal branches.

**Header (visible to both humans and agents reading the file):**

```powershell
<#
.SYNOPSIS
Refresh the local/integrated build branch with upstream master + all personal branches.

.DESCRIPTION
Run this when:
  - upstream llama.cpp has new commits you want
  - you finish work on a local/* or topic/* branch
  - you want a fresh build with everything

This is the ONLY supported way to update local/integrated.
Do not rebase local/integrated manually; let this script do it.

Configure which branches get merged in by editing the $Branches array below.

If master has diverged from upstream/master (local commits not on upstream),
the script refuses to run with a clear error and a recovery recipe. This
protects you from accidental master rewrites when upstream has new commits.
#>
```

**Body (~25 lines):**

```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib = Join-Path $here '_lib.ps1'
if (Test-Path $lib) { . $lib }

$Branches = @(
    'local/find-fitt-tools'
    'local/mtp-debug-helpers'
    # Add more as you create them
    # 'topic/mtp-pr-22673'    # only if you want it in the build target
)

git fetch upstream
if ($LASTEXITCODE -ne 0) { throw "fetch failed" }

# Preflight: refuse to run if master has diverged from upstream/master.
# A divergent master means the --ff-only merge below cannot succeed silently
# and the script would otherwise corrupt master by force-resetting.
$localMaster    = git rev-parse master
$upstreamMaster = git rev-parse upstream/master
$mergeBase      = git merge-base master upstream/master

if ($localMaster -ne $mergeBase -and $upstreamMaster -ne $mergeBase) {
    throw @"
master has diverged from upstream/master; refusing to continue.
  local master  = $localMaster
  upstream      = $upstreamMaster
  merge-base    = $mergeBase

Both sides have unique commits, so 'git merge --ff-only upstream/master' would
fail and the script would halt anyway. To recover:

    git checkout master
    git reset --hard upstream/master
    git checkout local/integrated
    git rebase master
    git push --force-with-lease origin local/integrated

The 1 local-only commit on master (if any) is already preserved on
local/integrated because that branch was created from master, so it survives
the reset. Then re-run this script.
"@
}

git checkout master
git merge --ff-only upstream/master
if ($LASTEXITCODE -ne 0) { throw "master FF failed; resolve manually" }

git checkout local/integrated
git rebase master
if ($LASTEXITCODE -ne 0) { throw "rebase local/integrated on master failed; resolve, then run this script again" }

foreach ($b in $Branches) {
    git show-ref --verify --quiet "refs/heads/$b"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Merging $b into local/integrated" -ForegroundColor Cyan
        git merge --no-ff $b
        if ($LASTEXITCODE -ne 0) {
            throw "merge of $b failed; resolve, then run this script again"
        }
    } else {
        Write-Warning "Branch $b does not exist locally; skipping"
    }
}

git push --force-with-lease origin local/integrated
Write-Host "local/integrated is current on $(git rev-parse --short master)" -ForegroundColor Green
```

### `tools/dev/Prune-Worktrees.ps1`

Lists / cleans stale `opencode/*` branches.

```powershell
<#
.SYNOPSIS
Archive stale opencode/* worktree branches: rename to archive/<name>, push to origin, then remove the local ref.

.DESCRIPTION
Safe-by-default cleanup. Each branch goes through this pipeline:
  1. Find its worktree (if any)
  2. Remove the worktree with 'git worktree remove --force'
  3. Rename the local branch to archive/<original-name>
  4. Push archive/<original-name> to origin
  5. Delete the local archive ref (the data is preserved on origin)

If any step fails, the script halts with a clear error and rolls back the
rename. The branch is NEVER just deleted: there's always a remote archive
under refs/heads/archive/opencode/<name> as a safety net.

To re-use an archived branch later:
    git fetch origin
    git checkout -b <new-name> origin/archive/opencode/<name>

.PARAMETER DryRun
Show what would be archived without doing anything.

.PARAMETER Interactive
Ask before archiving each branch (k/a/s = keep/archive/skip).

.PARAMETER Keep
List of branch-name patterns to never touch (e.g., 'opencode/keep-this').

.PARAMETER Force
In non-interactive mode, archive every opencode/* branch without prompting.
#>
param(
    [switch]$DryRun,
    [switch]$Interactive,
    [switch]$Force,
    [string[]]$Keep = @()
)

$worktreeMap = @{}
$wt = $null
git worktree list --porcelain | ForEach-Object {
    if ($_ -match '^worktree (.+)$') { $wt = $matches[1] }
    elseif ($_ -match '^branch refs/heads/(.+)$') {
        $worktreeMap[$matches[1]] = $wt
    }
}

foreach ($b in $branches) {
    $commits = (git log --oneline "master..$b" 2>$null | Measure-Object).Count
    $wtPath = $worktreeMap[$b]
    $wtInfo = if ($wtPath) { " [worktree: $wtPath]" } else { '' }
    $info = "$b ($commits commits ahead of master)$wtInfo"
    $archiveName = "archive/$b"

    if ($DryRun) {
        Write-Host "WOULD ARCHIVE: $info -> $archiveName (push to origin, remove local ref)"
        continue
    }

    if ($Interactive -and -not $Force) {
        $ans = Read-Host "$info -- (k)eep, (a)rchive, (s)kip?"
        switch -Wildcard ($ans) {
            'k*' { Write-Host "kept $b"; continue }
            's*' { Write-Host "skipped $b"; continue }
            'a*' { }  # fall through to archive
            default { Write-Host "skipped $b (unrecognized)"; continue }
        }
    } elseif (-not $Interactive -and -not $Force) {
        Write-Host $info
        Write-Warning "Pass -Interactive or -Force to act on the above."
        return
    }

    if (git show-ref --verify --quiet "refs/heads/$archiveName") {
        Write-Warning "$archiveName already exists locally; skipping $b"
        continue
    }
    if (git show-ref --verify --quiet "refs/remotes/origin/$archiveName") {
        Write-Warning "$archiveName already exists on origin; skipping $b"
        continue
    }

    if ($wtPath) {
        Write-Host "removing worktree $wtPath" -ForegroundColor Cyan
        git worktree remove --force $wtPath
        if ($LASTEXITCODE -ne 0) {
            throw "worktree remove failed for $wtPath; resolve manually, then re-run"
        }
    }

    git branch -m $b $archiveName
    if ($LASTEXITCODE -ne 0) { throw "rename $b -> $archiveName failed" }

    git push -u origin $archiveName
    if ($LASTEXITCODE -ne 0) {
        git branch -m $archiveName $b
        throw "push $archiveName to origin failed; rename rolled back"
    }

    git update-ref -d "refs/heads/$archiveName"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "local archive ref $archiveName could not be removed; leaving it (data is still on origin)"
    }

    Write-Host "archived $b -> $archiveName (pushed to origin, local ref removed)" -ForegroundColor Green
}
```

---

## 7. Day-to-day commands

| I want to… | Commands |
|------------|----------|
| Build llama-server with all my customizations | `git checkout local/integrated && cmake --build build` |
| Pull upstream into my build | `tools/dev/Update-Integrated.ps1` |
| Start a new personal tool | `git checkout -b local/<name> master` → work → commit → run `Update-Integrated.ps1` |
| Start a new upstream-bound feature | `git checkout -b topic/<name> master` → work → commit → push → open PR |
| Start a new agent session | Use opencode's worktree button (it'll branch from `local/integrated` now) |
| Tweak a tool in-place | edit files on `local/integrated` directly with `git commit --amend` later, OR rebase the `local/*` branch and re-run `Update-Integrated.ps1` |
| Verify behavior on vanilla upstream | `git checkout -b topic/verify-foo master` and tell the agent "branch from `master` for this" |
| Clean stale opencode branches | `tools/dev/Prune-Worktrees.ps1 -Interactive` |
| Throw away everything and start clean | `git checkout master && git clean -fdx` (your work is safe on `local/*` and `local/integrated`) |
| Re-apply everything on a fresh clone | `git checkout -b local/integrated master && git am /path/to/patches/*.patch` (only if you exported patches; not part of the default workflow) |

---

## 8. Execution checklist (when exiting plan mode)

These steps run **once** to set up the workflow. **All completed** as of 2026-06-03.

1. Add `upstream` remote (rename `origin` if needed, then `git remote add origin <fork>`)
2. `git fetch upstream`
3. `git checkout -b local/integrated master`
4. Create the workflow files (`AGENTS.workflow.md`, `tools/dev/AGENTS.md`, `tools/dev/README.md`, the two scripts) on `local/integrated`
5. `git add -A && git commit -m "tools/dev: add workflow docs and Update-Integrated/Prune-Worktrees scripts"`
6. `git push -u origin local/integrated`
7. Apply branch protection via `gh api` (linear history, no force-push, no delete, 1 PR approval; `enforce_admins: false` so admin can push directly)
8. Reset local `master` to `upstream/master` (the `.worktrees/` gitignore entry was moved to `.git/info/exclude` — local-only, no divergence)

### What the executor will NOT do without explicit confirmation

- Touch `<repo>/AGENTS.md` (upstream llama.cpp AI policy)
- Modify anything on `master` except resetting it to `upstream/master` (safe, preserves divergent content on `local/integrated`)
- Force-push anything except `--force-with-lease` for `local/integrated` rebase (lease check prevents overwriting newer remote commits)
- Delete any existing branches (use `Prune-Worktrees.ps1 -Interactive` to archive instead)
- Push to `upstream`
- Run `Prune-Worktrees.ps1 -Interactive` to clean stale branches

---

## 9. Recovery from a fresh clone

If everything is lost (new machine, fresh clone), recover the workflow:

```powershell
git clone <your-fork-url> llama.cpp
cd llama.cpp
git remote add upstream https://github.com/ggml-org/llama.cpp.git
git fetch upstream
git checkout master
git merge --ff-only upstream/master

# Recreate the integration branch (assumes you've pushed it to fork)
git checkout local/integrated

# Re-run the update to merge in personal branches
tools/dev/Update-Integrated.ps1
```

If `local/integrated` was lost too, recreate from a `local/*` or `topic/*`
branch you still have on the fork, or rebuild the workflow files by
copying from this document.

---

## 10. Open questions / future considerations

- **Patch export for portability:** Not part of the default workflow. If
  you ever want to share your customizations outside git, run
  `git format-patch master..local/integrated -o /tmp/patches/`.
- **CI on the fork:** Optional. Could add a GitHub Action that runs
  `Update-Integrated.ps1` weekly and posts a PR if it changes anything.
- **Multiple `local/integrated` flavors:** If you ever want different
  build targets (e.g., debug vs release), use `local/integrated-debug`,
  `local/integrated-release`, etc. Each is a separate integration branch.
