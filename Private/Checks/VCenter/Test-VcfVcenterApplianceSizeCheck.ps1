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
#region VCenterApplianceSizeCheck
function Get-VcfCheckVCenterApplianceUpgradeApiSteps {

    <#
        .SYNOPSIS
        Returns the fixed-width, numbered SDDC Manager API call sequence for resizing a vCenter
        appliance's disk tier during an upgrade.

        .DESCRIPTION
        VCSA does not support arbitrary disk sizes (Broadcom KB326287) - moving a vCenter
        appliance to a larger disk preset can only be done as part of an SDDC Manager API driven
        vCenter upgrade (Reduced Downtime Migration), never in place. This is the same call
        sequence documented for the Upgrade Resource Estimator in Docs/SIZING_ESTIMATOR_TODO.md.

        .OUTPUTS
        [String] the numbered steps, one per line.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    return @(
        '1. GET /v1/domains - determine the domain ID for the domain in question.'
        '2. GET /v1/upgradables/domains/{domainId} - check what''s upgradable for the domain.'
        '3. GET /v1/upgradables/domains/{domainId}/vcenter-upgrade-mechanisms - determine whether InPlace or ReducedDowntimeMigration (RDU) is eligible for this vCenter. Size selection only matters for the RDU path.'
        '4. GET /v1/upgradables/domains/{domainId}/vcenter-sizing-infos?targetVersion=<version> - fetch available applianceSize/storageSize combos with isRecommended and resource-requirement fields; select the next larger storageSize than the appliance''s current preset.'
        '5. POST /v1/upgrades with UpgradeSpec.draftMode = true - stages the upgrade without executing, so it can be precheck''d first.'
        '6. POST /v1/upgrades/{upgradeId}/prechecks - kicks off precheck validation, returns a Task.'
        '7. GET /v1/upgrades/{upgradeId}/prechecks/{precheckId} - poll until precheck completes.'
        '8. PATCH /v1/upgrades/{upgradeId} - commits the DRAFT upgrade to SCHEDULED, actually running it. Alternatively, skip draft mode entirely and call POST /v1/upgrades once with resourceUpgradeSpecs[].upgradeNow: true to run immediately, with no separate precheck/commit step.'
        '9. GET /v1/upgrades/{upgradeId} or GET /v1/tasks/{id} - poll status.'
        ''
        'The sizing choice is carried in vcenterUpgradeUserInputSpecs[].targetVcenterAppliance (applianceSize, storageSize), alongside upgradeMechanism, switchoverType, and a required temporaryNetwork (a temporary IP is needed during appliance switchover).'
    ) -join "`n"
}
function Get-VcfCheckVCenterApplianceSizeEvaluation {

    <#
        .SYNOPSIS
        Evaluates a vCenter appliance sizing snapshot for undersizing and disjoint disk conditions.

        .DESCRIPTION
        Reuses Get-VcfCheckSizingSnapshotForVCenter's output (recommendedSizeTier, actualSizeTier,
        actualStorageSizeKey) to decide the Status/Detail/Rows for Test-VcfVcenterApplianceSizeCheck.

        Undersized (recommendedSizeTier ranks above actualSizeTier - the appliance is currently
        running smaller than its live host/VM count now calls for): non-blocking, since
        Get-VcfCheckSizingSnapshotForVCenter never recommends a tier below the appliance's actual
        size, this only ever suggests sizing up.

        Disjoint disk (actualStorageSizeKey is null - the appliance's measured disk, even allowing
        the existing 5% thin-provisioning tolerance, does not match any of its tier's VCSA disk
        presets): blocking, since it requires an SDDC Manager API driven vCenter upgrade to move to
        the next disk preset rather than an in-place resize.

        .PARAMETER Snapshot
        Output of Get-VcfCheckSizingSnapshotForVCenter.

        .PARAMETER ReferenceData
        Output of Get-VcfCheckSizingReferenceData.

        .OUTPUTS
        [PSObject] with Status, Detail, and Rows.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [Hashtable]$Snapshot,
        [Parameter(Mandatory = $true)] [Hashtable]$ReferenceData
    )

    $vcenterFqdn = $Snapshot['vcenterFqdn']
    if (-not $Snapshot['actualSizeTier']) {
        return [PSCustomObject]@{ Status = 'Skipped'; Detail = "Could not determine `"$vcenterFqdn`"'s actual VCSA appliance size tier from its measured vCPU/RAM - cannot evaluate its sizing."; SkipReasonTag = 'Appliance size undetermined'; Rows = @() }
    }

    $isUndersized = $Snapshot['recommendedSizeTier'] -ne $Snapshot['actualSizeTier']
    $isDisjointDisk = -not $Snapshot['actualStorageSizeKey']

    if (-not $isUndersized -and -not $isDisjointDisk) {
        return [PSCustomObject]@{ Status = 'Pass'; Detail = "`"$vcenterFqdn`" is sized `"$($Snapshot['actualSizeTier'])`" ($($Snapshot['actualCpuCores']) vCPU, $($Snapshot['actualMemoryGb']) GB RAM, $($Snapshot['actualStorageGb']) GB disk) with a standard `"$($Snapshot['actualStorageSizeKey'])`" disk preset for its live host/VM inventory ($($Snapshot['hostCount']) hosts / $($Snapshot['virtualMachineCount']) VMs)."; Rows = @() }
    }

    $vcenterRef = $ReferenceData['vcenter']
    $rows = @()
    $detailParts = @()

    if ($isUndersized) {
        $recommendedTierKey = $Snapshot['recommendedSizeTier'].ToLowerInvariant()
        $recommendedVCpu = $vcenterRef['cpuCores'][$recommendedTierKey]
        $recommendedMemoryGb = $vcenterRef['memoryGb'][$recommendedTierKey]
        $recommendedStorageGb = $vcenterRef['storageGb']["$($recommendedTierKey)Default"]
        $rows += [PSCustomObject]@{
            Condition            = 'Undersized'
            CurrentSizeTier      = $Snapshot['actualSizeTier']
            CurrentVCpu          = $Snapshot['actualCpuCores']
            CurrentMemoryGb      = $Snapshot['actualMemoryGb']
            CurrentStorageGb     = $Snapshot['actualStorageGb']
            RecommendedSizeTier  = $Snapshot['recommendedSizeTier']
            RecommendedVCpu      = $recommendedVCpu
            RecommendedMemoryGb  = $recommendedMemoryGb
            RecommendedStorageGb = $recommendedStorageGb
        }
        $detailParts += "`"$vcenterFqdn`" is sized `"$($Snapshot['actualSizeTier'])`" ($($Snapshot['actualCpuCores']) vCPU, $($Snapshot['actualMemoryGb']) GB RAM, $($Snapshot['actualStorageGb']) GB disk; $($Snapshot['hostCount']) hosts / $($Snapshot['virtualMachineCount']) VMs under management), which calls for at least `"$($Snapshot['recommendedSizeTier'])`" ($recommendedVCpu vCPU, $recommendedMemoryGb GB RAM, $recommendedStorageGb GB disk with Standard Storage). This is a suggestion only - when it's time for upgrade, we recommend manually resizing the appliance to `"$($Snapshot['recommendedSizeTier'])`" via the SDDC Manager API."
    }

    if ($isDisjointDisk) {
        $rows += [PSCustomObject]@{
            Condition       = 'Disjoint Disk'
            ActualSizeTier  = $Snapshot['actualSizeTier']
            ActualVCpu      = $Snapshot['actualCpuCores']
            ActualMemoryGb  = $Snapshot['actualMemoryGb']
            ActualStorageGb = $Snapshot['actualStorageGb']
        }
        $detailParts += "`"$vcenterFqdn`" appliance ($($Snapshot['actualCpuCores']) vCPU, $($Snapshot['actualMemoryGb']) GB RAM, $($Snapshot['actualStorageGb']) GB disk) does not match any `"$($Snapshot['actualSizeTier'])`" VCSA disk preset (Default/Large Storage/X-Large Storage), even allowing the standard 5% thin-provisioning tolerance. VCSA does not support arbitrary disk sizes - this bumps the appliance to the next disk tier and blocks the upgrade until performed via an SDDC Manager API driven vCenter upgrade:`n`n$(Get-VcfCheckVCenterApplianceUpgradeApiSteps)"
    }

    $status = if ($isDisjointDisk) { 'Fail' } else { 'Warning' }
    return [PSCustomObject]@{ Status = $status; Detail = ($detailParts -join "`n`n"); Rows = $rows }
}
function Test-VcfVcenterApplianceSizeCheck {

    <#
        .SYNOPSIS
        Evaluates whether each vCenter appliance is correctly sized for its live host/VM inventory
        and its VCSA disk preset.

        .DESCRIPTION
        Reuses the Upgrade Resource Estimator's sizing snapshot (Get-VcfCheckSizingSnapshotForVCenter)
        for every vCenter attached to SDDC Manager:
        - Undersized appliance: non-blocking Warning suggesting a manual resize to the recommended
          size tier at upgrade time, with that tier's vCPU/RAM/disk requirements. Never suggests
          sizing down - the appliance's own actual tier is always the floor.
        - Disjoint disk (measured disk doesn't match any VCSA disk preset for its size tier):
          blocking Fail requiring an SDDC Manager API driven vCenter upgrade to the next disk tier.

        Delegates execution across vCenter domains to Invoke-VcfCheckPerVCenterCheck.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [PSObject[]] Per-vCenter check results generated by Invoke-VcfCheckPerVCenterCheck.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    return Invoke-VcfCheckPerVCenterCheck -Context $Context -CheckId 'vcenter_appliance_size_check' -Area vCenter -DisplayName $DisplayName -Body {
        param($Context, $VCenterFqdn)

        $domainName = Get-VcfCheckVCenterDomainName -Context $Context -Fqdn $VCenterFqdn
        $managementVCenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        $applianceInventoryServers = @($managementVCenterFqdn, $VCenterFqdn) | Select-Object -Unique
        $treatmentData = Get-VcfCheckBrownfieldTreatmentData
        $snapshot = Get-VcfCheckSizingSnapshotForVCenter -DomainName $domainName -VCenterFqdn $VCenterFqdn -ApplianceInventoryServers $applianceInventoryServers -TreatmentData $treatmentData

        return Get-VcfCheckVCenterApplianceSizeEvaluation -Snapshot $snapshot -ReferenceData (Get-VcfCheckSizingReferenceData)
    }
}
