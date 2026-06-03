# Find-Fitt

PowerShell helpers for computing a safe `--fit-target` (`-fitt`) value for `llama-server` on Windows/CUDA when running MTP-enabled models. The built-in fitter underestimates runtime static memory by ~10-15%, so users OOM at runtime even with a "correct" `-fitt`. These tools capture a probe run, parse the actual measured sizes, and apply a 1.15x underestimate factor plus a 300 MiB slack so the runtime spike still fits.

## Quick start

### Two-step

```powershell
# Step 1: probe run. Any fitt works; the goal is a captured log.
. .\Get-Fitt.ps1
$env:LLAMA_LOG_LEVEL = "info"
.\llama-server.exe -m model.gguf -c 262144 -ngl 99 -fa --fit-target 4096 > probe.log 2>&1

# Wait for "main: server listening", then kill the server.

# Step 2: compute a safe fitt.
Get-Fitt -LogPath .\probe.log -MtpEnabled -TargetCtx 150000

# FittMiB      = 1820
# PredictedCtx = 150000
```

### One-step

`Invoke-ProbeServer` runs the probe, kills it on the listen line, computes the fitt, and (with `-Start`) relaunches with the computed margin. The `llama-server` binary is auto-discovered:

```powershell
. .\Invoke-ProbeServer.ps1
Invoke-ProbeServer `
    -ModelPath .\model.gguf `
    -MtpEnabled `
    -TargetCtx 131072 `
    -ExtraArgs "-ngl 99 -fa" `
    -Start
