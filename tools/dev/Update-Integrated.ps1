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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
