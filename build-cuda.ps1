$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (Test-Path (Join-Path $PSScriptRoot ".git") -PathType Leaf) {
    $gitdir = (Get-Content (Join-Path $PSScriptRoot ".git")) -match '^gitdir:'
    $gitdir = $gitdir -replace '^gitdir:\s*', ''
    if ($gitdir -match '^/mnt/([a-z])/(.*)') {
        $gitdir = $matches[1].toupper() + ":/" + $matches[2] -replace '/', '\'
    }
    $env:GIT_DIR = $gitdir
}

cmake -B build `
    -DGGML_NATIVE=ON `
    -DGGML_CUDA=ON `
    -DGGML_CUDA_FA_ALL_QUANTS=ON `
    -DCUDA_TOOLKIT_ROOT_DIR="C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1" `
    -DCMAKE_CUDA_COMPILER="C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1\bin\nvcc.exe"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

cmake --build build --config Release --target llama-mtmd-cli -j 28
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Build complete"
