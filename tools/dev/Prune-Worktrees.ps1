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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$branches = git for-each-ref --format='%(refname:short)' refs/heads/ |
    Where-Object { $_ -like 'opencode/*' -and $_ -notin $Keep }

if (-not $branches) {
    Write-Host "No opencode/* branches to process."
    return
}

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
