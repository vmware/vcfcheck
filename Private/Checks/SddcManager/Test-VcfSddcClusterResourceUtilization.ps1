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
function Test-VcfSddcClusterResourceUtilization {

    <#
        .SYNOPSIS
        Checks CPU, memory, and vSAN storage utilization for the management domain's primary cluster.

        .DESCRIPTION
        Evaluates CPU, memory, and storage utilization for the management domain's primary cluster
        against defined capacity thresholds:
        - Storage usage >= 65% -> Warning
        - CPU or Memory usage >= 75% -> Warning

        Identifies the management domain's primary cluster by locating the host where the SDDC
        Manager appliance VM resides on the management vCenter.

        Computes utilization directly via PowerCLI: CPU and memory metrics are aggregated across
        every ESX host in the cluster, and storage capacity is aggregated across all datastores
        associated with those hosts. Free vSAN space is specifically calculated in tebibytes (TiB)
        for datastores of type 'vsan'.

        Reports CPU %, Memory %, Storage %, Free Memory (GB), and Free vSAN (TiB) in a structured
        breakdown table ('Rows').

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [PSObject] A single VcfCheck.Result object.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'sddc_cluster_resource_utilization'
    $cpuMemoryThreshold = 75
    $storageThreshold = 65

    try {
        $vcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn

        $vmName = ($Context.SddcManagerFqdn -split '\.')[0]
        $vmMatches = @(Get-VcfCheckVM -VmName $vmName -Server $vcenterFqdn)
        if ($vmMatches.Count -eq 0) {
            return New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $vcenterFqdn `
                -Detail "Could not find the SDDC Manager appliance's VM (`"$vmName`") on the management vCenter - cannot determine the management domain's primary cluster." `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }
        if ($vmMatches.Count -gt 1) {
            return New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $vcenterFqdn `
                -Detail "Found $($vmMatches.Count) VMs named `"$vmName`" on the management vCenter (ambiguous) - cannot determine the management domain's primary cluster." `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        $vmHost = Get-VcfCheckVMHostForVM -VM $vmMatches[0] -Server $vcenterFqdn
        $cluster = Get-VcfCheckClusterForVMHost -VMHost $vmHost -Server $vcenterFqdn
        if (-not $cluster) {
            return New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $vcenterFqdn `
                -Detail "The SDDC Manager appliance's host (`"$($vmHost.Name)`") is not part of a cluster - cannot evaluate the management domain's primary cluster." `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        $hosts = @(Get-VcfCheckClusterVMHostInventory -Server $vcenterFqdn -Cluster $cluster)
        if ($hosts.Count -eq 0) {
            return New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $vcenterFqdn `
                -Detail "Primary cluster `"$($cluster.Name)`" has no hosts." `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        $datastores = @(Get-VcfCheckClusterDatastoreInventory -Server $vcenterFqdn -VMHost $hosts)

        $totalCpuMhz = ($hosts | Measure-Object -Property CpuTotalMhz -Sum).Sum
        $usedCpuMhz = ($hosts | Measure-Object -Property CpuUsageMhz -Sum).Sum
        $totalMemoryGB = ($hosts | Measure-Object -Property MemoryTotalGB -Sum).Sum
        $usedMemoryGB = ($hosts | Measure-Object -Property MemoryUsageGB -Sum).Sum
        $totalCapacityGB = ($datastores | Measure-Object -Property CapacityGB -Sum).Sum
        $totalFreeGB = ($datastores | Measure-Object -Property FreeSpaceGB -Sum).Sum

        $vsanDatastores = @($datastores | Where-Object { $_.Type -eq 'vsan' })
        $vsanFreeGB = if ($vsanDatastores.Count -gt 0) { ($vsanDatastores | Measure-Object -Property FreeSpaceGB -Sum).Sum } else { $null }

        $cpuPercent = $null
        $memoryPercent = $null
        $storagePercent = $null
        $freeMemoryGB = $null
        $freeVsanTiB = $null
        $isFlagged = $false

        if ($totalCpuMhz -gt 0) {
            $cpuPercent = [Math]::Round(($usedCpuMhz / $totalCpuMhz) * 100, 1)
            if ($cpuPercent -ge $cpuMemoryThreshold) { $isFlagged = $true }
        }
        if ($totalMemoryGB -gt 0) {
            $memoryPercent = [Math]::Round(($usedMemoryGB / $totalMemoryGB) * 100, 1)
            $freeMemoryGB = [Math]::Round($totalMemoryGB - $usedMemoryGB, 1)
            if ($memoryPercent -ge $cpuMemoryThreshold) { $isFlagged = $true }
        }
        if ($totalCapacityGB -gt 0) {
            $storagePercent = [Math]::Round((($totalCapacityGB - $totalFreeGB) / $totalCapacityGB) * 100, 1)
            if ($storagePercent -ge $storageThreshold) { $isFlagged = $true }
        }
        if ($null -ne $vsanFreeGB) {
            $freeVsanTiB = [Math]::Round($vsanFreeGB / 1024, 2)
        }

        $status = if ($isFlagged) { 'Warning' } else { 'Pass' }
        $detail = if ($isFlagged) {
            "Primary cluster `"$($cluster.Name)`" (hosts the SDDC Manager appliance) is at or above threshold."
        } else {
            "Primary cluster `"$($cluster.Name)`" (hosts the SDDC Manager appliance) is below threshold."
        }

        $rows = @([PSCustomObject]@{
                Cluster            = $cluster.Name
                'CPU %'            = $cpuPercent
                'Memory %'         = $memoryPercent
                'Storage %'        = $storagePercent
                'Free Memory (GB)' = $freeMemoryGB
                'Free vSAN (TiB)'  = $freeVsanTiB
                Status             = $status
            })

        return New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $vcenterFqdn -Detail $detail `
            -Rows $rows -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -Exception $_.Exception.Message -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }
}
