# Build script for llama.cpp
# Outputs binaries to %TEMP%\llama.cpp\<branch>\<short_hash>\
# Symlinks latest binaries to %TEMP%\llama.cpp\<branch>\*.exe
#
# Override CUDA toolkit by setting env var before calling:
#   $env:CUDA_PATH = $env:CUDA_PATH_V13_3; ./build.ps1

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# Fix git for worktree: .git file has WSL path Windows git can't resolve
# Main repo is two levels up: .worktrees/branch-name -> main repo root
$MAIN_REPO = (Get-Item $PSScriptRoot).Parent.Parent.FullName
$env:GIT_DIR = Join-Path (Join-Path $MAIN_REPO ".git\worktrees") (Split-Path $PSScriptRoot -Leaf)

# Get branch and commit info
$BRANCH = git rev-parse --abbrev-ref HEAD
git fetch origin master
$MASTER_COMMIT = git rev-parse origin/master
$HEAD_COMMIT = git rev-parse HEAD
$HEAD_SHORT = git rev-parse --short HEAD

# Configure and build
cmake -B build -DGGML_NATIVE=ON -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON -DLLAMA_BUILD_UI=OFF
$proc = Start-Process -FilePath "cmake" -ArgumentList "--build build --config Release -j $([Environment]::ProcessorCount - 2) --target llama-server llama-cli llama-results llama-bench" -NoNewWindow -PassThru
$proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle
$proc.WaitForExit()
if ($proc.ExitCode -ne 0) { exit $proc.ExitCode }

# Output directory
$BRANCH_DIR = "$env:TEMP\llama.cpp\$BRANCH"
$OUTPUT_DIR = "$BRANCH_DIR\$HEAD_SHORT"
New-Item -ItemType Directory -Force -Path $OUTPUT_DIR | Out-Null

# Copy binaries
$BINARIES = @("llama-server.exe", "llama-cli.exe", "llama-results.exe", "llama-bench.exe")
foreach ($bin in $BINARIES) {
    Copy-Item "build\bin\Release\$bin" $OUTPUT_DIR

    # Symlink latest binaries to branch directory
    $LINK = Join-Path $BRANCH_DIR $bin
    if (Test-Path $LINK) { Remove-Item $LINK -Force }
    New-Item -ItemType Junction -Path $LINK -Target (Join-Path $OUTPUT_DIR $bin) | Out-Null
}

# Write version file
$VERSION_FILE = Join-Path $OUTPUT_DIR "version.txt"
@"
HEAD $BRANCH: $HEAD_COMMIT
Rebased on origin/master: $MASTER_COMMIT
"@ | Set-Content -Path $VERSION_FILE -Encoding UTF8

Write-Host "Built successfully -> $OUTPUT_DIR"
Write-Host "HEAD $BRANCH: $HEAD_COMMIT"
Write-Host "Rebased on origin/master: $MASTER_COMMIT"
