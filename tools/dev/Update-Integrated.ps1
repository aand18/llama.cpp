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

Worktree-safe: uses git update-ref instead of git checkout to update master,
so it works correctly from opencode-managed worktrees that pin a branch.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib = Join-Path $here '_lib.ps1'
if (Test-Path $lib) { . $lib }

$Branches = @(
    'local/find-fitt-tools'
    'local/webui-wsl-build'
    # Add more as you create them
    # 'topic/mtp-pr-22673'    # only if you want it in the build target
)

# Ensure we're on local/integrated. In a worktree, the branch is already
# checked out. In the main working tree, we may need to switch.
$currentBranch = git rev-parse --abbrev-ref HEAD
if ($currentBranch -ne 'local/integrated') {
    Write-Warning "Expected branch 'local/integrated', got '$currentBranch'. Continuing anyway."
}

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

Both sides have unique commits, so master cannot fast-forward to upstream/master.
To recover:

    git update-ref refs/heads/master $upstreamMaster
    git checkout local/integrated
    git rebase master
    git push --force-with-lease origin local/integrated

Any local-only commits on master are already preserved on local/integrated
because that branch was created from master, so they survive the reset.
Then re-run this script.
"@
}

# Update master to upstream/master using plumbing commands (worktree-safe).
# This avoids 'git checkout master' which fails in a pinned worktree.
if ($localMaster -ne $upstreamMaster) {
    # Verify master is behind or equal to upstream (FF-safe)
    if ($localMaster -ne $mergeBase) {
        throw "master has commits not on upstream/master; cannot fast-forward. Reset master manually."
    }
    git update-ref refs/heads/master $upstreamMaster
    Write-Host "Updated master to $($upstreamMaster.Substring(0, 7))" -ForegroundColor Cyan
} else {
    Write-Host "master already at $($upstreamMaster.Substring(0, 7))" -ForegroundColor Gray
}

# Rebase local/integrated on updated master
git rebase master
if ($LASTEXITCODE -ne 0) { throw "rebase local/integrated on master failed; resolve, then 'git rebase --continue' and re-run this script" }

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
