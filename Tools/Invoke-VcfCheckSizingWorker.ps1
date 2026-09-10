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
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#
# =============================================================================
<#
    .SYNOPSIS
    Long-lived worker process for calculating VCF management domain upgrade sizing estimates.

    .DESCRIPTION
    Imports the VcfCheck module and preloads sizing reference data via Get-VcfCheckSizingReferenceData
    and brownfield treatment data via Get-VcfCheckBrownfieldTreatmentData once at process startup.

    Listens on stdin for JSON-formatted selection payloads, calculates capacity estimates using
    Get-VcfCheckManagementDomainSizingEstimate, and streams compressed JSON result objects
    to stdout line-by-line until stdin closes.

    Writes a 'READY' handshake signal to stdout upon successful initialization to notify calling processes.

    .OUTPUTS
    Outputs 'READY' on startup, followed by line-delimited compressed JSON estimate payloads or error objects
    (`{"error": "<message>"}`) to stdout.
#>

[CmdletBinding()]
Param ()

if ($null -ne $PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

$envModulePsd1 = ([String]$env:VCFCHECK_MODULE_PSD1).Trim()
if (-not [String]::IsNullOrWhiteSpace($envModulePsd1) -and (Test-Path -LiteralPath $envModulePsd1 -PathType Leaf)) {
    $modulePath = $envModulePsd1
} else {
    $modulePath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'VcfCheck.psd1'
}

try {
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $referenceData = Get-VcfCheckSizingReferenceData
    $treatmentData = Get-VcfCheckBrownfieldTreatmentData
} catch {
    Write-Host "ERROR: Could not start the sizing worker from `"$modulePath`": $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

[Console]::Out.WriteLine('READY')
[Console]::Out.Flush()

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) {
        break
    }
    if ([String]::IsNullOrWhiteSpace($line)) {
        continue
    }

    try {
        $selections = @($line | ConvertFrom-Json -Depth 10 -AsHashtable -ErrorAction Stop)
        $result = Get-VcfCheckManagementDomainSizingEstimate -Selections $selections -ReferenceData $referenceData -TreatmentData $treatmentData
        $responseLine = $result | ConvertTo-Json -Depth 10 -Compress
    } catch {
        $responseLine = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
    }

    [Console]::Out.WriteLine($responseLine)
    [Console]::Out.Flush()
}
