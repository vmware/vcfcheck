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
function Test-VcfEsxHardwareDetails {

    <#
        .SYNOPSIS
        Reports hardware details (server, CPU, boot mode, network adapters, storage adapters, SCSI devices)
        for every ESX host across all vCenters managed by SDDC Manager.

        .DESCRIPTION
        Gathers hardware inventory (BIOS version, vendor, model, boot mode, CPU, network/storage
        adapters, and SCSI devices) for every ESX host on each connected vCenter.

        Reports 'Fail' for a vCenter domain if any host's CPU is not found on the shipped
        Broadcom Compatibility Guide CPU series snapshot for EsxDestinationVersion (see
        Resolve-VcfCheckEsxCpuCompatibility) - a blocking condition, since an unlisted CPU is
        likely unsupported on the target ESX release - or if any host's CPU is Discontinued per
        Broadcom KB 318697 (see Resolve-VcfCheckEsxCpuDeprecationStatus). Reports 'Warning'
        (non-blocking) if any host's CPU is Deprecated per that same KB - support for it is
        expected to be removed in a future major release. Reports 'Pass' if every host's CPU is
        confirmed compatible and not on the deprecation/discontinuation track, or could not be
        evaluated, or 'Error' if no hosts are found, a vCenter connection fails, or an execution
        error occurs.

        If $Context.ReportDirectoryPath is set, exports a timestamped JSON report ('esx-hardware-report-<timestamp>.json')
        per vCenter domain containing the host hardware findings for offline analysis. Results are returned
        per domain using New-VcfCheckPerDomainResults.

        Gathers detailed adapter information per host via Get-EsxCli calls. DEBUG-level Write-LogMessage
        calls log the host inventory fetch and individual host collection times to the log file for
        diagnosing execution performance without cluttering console output.

        Each host's CPU is flagged against the shipped Broadcom Compatibility Guide CPU series
        snapshot, entirely offline. Hosts whose CPU is not found on that list, or could not be
        evaluated, are sorted to the top of each domain's host list so they are seen first.

        .PARAMETER Context
        The VcfCheck.Context object. Must be connected to SDDC Manager. May contain ReportDirectoryPath
        for JSON report export.

        .PARAMETER DisplayName
        Optional display name for the check. If omitted, defaults to the display name specified in the
        precheck catalog entry for 'esx_hardware_details'.

        .PARAMETER EsxDestinationVersion
        The ESX release family to flag CPU compatibility against, e.g. '9.0' or '9.1'. Defaults to
        '9.1', the newest release the shipped CPU compatibility snapshot covers.

        .OUTPUTS
        [PSObject[]] Array of per-domain check result objects created by New-VcfCheckPerDomainResults.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$EsxDestinationVersion = '9.1'
    )

    $startedAt = Get-Date
    $checkId = 'esx_hardware_details'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }
    $validationCriteria = $catalogEntry.validationCriteria

    try {
        $vcenterFqdns = Get-VcfCheckAllVCenterFqdns -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Area ESX -Status Error `
            -Exception $_.Exception.Message -ValidationCriteria $validationCriteria -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $outcomes = foreach ($vcenterFqdn in $vcenterFqdns) {
        $iterationStartedAt = Get-Date
        $outcome = try {
            Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
            $hostInventoryStartedAt = Get-Date
            $hosts = @(Get-VcfCheckVMHostInventory -Server $vcenterFqdn)
            $hostInventoryMs = ((Get-Date) - $hostInventoryStartedAt).TotalMilliseconds
            Write-LogMessage -Type DEBUG -Message "[$vcenterFqdn] Host inventory returned $($hosts.Count) host(s) in $(Format-VcfCheckDuration -Milliseconds $hostInventoryMs)."

            if ($hosts.Count -eq 0) {
                [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = 'No ESX hosts found.'; HostDetails = @(); HostDetailsLabel = 'Summary' }
            } else {
                $hostIndex = 0
                $hostDetails = @($hosts | ForEach-Object {
                    $hostIndex++
                    Write-VcfCheckSubProgress -Context $Context -Current $hostIndex -Total $hosts.Count -Label $_.Name
                    $hostStartedAt = Get-Date
                    $hostDetail = Get-VcfCheckEsxHostHardwareDetail -VMHost $_ -EsxDestinationVersion $EsxDestinationVersion
                    $hostMs = ((Get-Date) - $hostStartedAt).TotalMilliseconds
                    Write-LogMessage -Type DEBUG -Message "[$vcenterFqdn] Host `"$($_.Name)`" hardware detail collected in $(Format-VcfCheckDuration -Milliseconds $hostMs)."
                    $hostDetail
                })

                $reportPath = $null
                if ($Context.ReportDirectoryPath) {
                    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $reportPath = Join-Path -Path $Context.ReportDirectoryPath -ChildPath "esx-hardware-report-$timestamp.json"
                    $report = @{
                        GeneratedAt = Get-Date -Format 'o'
                        VCenter     = $vcenterFqdn
                        Hosts       = $hostDetails
                    }
                    $json = $null
                    foreach ($depth in @(5, 3, 2)) {
                        try {
                            $json = $report | ConvertTo-Json -Depth $depth -ErrorAction Stop
                            break
                        }
                        catch {
                            if ($depth -eq 2) {
                                throw $_
                            }
                        }
                    }
                    $json | Set-Content -LiteralPath $reportPath -Encoding utf8
                }

                $detail = "Successfully retrieved hardware details for $($hostDetails.Count) host$(if ($hostDetails.Count -ne 1) { 's' })."
                if ($reportPath) { $detail += " Detailed hardware report: $reportPath" }

                $cpuIssueSortRank = @{ NotListed = 0; Discontinued = 0; Deprecated = 1; Unknown = 2; Compatible = 3; None = 3 }
                $sortedHostDetails = @($hostDetails | Sort-Object -Property `
                    @{ Expression = { [Math]::Min($cpuIssueSortRank[$_.CpuCompatibility], $cpuIssueSortRank[$_.CpuDeprecationStatus]) } }, HostName)

                $notListedHosts = @($sortedHostDetails | Where-Object { $_.CpuCompatibility -eq 'NotListed' })
                $discontinuedHosts = @($sortedHostDetails | Where-Object { $_.CpuDeprecationStatus -eq 'Discontinued' })
                $deprecatedHosts = @($sortedHostDetails | Where-Object { $_.CpuDeprecationStatus -eq 'Deprecated' })

                $status = 'Pass'
                if ($notListedHosts.Count -gt 0) {
                    $status = 'Fail'
                    $detail += " $($notListedHosts.Count) host$(if ($notListedHosts.Count -ne 1) { 's' }) with a CPU not found on Broadcom's Compatibility Guide for ESX $EsxDestinationVersion`: $(($notListedHosts | ForEach-Object { $_.HostName }) -join ', ')."
                }
                if ($discontinuedHosts.Count -gt 0) {
                    $status = 'Fail'
                    $detail += " $($discontinuedHosts.Count) host$(if ($discontinuedHosts.Count -ne 1) { 's' }) with a CPU discontinued for ESX $EsxDestinationVersion`: $(($discontinuedHosts | ForEach-Object { $_.HostName }) -join ', ')."
                }
                if ($deprecatedHosts.Count -gt 0) {
                    if ($status -eq 'Pass') { $status = 'Warning' }
                    $detail += " $($deprecatedHosts.Count) host$(if ($deprecatedHosts.Count -ne 1) { 's' }) with a CPU deprecated in VCF 9.0 with removal planned for a future version of VCF: $(($deprecatedHosts | ForEach-Object { $_.HostName }) -join ', '). See https://knowledge.broadcom.com/external/article/318697 for details."
                }

                [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = $status; Detail = $detail; HostDetails = $sortedHostDetails; HostDetailsLabel = 'Summary' }
            }
        } catch {
            [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = $_.Exception.Message; HostDetails = @(); HostDetailsLabel = 'Summary' }
        }
        $outcome | Add-Member -NotePropertyName StartedAt -NotePropertyValue $iterationStartedAt -Force
        $outcome | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date) -Force
        $outcome
    }

    return New-VcfCheckPerDomainResults -Context $Context -PerVCenterOutcome $outcomes -CheckId $checkId `
        -StartedAt $startedAt
}
function Get-VcfCheckEsxHostHardwareDetail {

    <#
        .SYNOPSIS
        Collects server, cluster, CPU, boot mode, network adapter, storage adapter, and storage device details for a single ESX host.

        .DESCRIPTION
        Helper cmdlet that extracts detailed hardware configuration for an ESX host object retrieved from Get-VcfCheckVMHostInventory.

        Queries and computes:
        - Host name, cluster name, vendor, model, and BIOS version
        - Boot mode (resolving firmware type, UEFI/Secure Boot capability, or Legacy BIOS)
        - CPU series and total core count via Get-VcfCheckVMHostCpuInfo
        - Physical network adapters via Get-VcfCheckVMHostNetworkDevices
        - Storage adapters via Get-VcfCheckVMHostStorageAdapters
        - SCSI storage devices and capacities via Get-VcfCheckVMHostScsiDevices
        - CPU compatibility flag against the shipped Broadcom Compatibility Guide CPU series
          snapshot for EsxDestinationVersion, via Resolve-VcfCheckEsxCpuCompatibility
        - CPU deprecation/discontinuation flag against Broadcom KB 318697's CPU support removal
          track for EsxDestinationVersion, via Resolve-VcfCheckEsxCpuDeprecationStatus - a CPU
          can be Compatible on the Hardware Compatibility Guide and still be Deprecated or
          Discontinued here, since the two are independent Broadcom data sources

        .PARAMETER VMHost
        A VMHost inventory object retrieved via Get-VcfCheckVMHostInventory.

        .PARAMETER EsxDestinationVersion
        The ESX release family to flag CPU compatibility against, e.g. '9.0' or '9.1'.

        .OUTPUTS
        [PSCustomObject] Structured object containing fields: HostName, ClusterName, Vendor, Model,
        BiosVersion, BootMode, CpuSeries, CpuCores, CpuCompatibility, CpuCompatibilityMatchedSeries,
        CpuDeprecationStatus, CpuDeprecationMatchedSeries, NetworkAdapters, StorageAdapters, and
        StorageDevices.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$EsxDestinationVersion = '9.1'
    )

    $bios = $VMHost.ExtensionData.Hardware.BiosInfo
    $cpuInfo = Get-VcfCheckVMHostCpuInfo -VMHost $VMHost -ErrorAction SilentlyContinue
    $cpuCompatibility = Resolve-VcfCheckEsxCpuCompatibility -CpuModel $cpuInfo.CpuSeries -EsxVersion $EsxDestinationVersion
    $cpuDeprecation = Resolve-VcfCheckEsxCpuDeprecationStatus -CpuModel $cpuInfo.CpuSeries -EsxVersion $EsxDestinationVersion

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

    $bootMode = 'Unknown'
    try {
        $firmwareType = $VMHost.ExtensionData.Hardware.BiosInfo.FirmwareType
        if ([string]::IsNullOrWhiteSpace($firmwareType)) {
            if ($VMHost.ExtensionData.Capability.SecureBootSupported -eq $true) {
                $bootMode = 'UEFI (SecureBoot Capable)'
            } else {
                $bootMode = 'Legacy BIOS'
            }
        } else {
            $bootMode = $firmwareType
        }
    } catch {
        $bootMode = 'Unknown'
    }

    $networkStartedAt = Get-Date
    $networkAdapters = @(Get-VcfCheckVMHostNetworkDevices -VMHost $VMHost -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{ Name = $_.Name; Vendor = $_.Vendor; Model = $_.Model }
    })
    $networkMs = ((Get-Date) - $networkStartedAt).TotalMilliseconds

    $storageAdaptersStartedAt = Get-Date
    $storageAdapters = @(Get-VcfCheckVMHostStorageAdapters -VMHost $VMHost -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{ Name = $_.Name; Vendor = $_.Vendor; Model = $_.Model; Type = $_.Type }
    })
    $storageAdaptersMs = ((Get-Date) - $storageAdaptersStartedAt).TotalMilliseconds

    $scsiStartedAt = Get-Date
    $storageDevices = @(Get-VcfCheckVMHostScsiDevices -VMHost $VMHost -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{ Name = $_.Name; Vendor = $_.Vendor; Model = $_.Model; Type = $_.Type; CapacityGB = $_.Capacity }
    })
    $scsiMs = ((Get-Date) - $scsiStartedAt).TotalMilliseconds

    Write-LogMessage -Type DEBUG -Message "[$($VMHost.Name)] NICs: $(Format-VcfCheckDuration -Milliseconds $networkMs) ($($networkAdapters.Count)), HBAs: $(Format-VcfCheckDuration -Milliseconds $storageAdaptersMs) ($($storageAdapters.Count)), SCSI devices: $(Format-VcfCheckDuration -Milliseconds $scsiMs) ($($storageDevices.Count))."

    return [PSCustomObject]@{
        HostName                      = $VMHost.Name
        ClusterName                   = $cluster
        Vendor                        = $VMHost.ExtensionData.Summary.Hardware.Vendor
        Model                         = $VMHost.ExtensionData.Summary.Hardware.Model
        BiosVersion                   = $bios.BiosVersion
        BootMode                      = $bootMode
        CpuSeries                     = $cpuInfo.CpuSeries
        CpuCores                      = $cpuInfo.TotalCores
        CpuCompatibility              = $cpuCompatibility.Status
        CpuCompatibilityMatchedSeries = $cpuCompatibility.MatchedSeries
        CpuDeprecationStatus          = $cpuDeprecation.Status
        CpuDeprecationMatchedSeries   = $cpuDeprecation.MatchedSeries
        NetworkAdapters               = $networkAdapters
        StorageAdapters               = $storageAdapters
        StorageDevices                = $storageDevices
    }
}
