# Copyright (c) 2026 Broadcom. All Rights Reserved.
# Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
# and/or its subsidiaries.
#
# =============================================================================
#
# SOFTWARE LICENSE AGREEMENT
#
# Copyright (c) CA, Inc. All rights reserved.
#
# You are hereby granted a non-exclusive, worldwide, royalty-free license
# under CA, Inc.'s copyrights to use, copy, modify, and distribute this
# software in source code or binary form for use in connection with CA, Inc.
# products.
#
# This copyright notice shall be included in all copies or substantial
# portions of the software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
# =============================================================================

#Requires -Version 7.4

<#
.SYNOPSIS
    Manually installs the VcfCheck PowerShell module cross-platform.

.DESCRIPTION
    Copies VcfCheck.psd1, VcfCheck.psm1, Config, Data, Docs, Private, and Tools into the
    first path in $env:PSModulePath for the current platform (Windows, Linux, or macOS).
    Validates the installed manifest before completing. Python __pycache__ directories
    are excluded from the copy.

    If the module is currently loaded in the session it is removed before the files
    are overwritten and reloaded afterward, so the in-memory version matches what was
    just installed.

    Once installed to $env:PSModulePath, PowerShell auto-imports the module the first time
    any of its commands is used in a session. No $PROFILE changes are needed - do not add
    'Import-Module VcfCheck' to $PROFILE, since eagerly loading ~80 check files on every
    shell startup is noticeably slower than PowerShell's built-in auto-import on first use.

    Prerequisites:
      - PowerShell 7.4 or newer (enforced by #Requires).
      - VCF.PowerCLI 9.0 or newer must already be installed.
      - Python 3.13 or newer, for the bundled web interface.

.PARAMETER SourcePath
    Path to the directory containing the module source files. Defaults to the
    directory containing this script ($PSScriptRoot), which is correct both when
    running directly from a cloned repository and when running from an expanded
    release ZIP.

.EXAMPLE
    .\Install-VcfCheckModule.ps1

    Installs from the script's own directory.

.EXAMPLE
    .\Install-VcfCheckModule.ps1 -SourcePath "~/Downloads/VcfCheck"

    Installs from a custom source directory.

.NOTES
    After installation, run 'Initialize-VcfCheck' once, then 'Start-VcfCheckServer' to
    launch the web interface. PowerShell auto-imports the module on first use - no
    profile line needed.
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$SourcePath = $PSScriptRoot
)

$itemsToCopy = @("VcfCheck.psd1", "VcfCheck.psm1", "Config", "Data", "Docs", "Private", "Tools")

Write-Host ""
Write-Host "VcfCheck Module Installer" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host ""
Write-Host "PREREQUISITE: VCF.PowerCLI 9.0 or newer must be installed before importing this module." -ForegroundColor Yellow
Write-Host ""

try {
    if (-not (Test-Path -Path $SourcePath -PathType Container)) {
        throw "Source path not found or is not a directory: $SourcePath"
    }

    $pathSeparator = [System.IO.Path]::PathSeparator
    $basePath = ($env:PSModulePath -split $pathSeparator)[0]
    $installPath = Join-Path -Path $basePath -ChildPath "VcfCheck"

    Write-Host "Source      : $SourcePath"
    Write-Host "Destination : $installPath"
    Write-Host ""

    # Unload the module if it is currently in the session so the files can be
    # overwritten and the reloaded copy is consistent with what was just installed.
    $loadedModule = Get-Module -Name "VcfCheck" -ErrorAction SilentlyContinue
    if ($null -ne $loadedModule) {
        Write-Host "Unloading currently loaded module (version $($loadedModule.Version))..." -ForegroundColor Gray
        Remove-Module -Name "VcfCheck" -Force -ErrorAction Stop
    }

    if (-not (Test-Path -Path $installPath)) {
        Write-Host "Creating module directory..." -ForegroundColor Gray
        New-Item -Path $installPath -ItemType Directory -Force | Out-Null
    }

    foreach ($item in $itemsToCopy) {
        $itemSource = Join-Path -Path $SourcePath -ChildPath $item

        if (-not (Test-Path -Path $itemSource)) {
            Write-Host "  [SKIP] $item - not found at source." -ForegroundColor Yellow
            continue
        }

        Write-Host "  Copying $item..." -ForegroundColor Gray
        # Exclude Python bytecode cache directories that may exist in a development checkout.
        Copy-Item -Path $itemSource -Destination $installPath -Recurse -Force -Exclude "__pycache__"
        # Copy-Item -Exclude does not recurse into subdirectories; remove any copied __pycache__ explicitly.
        Get-ChildItem -Path (Join-Path -Path $installPath -ChildPath $item) -Filter "__pycache__" -Recurse -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Unblock all copied files on Windows so execution policy does not block the module
    # after installation when the source was downloaded from the internet (ZIP or clone).
    # Unblock-File throws on macOS/Linux (unsupported cmdlet), so only run it on Windows.
    if ($IsWindows) {
        Write-Host "Unblocking installed module files (Windows execution policy)..." -ForegroundColor Gray
        Get-ChildItem -Path $installPath -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue }
    }

    Write-Host ""
    Write-Host "Validating module manifest..." -ForegroundColor Gray
    $manifestPath = Join-Path -Path $installPath -ChildPath "VcfCheck.psd1"
    $null = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop

    # Reload the module into the current session so the caller can use it immediately
    # without opening a new shell. Import errors are non-fatal - the files are on disk
    # and the user can reload manually if a dependency like VCF.PowerCLI is absent.
    Write-Host "Importing module into current session..." -ForegroundColor Gray
    try {
        Import-Module -Name $manifestPath -Force -ErrorAction Stop
        $reloadedVersion = (Get-Module -Name "VcfCheck").Version
        Write-Host "  Module loaded (version $reloadedVersion)." -ForegroundColor Gray
    } catch {
        Write-Host "  Import skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Run 'Import-Module VcfCheck' manually once all prerequisites are met." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Installation complete." -ForegroundColor Green
    Write-Host "  Initialize-VcfCheck" -ForegroundColor Green
    Write-Host "  Start-VcfCheckServer" -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
