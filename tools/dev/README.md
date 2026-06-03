# tools/dev — workflow scripts

PowerShell scripts for maintaining a personal fork of [llama.cpp](https://github.com/ggml-org/llama.cpp) on the `local/integrated` build branch. Run them by hand from a developer shell on Windows.

## Scripts

### Update-Integrated.ps1

Refreshes `local/integrated` with the latest upstream `master` plus all personal `local/*` and `topic/*` branches you want in your build.

Run it when upstream has new commits, when you finish work on a `local/*` or `topic/*` branch, or whenever you want a fresh build with everything in one tree. It is the only supported way to update `local/integrated`; do not rebase it by hand.

The branches it merges in are controlled by the `$Branches` array at the top of the script. Edit that array to add or remove `local/*` / `topic/*` names.

### Prune-Worktrees.ps1

Lists or cleans stale `opencode/*` worktree branches left over from agent sessions.

- `-DryRun` prints what would be processed and exits.
- `-Interactive` prompts for each branch: keep, delete, or skip.

## Typical day

1. Pull upstream: `tools/dev/Update-Integrated.ps1`.
2. Build: `git checkout local/integrated && cmake --build build`.
3. Start a personal tool: `git checkout -b local/<name> master`, work, commit, then re-run `Update-Integrated.ps1` to fold it in.
4. End of session: `tools/dev/Prune-Worktrees.ps1 -Interactive` to decide what to do with leftover `opencode/*` branches.

## First-time setup

1. Add the `upstream` remote pointing at `https://github.com/ggml-org/llama.cpp.git`, and `origin` at your fork `https://github.com/aand18/llama.cpp`.
2. Create the build branch: `git checkout -b local/integrated master`.
3. Push it to `origin` with branch protection enabled, so the script's `--force-with-lease` is the only path that ever updates it.

## See also

- [`AGENTS.workflow.md`](../../AGENTS.workflow.md) — full workflow spec
- [`tools/dev/AGENTS.md`](./AGENTS.md) — rules for agents in this dir
