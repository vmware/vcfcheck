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
#region SizingEstimator

function Get-VcfCheckSizingReferenceData {

    <#
        .SYNOPSIS
        Loads the vCPU/RAM/Disk reference data for VCF 9.1.1 management/workload domain
        components, keyed by component then size tier.

        .DESCRIPTION
        Reads Data/Sizing/VmsSizingReferences911.json - the authoritative sizing reference
        data checked into the codebase.

        .PARAMETER Path
        Path to the reference-data JSON file. Defaults to
        Data/Sizing/VmsSizingReferences911.json under the module root.

        .OUTPUTS
        [Hashtable] component name -> { cpuCores, memoryGb, storageGb, ... } keyed by size tier.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $false)] [String]$Path
    )

    if (-not $Path) {
        $moduleRoot = Split-Path -Parent $PSScriptRoot
        $Path = Join-Path -Path $moduleRoot -ChildPath 'Data/Sizing/VmsSizingReferences911.json'
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [System.InvalidOperationException]::new("Sizing reference data not found at `"$Path`".")
    }

    Test-VcfCheckStrictJson -Path $Path

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 10 -AsHashtable -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("`"$Path`" is not valid JSON: $($_.Exception.Message)")
    }
}
function Get-VcfCheckBrownfieldTreatmentData {

    <#
        .SYNOPSIS
        Loads the per-component brownfield upgrade treatment rules used to compute the 5.2 ->
        9.1.1 worst-case resource delta.

        .DESCRIPTION
        Reads Data/Sizing/ComponentUpgradeCoexistence.json, which classifies each management/
        workload domain component as 'excluded' (in-place upgrade or post-upgrade-only, no delta
        contribution), 'netNew' (brand-new appliance, counted once), or 'temporaryDouble'
        (old and new appliance coexist during migration - currently only vCenter).

        .PARAMETER Path
        Path to the treatment-rules JSON file. Defaults to
        Data/Sizing/ComponentUpgradeCoexistence.json under the module root.

        .OUTPUTS
        [Hashtable] with a 'components' key (component name -> treatment metadata) and a
        'vcenterSizeThresholds' key (tier -> capacity/resource requirement).
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $false)] [String]$Path
    )

    if (-not $Path) {
        $moduleRoot = Split-Path -Parent $PSScriptRoot
        $Path = Join-Path -Path $moduleRoot -ChildPath 'Data/Sizing/ComponentUpgradeCoexistence.json'
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [System.InvalidOperationException]::new("Brownfield treatment data not found at `"$Path`".")
    }

    Test-VcfCheckStrictJson -Path $Path

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 10 -AsHashtable -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("`"$Path`" is not valid JSON: $($_.Exception.Message)")
    }
}
function Get-VcfCheckVCenterSizeTier {

    <#
        .SYNOPSIS
        Derives the vCenter size tier that covers a live host/VM count, per
        vcenterSizeThresholds in ComponentUpgradeCoexistence.json.

        .DESCRIPTION
        Walks the tiers in ascending order and returns the first whose maxHosts and
        maxVirtualMachines both cover the supplied counts. Falls back to the largest
        defined tier if none of them cover the counts (rather than throwing), since an
        oversized live environment should still produce a usable, if under-sized, estimate.
        Never recommends the "Tiny" tier - Broadcom scopes Tiny to proof-of-concept
        deployments only, so the smallest tier this function will return is "Small".

        .PARAMETER HostCount
        Live ESX host count against the management domain's vCenter.

        .PARAMETER VirtualMachineCount
        Live VM count against the management domain's vCenter.

        .PARAMETER TreatmentData
        Output of Get-VcfCheckBrownfieldTreatmentData.

        .OUTPUTS
        [String] the matching tier's "size" value (e.g. "Medium").
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [Int]$HostCount,
        [Parameter(Mandatory = $true)] [Int]$VirtualMachineCount,
        [Parameter(Mandatory = $true)] [Hashtable]$TreatmentData
    )

    $tiers = $TreatmentData['vcenterSizeThresholds']['tiers'] | Where-Object { $_['size'] -ne 'Tiny' }
    foreach ($tier in $tiers) {
        if ($HostCount -le $tier['maxHosts'] -and $VirtualMachineCount -le $tier['maxVirtualMachines']) {
            return $tier['size']
        }
    }

    return $tiers[-1]['size']
}
function Get-VcfCheckManagementDomainSizingEstimate {

    <#
        .SYNOPSIS
        Computes the worst-case vCPU/RAM/Disk delta needed to upgrade a management domain's
        components to VCF 9.1.1, on top of whatever the domain's cluster is already using.

        .DESCRIPTION
        For each selected component, looks up its brownfield treatment ('excluded', 'netNew', or
        'temporaryDouble'). Excluded components (in-place upgrades, or 9.1.1-only constructs that
        never coexist with anything during the transition) contribute nothing. Every other
        component contributes exactly one new appliance's worth of resources - the arithmetic is
        identical for 'netNew' and 'temporaryDouble' because the existing appliance (if any) is
        already counted in the cluster's current utilization, which this delta is meant to sit on
        top of; 'temporaryDouble' only differs in how its size is determined (derived from live
        inventory, e.g. vCenter) rather than freely chosen by the caller.

        .PARAMETER Selections
        Array of objects/hashtables, each with ComponentKey (matches a top-level key in the
        reference data and treatment data), SizeKey (matches a size tier under that component,
        case-insensitive), and optional NodeCount (defaults to 1). For a component whose
        treatment has sizeConstraint "derivedFromLiveInventoryCount" (currently only vCenter),
        SizeKey may be omitted in favor of HostCount/VirtualMachineCount, from which the tier is
        derived via Get-VcfCheckVCenterSizeTier - an explicit SizeKey always takes precedence.

        .PARAMETER ReferenceData
        Output of Get-VcfCheckSizingReferenceData.

        .PARAMETER TreatmentData
        Output of Get-VcfCheckBrownfieldTreatmentData.

        .OUTPUTS
        [PSObject] with TotalVCpu, TotalMemoryGb, TotalStorageGb, and a Components array of
        per-selection breakdown rows.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [Object[]]$Selections,
        [Parameter(Mandatory = $true)] [Hashtable]$ReferenceData,
        [Parameter(Mandatory = $true)] [Hashtable]$TreatmentData
    )

    $components = $TreatmentData['components']
    $rows = @()
    $totalVCpu = 0.0
    $totalMemoryGb = 0.0
    $totalStorageGb = 0.0

    foreach ($selection in $Selections) {
        $componentKey = $selection.ComponentKey
        $sizeKey = $selection.SizeKey
        $nodeCount = if ($selection.NodeCount) { $selection.NodeCount } else { 1 }

        if (-not $components.ContainsKey($componentKey)) {
            throw [System.InvalidOperationException]::new("Unknown sizing component `"$componentKey`" - no brownfield treatment is defined for it.")
        }
        $treatment = $components[$componentKey]['treatment']

        if (-not $sizeKey -and $components[$componentKey]['sizeConstraint'] -eq 'derivedFromLiveInventoryCount' -and $null -ne $selection.HostCount -and $null -ne $selection.VirtualMachineCount) {
            $sizeKey = Get-VcfCheckVCenterSizeTier -HostCount $selection.HostCount -VirtualMachineCount $selection.VirtualMachineCount -TreatmentData $TreatmentData
        }

        if ($treatment -eq 'excluded') {
            $rows += [PSCustomObject]@{
                ComponentKey = $componentKey
                Treatment    = $treatment
                VCpu         = 0.0
                MemoryGb     = 0.0
                StorageGb    = 0.0
            }
            continue
        }

        if ($components[$componentKey]['referenceDataMissing']) {
            throw [System.InvalidOperationException]::new("Component `"$componentKey`" has no vCPU/RAM/Disk reference data extracted yet (see ComponentUpgradeCoexistence.json's referenceDataMissing flag) - cannot include it in the estimate.")
        }
        $referenceKey = if ($components[$componentKey]['referenceKey']) { $components[$componentKey]['referenceKey'] } else { $componentKey }
        if (-not $ReferenceData.ContainsKey($referenceKey)) {
            throw [System.InvalidOperationException]::new("No sizing reference data found for component `"$componentKey`" (reference key `"$referenceKey`").")
        }
        $componentData = $ReferenceData[$referenceKey]
        $sizeKeyLower = $sizeKey.ToLowerInvariant()
        if (-not $componentData['cpuCores'].ContainsKey($sizeKeyLower)) {
            throw [System.InvalidOperationException]::new("Component `"$componentKey`" has no size tier `"$sizeKey`" in the sizing reference data.")
        }

        $vCpu = [Double]$componentData['cpuCores'][$sizeKeyLower] * $nodeCount
        $memoryGb = [Double]$componentData['memoryGb'][$sizeKeyLower] * $nodeCount

        $storageDict = $componentData['storageGb']
        $storageDictKey = @($storageDict.Keys | Where-Object { $_ -ieq $sizeKeyLower })[0]
        if (-not $storageDictKey) {
            # Some components (currently only vcenter) key storageGb by a compound
            # "<size><StorageSizeKey>" (e.g. "mediumDefault"/"mediumLStorage"/"mediumXLStorage")
            # because VCDB storage size is a second, independently-chosen dimension - see the
            # sizeConstraint note on managementDomainVcenter/workloadDomainVcenter in
            # ComponentUpgradeCoexistence.json. Defaults to "Default" when the caller doesn't
            # specify one.
            $storageSizeKey = if ($selection.StorageSizeKey) { $selection.StorageSizeKey } else { 'Default' }
            $compoundKey = "$sizeKey$storageSizeKey"
            $storageDictKey = @($storageDict.Keys | Where-Object { $_ -ieq $compoundKey })[0]
        }
        if (-not $storageDictKey) {
            throw [System.InvalidOperationException]::new("Component `"$componentKey`" has no storage size entry matching `"$sizeKey`" (or `"$sizeKey$($selection.StorageSizeKey ?? 'Default')`") in the sizing reference data.")
        }
        $storageGb = [Double]$storageDict[$storageDictKey] * $nodeCount

        $totalVCpu += $vCpu
        $totalMemoryGb += $memoryGb
        $totalStorageGb += $storageGb

        $rows += [PSCustomObject]@{
            ComponentKey = $componentKey
            Treatment    = $treatment
            SizeKey      = $sizeKeyLower
            NodeCount    = $nodeCount
            VCpu         = $vCpu
            MemoryGb     = $memoryGb
            StorageGb    = $storageGb
        }
    }

    return [PSCustomObject]@{
        TotalVCpu      = $totalVCpu
        TotalMemoryGb  = $totalMemoryGb
        TotalStorageGb = $totalStorageGb
        Components     = $rows
    }
}
function Write-VcfCheckSizingProgress {

    <#
        .SYNOPSIS
        Records the sizing-detection step currently in progress, for both the debug log and
        Start-VcfCheckServer.py's timeout handler.

        .DESCRIPTION
        Invoke-VcfCheckSizingDetect.ps1 runs as a one-shot subprocess with a fixed overall
        timeout; if it's killed for exceeding that timeout, the only trace of what it was doing
        is whatever it last logged. A slow step (e.g. a Supervisor check stuck on a failing TLS
        handshake) never gets to log its own completion, so the log alone can't say which step
        was still running when the process was killed. Writing the in-progress step to a small
        file the parent process can read after a timeout closes that gap.

        .PARAMETER Step
        Short human-readable description of the check in progress (e.g. "checking Supervisor presence").

        .PARAMETER DomainName
        Domain the step is running against.

        .PARAMETER VCenterFqdn
        vCenter FQDN the step is running against.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Step,
        [Parameter(Mandatory = $false)] [String]$DomainName,
        [Parameter(Mandatory = $false)] [String]$VCenterFqdn
    )

    Write-LogMessage -Type DEBUG -Message "Sizing detection progress: $Step (domain `"$DomainName`", vCenter `"$VCenterFqdn`")."

    $progressFilePath = $env:VCFCHECK_SIZING_PROGRESS_FILE
    if ([String]::IsNullOrWhiteSpace($progressFilePath)) {
        return
    }
    try {
        @{
            step         = $Step
            domainName   = $DomainName
            vcenterFqdn  = $VCenterFqdn
            timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $progressFilePath -Encoding UTF8 -Force
    } catch {
        Write-LogMessage -Type DEBUG -Message "Sizing detection: could not write progress file `"$progressFilePath`": $($_.Exception.Message)"
    }
}
function Get-VcfCheckSizingSnapshotForVCenter {

    <#
        .SYNOPSIS
        Gathers the live host/VM counts, Supervisor presence, and appliance sizing snapshot for
        one already-reachable vCenter, for the Upgrade Resource Estimator's live Detect feature.

        .DESCRIPTION
        Shared by the management domain and every workload domain vCenter in
        Invoke-VcfCheckSizingDetect.ps1 - the snapshot shape (current/actual/recommended tier)
        is identical regardless of which kind of domain the vCenter belongs to.

        .PARAMETER DomainName
        Name of the domain this vCenter belongs to, carried through into the snapshot for display.

        .PARAMETER VCenterFqdn
        The vCenter FQDN to gather the snapshot for. Must already be connected via
        Connect-VcfCheckVCenter.

        .PARAMETER ApplianceInventoryServers
        FQDNs of every already-connected vCenter to search for this vCenter's own appliance VM,
        in search order. VCF deploys every vCenter appliance - including workload domain ones -
        onto the management domain's cluster, so a workload domain vCenter's own appliance VM
        usually is not visible in its own inventory and must be found via the management vCenter
        instead.

        .PARAMETER TreatmentData
        Output of Get-VcfCheckBrownfieldTreatmentData.

        .OUTPUTS
        [Hashtable] the vCenter sizing snapshot: { domainName, hostCount, virtualMachineCount,
        supervisorPresent, vcenterFqdn, currentSizeTier, currentSizeMaxHosts,
        currentSizeMaxVirtualMachines, currentSizeStorageGb, actualCpuCores, actualMemoryGb,
        actualStorageGb, actualSizeTier, actualStorageSizeKey, recommendedSizeTier }.
        "actualSizeTier" is null when the appliance's own VM couldn't be identified in its
        inventory, or when its specs don't match any known tier (a non-standard/manually-resized
        appliance). "actualStorageSizeKey" is which of the VCSA deployment wizard's fixed disk
        presets ("Default", "LStorage", "XLStorage") the appliance's actual disk total matches
        for its actualSizeTier - null when actualSizeTier itself is null, or when the disk was
        customized to a size outside all three presets (VCSA does not support arbitrary disk
        sizes; see Broadcom KB326287).
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DomainName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VCenterFqdn,
        [Parameter(Mandatory = $true)] [String[]]$ApplianceInventoryServers,
        [Parameter(Mandatory = $true)] [Hashtable]$TreatmentData
    )

    Write-VcfCheckSizingProgress -Step 'reading host inventory' -DomainName $DomainName -VCenterFqdn $VCenterFqdn
    $hostCount = @(Get-VcfCheckVMHostInventory -Server $VCenterFqdn).Count

    Write-VcfCheckSizingProgress -Step 'reading virtual machine inventory' -DomainName $DomainName -VCenterFqdn $VCenterFqdn
    $virtualMachineCount = @(Get-VcfCheckVMInventory -Server $VCenterFqdn).Count

    Write-VcfCheckSizingProgress -Step 'checking Supervisor presence' -DomainName $DomainName -VCenterFqdn $VCenterFqdn
    $supervisorPresent = $false
    try {
        $supervisorClusters = @(Get-VcfCheckSupervisorCluster -Server $VCenterFqdn)
        $supervisorPresent = $supervisorClusters.Count -gt 0
    } catch {
        Write-LogMessage -Type WARNING -Message "Sizing detection: could not determine Supervisor presence on `"$VCenterFqdn`" - defaulting to not present: $($_.Exception.Message)"
    }

    $currentSizeTier = Get-VcfCheckVCenterSizeTier -HostCount $hostCount -VirtualMachineCount $virtualMachineCount -TreatmentData $TreatmentData
    $currentTierData = @($TreatmentData['vcenterSizeThresholds']['tiers'] | Where-Object { $_['size'] -eq $currentSizeTier })[0]
    $tierOrder = @($TreatmentData['vcenterSizeThresholds']['tiers'] | ForEach-Object { $_['size'] })

    # Match the vCenter appliance VM's own measured vCPU/RAM against the reference tiers to
    # report what it is actually running today, as distinct from what the live host/VM count
    # requires - a manually-resized or otherwise non-standard appliance won't match any tier.
    $actualCpuCores = $null
    $actualMemoryGb = $null
    $actualStorageGb = $null
    $actualSizeTier = $null
    $actualStorageSizeKey = $null
    Write-VcfCheckSizingProgress -Step 'identifying the vCenter appliance VM' -DomainName $DomainName -VCenterFqdn $VCenterFqdn
    try {
        $vcenterVm = $null
        foreach ($inventoryServer in $ApplianceInventoryServers) {
            $vcenterVm = @(Get-VcfCheckVMInventory -Server $inventoryServer | Where-Object { $_.Guest -and $_.Guest.HostName -and $_.Guest.HostName -ieq $VCenterFqdn }) | Select-Object -First 1
            if ($vcenterVm) {
                break
            }
        }
        if ($vcenterVm) {
            $actualCpuCores = [Int]$vcenterVm.NumCpu
            $actualMemoryGb = [Math]::Round([Double]$vcenterVm.MemoryGB, 0)
            $actualStorageGb = [Math]::Round([Double](Get-VcfCheckHardDiskInventoryForVM -VM $vcenterVm | Measure-Object -Property CapacityGB -Sum).Sum, 0)

            $vcenterRef = (Get-VcfCheckSizingReferenceData)['vcenter']
            foreach ($tierName in $tierOrder) {
                $tierKey = $tierName.ToLowerInvariant()
                if ($vcenterRef['cpuCores'][$tierKey] -eq $actualCpuCores -and $vcenterRef['memoryGb'][$tierKey] -eq $actualMemoryGb) {
                    $actualSizeTier = $tierName
                    break
                }
            }
            if (-not $actualSizeTier) {
                Write-LogMessage -Type WARNING -Message "Sizing detection: `"$VCenterFqdn`" appliance ($actualCpuCores vCPU / $actualMemoryGb GB RAM) does not match any known vCenter size tier - reporting as non-standard."
            } else {
                # The VCSA deployment wizard only ever creates one of a fixed set of disk
                # layouts per t-shirt size (Default/Large Storage/X-Large Storage) - it does not
                # support arbitrary disk sizes (see Broadcom KB326287). If the appliance's actual
                # disk total doesn't exactly match one of its own tier's presets, its disk was
                # customized outside those presets, so a "we need N GB more" delta is misleading:
                # growing it during the upgrade would actually mean moving up to the next preset.
                # Each preset's exact GB total has changed release to release (e.g. vSphere 8.0's
                # Small Default is 694 GB vs. 9.1's 734 GB), so an appliance still on an older
                # release's preset size is matched against every known release's values, not just
                # the current reference data's - otherwise a perfectly standard older appliance
                # would be wrongly reported as customized/disjoint. A disk up to 5% smaller than
                # a preset's GB total is still treated as that preset rather than "customized" -
                # thin-provisioned/rounded appliances routinely report a hair under the nominal
                # preset size without ever having been deliberately resized.
                $storageTierKey = $actualSizeTier.ToLowerInvariant()
                $storageGbSets = @($vcenterRef['storageGb'], $vcenterRef['storageGbLegacy80'])
                foreach ($presetSuffix in @('Default', 'LStorage', 'XLStorage')) {
                    if (@($storageGbSets | Where-Object {
                        $presetGb = $_[$storageTierKey + $presetSuffix]
                        $presetGb -and $actualStorageGb -le $presetGb -and $actualStorageGb -ge ($presetGb * 0.95)
                    }).Count -gt 0) {
                        $actualStorageSizeKey = $presetSuffix
                        break
                    }
                }
                if (-not $actualStorageSizeKey) {
                    Write-LogMessage -Type WARNING -Message "Sizing detection: `"$VCenterFqdn`" appliance disk ($actualStorageGb GB) does not match any `"$actualSizeTier`" storage preset (Default/Large Storage/X-Large Storage) - reporting as a customized disk size."
                }
            }
        } else {
            Write-LogMessage -Type WARNING -Message "Sizing detection: could not identify the vCenter appliance VM for `"$VCenterFqdn`" in its own inventory by guest hostname - actual appliance size cannot be determined."
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Sizing detection: could not read the vCenter appliance VM's vCPU/RAM/disk for `"$VCenterFqdn`": $($_.Exception.Message)"
    }

    # "We size to whichever offers the larger appliance" - an appliance already running bigger
    # than the live host/VM count requires (or vice versa, an undersized one) should recommend
    # upgrading to the larger of the two, not just the inventory floor.
    $recommendedSizeTier = $currentSizeTier
    if ($actualSizeTier -and [Array]::IndexOf($tierOrder, $actualSizeTier) -gt [Array]::IndexOf($tierOrder, $currentSizeTier)) {
        $recommendedSizeTier = $actualSizeTier
    }

    Write-LogMessage -Type INFO -Message "Sizing detection completed for `"$VCenterFqdn`" (domain `"$DomainName`"): hostCount=$hostCount, virtualMachineCount=$virtualMachineCount, supervisorPresent=$supervisorPresent, currentSizeTier=$currentSizeTier, actualSizeTier=$actualSizeTier, recommendedSizeTier=$recommendedSizeTier."
    return @{
        domainName                    = $DomainName
        hostCount                     = $hostCount
        virtualMachineCount           = $virtualMachineCount
        supervisorPresent             = $supervisorPresent
        vcenterFqdn                   = $VCenterFqdn
        currentSizeTier               = $currentSizeTier
        currentSizeMaxHosts           = $currentTierData['maxHosts']
        currentSizeMaxVirtualMachines = $currentTierData['maxVirtualMachines']
        currentSizeStorageGb          = $currentTierData['storageGb']
        actualCpuCores                = $actualCpuCores
        actualMemoryGb                = $actualMemoryGb
        actualStorageGb               = $actualStorageGb
        actualSizeTier                = $actualSizeTier
        actualStorageSizeKey          = $actualStorageSizeKey
        recommendedSizeTier           = $recommendedSizeTier
    }
}
