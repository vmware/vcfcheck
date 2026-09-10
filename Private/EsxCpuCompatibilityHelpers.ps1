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
#region EsxCpuCompatibilityHelpers

$Script:VcfCheckEsxCpuCompatibilityDataCache = $null

function Get-VcfCheckEsxCpuCompatibilityData {

    <#
        .SYNOPSIS
        Loads and caches the shipped Broadcom Compatibility Guide CPU series snapshot
        (Data/EsxCpu/EsxCpuCompatibility.json).

        .DESCRIPTION
        Reads a snapshot captured by InternalTools/Update-VcfEsxCpuCompatibilityData.ps1 at release-prep
        time from the public JSON API backing https://compatibilityguide.broadcom.com/search, so
        the ESX Hardware Summary check can flag likely CPU incompatibilities entirely offline.

        .OUTPUTS
        [PSObject[]] array of CPU series entries (.Series, .Vendor, .NumberPatterns,
        .SupportedEsx), or an empty array if the file is missing or fails to parse - callers
        treat that as "could not confirm," never as "not compatible."
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param ()

    if ($null -eq $Script:VcfCheckEsxCpuCompatibilityDataCache) {
        $data = @()
        $path = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path '..' -ChildPath (Join-Path -Path 'Data' -ChildPath (Join-Path -Path 'EsxCpu' -ChildPath 'EsxCpuCompatibility.json')))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $data = @(Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not parse ESX CPU compatibility data file `"$path`": $($_.Exception.Message)"
                $data = @()
            }
        } else {
            Write-LogMessage -Type WARNING -Message "No shipped ESX CPU compatibility data file found: `"$path`" not found"
        }
        $Script:VcfCheckEsxCpuCompatibilityDataCache = $data
    }

    return $Script:VcfCheckEsxCpuCompatibilityDataCache
}
function Resolve-VcfCheckEsxCpuCompatibility {

    <#
        .SYNOPSIS
        Flags whether an ESX host's reported CPU model appears on Broadcom's published server/CPU
        Hardware Compatibility Guide for a given ESX release.

        .DESCRIPTION
        Matches CpuModel against each shipped CPU series entry's vendor and generation-number
        regex fragments (see InternalTools/Update-VcfEsxCpuCompatibilityData.ps1 for how those are
        derived - this is a heuristic against a display-name grouping, not an exact per-SKU HCL
        lookup). Only ESXi 9.0/9.1 data is shipped, matching this check's scope.

        .PARAMETER CpuModel
        The CPU model string as reported by the host, e.g. "Intel(R) Xeon(R) Gold 6338 CPU @
        2.00GHz".

        .PARAMETER EsxVersion
        The ESX release family to check against, e.g. '9.0' or '9.1'.

        .OUTPUTS
        [PSObject] with .Status ('Compatible', 'NotListed', or 'Unknown') and .MatchedSeries (the
        matched series display name, or $null). 'NotListed' means no shipped series matched -
        this may be a genuinely unsupported CPU, or one this heuristic's regexes do not yet
        recognize; it is not a certified verdict. 'Unknown' means CpuModel was empty, EsxVersion
        is outside the shipped 9.0/9.1 data, or no compatibility data could be loaded.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$CpuModel,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxVersion
    )

    $unknown = [PSCustomObject]@{ Status = 'Unknown'; MatchedSeries = $null }
    if ([String]::IsNullOrWhiteSpace($CpuModel)) { return $unknown }

    $esxFamily = [Regex]::Match($EsxVersion, '^\d+\.\d+').Value
    if ([String]::IsNullOrEmpty($esxFamily)) { return $unknown }

    $data = @(Get-VcfCheckEsxCpuCompatibilityData)
    if ($data.Count -eq 0) { return $unknown }

    $applicableEntries = @($data | Where-Object { $_.SupportedEsx -contains $esxFamily })
    if ($applicableEntries.Count -eq 0) { return $unknown }

    foreach ($entry in $applicableEntries) {
        if ($CpuModel -notmatch [Regex]::Escape($entry.Vendor)) { continue }
        foreach ($numberPattern in @($entry.NumberPatterns)) {
            if ($CpuModel -match $numberPattern) {
                return [PSCustomObject]@{ Status = 'Compatible'; MatchedSeries = $entry.Series }
            }
        }
    }

    return [PSCustomObject]@{ Status = 'NotListed'; MatchedSeries = $null }
}
$Script:VcfCheckEsxCpuDeprecationDataCache = $null

function Get-VcfCheckEsxCpuDeprecationData {

    <#
        .SYNOPSIS
        Loads and caches the shipped CPU deprecation/discontinuation snapshot
        (Data/EsxCpu/EsxCpuDeprecation.json).

        .DESCRIPTION
        Reads a hand-curated snapshot of Broadcom KB 318697 ("CPU Support Deprecation and
        Discontinuation in VCF Releases"), so the ESX Hardware Summary check can flag a CPU
        that is on the removal track even when it still passes the separate server/CPU
        Hardware Compatibility Guide check. Unlike Data/EsxCpu/EsxCpuCompatibility.json, this snapshot
        is scraped from an HTML knowledge base article rather than a stable JSON API, so it must
        be re-verified against https://knowledge.broadcom.com/external/article/318697 by hand
        whenever Broadcom updates that page - there is no maintainer tool for it.

        .OUTPUTS
        [PSObject[]] array of entries (.Series, .Vendor, .NumberPatterns, .Status,
        .DiscontinuedFromEsx), or an empty array if the file is missing or fails to parse -
        callers treat that as "could not confirm," never as "not deprecated."
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param ()

    if ($null -eq $Script:VcfCheckEsxCpuDeprecationDataCache) {
        $data = @()
        $path = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path '..' -ChildPath (Join-Path -Path 'Data' -ChildPath (Join-Path -Path 'EsxCpu' -ChildPath 'EsxCpuDeprecation.json')))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $data = @(Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not parse ESX CPU deprecation data file `"$path`": $($_.Exception.Message)"
                $data = @()
            }
        } else {
            Write-LogMessage -Type WARNING -Message "No shipped ESX CPU deprecation data file found: `"$path`" not found"
        }
        $Script:VcfCheckEsxCpuDeprecationDataCache = $data
    }

    return $Script:VcfCheckEsxCpuDeprecationDataCache
}
function Resolve-VcfCheckEsxCpuDeprecationStatus {

    <#
        .SYNOPSIS
        Flags whether an ESX host's reported CPU is on Broadcom's published CPU support
        deprecation/discontinuation track for VCF 9.x, independently of whether that CPU is
        still listed on the server/CPU Hardware Compatibility Guide.

        .DESCRIPTION
        Matches CpuModel against each shipped deprecation entry's vendor and model-number regex
        fragments (see Data/EsxCpu/EsxCpuDeprecation.json, curated from Broadcom KB 318697). A CPU can
        be both "Compatible" on the Hardware Compatibility Guide and "Deprecated" or
        "Discontinued" here at the same time - these are two independent Broadcom data sources.

        A small number of entries only become Discontinued starting at a later ESX release
        (DiscontinuedFromEsx); for an EsxVersion earlier than that threshold, this function
        reports 'Deprecated' instead of 'Discontinued' for those entries.

        .PARAMETER CpuModel
        The CPU model string as reported by the host, e.g. "Intel(R) Xeon(R) CPU E3-1230 v6 @
        3.50GHz".

        .PARAMETER EsxVersion
        The ESX release family to check against, e.g. '9.0', '9.1', or '9.2'.

        .OUTPUTS
        [PSObject] with .Status ('None', 'Deprecated', 'Discontinued', or 'Unknown') and
        .MatchedSeries (the matched series display name, or $null). 'Unknown' means CpuModel was
        empty or no deprecation data could be loaded.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$CpuModel,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxVersion
    )

    $unknown = [PSCustomObject]@{ Status = 'Unknown'; MatchedSeries = $null }
    if ([String]::IsNullOrWhiteSpace($CpuModel)) { return $unknown }

    $data = @(Get-VcfCheckEsxCpuDeprecationData)
    if ($data.Count -eq 0) { return $unknown }

    $esxFamily = [Regex]::Match($EsxVersion, '^\d+\.\d+').Value
    if ([String]::IsNullOrEmpty($esxFamily)) { $esxFamily = '0.0' }

    foreach ($entry in $data) {
        if ($CpuModel -notmatch [Regex]::Escape($entry.Vendor)) { continue }
        $matched = $false
        foreach ($numberPattern in @($entry.NumberPatterns)) {
            if ($CpuModel -match $numberPattern) { $matched = $true; break }
        }
        if (-not $matched) { continue }

        $status = $entry.Status
        if ($status -eq 'Discontinued' -and -not [String]::IsNullOrEmpty($entry.DiscontinuedFromEsx)) {
            if ([Version]$esxFamily -lt [Version]$entry.DiscontinuedFromEsx) { $status = 'Deprecated' }
        }
        return [PSCustomObject]@{ Status = $status; MatchedSeries = $entry.Series }
    }

    return [PSCustomObject]@{ Status = 'None'; MatchedSeries = $null }
}

#endregion
