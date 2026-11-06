#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fails when a packaged engine still depends on a DLL that is not shipped.

.DESCRIPTION
  The runtime is meant to be self-contained: one executable per backend,
  statically linked against the C runtime, plus the Vulkan loader on the
  accelerated build (a driver component, not a redistributable). The guard is
  an allowlist: every imported DLL must be a Windows component (API sets
  included) or, for the accelerated build, the Vulkan loader. An unknown name
  fails the build. A denylist misses the next redistributable DLL, such as
  msvcp140_atomic_wait.dll or vcruntime140_threads.dll.

  This is deliberately a dependency check rather than a launch check. A launch
  on a build machine proves the build machine has the DLL; it does not prove a
  clean machine does.

.PARAMETER Binary
  Executable to inspect.

.PARAMETER Vulkan
  Require the Vulkan loader and allow it in the import table.

.EXAMPLE
  .\verify-imports.ps1 -Binary .\dist\runtime\transcribe-server.exe -Vulkan
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Binary,

    [switch]$Vulkan
)

$ErrorActionPreference = "Stop"

# The allowlist. Anything not named here fails the build until a person
# decides it is safe to ship or is already part of Windows. API sets are
# covered by the prefix check in the loop; the UCRT API set is a Windows
# component, while the redistributable CRT DLLs are not in this list and
# therefore cannot sneak back in.
$osDlls = @(
    'advapi32.dll',
    'bcrypt.dll',
    'bcryptprimitives.dll',
    'combase.dll',
    'comctl32.dll',
    'crypt32.dll',
    'dbghelp.dll',
    'dwmapi.dll',
    'gdi32.dll',
    'imm32.dll',
    'iphlpapi.dll',
    'kernel32.dll',
    'ntdll.dll',
    'ole32.dll',
    'oleaut32.dll',
    'powrprof.dll',
    'psapi.dll',
    'rpcrt4.dll',
    'secur32.dll',
    'setupapi.dll',
    'shell32.dll',
    'shlwapi.dll',
    'user32.dll',
    'userenv.dll',
    'version.dll',
    'winmm.dll',
    'ws2_32.dll'
)

# The Vulkan loader comes from the graphics driver; the application probes for
# it and uses the processor build when it is absent.
$shipped = @()
if ($Vulkan) { $shipped += 'vulkan-1.dll' }

function Find-VisualStudioRoot {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $found = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if ($found) { return $found }
    }
    foreach ($candidate in @(
        "$env:ProgramFiles\Microsoft Visual Studio\2022\Enterprise",
        "$env:ProgramFiles\Microsoft Visual Studio\2022\Professional",
        "$env:ProgramFiles\Microsoft Visual Studio\2022\Community",
        "$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    throw "Visual Studio with the C++ tools was not found"
}

function Find-Dumpbin {
    $root = Find-VisualStudioRoot
    $tools = Get-ChildItem (Join-Path $root 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($tool in $tools) {
        $dumpbin = Join-Path $tool.FullName 'bin\Hostx64\x64\dumpbin.exe'
        if (Test-Path $dumpbin) { return $dumpbin }
    }
    throw "dumpbin.exe was not found under $root"
}

function Get-Imports([string]$file) {
    $dumpbin = Find-Dumpbin
    $output = & $dumpbin /nologo /dependents $file 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dumpbin failed for $file`n$($output -join "`n")"
    }
    # Case-sensitive matching avoids Windows PowerShell 5.1 under a Turkish
    # locale folding I to a dotless i; the extension is checked
    # case-insensitively afterwards because dumpbin prints VULKAN-1.DLL as
    # readily as vulkan-1.dll.
    $imports = @()
    foreach ($line in $output) {
        if ($line -cmatch '^\s+([A-Za-z0-9_.-]+\.[A-Za-z]+)\s*$') {
            $name = $Matches[1]
            if ($name.ToLowerInvariant().EndsWith('.dll')) {
                $imports += $name
            }
        }
    }
    if (-not $imports) {
        throw "no import table was read from $file"
    }
    return $imports
}

foreach ($file in $Binary) {
    if (-not (Test-Path $file)) {
        throw "missing binary: $file"
    }
    $imports = Get-Imports $file
    $bad = @()
    foreach ($name in $imports) {
        $lower = $name.ToLowerInvariant()
        # Case-sensitive and lowercase on both sides: Windows PowerShell 5.1
        # under a Turkish locale folds I to a dotless i when it is allowed to
        # ignore case, which silently dropped ADVAPI32.dll from the list this
        # guard is supposed to check.
        $isApiSet = $lower.StartsWith('api-ms-win-')
        $isOs = $osDlls -contains $lower
        $isShipped = $shipped -contains $lower
        if (-not ($isApiSet -or $isOs -or $isShipped)) {
            $bad += $name
        }
    }
    if ($bad.Count -gt 0) {
        Write-Host "[imports] $file depends on DLLs the package does not ship:" -ForegroundColor Red
        $bad | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    }
    $required = @()
    if ($Vulkan) { $required += 'vulkan-1.dll' }
    foreach ($name in $required) {
        if (-not ($imports | Where-Object { $_.ToLowerInvariant() -eq $name })) {
            Write-Host "[imports] $file is missing the required import $name" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host "[imports] $file ok ($($imports.Count) imports)"
}
