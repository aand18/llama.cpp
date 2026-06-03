# Get-Fitt.ps1 - Compute optimal -fitt value from llama-server log output
# https://github.com/ggml-org/llama.cpp  (private fork helper)
#
# The fitter in common/fit.cpp underestimates runtime memory on Windows/CUDA
# by ~10-15%, so users OOM at runtime even with sufficient -fitt. This helper
# parses the fitter/server log, measures the true per-token KV cost, and
# returns a -fitt value that includes a safety factor (UnderestimateFactor)
# plus a SlackMiB margin.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Script-scope buffer used by the pipeline parameter set.  Declared via
# New-Variable so Set-StrictMode does not complain about an undefined
# reference inside the process block.
if (-not (Get-Variable -Name _gfBuffer -Scope Script -ErrorAction SilentlyContinue)) {
    New-Variable -Name _gfBuffer -Scope Script -Value $null
}

# ---------------------------------------------------------------------------
# Internal engine: all parsing and computation lives in this class.
# ---------------------------------------------------------------------------

class FindFittResult {
    [int]    $FittMiB
    [int]    $PredictedCtx
    [double] $PerTokenKVKiB
    [int]    $KvLayers
    [int]    $KvCells
    [string] $KvKType
    [string] $KvVType
    [double] $ModelMiB
    [double] $RSMiB
    [double] $ComputeMiB
    [int]    $MtpOverheadMiB
    [double] $RuntimeStaticMiB
    [double] $RuntimeFreeMiB
    [string] $Note
}