```

## How `-fitt` works

`-fitt` is the **free-VRAM margin** (MiB) the fitter preserves before sizing `n_ctx`. It is not a context size. The fitter walks `n_ctx` downward from `-c` until the predicted footprint fits in `total_VRAM - fitt`. Higher fitt = smaller `n_ctx`.

```
fitt = total_VRAM - runtime_static - slack
```

The runtime spike is larger than the fitter's estimate. This tool adds a 1.15x underestimate factor and 300 MiB slack to the measured runtime static.

### Per-token KV cost

KV per token (across all attention layers) = `n_embd_k_gqa * (bytes_per_k_element + bytes_per_v_element)`.

The `n_embd_k_gqa` value is the per-layer per-head K dimension (n_embd_head_k) times the number of KV heads. For Qwen3.6-27B, this is 4 heads * 256 = 1024. With q8_0 K (1.0625 bytes/elem) and q5_1 V (0.75 bytes/elem), per-token KV is `1024 * (1.0625 + 0.75) = 1856 bytes` per layer, or `1856 * 16 attn_layers = 29696 bytes (~29 KiB)` per token across all attention layers.

| Quant | Bytes/elem | Notes |
|-------|-----------:|-------|
| f32   | 4.0000 | reference |
| f16/bf16 | 2.0000 | reference |
| q8_0  | 1.0625 | |
| q5_1  | 0.7500 | has min term |
| q5_0  | 0.6875 | |
| q4_1  | 0.6250 | has min term |
| q4_0  | 0.5625 | |
| iq4_nl| 0.5625 | |

Use `Get-KvBytesPerElement` to fetch the factor for a given cache quant.

## Function reference

### Get-Fitt

Parses a server log, extracts measured sizes, and returns a recommended `-fitt`.

| Parameter | Type | Default | Description |
|-----------|------|--------:|-------------|
| `-LogPath` | string | required | Path to captured `llama-server` log |
| `-TotalVramMiB` | int | 24563 | Total device VRAM (RTX 4090 default) |
| `-BatchSize` | int | 2048 | Informational; logged for sanity |
| `-MtpEnabled` | switch | off | Add 1140 MiB MTP-draft overhead to margin |
| `-TargetCtx` | int | 0 | Desired `n_ctx`; 0 = maximize |
| `-FitTargetMiB` | int | 0 | Inverse mode: predict n_ctx given a fitt |
| `-UnderestimateFactor` | double | 1.15 | Multiplier on measured model weight |
| `-SlackMiB` | int | 300 | Extra headroom in MiB |

**Returns** `[pscustomobject]` with `FittMiB`, `PredictedCtx`, plus diagnostic fields (`PerTokenKVKiB`, `KvCells`, `KvKType`, `KvVType`, `ModelMiB`, `RSMiB`, `ComputeMiB`, `MtpOverheadMiB`, `RuntimeStaticMiB`, `RuntimeFreeMiB`, `Note`).

**Quiet by default; use `-Verbose` for the full diagnostic table.**

```powershell
Get-Fitt -LogPath .\probe.log -MtpEnabled -TargetCtx 150000
```

Pipe a log in via the pipeline instead:

```powershell
Get-Content .\probe.log | Get-Fitt -MtpEnabled
```

### Get-KvBytesPerElement

Returns the bytes-per-element factor for a KV cache quant type.

| Parameter | Type | Default | Description |
|-----------|------|--------:|-------------|
| `-Type` | string | required | One of: `f32`, `f16`, `bf16`, `q8_0`, `q5_1`, `q5_0`, `q4_1`, `q4_0`, `iq4_nl` |

**Returns** `[double]`.

```powershell
Get-KvBytesPerElement -Type q4_1
# 0.625
```

### Invoke-ProbeServer

Launches a probe server, waits for the listen line, kills the process, computes fitt, and (optionally) relaunches with the computed margin.

| Parameter | Type | Default | Description |
|-----------|------|--------:|-------------|
| `-ModelPath` | string | required | Path to `.gguf` |
| `-MmprojPath` | string | none | Optional mmproj path for VLMs |
| `-ExtraArgs` | string | none | Extra args passed as a single string |
| `-TotalVramMiB` | int | 24563 | Total device VRAM |
| `-BatchSize` | int | 2048 | Informational |
| `-MtpEnabled` | switch | off | Apply MTP safety |
| `-TargetCtx` | int | 0 | Desired final ctx |
| `-ProbeTimeoutSec` | int | 300 | Max wait for "server listening" |
| `-Start` | switch | off | If set, relaunch the server with the computed fitt |

Server binary is auto-discovered from `$env:LLAMA_SERVER_BIN`, then `PATH`, then `msvc\build\bin\Release\llama-server.exe`, then walking up the directory tree looking for `build/bin/Release/llama-server.exe`.

**Returns** none. Prints the computed fitt, optionally relaunches.

```powershell
Invoke-ProbeServer -ModelPath .\model.gguf -MtpEnabled -TargetCtx 131072 -Start
```

### New-SyntheticPrompt

Writes a synthetic prompt of approximately N tokens to a file for soak testing.

| Parameter | Type | Default | Description |
|-----------|------|--------:|-------------|
| `-TokenCount` | int | required | Target token count (1 token ~ 4 chars) |
| `-OutputFile` | string | required | Where to write the prompt |
| `-Seed` | int | 42 | RNG seed for reproducibility |
| `-Style` | string | lorem | One of: `lorem`, `wikipedia`, `code`, `shakespeare` |

**Returns** none. Writes the file.

```powershell
New-SyntheticPrompt -TokenCount 150000 -OutputFile .\soak.txt -Seed 42
```

## Worked example: 27B MTP on RTX 4090

**Hardware:** RTX 4090, 24 GiB.
**Model:** `Qwen3.6-27B-MTP-IQ4_XS` (q8_0 K-cache, q5_1 V-cache, 16 attention layers, 4 KV heads, head_dim 256, n_ctx_train=262144, MTP enabled). Captured probe log lives at `tests/fixtures/real-qwen27b-mtp.log`.

```powershell
. .\Get-Fitt.ps1

# For a 128k target ctx with MTP safety:
Get-Fitt -LogPath tests\fixtures\real-qwen27b-mtp.log -MtpEnabled -TargetCtx 131072

