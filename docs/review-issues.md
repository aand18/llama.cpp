# Issues Found in Code Review

## Critical Issues

### C1. Missing `./slots` component directory
`tools/ui/src/lib/components/app/index.ts:13` exports `./slots` but directory doesn't exist. Build will fail.
- **Fix**: Create `tools/ui/src/lib/components/app/slots/index.ts` or remove the export

### C2. Inconsistent API path prefixes — `/slots` vs `./slots`
- `API_SLOTS.LIST` uses `/slots` (absolute)
- `ChatService.areAllSlotsIdle` hardcodes `./slots` (relative)
- Behaves differently under non-root deployment path
- **Fix**: Use `API_SLOTS.LIST` consistently everywhere

### C3. Hardcoded CUDA build flags
`build.ps1:24` always passes `-DGGML_CUDA=ON`. Fails on non-CUDA machines.
- **Fix**: Check for CUDA_PATH, default to OFF if not found
- **Status**: FIXED in build.ps1

### I1. `sse_ping_interval` removal breaks SSE keep-alive
Removing `--sse-ping-interval` means no keep-alive pings. Reverse proxies drop idle streaming connections.
- **Fix**: Restore SSE ping mechanism or document that proxies need `proxy_read_timeout` adjustment

### I2. `common_speculative_n_max` duplicated in server
Function removed from `common/speculative.h`, inlined into `server-context.cpp`. Duplicates logic.
- **Fix**: Keep in common library, don't inline

### I3. `startedAt` map keyed by `slot.id_task` leaks
`slots.svelte.ts:76` — `id_task` changes per task. Old entries never cleaned up.
- **Fix**: Delete stale entries when slot finishes, or key by slot index instead of task ID

### I4. `rebase.ps1` misleading variable name
`$OLD_MASTER` captured after `git fetch`, so it's the new master commit.
- **Fix**: Rename to `$MASTER_COMMIT`
- **Status**: TODO

### I5. `Copy-Item` copies everything
`build.ps1:36` copies PDBs, .exp, .lib files.
- **Fix**: Filter to `*.exe`, `*.dll` only
- **Status**: FIXED in build.ps1

### M1. Worktree path assumption fragile
Both scripts assume `Parent.Parent` is main repo. No validation.
- **Fix**: Add `Test-Path (Join-Path $MAIN_REPO ".git")` check
- **Status**: TODO

### M2. No cleanup of old builds
Old commit directories in `%TEMP%\llama.cpp\<branch>\` accumulate.
- **Fix**: Add `-Keep N` parameter or age-based cleanup
- **Status**: TODO

### M3. Eviction loads all entries into memory
`slots-history.service.ts:111` loads all 500 entries for sorting on every add.
- **Fix**: Use Dexie `limit()` to load only oldest N candidates

### M4. Removed `beautifyNetworkError`
Network errors now bubble as raw fetch errors.
- **Fix**: Restore user-friendly error messages for all API calls

### M5. Removed `VITE_PUBLIC_SERVER_ORIGIN`
Hardcoded `http://localhost:8080` breaks non-standard server setups.
- **Fix**: Restore env variable or make configurable

### M6. `escapeHtml` incomplete
Missing backtick escaping and newline handling.
- **Fix**: Add backtick and newline escaping