class FindFittEngine {
    static [FindFittResult] Compute([string]$log, [hashtable]$params) {
        $notes = New-Object 'System.Collections.Generic.List[string]'
        $logText = if ($null -eq $log) { '' } else { $log }

        # --- Parse hparams ---
        $hparams = [FindFittEngine]::ParseHparams($logText)
        $nCtxTrain = $hparams['n_ctx_train']
        $nLayer    = $hparams['n_layer']
        $nEmbdK    = $hparams['n_embd_k_gqa']
        $nEmbdV    = $hparams['n_embd_v_gqa']
        $nEmbdHk   = $hparams['n_embd_head_k']
        $nEmbdHv   = $hparams['n_embd_head_v']
        $ssmDState  = $hparams['ssm_d_state']
        $ssmDInner  = $hparams['ssm_d_inner']
        $ssmNGroup  = $hparams['ssm_n_group']

        # --- Parse KV cache line (golden truth for per-token cost) ---
        $kv = [FindFittEngine]::ParseKvCache($logText)
        $hasKv = $null -ne $kv
        if (-not $hasKv) {
            [void]$notes.Add('No KV cache found in log; using model defaults')
        }

        # --- Parse recurrent state (SSM only) ---
        $rs = [FindFittEngine]::ParseRecurrentState($logText)
        $hasRs = $null -ne $rs

        # --- Parse compute buffer ---
        $computeMiB = [FindFittEngine]::ParseComputeBuffer($logText)

        # --- Parse runtime memory breakdown ---
        $brk = [FindFittEngine]::ParseBreakdown($logText)
        $hasBrk = $null -ne $brk

        # --- Parse fitter output ---
        $fit = [FindFittEngine]::ParseFitterOutput($logText)

        # --- Compute per_token_KV cost (golden truth from log) ---
        # The KV "cells" value is the kv_size (sequence length per layer).
        # Each cell already holds K+V for ALL attention layers in the cache,
        # so per_cell_bytes = (K_MiB + V_MiB) / cells gives the per-token
        # cost summed across every attention layer.  No further multiplication
        # by n_layer is needed (that would double-count).
        $perTokenKVKiB = 0.0
        $kvLayers = 0
        $kvCells = 0
        $kvKType = ''
        $kvVType = ''
        $kvKMiB = 0.0
        $kvVMiB = 0.0
        if ($hasKv) {
            $kvLayers  = [int]$kv['layers']
            $kvCells   = [int]$kv['cells']
            $kvKType   = [string]$kv['k_type']
            $kvVType   = [string]$kv['v_type']
            $kvKMiB    = [double]$kv['k_mib']
            $kvVMiB    = [double]$kv['v_mib']

            if ($kvCells -gt 0) {
                $perCellBytes = ($kvKMiB + $kvVMiB) * 1048576.0 / $kvCells
                $perTokenKVKiB = $perCellBytes / 1024.0
            }
        }

        # If we have no KV line, fall back to model hparams.
        if (-not $hasKv -and $nEmbdK -gt 0 -and $nEmbdV -gt 0 -and $nLayer -gt 0) {
            $bpeF16 = Get-KvBytesPerElement -Type 'f16'
            # bytes per cell (K+V) * n_layer = bytes per token (all layers)
            $perTokenKVBytes = ($nEmbdK + $nEmbdV) * $bpeF16 * $nLayer
            $perTokenKVKiB   = $perTokenKVBytes / 1024.0
            $kvLayers  = $nLayer
            $kvKType   = 'f16'
            $kvVType   = 'f16'
        }

        # --- Compute RS (recurrent state) MiB ---
        $rsMiB = 0.0
        if ($hasRs) {
            $rsMiB = [double]$rs['r_mib'] + [double]$rs['s_mib']
        } elseif ($ssmDState -gt 0 -and $ssmDInner -gt 0 -and $ssmNGroup -gt 0 -and $nLayer -gt 0) {
            $bytesPerElem = 2.0
            $rsMiB = (2.0 * $ssmDInner * $ssmDState * $bytesPerElem * $nLayer) / 1048576.0
        }

        # --- Model and compute MiB (prefer runtime breakdown) ---
        $modelMiB  = 0.0
        $brkCtxMiB = 0.0
        $brkComputeMiB = 0.0
        if ($hasBrk) {
            $modelMiB      = [double]$brk['model']
            $brkCtxMiB     = [double]$brk['context']
            $brkComputeMiB = [double]$brk['compute']
        }
        if ($modelMiB -le 0 -and $null -ne $fit) {
            $modelMiB = [double]$fit['fitter_self_full'] - ($kvKMiB + $kvVMiB) - $computeMiB
        }
        if ($brkComputeMiB -le 0) { $brkComputeMiB = $computeMiB }
        if ($brkComputeMiB -le 0) { $brkComputeMiB = 800.0 }

        # --- MTP overhead pre-charge ---
        $mtpOverheadMiB = 0
        $mtpEnabled = [bool]$params['MtpEnabled']
        if ($mtpEnabled) {
            $mtpOverheadMiB = 1140
            [void]$notes.Add('MTP overhead pre-charged to fitter; this helper adds 1140 MiB to margin')
        }

        # --- Free VRAM ---
        $freeVramMiB = 0.0
        if ($null -ne $fit) {
            $freeVramMiB = [double]$fit['free_vram']
        }
        if ($freeVramMiB -le 0) {
            $freeVramMiB = [double]$params['TotalVramMiB']
        }

        $nCtxMin = 4096

        # --- Determine target n_ctx and mode ---
        $targetCtx = 0
        $mode = 'max'

        $hasTarget = $params.ContainsKey('TargetCtx') -and $null -ne $params['TargetCtx'] -and [int]$params['TargetCtx'] -gt 0
        $hasFitt   = $params.ContainsKey('FitTargetMiB') -and $null -ne $params['FitTargetMiB'] -and [int]$params['FitTargetMiB'] -gt 0

        if ($hasTarget) {
            $mode = 'target_ctx'
            $targetCtx = [int]$params['TargetCtx']
            if ($nCtxTrain -gt 0 -and $targetCtx -gt $nCtxTrain) {
                [void]$notes.Add("TargetCtx exceeds training context; clamping to n_ctx_train ($nCtxTrain)")
                $targetCtx = $nCtxTrain
            }
        } elseif ($hasFitt) {
            $mode = 'target_fitt'
        } else {
            $mode = 'max'
        }

        # --- Step 3: predict n_ctx from FitTargetMiB (if provided) ---
        $predictedCtx = 0
        if ($mode -eq 'target_fitt') {
            $fitt = [int]$params['FitTargetMiB']
            $predictedCtx = [FindFittEngine]::PredictCtxFromFitt(
                $fitt, $freeVramMiB, $fit, $nCtxTrain, $nCtxMin,
                $perTokenKVKiB, $brkComputeMiB, $modelMiB, $mtpOverheadMiB
            )
            $targetCtx = $predictedCtx
        }

        # --- Step 4: compute fitt for target n_ctx ---
        $fittMiB = 0
        if ($mode -eq 'target_ctx' -or $mode -eq 'target_fitt') {
            $ctxForCalc = $targetCtx
            if ($ctxForCalc -lt $nCtxMin) { $ctxForCalc = $nCtxMin }

            $kvAtTargetMiB = ($ctxForCalc * $perTokenKVKiB) / 1024.0
            $runtimeStatic = ($modelMiB * [double]$params['UnderestimateFactor']) +
                             $kvAtTargetMiB + $rsMiB + $brkComputeMiB + $mtpOverheadMiB
            $fittMiB = [int][math]::Floor(
                [double]$params['TotalVramMiB'] - $runtimeStatic - [int]$params['SlackMiB']
            )
            if ($fittMiB -lt 0) { $fittMiB = 0 }
            $predictedCtx = $ctxForCalc
        }

        # --- Step 5: maximize n_ctx ---
        if ($mode -eq 'max') {
            $maxStaticExclKv = ($modelMiB * [double]$params['UnderestimateFactor']) +
                               $rsMiB + $brkComputeMiB + $mtpOverheadMiB + [int]$params['SlackMiB']
            $availableForKv = [double]$params['TotalVramMiB'] - $maxStaticExclKv
            if ($availableForKv -lt 0) { $availableForKv = 0 }
            $perTokenKVMiB = $perTokenKVKiB / 1024.0
            if ($perTokenKVMiB -le 0) { $perTokenKVMiB = 0.0001 }
            $maxNCtx = [int][math]::Floor($availableForKv / $perTokenKVMiB)
            $maxNCtx = [int][math]::Floor($maxNCtx / 256) * 256
            if ($maxNCtx -lt $nCtxMin) { $maxNCtx = $nCtxMin }
            if ($nCtxTrain -gt 0 -and $maxNCtx -gt $nCtxTrain) { $maxNCtx = $nCtxTrain }
            $predictedCtx = $maxNCtx
            $fittMiB = [int][math]::Floor(
                [double]$params['TotalVramMiB'] - $maxStaticExclKv - ($maxNCtx * $perTokenKVMiB)
            )
            if ($fittMiB -lt 0) { $fittMiB = 0 }
        }

        # --- Build result ---
        $result = [FindFittResult]::new()
        $result.FittMiB         = $fittMiB
        $result.PredictedCtx    = $predictedCtx
        $result.PerTokenKVKiB   = [math]::Round($perTokenKVKiB, 4)
        $result.KvLayers        = $kvLayers
        $result.KvCells         = $kvCells
        $result.KvKType         = $kvKType
        $result.KvVType         = $kvVType
        $result.ModelMiB        = [math]::Round($modelMiB, 2)
        $result.RSMiB           = [math]::Round($rsMiB, 2)
        $result.ComputeMiB      = [math]::Round($brkComputeMiB, 2)
        $result.MtpOverheadMiB  = $mtpOverheadMiB
        $kvAtPredictedMiB = ($predictedCtx * $perTokenKVKiB) / 1024.0
        $result.RuntimeStaticMiB = [math]::Round(
            ($modelMiB * [double]$params['UnderestimateFactor']) + $kvAtPredictedMiB +
            $rsMiB + $brkComputeMiB + $mtpOverheadMiB, 2)
        $result.RuntimeFreeMiB  = [math]::Round(
            [double]$params['TotalVramMiB'] - $result.RuntimeStaticMiB, 2)
        $result.Note = ($notes -join '; ')

        return $result
    }

