# Pester 3.x compatible test for Get-Fitt helper.
#
# Run from repo root with:
#   powershell.exe -NoProfile -Command "Import-Module Pester; Invoke-Pester C:\Users\yoho\Downloads\llama.cpp-mtp\tools\find-fitt\tests\Test-Get-Fitt.ps1"
#
# Or with v5+:
#   powershell.exe -NoProfile -Command "Invoke-Pester C:\Users\yoho\Downloads\llama.cpp-mtp\tools\find-fitt\tests\Test-Get-Fitt.ps1"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$module = Join-Path $root 'Get-Fitt.ps1'
. $module

$fixturesDir = Join-Path $here 'fixtures'
$realLog     = Join-Path $fixturesDir 'real-qwen27b-mtp.log'
$synLog      = Join-Path $fixturesDir 'syn-smoke.log'

Describe 'Get-KvBytesPerElement' {
    It 'returns documented byte sizes' {
        (Get-KvBytesPerElement -Type f32)   | Should Be 4.0
        (Get-KvBytesPerElement -Type f16)   | Should Be 2.0
        (Get-KvBytesPerElement -Type bf16)  | Should Be 2.0
        (Get-KvBytesPerElement -Type q8_0)  | Should Be 1.0625
        (Get-KvBytesPerElement -Type q5_1)  | Should Be 0.75
        (Get-KvBytesPerElement -Type q5_0)  | Should Be 0.6875
        (Get-KvBytesPerElement -Type q4_1)  | Should Be 0.625
        (Get-KvBytesPerElement -Type q4_0)  | Should Be 0.5625
        (Get-KvBytesPerElement -Type iq4_nl)| Should Be 0.5625
    }
    It 'throws on unknown type' {
        { Get-KvBytesPerElement -Type borked } | Should Throw
    }
}

Describe 'Get-Fitt on synthetic minimal log' {
    $r = Get-Fitt -LogPath $synLog -MtpEnabled -Verbose:$false
    It 'parses KV cells'             { $r.KvCells  | Should Be 161792 }
    It 'parses KV K/V types'         { $r.KvKType  | Should Be 'q4_1'; $r.KvVType | Should Be 'q4_0' }
    It 'computes per-token KV'       { $r.PerTokenKVKiB | Should BeGreaterThan 0 }
    It 'extracts model MiB'          { $r.ModelMiB | Should BeGreaterThan 0 }
    It 'predicts some n_ctx'         { $r.PredictedCtx | Should BeGreaterThan 0 }
}

Describe 'Get-Fitt on real Qwen3.6-27B-MTP log' {
    Context 'max mode' {
        $r = Get-Fitt -LogPath $realLog -MtpEnabled
        It 'finds a non-negative fitt'  { $r.FittMiB      | Should BeGreaterThan -1 }
        It 'predicts ~180k ctx'         { $r.PredictedCtx | Should BeGreaterThan 170000 }
        It 'predicts ctx within 256'    { ($r.PredictedCtx % 256) | Should Be 0 }
        It 'per-token KV ~29 KiB'       { [math]::Abs($r.PerTokenKVKiB - 29) | Should BeLessThan 1 }
        It 'KvLayers = 16 (hybrid)'     { $r.KvLayers     | Should Be 16 }
        It 'KvCells = 177152'           { $r.KvCells      | Should Be 177152 }
        It 'ModelMiB = 14285'           { $r.ModelMiB     | Should Be 14285 }
        It 'RSMiB = 748'                { [math]::Abs($r.RSMiB - 748.12) | Should BeLessThan 1 }
        It 'ComputeMiB from breakdown'  { $r.ComputeMiB   | Should Be 836 }
        It 'MtpOverheadMiB = 1140'      { $r.MtpOverheadMiB | Should Be 1140 }
    }
    Context 'TargetCtx=131072' {
        $r = Get-Fitt -LogPath $realLog -MtpEnabled -TargetCtx 131072
        It 'predicts exact ctx'         { $r.PredictedCtx | Should Be 131072 }
        It 'fitt is non-negative'       { $r.FittMiB      | Should BeGreaterThan -1 }
        It 'fitt is reasonable (1k-3k)' { $r.FittMiB      | Should BeGreaterThan 1000; $r.FittMiB | Should BeLessThan 3000 }
    }
    Context 'TargetCtx=65536' {
        $r = Get-Fitt -LogPath $realLog -MtpEnabled -TargetCtx 65536
        It 'predicts exact ctx'         { $r.PredictedCtx | Should Be 65536 }
        It 'fitt grows as ctx shrinks'  { $r.FittMiB      | Should BeGreaterThan 3000 }
    }
    Context 'FitTargetMiB=2000' {
        $r = Get-Fitt -LogPath $realLog -MtpEnabled -FitTargetMiB 2000
        It 'predicts valid ctx'         { $r.PredictedCtx | Should BeGreaterThan 0 }
        It 'ctx is 256-aligned'         { ($r.PredictedCtx % 256) | Should Be 0 }
        It 'ctx is < n_ctx_train (262k)'{ $r.PredictedCtx | Should BeLessThan 262145 }
    }
    Context 'pipeline mode' {
        $r = Get-Content $realLog | Get-Fitt -TargetCtx 131072
        It 'pipeline works'             { $r.FittMiB | Should BeGreaterThan -1 }
        It 'no MTP = higher fitt'       { $r.MtpOverheadMiB | Should Be 0 }
    }
}
