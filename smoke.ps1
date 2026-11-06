#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Starts each staged engine, checks the request contract, and transcribes a
  sample. Fails the build when either backend cannot serve.

.DESCRIPTION
  The supervisor's contract is small, and this is the check that it holds for
  the packaged bytes: readiness on GET /, a multipart POST to /inference (and
  the OpenAI-compatible path), and a JSON reply with non-empty text. The
  startup line is printed; with -RequireVulkan the accelerated executable must
  prove it bound a Vulkan device.

  The sample is jfk.wav from the pinned transcribe.cpp revision, downloaded
  when it is not already present.

.PARAMETER DistDir
  Directory holding transcribe-server.exe and transcribe-server-cpu.exe.

.PARAMETER Model
  GGUF the engines load. CI uses a small whisper-tiny model.

.PARAMETER PortBase
  First port to try; the processor engine uses the next one.

.PARAMETER RequireVulkan
  Fail when the accelerated engine did not bind Vulkan (use on a machine with
  a GPU; GitHub runners have none).

.EXAMPLE
  .\smoke.ps1 -DistDir .\dist\runtime -Model .\dist\smoke.gguf
#>
[CmdletBinding()]
param(
    [string]$DistDir = "",
    [Parameter(Mandatory = $true)]
    [string]$Model,
    [int]$PortBase = 8801,
    [switch]$RequireVulkan
)

# $PSScriptRoot is empty inside a param default; resolve it in the body.
if (-not $DistDir) { $DistDir = Join-Path $PSScriptRoot "dist\runtime" }

$ErrorActionPreference = "Stop"
$rev = "2778ae4bf5ca5f394d129a39467f4ad9552dc34f"
# Smoke artefacts live beside the staged runtime, never inside it: the
# packaged zip is the two executables only.
$work = Join-Path (Split-Path -Parent $DistDir) "smoke"
$audio = Join-Path $work "jfk.wav"
$logs = Join-Path $work "logs"

function Say([string]$m) { Write-Host "[smoke] $m" }

if (-not (Test-Path (Join-Path $DistDir "transcribe-server.exe"))) {
    throw "transcribe-server.exe not found in $DistDir"
}
if (-not (Test-Path $Model)) {
    throw "smoke model not found: $Model"
}
New-Item -ItemType Directory -Force -Path $work, $logs | Out-Null
if (-not (Test-Path $audio)) {
    Say "downloading jfk.wav"
    $url = "https://raw.githubusercontent.com/anomalyco/transcribe.cpp/$rev/samples/jfk.wav"
    & curl.exe -sS -L --fail -o $audio $url
    if ($LASTEXITCODE -ne 0) { throw "could not download $url" }
}

function Wait-Ready([System.Diagnostics.Process]$process, [int]$port) {
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            throw "engine exited before answering (code $($process.ExitCode))"
        }
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:$port/" -TimeoutSec 2 -UseBasicParsing
            if ($r.StatusCode -eq 200) { return }
        } catch { Start-Sleep -Milliseconds 400 }
    }
    throw "engine did not answer GET / within 90 s"
}

function Post-Wav([int]$port, [string]$path) {
    $out = Join-Path $logs ("response-{0}.json" -f [guid]::NewGuid().ToString('N'))
    & curl.exe -sS -X POST "http://127.0.0.1:$port$path" `
        -F "file=@$audio;type=audio/wav" -F "response_format=json" -F "language=en" `
        -o $out
    if ($LASTEXITCODE -ne 0) { throw "POST $path failed" }
    $json = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($out))
    try { $parsed = $json | ConvertFrom-Json } catch { throw "reply is not JSON: $json" }
    if (-not $parsed.text -or $parsed.text.Trim().Length -eq 0) {
        throw "reply has no text: $json"
    }
    return $parsed.text.Trim()
}

$engines = @(
    @{ exe = "transcribe-server.exe"; port = $PortBase; name = "vulkan" },
    @{ exe = "transcribe-server-cpu.exe"; port = $PortBase + 1; name = "cpu" }
)

foreach ($engine in $engines) {
    $exe = Join-Path $DistDir $engine.exe
    $log = Join-Path $logs ("{0}.log" -f $engine.name)
    Remove-Item $log -ErrorAction SilentlyContinue | Out-Null
    $process = Start-Process -FilePath $exe `
        -ArgumentList @('--model', $Model, '--host', '127.0.0.1', '--port', "$($engine.port)", '--language', 'en') `
        -RedirectStandardError $log -PassThru -WindowStyle Hidden
    try {
        Wait-Ready $process $engine.port
        $text = Post-Wav $engine.port "/inference"
        Say "$($engine.name): $text"
        $banner = Get-Content $log | Where-Object { $_ -match '^transcribe-server backend=' } | Select-Object -First 1
        if (-not $banner) { throw "$($engine.name): startup line is missing" }
        Say "$($engine.name): $banner"
        if ($engine.name -eq "vulkan" -and $RequireVulkan -and $banner -notmatch 'backend=vulkan') {
            throw "accelerated engine did not bind Vulkan: $banner"
        }
        if ($engine.name -eq "vulkan") {
            $fallback = Post-Wav $engine.port "/v1/audio/transcriptions"
            Say "vulkan: OpenAI-compatible path ok ($($fallback.Length) chars)"
        }
    }
    finally {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    }
}

Say "both backends answered"