    # -----------------------------------------------------------------------
    # Parsers
    # -----------------------------------------------------------------------

    static [hashtable] ParseHparams([string]$log) {
        $h = @{
            n_ctx_train = 0; n_layer = 0; n_head = 0; n_head_kv = 0
            n_embd_head_k = 0; n_embd_head_v = 0
            n_embd_k_gqa = 0; n_embd_v_gqa = 0
            ssm_d_state = 0; ssm_d_inner = 0; ssm_n_group = 0
            full_attention_interval = 0; n_ctx = 0
        }
        $patterns = @{
            'n_ctx_train'             = 'n_ctx_train\s*=\s*(\d+)'
            'n_layer'                 = 'n_layer\s*=\s*(\d+)'
            'n_head'                  = 'n_head\s*=\s*(\d+)'
            'n_head_kv'               = 'n_head_kv\s*=\s*(\d+)'
            'n_embd_head_k'           = 'n_embd_head_k\s*=\s*(\d+)'
            'n_embd_head_v'           = 'n_embd_head_v\s*=\s*(\d+)'
            'n_embd_k_gqa'            = 'n_embd_k_gqa\s*=\s*(\d+)'
            'n_embd_v_gqa'            = 'n_embd_v_gqa\s*=\s*(\d+)'
            'ssm_d_state'             = 'ssm_d_state\s*=\s*(\d+)'
            'ssm_d_inner'             = 'ssm_d_inner\s*=\s*(\d+)'
            'ssm_n_group'             = 'ssm_n_group\s*=\s*(\d+)'
            'full_attention_interval' = 'full_attention_interval\s*=\s*(\d+)'
            'n_ctx'                   = 'n_ctx\s*=\s*(\d+)'
        }
        foreach ($k in $patterns.Keys) {
            $m = [regex]::Match($log, $patterns[$k])
            if ($m.Success) { $h[$k] = [int]$m.Groups[1].Value }
        }
        return $h
    }

