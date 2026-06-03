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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$branches = git for-each-ref --format='%(refname:short)' refs/heads/ |
    Where-Object { $_ -like 'opencode/*' -and $_ -notin $Keep }

if (-not $branches) {
    Write-Host "No opencode/* branches to process."
    return
}

foreach ($b in $branches) {
    $commits = (git log --oneline "master..$b" 2>$null | Measure-Object).Count
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
    } else {
        Write-Host $info
    }
}
