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
#>
```

**Body (~25 lines):**

```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '_lib.ps1')   # optional: shared helpers

$Branches = @(
    'local/find-fitt-tools'
    'local/mtp-debug-helpers'
    # Add more as you create them
    # 'topic/mtp-pr-22673'    # only if you want it in the build target
)

git fetch upstream
if ($LASTEXITCODE -ne 0) { throw "fetch failed" }

git checkout master
git merge --ff-only upstream/master
if ($LASTEXITCODE -ne 0) { throw "master FF failed; resolve manually" }

git checkout local/integrated
git rebase master
if ($LASTEXITCODE -ne 0) { throw "rebase local/integrated on master failed; resolve, then run this script again" }

foreach ($b in $Branches) {
    if (git show-ref --verify --quiet "refs/heads/$b") {
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
List or clean stale `opencode/*` worktree branches.

.PARAMETER DryRun
Show what would be removed without doing anything.

.PARAMETER Interactive
Ask before deleting each branch.

.PARAMETER Keep
List of branch-name patterns to never delete (e.g., 'opencode/keep-this').
#>
param(
    [switch]$DryRun,
    [switch]$Interactive,
    [string[]]$Keep = @()
)

$branches = git for-each-ref --format='%(refname:short)' refs/heads/ |
    Where-Object { $_ -like 'opencode/*' -and $_ -notin $Keep }

if (-not $branches) {
    Write-Host "No opencode/* branches to process."
    return
}

foreach ($b in $branches) {
    $commits = (git log --oneline "master..$b" 2>$null | Measure-Object).Count
    $worktree = git worktree list --porcelain | Select-String -Pattern "^worktree" -Context 0 |
                Where-Object { $_ -match $b }   # best-effort
    $info = "$b ($commits commits ahead of master)"

    if ($DryRun) {
        Write-Host "WOULD PROCESS: $info"
    } elseif ($Interactive) {
        $ans = Read-Host "$info -- (k)eep, (d)elete, (s)kip?"
        switch ($ans) {
            'd' {
                git checkout master 2>$null
                git worktree prune
                git branch -D $b
                Write-Host "deleted $b"
            }
            'k' { Write-Host "kept $b" }
            default { Write-Host "skipped $b" }
        }
    }
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

These steps run **once** to set up the workflow:

1. Add `upstream` remote (rename `origin` if needed, then `git remote add origin <fork>`)
2. `git fetch upstream`
3. `git checkout -b local/integrated master`
4. Create the 4 files in this plan (`AGENTS.workflow.md`, `tools/dev/AGENTS.md`, `tools/dev/README.md`, the two scripts) on `local/integrated`
5. `git add -A && git commit -m "tools/dev: add workflow docs and Update-Integrated/Prune-Worktrees scripts"`
6. `git push -u origin local/integrated`
7. Print the GitHub branch-protection URL for the user to click through
8. Show the user the exact `~/.config/opencode/AGENTS.md` addition for approval, then add it

### What the executor will NOT do without explicit confirmation

- Touch `<repo>/AGENTS.md` (upstream llama.cpp AI policy)
- Modify anything on `master`
- Force-push anything
- Delete any existing branches
- Push to `upstream`
- Modify `~/.config/opencode/AGENTS.md` without showing the exact text first
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