    static [hashtable] ParseKvCache([string]$log) {
        $pattern = 'llama_kv_cache:\s*size\s*=\s*(\d+(?:\.\d+)?)\s*MiB\s*\(\s*(\d+)\s*cells,\s+(\d+)\s+layers.*K\s*\(([^)]+)\):\s*(\d+(?:\.\d+)?)\s*MiB,\s*V\s*\(([^)]+)\):\s*(\d+(?:\.\d+)?)\s*MiB'
        $m = [regex]::Match($log, $pattern)
        if (-not $m.Success) { return $null }
        return @{
            size_mib = [double]$m.Groups[1].Value
            cells    = [int]$m.Groups[2].Value
            layers   = [int]$m.Groups[3].Value
            k_type   = [string]$m.Groups[4].Value
            k_mib    = [double]$m.Groups[5].Value
            v_type   = [string]$m.Groups[6].Value
            v_mib    = [double]$m.Groups[7].Value
        }
    }

    static [hashtable] ParseRecurrentState([string]$log) {
        $pattern = 'llama_memory_recurrent:\s*size\s*=\s*(\d+(?:\.\d+)?)\s*MiB.*R\s*\(([^)]+)\):\s*(\d+(?:\.\d+)?)\s*MiB,\s*S\s*\(([^)]+)\):\s*(\d+(?:\.\d+)?)\s*MiB'
        $m = [regex]::Match($log, $pattern)
        if (-not $m.Success) { return $null }
        return @{
            size_mib = [double]$m.Groups[1].Value
            r_type   = [string]$m.Groups[2].Value
            r_mib    = [double]$m.Groups[3].Value
            s_type   = [string]$m.Groups[4].Value
            s_mib    = [double]$m.Groups[5].Value
        }
    }

    static [double] ParseComputeBuffer([string]$log) {
        $pattern = 'CUDA0 compute buffer size\s*=\s*(\d+(?:\.\d+)?)\s*MiB'
        $m = [regex]::Match($log, $pattern)
        if (-not $m.Success) { return 0.0 }
        return [double]$m.Groups[1].Value
    }

    static [hashtable] ParseBreakdown([string]$log) {
        $pattern = '\|\s+-\s+CUDA0[^\|]*\|\s+\d+\s+=\s+\d+\s+\+\s+\((\d+)\s+=\s+(\d+)\s+\+\s+(\d+)\s+\+\s+(\d+)\)\s+\+'
        $m = [regex]::Match($log, $pattern)
        if (-not $m.Success) { return $null }
        return @{
            self    = [double]$m.Groups[1].Value
            model   = [double]$m.Groups[2].Value
            context = [double]$m.Groups[3].Value
            compute = [double]$m.Groups[4].Value
        }
    }

    static [hashtable] ParseFitterOutput([string]$log) {
        $h = @{
            fitter_self_full  = 0.0
            fitter_self_min   = 0.0
            free_vram         = 0.0
            reduced_from      = 0
            reduced_to        = 0
            reduced_savings   = 0.0
        }

        $m1 = [regex]::Match($log, 'projected to use\s+(\d+(?:\.\d+)?)\s*MiB.*vs\.\s+(\d+(?:\.\d+)?)\s*MiB of (?:free|total)')
        if ($m1.Success) {
            $h['fitter_self_full'] = [double]$m1.Groups[1].Value
            $h['free_vram']        = [double]$m1.Groups[2].Value
        }

        $m2 = [regex]::Match($log, 'context size reduced from\s+(\d+)\s+to\s+(\d+)\s+->\s+need\s+(\d+(?:\.\d+)?)\s*MiB less')
        if ($m2.Success) {
            $h['reduced_from']    = [int]$m2.Groups[1].Value
            $h['reduced_to']      = [int]$m2.Groups[2].Value
            $h['reduced_savings'] = [double]$m2.Groups[3].Value
        }

        return $h
    }

    # -----------------------------------------------------------------------
    # Math helpers
    # -----------------------------------------------------------------------

