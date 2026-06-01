# Build script for llama.cpp
# Outputs binaries to %TEMP%\llama.cpp\master\commit\<hash>\

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# Fetch latest master to get accurate commit info
git fetch origin master

# Get commit info
$MASTER_COMMIT = git rev-parse origin/master
$HEAD_COMMIT = git rev-parse HEAD

# Configure and build
cmake -B build -DGGML_NATIVE=ON -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON -DLLAMA_BUILD_UI=OFF
cmake --build build --config Release -j 32 --target llama-server llama-cli llama-results llama-bench

# Output directory
$OUTPUT_DIR = "$env:TEMP\llama.cpp\master\commit\$HEAD_COMMIT"
New-Item -ItemType Directory -Force -Path $OUTPUT_DIR | Out-Null

# Copy binaries
Copy-Item "build\Release\llama-server.exe"    $OUTPUT_DIR
Copy-Item "build\Release\llama-cli.exe"       $OUTPUT_DIR
Copy-Item "build\Release\llama-results.exe"    $OUTPUT_DIR
Copy-Item "build\Release\llama-bench.exe"      $OUTPUT_DIR

# Write version file
$VERSION_FILE = Join-Path $OUTPUT_DIR "version.txt"
@"
master commit: $MASTER_COMMIT
HEAD: $HEAD_COMMIT
"@ | Set-Content -Path $VERSION_FILE -Encoding UTF8

Write-Host "Built successfully -> $OUTPUT_DIR"
Write-Host "master: $MASTER_COMMIT"
Write-Host "HEAD:   $HEAD_COMMIT"