# FittMiB      = 1399
# PredictedCtx = 131072
```

Then launch the real server with `--fit-target 1399`.

Without MTP, the fitt for the same target goes up (less overhead, but no MTP speedup):

```powershell
Get-Fitt -LogPath tests\fixtures\real-qwen27b-mtp.log -TargetCtx 131072
# FittMiB = 2539
```

Why the difference (rough back-of-envelope, verify with `Get-Fitt` on your own probe log):

- 24 GiB total - 1399 MiB margin = ~22.6 GiB available
- Measured runtime static with MTP: 14285 (model) + 748 (RS) + 836 (compute) + 1140 (MTP overhead) = 17009 MiB
- After 1.15x model underestimate: 16428 + 748 + 836 + 1140 = 19152 MiB
- After +300 MiB slack: 19452 MiB
- Remaining for KV: ~5100 MiB
- Per-token KV (16 attn layers, q8_0 K, q5_1 V, 1024 K heads per layer): ~29 KiB
- Predicted `n_ctx`: 5100 * 1024 / 29 = 180,069 → rounded to 131072 (256-aligned) when target is 131072

The fitter alone would have returned a larger `n_ctx`. This fitt trades a small ctx reduction for the safety margin the runtime actually needs.

## Testing

Pester tests live in `tests/Test-Get-Fitt.ps1`. They parse the captured log at `tests/fixtures/real-qwen27b-mtp.log` and assert the parsed hparams, KV bytes, and computed fitt values for all three modes (max, TargetCtx, FitTargetMiB). Run from PowerShell 5.1+:

```powershell
Import-Module Pester -MinimumVersion 3.0.0
Invoke-Pester .\tools\find-fitt\tests\Test-Get-Fitt.ps1
```

For a real end-to-end check on your own model, two-stage verification:

### Stage A - static

Confirm the model loads and the fitter doesn't shrink ctx too aggressively. Use `-fit off` to see raw requirements without the fitter:

```powershell
.\llama-server.exe -m model.gguf -c 262144 --fit-target 4096 -fit off -n 0
```

### Stage B - runtime

Generate a soak prompt and run the real server with the computed fitt:

```powershell
New-SyntheticPrompt -TokenCount 150000 -OutputFile .\soak.txt -Seed 42
.\llama-server.exe -m model.gguf -c 262144 --fit-target 1399 -fa -ngl 99 `
    -p "$(Get-Content .\soak.txt -Raw)" 2>&1 | Tee-Object .\runtime.log
```

Watch for OOM, "out of memory", or context-shrunk warnings. If the runtime log shows the fitter shrinking below your target, raise `--fit-target` by 256 MiB and retry.

## Troubleshooting

- **Log missing "listening" or KV lines**: log level too low. Set `$env:LLAMA_LOG_LEVEL="info"` and re-run. Older llama.cpp builds (before b4980-ish) don't log measured KV size in the format this tool expects.
- **Fitt computed but server still OOMs**: the probe run had different `-ngl` / `-fa` / KV quant settings than the real run. Match them exactly.
- **`-MtpEnabled` reports 0 overhead**: MTP heads weren't detected. Confirm the build supports MTP for that arch and that MTP is actually enabled on the model.
- **Different numbers on Linux vs Windows**: the 1.15x factor is calibrated for Windows/CUDA. On Linux/Vulkan the underestimate is smaller; try `-MtpEnabled:$false`.
- **`FittMiB` is negative**: measured runtime static exceeds available VRAM. Reduce `-c` for the probe or use a smaller model.

## Limitations

- Calibrated for Windows + CUDA. Other backends may have different static-vs-runtime gaps.
- Single-GPU inference only. Multi-GPU splits change the math.
- MTP detection is heuristic; verify the log shows a non-zero MTP overhead when `-MtpEnabled` is set.
- The 1.15x factor is empirical; treat it as a starting point, not a guarantee.
- Pester tests live in `tests/Test-Get-Fitt.ps1` and use the fixture in `tests/fixtures/real-qwen27b-mtp.log`. A minimal synthetic log is also kept at `tests/fixtures/syn-smoke.log` for offline smoke testing.

## References

- `--fit-target` argument: `common/arg.cpp:2458`
- Fitter algorithm: `common/fit.cpp:153-334`
- MTP pre-charge (runtime spike): `tools/server/server-context.cpp:898-912`
- Known issue: MTP undersizing, `ggml-org/llama.cpp#23472`