    # Predict n_ctx for a given FitTargetMiB using the fitter's linear
    # interpolation between (n_ctx_min, sum_projected_used_min_ctx) and
    # (n_ctx_train, sum_projected_used).  See common/fit.cpp:317.
    static [int] PredictCtxFromFitt(
        [int]$fittMiB,
        [double]$freeVramMiB,
        [hashtable]$fit,
        [int]$nCtxTrain,
        [int]$nCtxMin,
        [double]$perTokenKVKiB,
        [double]$computeMiB,
        [double]$modelMiB,
        [int]$mtpOverheadMiB
    ) {
        if ($nCtxTrain -le 0) { return $nCtxMin }
        if ($freeVramMiB -le 0) { return $nCtxMin }

        $fitterSelfFull = 0.0
        if ($null -ne $fit) { $fitterSelfFull = [double]$fit['fitter_self_full'] }
        if ($fitterSelfFull -le 0) {
            $kvAtFullMiB = ($nCtxTrain * $perTokenKVKiB) / 1024.0
            $fitterSelfFull = $modelMiB + $kvAtFullMiB + $computeMiB + $mtpOverheadMiB
        }

        # When the log does not provide a second fitter measurement at
        # n_ctx_min, approximate it the same way the fitter does at min ctx.
        $fitterSelfMin = 0.0
        if ($null -ne $fit) { $fitterSelfMin = [double]$fit['fitter_self_min'] }
        if ($fitterSelfMin -le 0) {
            $kvAtMinMiB = ($nCtxMin * $perTokenKVKiB) / 1024.0
            $fitterSelfMin = $modelMiB + $kvAtMinMiB + $computeMiB + $mtpOverheadMiB
        }

        $denom = $nCtxTrain - $nCtxMin
        if ($denom -le 0) { return $nCtxMin }
        $P = ($fitterSelfFull - $fitterSelfMin) / $denom
        if ($P -le 0) { return $nCtxMin }

        $fitterTarget = $freeVramMiB - $fittMiB
        $savingsNeeded = $fitterSelfFull - $fitterTarget
        if ($savingsNeeded -lt 0) { $savingsNeeded = 0 }
        $maxSavings = $fitterSelfFull - $fitterSelfMin
        if ($savingsNeeded -gt $maxSavings) { $savingsNeeded = $maxSavings }

        $ctxReduction = $savingsNeeded / $P
        $predicted = $nCtxTrain - [int][math]::Floor($ctxReduction)
        $predicted = [int][math]::Floor($predicted / 256) * 256
        if ($predicted -lt $nCtxMin) { $predicted = $nCtxMin }
        return $predicted
    }
}

# ---------------------------------------------------------------------------
# Public functions: Get-KvBytesPerElement and Get-Fitt.
# ---------------------------------------------------------------------------

function Get-KvBytesPerElement {
    <#
        .SYNOPSIS Return bytes-per-element for a KV cache quantization type.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Type)

    switch -Regex ($Type.Trim().ToLowerInvariant()) {
        '^f32$'                              { return 4.0 }
        '^(f16|bf16)$'                       { return 2.0 }
        '^q8_0$'                             { return 1.0625 }
        '^q5_1$'                             { return 0.75 }
        '^q5_0$'                             { return 0.6875 }
        '^q4_1$'                             { return 0.625 }
        '^(q4_0|iq4_nl)$'                    { return 0.5625 }
        default {
            throw "Get-KvBytesPerElement: unknown KV quant type '$Type'"
        }
    }
}

