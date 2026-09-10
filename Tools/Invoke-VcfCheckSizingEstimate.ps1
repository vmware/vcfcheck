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
    Command-line entry point for calculating VCF management domain upgrade sizing estimates.

    .DESCRIPTION
    Reads component selection parameters from a JSON file specified by -SelectionsPath.

    Loads shipped reference data via Get-VcfCheckSizingReferenceData and brownfield treatment data
    via Get-VcfCheckBrownfieldTreatmentData, then calculates resource capacity requirements using
    Get-VcfCheckManagementDomainSizingEstimate.

    Writes the compressed JSON estimate payload directly to stdout. If an error occurs during module loading,
    file reading, or estimate calculation, outputs an error message to stderr and exits with code 1.

    .PARAMETER SelectionsPath
    Path to a JSON file containing an array of component selection objects (each specifying ComponentKey,
    SizeKey, NodeCount, and StorageSizeKey).

    .OUTPUTS
    Outputs a compressed JSON string containing management domain sizing estimates to stdout.
#>

[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)] [String]$SelectionsPath
)

if ($null -ne $PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

$envModulePsd1 = ([String]$env:VCFCHECK_MODULE_PSD1).Trim()
if (-not [String]::IsNullOrWhiteSpace($envModulePsd1) -and (Test-Path -LiteralPath $envModulePsd1 -PathType Leaf)) {
    $modulePath = $envModulePsd1
} else {
    $modulePath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'VcfCheck.psd1'
}
try {
    Import-Module -Name $modulePath -Force -ErrorAction Stop
} catch {
    Write-Host "ERROR: Could not load the VcfCheck module from `"$modulePath`": $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

try {
    $selections = @(Get-Content -LiteralPath $SelectionsPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 10 -AsHashtable -ErrorAction Stop)
    $referenceData = Get-VcfCheckSizingReferenceData
    $treatmentData = Get-VcfCheckBrownfieldTreatmentData
    $result = Get-VcfCheckManagementDomainSizingEstimate -Selections $selections -ReferenceData $referenceData -TreatmentData $treatmentData
    $result | ConvertTo-Json -Depth 10 -Compress
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
