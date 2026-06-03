# tools/dev — workflow scripts

PowerShell scripts for maintaining a personal fork of [llama.cpp](https://github.com/ggml-org/llama.cpp) on the `local/integrated` build branch. Run them by hand from a developer shell on Windows.

## Scripts

### Update-Integrated.ps1

Refreshes `local/integrated` with the latest upstream `master` plus all personal `local/*` and `topic/*` branches you want in your build.

Run it when upstream has new commits, when you finish work on a `local/*` or `topic/*` branch, or whenever you want a fresh build with everything in one tree. It is the only supported way to update `local/integrated`; do not rebase it by hand.

The branches it merges in are controlled by the `$Branches` array at the top of the script. Edit that array to add or remove `local/*` / `topic/*` names.

The script includes a preflight check: if `master` has diverged from `upstream/master` (you have local commits upstream doesn't, AND upstream has commits you don't), it refuses to run with a clear error and a recovery recipe. This protects you from silently rewriting master.

### Prune-Worktrees.ps1

Archives stale `opencode/*` worktree branches left over from agent sessions. **Never just deletes** — every branch goes through a safe pipeline:

1. Find its worktree (if any)
2. `git worktree remove --force` on the worktree
3. Rename the local branch to `archive/<original-name>`
4. Push `archive/<original-name>` to `origin`
5. Delete the local archive ref (data is preserved on `origin`)

If any step fails, the script halts with a clear error and rolls back the rename. To re-use an archived branch later: `git fetch origin && git checkout -b <new-name> origin/archive/opencode/<name>`.

- `-DryRun` prints what would be archived and exits.
- `-Interactive` prompts for each branch: keep, archive, or skip.
- `-Force` archives every branch without prompting (use carefully).

## Typical day

1. Pull upstream: `tools/dev/Update-Integrated.ps1`.
2. Build: `git checkout local/integrated && cmake --build build`.
3. Start a personal tool: `git checkout -b local/<name> master`, work, commit, then re-run `Update-Integrated.ps1` to fold it in.
4. End of session: `tools/dev/Prune-Worktrees.ps1 -Interactive` to decide what to do with leftover `opencode/*` branches.

## First-time setup

1. Add the `upstream` remote pointing at `https://github.com/ggml-org/llama.cpp.git`, and `origin` at your fork `https://github.com/aand18/llama.cpp`.
2. Create the build branch: `git checkout -b local/integrated master`.
3. Push it to `origin` with branch protection enabled (linear history, no force-push, no delete, 1 PR approval). The script's `--force-with-lease` is the only path that ever updates it.
4. If `master` has local commits upstream doesn't, reset it: `git checkout master && git reset --hard upstream/master`. Local-only gitignore entries (like `.worktrees/`) belong in `.git/info/exclude`, not in committed `.gitignore`.

## See also

- [`AGENTS.workflow.md`](../../AGENTS.workflow.md) — full workflow spec
- [`tools/dev/AGENTS.md`](./AGENTS.md) — rules for agents in this dir