function Get-Fitt {
    <#
        .SYNOPSIS Compute the optimal -fitt value from a llama-server log.
        .DESCRIPTION
            Parses llama-server output (the log captured with `2>&1`) and
            returns a PSCustomObject with the recommended -fitt value and the
            predicted n_ctx that value will yield.

            Two modes are supported:
              - FromFile (default):   pass -LogPath
              - FromPipeline:         pipe log lines in via the pipeline
        .EXAMPLE
            Get-Fitt -LogPath .\server.log -TotalVramMiB 24563 -MtpEnabled
        .EXAMPLE
            Get-Content .\server.log | Get-Fitt -TotalVramMiB 24563
    #>
    [CmdletBinding(DefaultParameterSetName='FromFile')]
    param(
        [Parameter(ParameterSetName='FromFile', Mandatory, Position=0)]
        [string]$LogPath,

        [Parameter(ParameterSetName='FromPipeline', Mandatory, ValueFromPipeline)]
        [AllowEmptyString()][string]$LogLine,

        [int]$TotalVramMiB = 24563,
        [switch]$MtpEnabled,
        [int]$TargetCtx = 0,
        [int]$FitTargetMiB = 0,
        [int]$BatchSize = 2048,
        [double]$UnderestimateFactor = 1.15,
        [int]$SlackMiB = 300
    )

    begin {
        if ($PSCmdlet.ParameterSetName -eq 'FromPipeline') {
            $script:_gfBuffer = [System.Text.StringBuilder]::new()
        }
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'FromPipeline') {
            if ($null -ne $LogLine) {
                [void]$script:_gfBuffer.AppendLine($LogLine)
            }
        }
    }

    end {
        $log = $null
        if ($PSCmdlet.ParameterSetName -eq 'FromFile') {
            if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
                throw "Log file not found: $LogPath"
            }
            $log = Get-Content -LiteralPath $LogPath -Raw -ErrorAction Stop
        } else {
            $log = $script:_gfBuffer.ToString()
            $script:_gfBuffer = $null
        }

        # Snapshot bound parameters so the static helper sees a plain
        # hashtable.  Hashtable.ContainsKey is supported under StrictMode.
        $bound = @{}
        foreach ($k in $PSBoundParameters.Keys) {
            $bound[$k] = $PSBoundParameters[$k]
        }
        if (-not $bound.ContainsKey('TotalVramMiB'))     { $bound['TotalVramMiB']     = $TotalVramMiB }
        if (-not $bound.ContainsKey('UnderestimateFactor')) { $bound['UnderestimateFactor'] = $UnderestimateFactor }
        if (-not $bound.ContainsKey('SlackMiB'))         { $bound['SlackMiB']         = $SlackMiB }
        $bound['MtpEnabled'] = [bool]$MtpEnabled

        $result = [FindFittEngine]::Compute($log, $bound)

        if ($PSBoundParameters.ContainsKey('Verbose') -or $VerbosePreference -eq 'Continue') {
            $rows = @(
                [pscustomobject]@{ Field = 'FittMiB';          Value = $result.FittMiB }
                [pscustomobject]@{ Field = 'PredictedCtx';     Value = $result.PredictedCtx }
                [pscustomobject]@{ Field = 'PerTokenKVKiB';    Value = $result.PerTokenKVKiB }
                [pscustomobject]@{ Field = 'KvLayers';         Value = $result.KvLayers }
                [pscustomobject]@{ Field = 'KvCells';          Value = $result.KvCells }
                [pscustomobject]@{ Field = 'KvKType';          Value = $result.KvKType }
                [pscustomobject]@{ Field = 'KvVType';          Value = $result.KvVType }
                [pscustomobject]@{ Field = 'ModelMiB';         Value = $result.ModelMiB }
                [pscustomobject]@{ Field = 'RSMiB';            Value = $result.RSMiB }
                [pscustomobject]@{ Field = 'ComputeMiB';       Value = $result.ComputeMiB }
                [pscustomobject]@{ Field = 'MtpOverheadMiB';   Value = $result.MtpOverheadMiB }
                [pscustomobject]@{ Field = 'RuntimeStaticMiB'; Value = $result.RuntimeStaticMiB }
                [pscustomobject]@{ Field = 'RuntimeFreeMiB';   Value = $result.RuntimeFreeMiB }
                [pscustomobject]@{ Field = 'Note';             Value = $result.Note }
            )
            $rows | Format-Table -AutoSize | Out-Host
        } else {
            $brief = @(
                [pscustomobject]@{ Field = 'FittMiB';      Value = $result.FittMiB }
                [pscustomobject]@{ Field = 'PredictedCtx'; Value = $result.PredictedCtx }
            )
            $brief | Format-Table -AutoSize | Out-Host
        }

        # Also return the raw object so callers can pipe it.
        [pscustomobject]@{
            FittMiB          = $result.FittMiB
            PredictedCtx     = $result.PredictedCtx
            PerTokenKVKiB    = $result.PerTokenKVKiB
            KvLayers         = $result.KvLayers
            KvCells          = $result.KvCells
            KvKType          = $result.KvKType
            KvVType          = $result.KvVType
            ModelMiB         = $result.ModelMiB
            RSMiB            = $result.RSMiB
            ComputeMiB       = $result.ComputeMiB
            MtpOverheadMiB   = $result.MtpOverheadMiB
            RuntimeStaticMiB = $result.RuntimeStaticMiB
            RuntimeFreeMiB   = $result.RuntimeFreeMiB
            Note             = $result.Note
        }
    }
}
