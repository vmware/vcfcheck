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
function Test-VcfEsxExecInstalledOnlyCheck {

    <#
        .SYNOPSIS
        Reports VMkernel.Boot.execInstalledOnly status for every ESX host managed by every
        vCenter attached to SDDC Manager.

        .DESCRIPTION
        Uses Get-VcfCheckHostAdvancedSettingForHost to query the 'VMkernel.Boot.execInstalledOnly'
        setting for each ESX host attached to each vCenter domain, one host at a time (PowerCLI's
        Get-AdvancedSetting makes one API round trip per host, so this can take a while on
        environments with many hosts - Write-VcfCheckSubProgress reports "Current/Total (hostname)"
        progress between hosts). This standard ESX security-hardening setting (part of the vSphere
        Security Configuration Guide) enforces that only digitally-signed, installed executables can run.

        Informational only: reports each host's execInstalledOnly state ('Enabled' or 'Disabled')
        in a per-vCenter table containing Cluster, Hostname, and Status. The check yields a
        'Pass' status regardless of whether individual hosts have the setting disabled. It returns
        an 'Error' status only if an execution failure occurs (e.g., unable to retrieve vCenters,
        connect to a vCenter, or fetch advanced settings).

        Iterates through all vCenters managed by SDDC Manager and delegates output generation
        to New-VcfCheckPerDomainResults to return results grouped per vCenter domain.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly name for the check, used when generating top-level error results.

        .OUTPUTS
        [PSObject[]] Per-domain check results produced by New-VcfCheckPerDomainResults.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'esx_execInstalledOnly_check'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }

    try {
        $vcenterFqdns = Get-VcfCheckAllVCenterFqdns -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -Exception $_.Exception.Message -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $outcomes = foreach ($vcenterFqdn in $vcenterFqdns) {
        $iterationStartedAt = Get-Date
        $outcome = try {
            Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
            $vmHosts = @(Get-VcfCheckVMHostInventory -Server $vcenterFqdn)
            $hostIndex = 0
            $settings = @($vmHosts | ForEach-Object {
                $hostIndex++
                Write-VcfCheckSubProgress -Context $Context -Current $hostIndex -Total $vmHosts.Count -Label $_.Name
                Get-VcfCheckHostAdvancedSettingForHost -VMHost $_ -SettingName 'VMkernel.Boot.execInstalledOnly'
            })

            $hostsByCluster = @($settings | ForEach-Object {
                [PSCustomObject]@{
                    Cluster  = $_.Entity.Parent.Name
                    Hostname = $_.Entity.Name
                    Status   = if ([Boolean]$_.Value) { 'Enabled' } else { 'Disabled' }
                }
            } | Group-Object -Property Cluster)

            $rows = @()
            foreach ($clusterGroup in $hostsByCluster) {
                $clusterName = $clusterGroup.Name
                $hostsInCluster = @($clusterGroup.Group)
                $uniqueStatuses = @($hostsInCluster.Status | Select-Object -Unique)

                if ($uniqueStatuses.Count -eq 1) {
                    $commonStatus = $uniqueStatuses[0]
                    $hostCount = $hostsInCluster.Count
                    $rows += [PSCustomObject]@{
                        Cluster  = $clusterName
                        Hostname = "All $hostCount host$(if ($hostCount -ne 1) { 's' }) in the cluster have the identical state"
                        Status   = $commonStatus
                    }
                } else {
                    $rows += @($hostsInCluster | Sort-Object -Property Hostname)
                }
            }
            $rows = @($rows | Sort-Object -Property Cluster)

            [PSCustomObject]@{
                VCenterFqdn = $vcenterFqdn
                Status      = 'Pass'
                Detail      = $null
                Rows        = $rows
            }
        } catch {
            [PSCustomObject]@{
                VCenterFqdn = $vcenterFqdn
                Status      = 'Error'
                Detail      = $_.Exception.Message
                Rows        = @()
            }
        }
        $outcome | Add-Member -NotePropertyName StartedAt -NotePropertyValue $iterationStartedAt -Force
        $outcome | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date) -Force
        $outcome
    }

    return New-VcfCheckPerDomainResults -Context $Context -PerVCenterOutcome $outcomes -CheckId $checkId `
        -StartedAt $startedAt
}
