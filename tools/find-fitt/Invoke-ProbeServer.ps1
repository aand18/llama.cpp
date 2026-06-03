<#
.SYNOPSIS
Run llama-server in probe mode, capture its log, compute fitt, optionally relaunch.
#>
function Invoke-ProbeServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModelPath,
        [string]$MmprojPath,
        [string]$ExtraArgs,
        [int]$TotalVramMiB = 24563,
        [int]$BatchSize = 2048,
        [switch]$MtpEnabled,
        [switch]$Start,
        [int]$TargetCtx = 0,
        [int]$ProbeTimeoutSec = 300
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $llamaServer = Find-LlamaServerBinary
    $tempLog = [System.IO.Path]::GetTempFileName() + '.log'
    $proc = $null

    try {
        $serverArgs = @('-m', $ModelPath)
        if ($MmprojPath) { $serverArgs += @('--mmproj', $MmprojPath) }
        if ($ExtraArgs) {
            $serverArgs += $ExtraArgs.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
        }

        $proc = Start-Process -FilePath $llamaServer `
                               -ArgumentList $serverArgs `
                               -RedirectStandardOutput $tempLog `
                               -RedirectStandardError $tempLog `
                               -PassThru -NoNewWindow

        $deadline = (Get-Date).AddSeconds($ProbeTimeoutSec)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            if ((Test-Path $tempLog) -and
                (Select-String -Path $tempLog -Pattern 'server is listening|model loaded' -Quiet)) {
                $ready = $true
                break
            }
            if ($proc.HasExited) {
                $tail = if (Test-Path $tempLog) { Get-Content $tempLog -Tail 50 } else { '<no log>' }
                throw "Server exited prematurely. Last 50 lines:`n$tail"
            }
            Start-Sleep -Milliseconds 500
        }

        if (-not $ready) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $proc = $null
            $tail = if (Test-Path $tempLog) { Get-Content $tempLog -Tail 50 } else { '<no log>' }
            throw "Server did not start within $ProbeTimeoutSec seconds. Last 50 lines:`n$tail"
        }

        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $proc = $null
        Start-Sleep -Seconds 2

        $getFitt = Join-Path $PSScriptRoot 'Get-Fitt.ps1'
        if (-not (Test-Path $getFitt)) { throw "Get-Fitt.ps1 not found at $getFitt" }
        . $getFitt
        $fittArgs = @{}
        foreach ($k in 'TotalVramMiB','BatchSize','MtpEnabled','TargetCtx') {
            if ($PSBoundParameters.ContainsKey($k)) { $fittArgs[$k] = $PSBoundParameters[$k] }
        }
        $result = Get-Fitt -LogPath $tempLog @fittArgs

        $result | Format-List

        if ($Start) {
            $fittArg = @('-fitt', $result.FittMiB)
            Start-Process -FilePath $llamaServer -ArgumentList @($serverArgs + $fittArg) -NoNewWindow
        }
    }
    finally {
        if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempLog) { Remove-Item $tempLog -Force -ErrorAction SilentlyContinue }
    }
}

function Find-LlamaServerBinary {
    if ($env:LLAMA_SERVER_BIN -and (Test-Path $env:LLAMA_SERVER_BIN)) {
        return (Resolve-Path $env:LLAMA_SERVER_BIN).Path
    }

    $onPath = Get-Command 'llama-server.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $relativePaths = @(
        'msvc\build\bin\Release\llama-server.exe',
        'build\bin\Release\llama-server.exe'
    )
    $cwd = (Get-Location).Path
    foreach ($rel in $relativePaths) {
        $candidate = Join-Path $cwd $rel
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    }

    $dir = $cwd
    while ($dir) {
        $candidate = Join-Path $dir 'build/bin/Release/llama-server.exe'
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        $parent = Split-Path $dir -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }

    throw "llama-server.exe not found. Set `$env:LLAMA_SERVER_BIN, add it to PATH, or build the project (cmake --build build --config Release)."
}
