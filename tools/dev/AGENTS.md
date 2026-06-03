# AGENTS.md — tools/dev/

Subdir-scoped rules for agents working inside `tools/dev/`.

## Scripts in this directory

- `Update-Integrated.ps1` — run to refresh `local/integrated` with the latest upstream + your personal branches.
- `Prune-Worktrees.ps1` — run to list or clean up stale `opencode/*` worktree branches left over from prior sessions.

## Read the script header first

Before invoking a `.ps1` here, read the `<# .SYNOPSIS ... #>` block at the top of the file for parameters, exit conditions, and the expected branch.

## Editing scripts

If you change a script, also update its entry in `tools/dev/README.md` and in section 6 of `AGENTS.workflow.md` (in the repo root) to keep all three in sync.

## Don't run on `master`

These scripts are designed to operate on `local/integrated`. Running them while `master` is checked out is unsupported and may corrupt your build target branch.
