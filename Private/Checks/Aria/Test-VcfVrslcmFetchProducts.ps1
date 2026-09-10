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
function Test-VcfVrslcmFetchProducts {

    <#
        .SYNOPSIS
        Validates Aria Suite Lifecycle Manager (vRSLCM) and its registered product versions against minimum requirements.

        .DESCRIPTION
        Queries vRSLCM to retrieve appliance version and registered environment products via REST APIs:
        - System settings endpoints ('/lcm/lcops/api/settings/systemsettings', fallback to v2 or connection metadata) for vRSLCM version.
        - Environments endpoint ('/lcm/lcops/api/v2/environments') for deployed product fleet components.

        Maps raw product IDs (vrslcm, vra, vrops, etc.) to friendly display names and judges each one's
        compliance in the same priority order as Test-VcfSddcBomCheck (see New-VcfCheckBomComplianceRow):
        1. PRIMARY - Broadcom's public Interop Matrix's own real per-version-pair upgrade-path status
           (Get-VcfCheckInteropMatrixCompatibilityVerdict), for products with a known Interop Matrix
           product ID (VRA, VROPS, VRNI, VRO, VRSLCM, VRLI, VIDM). A floor comparison alone cannot see a
           release-date-based incompatibility the matrix flags even though the installed build numerically
           clears the floor.
        2. FALLBACK - a floor (>=) comparison against MinimumVersion, used when the shipped Interop
           Matrix snapshot (Data/Interoperability/*.json) has no resolvable verdict for this exact
           pair - the installed version isn't listed as a source row, or the pair isn't listed.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if Aria Suite Lifecycle Manager is not deployed in the environment.
        - Pass: Returns 'Pass' if no components are registered or all registered products meet/exceed minimum required versions.
        - Fail: Returns 'Fail' if one or more products fall below minimum version thresholds.
        - Error: Returns 'Error' if vRSLCM connection or API requests fail.

        Includes a structured table breakdown ('Rows') detailing Product, InstalledVersion,
        MinimumDirectUpgradeVersion, ReadyforUpgrade, and FailureReason (populated from the
        Interop Matrix's own footnote/support-window data when a component is not ready to
        upgrade, via Get-VcfCheckInteropMatrixFailureReason).

        One-off: when the 'vrslcm' product's own MinimumDirectUpgradeVersion floor is 9.0 or
        later, its row is forced to ReadyforUpgrade=true with FailureReason 'SDDC Manager is
        replaced by VCF Ops in VCF 9.x', overriding whatever New-VcfCheckBomComplianceRow
        otherwise decided - VMware Aria Suite Lifecycle itself is retired at that floor (its
        role is absorbed by VCF Ops), so a version mismatch against it must not block the
        upgrade.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER VcfDestinationRelease
        Same top-level destination-release selection Test-VcfSddcBomCheck accepts - a full
        concrete release (e.g. '9.1.0.0300'), a release family (major.minor.patch only, e.g.
        '9.1.0'), or 'latest'. A family or 'latest' is resolved independently per Aria product
        (via Resolve-VcfCheckInteropMatrixReleaseInFamily) to that product's own newest
        release matching the request, since each Aria Interop Matrix snapshot's releases[] are
        themselves VCF-numbered destination versions and two products can have a different
        newest one in the same family. Defaults to $Script:VcfCheckDefaultDestinationRelease
        ('latest'), the same shared default Test-VcfSddcBomCheck uses.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [PSObject] A single VcfCheck.Result object.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Renaming would break existing callers, Pester tests, and the check catalog entry keyed on this function name.')]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$VcfDestinationRelease = $Script:VcfCheckDefaultDestinationRelease,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'vrslcm_fetch_products'

    try {
        $connection = Get-VcfCheckVrslcmConnection -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    if (-not $connection) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Suite Lifecycle Manager is not deployed in this environment.' -SkipReasonTag 'vRSLCM not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $allProducts = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. Fetch vRSLCM Appliance Version using the systemsettings endpoint
    $vrslcmVersion = $null
    $systemPaths = @(
        '/lcm/lcops/api/settings/systemsettings',
        '/lcm/lcops/api/v2/settings/systemsettings'
    )

    foreach ($path in $systemPaths) {
        if ($vrslcmVersion) { break }
        try {
            $settings = Invoke-VcfCheckVrslcmApi -Connection $connection -Path $path
            if ($settings) {
                if ($settings.lcmVersion) {
                    $vrslcmVersion = $settings.lcmVersion
                } elseif ($settings.version) {
                    $vrslcmVersion = $settings.version
                } elseif ($settings.systemVersion) {
                    $vrslcmVersion = $settings.systemVersion
                }
            }
        } catch {
            Write-LogMessage -Type WARNING -Message "vRSLCM system settings query failed at $path`: $($_.Exception.Message)"
        }
    }

    # Fallback: check if the connection object established by VCF contains the version metadata
    if (-not $vrslcmVersion -and $connection) {
        if ($connection.Version) {
            $vrslcmVersion = $connection.Version
        } elseif ($connection.ProductVersion) {
            $vrslcmVersion = $connection.ProductVersion
        }
    }

    if ($vrslcmVersion) {
        $allProducts.Add([PSCustomObject]@{
            id      = 'vrslcm'
            version = $vrslcmVersion
        })
    }

    # 2. Fetch Environment Registered Products
    try {
        $environments = Invoke-VcfCheckVrslcmApi -Connection $connection -Path '/lcm/lcops/api/v2/environments'
        $envProducts = @($environments) | ForEach-Object { $_.products } | Where-Object { $_ }
        foreach ($p in $envProducts) {
            $allProducts.Add($p)
        }
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $connection.Fqdn `
            -Exception (ConvertTo-VcfCheckFriendlyVrslcmError -Fqdn $connection.Fqdn -ErrorMessage $_.Exception.Message) `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    if ($allProducts.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Pass `
            -TargetComponent $connection.Fqdn -Detail 'Aria Suite Lifecycle Manager is deployed but reports no registered fleet components.' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $productNameMap = @{
        'vrslcm' = 'VMware Aria Suite Lifecycle'
        'vidm'   = 'VMware Identity Manager'
        'vra'    = 'VMware Aria Automation'
        'vrli'   = 'VMware Aria Operations for Logs'
        'vrni'   = 'VMware Aria Operations for Networks'
        'vrops'  = 'VMware Aria Operations'
        'vro'    = 'VMware Aria Automation Orchestrator'
    }
    $interopComponentMap = @{
        'vra' = 'VRA'; 'vrni' = 'VRNI'; 'vrops' = 'VROPS'; 'vro' = 'VRO'
        'vrslcm' = 'VRSLCM'; 'vrli' = 'VRLI'; 'vidm' = 'VIDM'
    }

    $nonCompliantProducts = @()
    $interopUnverifiedProducts = @()
    $isDestinationReleaseFamily = ($VcfDestinationRelease -eq 'latest') -or ($VcfDestinationRelease -match '^\d+\.\d+\.\d+$')

    $rows = @($allProducts | ForEach-Object {
        $id = $_.id
        $friendlyName = if ($productNameMap[$id]) { $productNameMap[$id] } else { $id }
        $installedVersionStr = $_.version
        $askedInteropMatrix = $interopComponentMap.ContainsKey($id)
        $interopComponent = if ($askedInteropMatrix) { $interopComponentMap[$id] } else { $null }
        $destinationVersion = $VcfDestinationRelease
        if ($askedInteropMatrix -and $isDestinationReleaseFamily) {
            $resolvedRelease = Resolve-VcfCheckInteropMatrixReleaseInFamily -Component $interopComponent -Family $VcfDestinationRelease
            if ($resolvedRelease) { $destinationVersion = $resolvedRelease }
        }

        $interopVerdict = $null
        if ($askedInteropMatrix -and -not [String]::IsNullOrWhiteSpace($installedVersionStr)) {
            try {
                $interopVerdict = Get-VcfCheckInteropMatrixCompatibilityVerdict -Component $interopComponent -InstalledVersion $installedVersionStr -DestinationVersion $destinationVersion -ErrorAction Stop
            } catch {
                Write-LogMessage -Type WARNING -Message "Interop Matrix compatibility lookup failed for $friendlyName ($installedVersionStr -> $destinationVersion): $($_.Exception.Message)"
            }
        }
        $resolvedFloor = if ($askedInteropMatrix) { Get-VcfCheckInteropMatrixMinimumCompatibleVersion -Component $interopComponent -DestinationVersion $destinationVersion } else { $null }

        if (-not $interopVerdict -and -not $resolvedFloor) {
            if ($askedInteropMatrix) { $interopUnverifiedProducts += $friendlyName }
            [PSCustomObject]@{
                Product                     = $friendlyName
                InstalledVersion            = $installedVersionStr
                MinimumDirectUpgradeVersion = 'N/A'
                ReadyforUpgrade             = $true
                FailureReason               = 'N/A'
            }
        } else {
            # A resolved primary verdict decides compliance on its own, so a placeholder floor
            # (the installed version itself) is only ever used when $resolvedFloor is unavailable.
            $minVersionStr = if ($resolvedFloor) { $resolvedFloor } else { $installedVersionStr }
            $row = New-VcfCheckBomComplianceRow -Domain 'N/A' -Component $friendlyName -Target $connection.Fqdn `
                -InstalledVersion $installedVersionStr -MinimumVersion $minVersionStr `
                -InteropComponent $interopComponent -DestinationVersion $destinationVersion

            $minimumFloorVersion = ConvertTo-VcfCheckSimpleVersion -VersionString $resolvedFloor
            if ($id -eq 'vrslcm' -and $minimumFloorVersion -and $minimumFloorVersion -ge [Version]'9.0.0.0') {
                $row.ReadyforUpgrade = $true
                $row.FailureReason = 'SDDC Manager is replaced by VCF Ops in VCF 9.x'
            }

            if (-not $row.ReadyforUpgrade) {
                $nonCompliantProducts += "$friendlyName - $($row.FailureReason)"
            }
            if ($askedInteropMatrix -and -not $interopVerdict) {
                $interopUnverifiedProducts += $friendlyName
            }

            [PSCustomObject]@{
                Product                     = $friendlyName
                InstalledVersion            = $installedVersionStr
                MinimumDirectUpgradeVersion = if ($resolvedFloor) { $resolvedFloor } else { 'N/A' }
                ReadyforUpgrade             = $row.ReadyforUpgrade
                FailureReason               = $row.FailureReason
            }
        }
    })

    if ($nonCompliantProducts.Count -gt 0) {
        $status = 'Fail'
        $detail = "Not ready to upgrade: $($nonCompliantProducts -join '; ')"
    } else {
        $status = 'Pass'
        $detail = "Aria Suite Lifecycle and all registered products meet minimum version requirements."
    }
    if ($interopUnverifiedProducts.Count -gt 0) {
        $detail += " Could not confirm against Broadcom's Interop Matrix: $($interopUnverifiedProducts -join ', ')."
    }

    return New-VcfCheckResult -CheckId $checkId -Status $status `
        -TargetComponent $connection.Fqdn -Detail $detail -Rows $rows `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
