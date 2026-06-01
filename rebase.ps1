# Rebase current branch on origin/master and log history
# Usage: ./rebase.ps1

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# Fix git for worktree: .git file has WSL path Windows git can't resolve
$MAIN_REPO = (Get-Item $PSScriptRoot).Parent.Parent.FullName
$env:GIT_DIR = Join-Path (Join-Path $MAIN_REPO ".git\worktrees") (Split-Path $PSScriptRoot -Leaf)

# Get info before rebase
$BRANCH = git rev-parse --abbrev-ref HEAD
$OLD_HEAD = git rev-parse HEAD
$OLD_SHORT = git rev-parse --short HEAD
git fetch origin master
$OLD_MASTER = git rev-parse origin/master

Write-Host "Rebasing $BRANCH on origin/master..."
$proc = Start-Process -FilePath "git" -ArgumentList "rebase origin/master" -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Host "Rebase failed! Run 'git rebase --abort' to undo." -ForegroundColor Red
    exit 1
}

# Get info after rebase
$NEW_HEAD = git rev-parse HEAD
$NEW_SHORT = git rev-parse --short HEAD
$NEW_MASTER = git rev-parse origin/master

# Log to history file
$HISTORY_FILE = Join-Path $PSScriptRoot "rebase-history.txt"
$TIMESTAMP = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$ENTRY = "$TIMESTAMP | $BRANCH | $OLD_SHORT -> $NEW_SHORT | master: $OLD_MASTER"
Add-Content -Path $HISTORY_FILE -Value $ENTRY -Encoding UTF8

Write-Host "Rebase complete."
Write-Host "  $BRANCH: $OLD_SHORT -> $NEW_SHORT"
Write-Host "  master: $NEW_MASTER"
Write-Host "  Logged to rebase-history.txt"
