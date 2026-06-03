# Build script for llama.cpp
# Outputs binaries to %TEMP%\llama.cpp\<branch>\<short_hash>\
# Symlinks latest binaries to %TEMP%\llama.cpp\<branch>\*.exe
#
# Override CUDA toolkit by setting env var before calling:
#   $env:CUDA_PATH = $env:CUDA_PATH_V13_3; ./build.ps1

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# Fix git for worktree: .git file has WSL path Windows git can't resolve
if (Test-Path (Join-Path $PSScriptRoot ".git") -PathType Leaf) {
    # Worktree: parse gitdir from .git file
    $gitdir = (Get-Content (Join-Path $PSScriptRoot ".git")) -match '^gitdir:'
    $gitdir = $gitdir -replace '^gitdir:\s*', ''
    # Convert WSL path (/mnt/c/...) to Windows path (C:/...)
    if ($gitdir -match '^/mnt/([a-z])/(.*)') {
        $gitdir = $matches[1].toupper() + ":/" + $matches[2] -replace '/', '\'
    }
    $env:GIT_DIR = $gitdir
}
# Regular repo: no GIT_DIR override needed

# Get branch and commit info
$BRANCH = (git rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
$oldErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
git fetch origin master 2>&1 | Out-Null
$ErrorActionPreference = $oldErrorAction
$MASTER_COMMIT = (git rev-parse origin/master 2>$null | Out-String).Trim()
$HEAD_COMMIT = (git rev-parse HEAD 2>$null | Out-String).Trim()
$HEAD_SHORT = (git rev-parse --short HEAD 2>$null | Out-String).Trim()

# Configure and build
cmake -B build -DGGML_NATIVE=ON -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
cmake --build build --config Release -j $([Math]::Max(1, [Environment]::ProcessorCount - 2)) --target llama-server llama-cli llama-results llama-bench
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Output directory — replace / in branch name to avoid nested dirs
$BRANCH_OUTPUT = $BRANCH -replace '/', '-'
$BRANCH_DIR = Join-Path (Join-Path $env:TEMP "llama.cpp") $BRANCH_OUTPUT
$OUTPUT_DIR = Join-Path $BRANCH_DIR $HEAD_SHORT
New-Item -ItemType Directory -Force -Path $OUTPUT_DIR | Out-Null

# Copy all build artifacts (exes + dlls)
$BIN_DIR = Join-Path (Join-Path (Join-Path $PSScriptRoot "build") "bin") "Release"
Copy-Item (Join-Path $BIN_DIR "*") $OUTPUT_DIR -Force

# Create batch wrappers in branch directory pointing to latest commit's EXEs
$EXES = Get-ChildItem $OUTPUT_DIR -Filter "*.exe" | Select-Object -ExpandProperty Name
foreach ($exe in $EXES) {
    $batName = $exe -replace '\.exe$', '.bat'
    $batPath = Join-Path $BRANCH_DIR $batName
    $exePath = Join-Path $OUTPUT_DIR $exe
    $content = "@echo off`r`n"
    $content += "cd /d ""$OUTPUT_DIR""`r`n"
    $content += """$exePath"" %*"
    Set-Content -Path $batPath -Value $content -Encoding ASCII
}

# Write version file
$VERSION_FILE = Join-Path $OUTPUT_DIR "version.txt"
@"
HEAD ${BRANCH}: $HEAD_COMMIT
Rebased on origin/master: $MASTER_COMMIT
"@ | Set-Content -Path $VERSION_FILE -Encoding UTF8

Write-Host "Built successfully -> $OUTPUT_DIR"
Write-Host "HEAD ${BRANCH}: $HEAD_COMMIT"
Write-Host "Rebased on origin/master: $MASTER_COMMIT"
