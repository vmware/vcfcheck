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
#region BomHelpers

function Get-VcfCheckReleaseBom {

    <#
        .SYNOPSIS
        Looks up the officially published BOM (component name -> expected version) for a VCF
        release.

        .DESCRIPTION
        Wraps Invoke-VcfGetReleases -VersionEq <Version> to retrieve the published release BOM.
        The returned Release object's .Bom property contains a list of ProductVersion objects.
        (Name/Version pairs) covering the LCM-managed BOM stack (SDDC Manager, vCenter, ESXi, NSX-T)
        vRealize/Aria components (vRSLCM, vRA, vRLI, vROPS) are excluded from this comparison.

        .PARAMETER Version
        The semantic version to look up, e.g. '5.2.2.0' (without the build-number suffix).

        .OUTPUTS
        [Hashtable] component name -> expected version string, or $null if SDDC Manager's release
        catalog has no entry for that version (e.g. a very new or unpublished build).
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Version
    )

    $releases = @((Invoke-VcfGetReleases -VersionEq $Version -ErrorAction Stop).Elements)
    $release = $releases | Select-Object -First 1
    if (-not $release) {
        return $null
    }

    $bom = @{}
    foreach ($entry in @($release.Bom)) {
        if ($entry -and -not [String]::IsNullOrWhiteSpace($entry.Name)) {
            $bom[$entry.Name] = $entry.Version
        }
    }
    return $bom
}
function Test-VcfCheckBomVersionMatch {

    <#
        .SYNOPSIS
        Compares an actual component version against a BOM-declared expected version

        .DESCRIPTION
        Tries an exact (trimmed, case-insensitive) match first; falls back to comparing just the
        build-number suffix—the trailing run of digits at the end of the string, regardless of
        what character (if any) precedes it. This distinguishes a validated BOM combination from
        out-of-band/async patches while remaining tolerant of minor "marketing version" formatting
        differences between live component reports and BOM entries.

        Extracts the build suffix via regex rather than splitting on specific separator characters,
        ensuring compatibility across varying component version string formats (e.g., period-separated
        build numbers in NSX Manager versus hyphenated versions).

        .OUTPUTS
        [Boolean]
    #>

    [CmdletBinding()]
    [OutputType([Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Actual,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Expected
    )

    if ([String]::IsNullOrWhiteSpace($Actual) -or [String]::IsNullOrWhiteSpace($Expected)) {
        return $false
    }

    $actualTrim = $Actual.Trim()
    $expectedTrim = $Expected.Trim()
    if ($actualTrim.Equals($expectedTrim, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $actualBuild = [Regex]::Match($actualTrim, '(\d+)$').Value
    $expectedBuild = [Regex]::Match($expectedTrim, '(\d+)$').Value
    if (-not [String]::IsNullOrEmpty($actualBuild) -and -not [String]::IsNullOrEmpty($expectedBuild)) {
        return $actualBuild -eq $expectedBuild
    }

    return $false
}

#endregion
