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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
