#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Builds transcribe-server for Windows x64 as two self-contained executables.

.DESCRIPTION
  Same sequence the CI workflow runs. Use this to produce a build without
  waiting for a release, or to test a change before pushing.

  The package is deliberately two executables rather than a pile of DLLs:

  - transcribe-server.exe carries the Vulkan backend.
  - transcribe-server-cpu.exe carries the processor backend.

  Both link the static MSVC runtime (/MT on the CMake side, +crt-static on the
  Rust side), so a machine that has never had the Visual C++ redistributable
  can still start the engine. The import guard runs against the staged bytes.

.PARAMETER DistDir
  Where the two executables are staged. Default: .\dist\runtime.

.PARAMETER VulkanSdk
  Vulkan SDK root. Default: $env:VULKAN_SDK, else the newest C:\VulkanSDK\*.

.PARAMETER Jobs
  Accepted for parity with the whisper build script; cargo uses its own
  parallelism.

.PARAMETER SkipSmoke
  Skip the smoke launch (CI always runs it; use this on a machine without a
  model).

.PARAMETER SmokeModel
  GGUF used by the smoke launch. The workflow downloads a small whisper-tiny
  model; locally point this at any model you have.

.EXAMPLE
  .\build.ps1

.EXAMPLE
  .\build.ps1 -SmokeModel .\dist\smoke.gguf
#>
[CmdletBinding()]
param(
    [string]$DistDir = "",
    [string]$VulkanSdk = $env:VULKAN_SDK,
    [int]$Jobs = [Environment]::ProcessorCount,
    [switch]$SkipSmoke,
    [string]$SmokeModel = ""
)

# $PSScriptRoot is empty inside a param default; resolve it in the body.
if (-not $DistDir) { $DistDir = Join-Path $PSScriptRoot "dist\runtime" }

$ErrorActionPreference = "Stop"

function Say([string]$m) { Write-Host "[build] $m" }

# ---- locate the SDK -------------------------------------------------------
if (-not $VulkanSdk) {
    $VulkanSdk = Get-ChildItem "C:\VulkanSDK" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $VulkanSdk) {
    Say "No Vulkan SDK found. Install it from https://vulkan.lunarg.com/sdk/home"
    exit 1
}
if (-not (Test-Path "$VulkanSdk\Bin\glslc.exe")) {
    Say "glslc.exe missing from $VulkanSdk\Bin - is this a complete SDK install?"
    exit 1
}
Say "Vulkan SDK: $VulkanSdk"

# The import library is named vulkan-1.lib, not vulkan.lib. Probe rather
# than assume.
$vulkanLib = @("vulkan-1.lib", "vulkan.lib") |
    ForEach-Object { Join-Path $VulkanSdk "Lib\$_" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vulkanLib) {
    Say "No Vulkan import library under $VulkanSdk\Lib"
    exit 1
}
Say "import lib: $vulkanLib"

foreach ($tool in @("cargo", "cmake", "git")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Say "$tool not found on PATH"
        exit 1
    }
}

# ---- environment ----------------------------------------------------------
# The -sys crate emits `link-lib=vulkan-1` without a search path; link.exe
# needs the SDK's Lib directory through LIB.
# The CMake side defaults to the DLL runtime; pin it to the static one so
# both halves of the executable agree.
# GGML_VULKAN_SHADER_TYPES keeps the embedded shader set to the tensor types
# the catalogue uses; ggml aborts a Vulkan run whose weights need any other.
# RUSTFLAGS link the Rust side statically too, so no VCRUNTIME140 or UCRT
# import reaches the import table.
$env:CMAKE_ARGS = "-DGGML_NATIVE=OFF -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DGGML_VULKAN_SHADER_TYPES=f32,f16,q8_0,q5_0 -DGGML_VULKAN_MUL_MAT_ID=OFF"
$env:LIB = "$VulkanSdk\Lib;$env:LIB"
$env:RUSTFLAGS = "-C target-feature=+crt-static"
$env:VULKAN_SDK = $VulkanSdk
$env:PATH = "$VulkanSdk\Bin;$env:PATH"

$serverDir = Join-Path $PSScriptRoot "server"
if (-not (Test-Path (Join-Path $serverDir "Cargo.toml"))) {
    Say "server sources not found under $serverDir"
    exit 1
}

# ---- Vulkan build ---------------------------------------------------------
Say "Building the Vulkan engine (first build compiles transcribe.cpp; expect minutes)..."
& cargo build --release --manifest-path (Join-Path $serverDir "Cargo.toml") `
    --target-dir (Join-Path $PSScriptRoot "build-vulkan")
if ($LASTEXITCODE -ne 0) { Say "Vulkan build failed"; exit 1 }

# ---- processor build ------------------------------------------------------
Say "Building the processor engine..."
& cargo build --release --no-default-features `
    --manifest-path (Join-Path $serverDir "Cargo.toml") `
    --target-dir (Join-Path $PSScriptRoot "build-cpu")
if ($LASTEXITCODE -ne 0) { Say "processor build failed"; exit 1 }

# ---- stage ----------------------------------------------------------------
if (Test-Path $DistDir) { Remove-Item $DistDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$vulkanServer = Join-Path $PSScriptRoot "build-vulkan\release\transcribe-server.exe"
$cpuServer = Join-Path $PSScriptRoot "build-cpu\release\transcribe-server.exe"
if (-not (Test-Path $vulkanServer)) { Say "Vulkan build produced no transcribe-server.exe"; exit 1 }
if (-not (Test-Path $cpuServer)) { Say "processor build produced no transcribe-server.exe"; exit 1 }
Copy-Item $vulkanServer (Join-Path $DistDir "transcribe-server.exe")
Copy-Item $cpuServer (Join-Path $DistDir "transcribe-server-cpu.exe")

# A clean machine is the only machine that can prove this, so the check runs
# against the packaged bytes rather than the build tree.
& "$PSScriptRoot\verify-imports.ps1" `
    -Binary (Join-Path $DistDir "transcribe-server.exe") -Vulkan
if ($LASTEXITCODE -ne 0) { Say "Vulkan import check failed"; exit 1 }
& "$PSScriptRoot\verify-imports.ps1" `
    -Binary (Join-Path $DistDir "transcribe-server-cpu.exe")
if ($LASTEXITCODE -ne 0) { Say "processor import check failed"; exit 1 }

# ---- smoke ----------------------------------------------------------------
if (-not $SkipSmoke) {
    if (-not $SmokeModel -or -not (Test-Path $SmokeModel)) {
        Say "No smoke model given; skipping the smoke launch (CI passes one)"
    } else {
        & "$PSScriptRoot\smoke.ps1" -DistDir $DistDir -Model (Resolve-Path $SmokeModel)
        if ($LASTEXITCODE -ne 0) { Say "smoke launch failed"; exit 1 }
    }
}

$files = Get-ChildItem $DistDir -File
$bytes = ($files | Measure-Object Length -Sum).Sum
Say ("staged {0} files, {1:N1} MB, in {2}" -f $files.Count, ($bytes / 1MB), $DistDir)
