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
function Test-VcfVsanHclCompliance {

    <#
        .SYNOPSIS
        Flags any ESX host storage controller or NIC that is not on Broadcom's published vSAN
        Hardware Compatibility List (HCL) for the target VCF upgrade release.

        .DESCRIPTION
        For every ESX host across all vCenters managed by SDDC Manager, matches each storage
        controller's and NIC's PCI VendorId/DeviceId/SubVendorId/SubDeviceId against the shipped
        vSAN HCL snapshot (see Resolve-VcfCheckVsanHclCompatibility), and each SSD/HDD drive
        against the shipped drive HCL snapshot by PCI identity when available or reported model
        string otherwise (see Resolve-VcfCheckVsanHclDriveCompatibility and
        Get-VcfCheckVsanHclDriveHbaPciIdentity - only NVMe drives carry a PCI identity of their
        own, since an NVMe drive is its own PCIe endpoint; SAS/SATA drives sit behind a shared HBA
        and are matched on model string alone), for the target ESX release being
        upgraded to (VcfDestinationRelease), not the host's currently-installed release - this is
        a pre-upgrade readiness check, and the shipped HCL snapshots only carry data for ESXi
        9.0/9.1, so resolving against an older installed release would report every component as
        unconfirmed. NICs additionally match on driver name/version/firmware, since that data is
        available for NICs but not for storage adapters (see Get-VcfCheckVMHostStorageAdapters).

        Reports 'Fail' for a vCenter domain if any host has a component currently in use by vSAN
        (CurrentlyUsedByvSAN) whose PCI identity is not found anywhere in the shipped HCL data
        ('NotListed'), whose driver/firmware combination does not appear on the HCL for an
        otherwise-matched component ('FirmwareUnsupported'), or that is certified on the HCL only
        for an ESX release older than the target upgrade release ('IncompatibleWithTargetRelease' - see
        Resolve-VcfCheckVsanHclOlderFamily). A component not currently backing vSAN can't cause a
        vSAN upgrade problem, so its status never affects the check's outcome - it's still reported
        (see Get-VcfCheckVsanHclHostDetail's Components/CurrentlyUsedByvSAN), just not counted
        towards NotListedComponents/FirmwareUnsupportedComponents/IncompatibleWithTargetReleaseComponents.
        Components that could not be evaluated at all (no shipped HCL data for the target or any
        older ESX release, or a missing PCI identity) are treated as 'Unknown' and do not affect
        the check's status, mirroring how Test-VcfEsxHardwareDetails treats an unevaluable CPU.
        Reports 'Pass' if every in-use component is confirmed compatible or could not be
        evaluated, or 'Error' if no hosts are found, a vCenter connection fails, or an execution
        error occurs.

        Reuses the per-run device cache shared with Test-VcfEsxHardwareDetails
        (Get-VcfCheckCachedHostHardwareDetail) so both checks never pay for the expensive
        per-host esxcli collection independently.

        .PARAMETER Context
        The VcfCheck.Context object. Must be connected to SDDC Manager.

        .PARAMETER VcfDestinationRelease
        Same top-level destination-release selection Test-VcfSddcBomCheck accepts - a full
        concrete release, a release family (major.minor.patch), or 'latest'. A family or 'latest'
        is resolved to ESX's own newest matching release via
        Resolve-VcfCheckInteropMatrixReleaseInFamily, and only that release's major.minor family
        (e.g. '9.1') is used to select the shipped HCL data. Defaults to
        $Script:VcfCheckDefaultDestinationRelease ('latest').

        .PARAMETER DisplayName
        Optional display name for the check. If omitted, defaults to the display name specified in
        the precheck catalog entry for 'vsan_hcl_compliance'.

        .PARAMETER MaxConcurrentHosts
        Maximum number of hosts per vCenter collected concurrently (ForEach-Object -Parallel -
        each host's esxcli/PowerCLI collection is an independent per-host round trip, so this is
        the only cross-host resource contention). Defaults to 10. A single host's own connection
        to vCenter is established inside its own runspace via Connect-VcfCheckVCenter, since
        PowerCLI's ambient $global:DefaultVIServers session state does not cross runspace
        boundaries. A value of 1 collects hosts sequentially in the caller's own runspace instead
        - Pester's Mock cannot see into a separate -Parallel runspace (each one re-imports the
        module fresh), so tests exercising per-host mock behavior pass -MaxConcurrentHosts 1.
        Write-VcfCheckSubProgress's Current/Total still count accurately with concurrent
        collection (a synchronized counter incremented once per completed host), but Label names
        whichever host most recently finished, not a batch - up to MaxConcurrentHosts hosts are
        being collected at any moment, so the browser UI's "Scanning N/Total hosts (<label>)" line
        advances in completion order, not host-list order.

        .OUTPUTS
        [PSObject[]] Array of per-domain check result objects created by New-VcfCheckPerDomainResults.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$VcfDestinationRelease = $Script:VcfCheckDefaultDestinationRelease,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateRange(1, 100)] [Int]$MaxConcurrentHosts = 10
    )

    $startedAt = Get-Date
    $checkId = 'vsan_hcl_compliance'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }
    $validationCriteria = $catalogEntry.validationCriteria

    $targetEsxVersion = $VcfDestinationRelease
    $isDestinationReleaseFamily = ($VcfDestinationRelease -eq 'latest') -or ($VcfDestinationRelease -match '^\d+\.\d+\.\d+$')
    if ($isDestinationReleaseFamily) {
        $resolvedRelease = Resolve-VcfCheckInteropMatrixReleaseInFamily -Component 'ESX' -Family $VcfDestinationRelease
        if ($resolvedRelease) { $targetEsxVersion = $resolvedRelease }
    }

    try {
        $vcenterFqdns = Get-VcfCheckAllVCenterFqdns -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Area vSAN -Status Error `
            -Exception $_.Exception.Message -ValidationCriteria $validationCriteria -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $outcomes = foreach ($vcenterFqdn in $vcenterFqdns) {
        $iterationStartedAt = Get-Date
        $outcome = try {
            Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
            $hosts = @(Get-VcfCheckVMHostInventory -Server $vcenterFqdn)

            if ($hosts.Count -eq 0) {
                [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = 'No ESX hosts found.'; HostDetails = @(); HostDetailsLabel = 'Hosts' }
            } else {
                if ($MaxConcurrentHosts -le 1) {
                    $hostIndex = 0
                    $hostDetails = @($hosts | ForEach-Object {
                        $hostIndex++
                        Write-VcfCheckSubProgress -Context $Context -Current $hostIndex -Total $hosts.Count -Label $_.Name
                        Get-VcfCheckVsanHclHostDetail -VMHost $_ -Context $Context -EsxVersion $targetEsxVersion
                    })
                } else {
                    $vcfCheckModulePath = (Get-Module -Name VcfCheck).Path
                    $progressCounter = [Hashtable]::Synchronized(@{ Current = 0 })
                    $totalHostCount = $hosts.Count
                    $hostDetails = @($hosts | ForEach-Object -ThrottleLimit $MaxConcurrentHosts -Parallel {
                        $vmHost = $_
                        $context = $using:Context
                        $esxVersion = $using:targetEsxVersion
                        $fqdn = $using:vcenterFqdn
                        $counter = $using:progressCounter
                        $totalHosts = $using:totalHostCount

                        Import-Module -Name $using:vcfCheckModulePath -Force
                        Connect-VcfCheckVCenter -Context $context -Fqdn $fqdn

                        $detail = Get-VcfCheckVsanHclHostDetail -VMHost $vmHost -Context $context -EsxVersion $esxVersion

                        [System.Threading.Monitor]::Enter($counter)
                        try {
                            $counter.Current++
                            Write-VcfCheckSubProgress -Context $context -Current $counter.Current -Total $totalHosts -Label $vmHost.Name
                        } finally {
                            [System.Threading.Monitor]::Exit($counter)
                        }

                        $detail
                    })
                }

                $sortedHostDetails = @($hostDetails | Sort-Object -Property `
                    @{ Expression = { if ($_.NotListedComponents.Count -gt 0 -or $_.FirmwareUnsupportedComponents.Count -gt 0 -or $_.IncompatibleWithTargetReleaseComponents.Count -gt 0) { 0 } else { 1 } } }, HostName)

                $notListedHosts = @($sortedHostDetails | Where-Object { $_.NotListedComponents.Count -gt 0 })
                $unsupportedHosts = @($sortedHostDetails | Where-Object { $_.FirmwareUnsupportedComponents.Count -gt 0 })
                $incompatibleHosts = @($sortedHostDetails | Where-Object { $_.IncompatibleWithTargetReleaseComponents.Count -gt 0 })

                $detail = "Successfully checked vSAN HCL compliance for $($hostDetails.Count) host$(if ($hostDetails.Count -ne 1) { 's' }) against ESX $targetEsxVersion."
                $status = 'Pass'
                if ($notListedHosts.Count -gt 0) {
                    $status = 'Fail'
                    $detail += " $($notListedHosts.Count) host$(if ($notListedHosts.Count -ne 1) { 's' }) with a storage controller or NIC not found on the vSAN Hardware Compatibility List: $(($notListedHosts | ForEach-Object { $_.HostName }) -join ', ')."
                }
                if ($unsupportedHosts.Count -gt 0) {
                    $status = 'Fail'
                    $detail += " $($unsupportedHosts.Count) host$(if ($unsupportedHosts.Count -ne 1) { 's' }) with a NIC driver/firmware combination not on the vSAN Hardware Compatibility List: $(($unsupportedHosts | ForEach-Object { $_.HostName }) -join ', ')."
                }
                if ($incompatibleHosts.Count -gt 0) {
                    $status = 'Fail'
                    $detail += " $($incompatibleHosts.Count) host$(if ($incompatibleHosts.Count -ne 1) { 's' }) with a storage controller, NIC, or drive certified on the vSAN Hardware Compatibility List only for an ESX release older than $targetEsxVersion - verify with the vendor before upgrading: $(($incompatibleHosts | ForEach-Object { $_.HostName }) -join ', ')."
                }

                [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = $status; Detail = $detail; HostDetails = $sortedHostDetails; HostDetailsLabel = 'Hosts' }
            }
        } catch {
            [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = $_.Exception.Message; HostDetails = @(); HostDetailsLabel = 'Hosts' }
        }
        $outcome | Add-Member -NotePropertyName StartedAt -NotePropertyValue $iterationStartedAt -Force
        $outcome | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date) -Force
        $outcome
    }

    return New-VcfCheckPerDomainResults -Context $Context -PerVCenterOutcome $outcomes -CheckId $checkId `
        -StartedAt $startedAt
}
function Get-VcfCheckVsanHclHostDetail {

    <#
        .SYNOPSIS
        Resolves vSAN HCL compliance for a single ESX host's storage controllers and NICs.

        .DESCRIPTION
        Reads the host's network/storage adapter PCI identities and drives from the per-run
        device cache (Get-VcfCheckCachedHostHardwareDetail) and matches each one against the
        shipped vSAN HCL snapshots via Resolve-VcfCheckVsanHclCompatibility /
        Resolve-VcfCheckVsanHclDriveCompatibility, using the target upgrade ESX version
        (EsxVersion) rather than the host's own installed version, since the shipped HCL data
        only covers the upgrade destination releases. NICs are matched including driver
        name/version/firmware; storage adapters are matched on PCI identity only, since no
        firmware version is available for them (see Get-VcfCheckVMHostStorageAdapters). An NVMe
        drive is its own PCIe endpoint and so is also enumerated as a single-LUN storage adapter -
        those synthetic entries are excluded from storageComponents (matched via Drive.HbaName)
        so the drive isn't evaluated twice under two different PCI-derived identities. Drives are
        matched on PCI identity when the drive is NVMe (see Get-VcfCheckVsanHclDriveHbaPciIdentity)
        or reported model string otherwise, plus firmware revision. Each component row also
        carries CurrentlyUsedByvSAN: for drives, resolved against the host's vSAN disk group
        inventory (see Get-VcfCheckVsanHclHostMemberDiskCanonicalNames); for network adapters and
        storage controllers, resolved against the host's live vSAN traffic/controller usage (see
        Get-VcfCheckVsanHclHostInUseDeviceNames).

        .PARAMETER VMHost
        A VMHost inventory object retrieved via Get-VcfCheckVMHostInventory.

        .PARAMETER Context
        The VcfCheck.Context object, used to read the shared per-host device cache.

        .PARAMETER EsxVersion
        The target ESX release being upgraded to (e.g. '9.1.0.0300'), resolved by the caller from
        VcfDestinationRelease. Only the major.minor family is used to select shipped HCL data.

        .OUTPUTS
        [PSCustomObject] with HostName, ClusterName, Components (per-component verdicts, grouped
        by DeviceType/Vendor/Model/Status via Group-VcfCheckVsanHclComponentsByModel for display -
        includes hardware not currently used by vSAN), NotListedComponents,
        FirmwareUnsupportedComponents, and IncompatibleWithTargetReleaseComponents (all three ungrouped,
        filtered by Status from the per-device verdicts and restricted to CurrentlyUsedByvSAN
        components only - these three drive the check's Fail status, so hardware not backing vSAN
        today never fails the check).
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxVersion
    )

    $cachedDeviceDetail = Get-VcfCheckCachedHostHardwareDetail -Context $Context -VMHost $VMHost
    $vsanMemberDiskNames = @(Get-VcfCheckVsanHclHostMemberDiskCanonicalNames -Context $Context -VMHost $VMHost)
    $inUseDeviceNames = Get-VcfCheckVsanHclHostInUseDeviceNames -Context $Context -VMHost $VMHost

    $networkComponents = @($cachedDeviceDetail.NetworkAdapters | ForEach-Object {
        $verdict = Resolve-VcfCheckVsanHclCompatibility -VendorId $_.VendorId -DeviceId $_.DeviceId `
            -SubVendorId $_.SubVendorId -SubDeviceId $_.SubDeviceId -EsxVersion $EsxVersion `
            -DriverName $_.Driver -DriverVersion $_.DriverVersion -FirmwareVersion $_.FirmwareVersion
        [PSCustomObject]@{ Name = $_.Name; DeviceType = 'Network'; Vendor = $_.Vendor; Model = $_.Model; Status = $verdict.Status; SupportedVsanTypes = $verdict.SupportedVsanTypes; LatestCompatibleRelease = $verdict.LatestCompatibleRelease; CurrentlyUsedByvSAN = ($inUseDeviceNames.NetworkAdapterNames -contains $_.Name) }
    })

    $nvmeDriveHbaNames = @($cachedDeviceDetail.Drives | Where-Object { "$($_.Type)" -like 'NVMe *' } | ForEach-Object { $_.HbaName })
    $storageComponents = @($cachedDeviceDetail.StorageAdapters | Where-Object { $nvmeDriveHbaNames -notcontains $_.Name } | ForEach-Object {
        $verdict = Resolve-VcfCheckVsanHclCompatibility -VendorId $_.VendorId -DeviceId $_.DeviceId `
            -SubVendorId $_.SubVendorId -SubDeviceId $_.SubDeviceId -EsxVersion $EsxVersion
        [PSCustomObject]@{ Name = $_.Name; DeviceType = $_.Type; Vendor = $_.Vendor; Model = $_.Model; Status = $verdict.Status; SupportedVsanTypes = $verdict.SupportedVsanTypes; LatestCompatibleRelease = $verdict.LatestCompatibleRelease; CurrentlyUsedByvSAN = ($inUseDeviceNames.ControllerNames -contains $_.Name) }
    })

    $driveComponents = @($cachedDeviceDetail.Drives | ForEach-Object {
        $pciIdentity = Get-VcfCheckVsanHclDriveHbaPciIdentity -Drive $_ -StorageAdapters $cachedDeviceDetail.StorageAdapters
        $verdict = Resolve-VcfCheckVsanHclDriveCompatibility -Model $_.Model -Vendor $_.Vendor -EsxVersion $EsxVersion -FirmwareRevision $_.Revision `
            -VendorId $pciIdentity.VendorId -DeviceId $pciIdentity.DeviceId -SubVendorId $pciIdentity.SubVendorId -SubDeviceId $pciIdentity.SubDeviceId
        [PSCustomObject]@{ Name = $_.Name; DeviceType = $_.Type; Vendor = $_.Vendor; Model = $_.Model; Status = $verdict.Status; SupportedVsanTypes = $verdict.SupportedVsanTypes; LatestCompatibleRelease = $verdict.LatestCompatibleRelease; CurrentlyUsedByvSAN = ($vsanMemberDiskNames -contains $_.Name) }
    })

    $components = @($networkComponents) + @($storageComponents) + @($driveComponents)

    $cluster = $null
    try {
        if ($VMHost.Parent -and $VMHost.Parent.Name) {
            $cluster = $VMHost.Parent.Name
        } elseif ($VMHost.ExtensionData.Parent -and $VMHost.ExtensionData.Parent.Name) {
            $cluster = $VMHost.ExtensionData.Parent.Name
        }
    } catch {
        $cluster = $null
    }

    return [PSCustomObject]@{
        HostName                       = $VMHost.Name
        ClusterName                    = $cluster
        Components                     = Group-VcfCheckVsanHclComponentsByModel -Components $components
        NotListedComponents            = @($components | Where-Object { $_.Status -eq 'NotListed' -and $_.CurrentlyUsedByvSAN } | Select-Object -ExcludeProperty SupportedVsanTypes -Property *)
        FirmwareUnsupportedComponents  = @($components | Where-Object { $_.Status -eq 'FirmwareUnsupported' -and $_.CurrentlyUsedByvSAN } | Select-Object -ExcludeProperty SupportedVsanTypes -Property *)
        IncompatibleWithTargetReleaseComponents = @($components | Where-Object { $_.Status -eq 'IncompatibleWithTargetRelease' -and $_.CurrentlyUsedByvSAN } | Select-Object -ExcludeProperty SupportedVsanTypes -Property *)
    }
}
