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
function Test-VcfNsxtDiskSpace {

    <#
        .SYNOPSIS
        Checks disk space utilization on every NSX transport node.

        .DESCRIPTION
        Queries GET /api/v1/transport-nodes to list nodes, followed by per-node GET
        /api/v1/transport-nodes/{id}/status to inspect node_status.system_status.file_systems.

        Evaluates used/total utilization ratios against defined thresholds:
        - 'vsantraces' filesystem -> 0.95 (95%)
        - All other filesystems -> 0.75 (75%)

        Filesystems exceeding their threshold generate a Warning status.

        Returns a single VcfCheck.Result with one HostDetails entry per transport node (see
        Format-VcfCheckHtmlHostDetailCard), rendering one collapsible section per node.
        Each node contains a DiskUsage array detailing all reported filesystems
        (Filesystem/Mount/Type/Size/Used/Available/UsedPercent/Status). Raw KB values are
        formatted into human-readable strings via ConvertTo-VcfCheckHumanReadableKb.
        Entries are labeled "Transport Nodes" and sorted alphabetically by display name.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .OUTPUTS
        [PSObject] a VcfCheck.Result.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'nsxt_disk_space'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $defaultThreshold = 0.75
    $thresholdMap = @{ vsantraces = 0.95 }

    try {
        $nsxFqdn = Get-VcfCheckManagementNsxManagerFqdn -Context $Context
        $transportNodes = @((Invoke-VcfCheckNsxManagerApi -Context $Context -Fqdn $nsxFqdn -Path '/api/v1/transport-nodes').results)
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $nsxFqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    if ($transportNodes.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -TargetComponent $nsxFqdn -Detail 'No transport nodes found.' -SkipReasonTag 'no transport nodes' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $alerts = [System.Collections.Generic.List[String]]::new()
    $transportNodeDetails = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($node in $transportNodes) {
        try {
            $status = Invoke-VcfCheckNsxManagerApi -Context $Context -Fqdn $nsxFqdn -Path "/api/v1/transport-nodes/$($node.id)/status"
        } catch {
            return New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $nsxFqdn -Exception $_.Exception.Message `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }
        $nodeRows = [System.Collections.Generic.List[Object]]::new()
        $nodeStatus = 'Pass'
        foreach ($fs in @($status.node_status.system_status.file_systems)) {
            if (-not $fs -or $fs.total -le 0) { continue }
            $threshold = if ($thresholdMap.ContainsKey($fs.file_system)) { $thresholdMap[$fs.file_system] } else { $defaultThreshold }
            $ratio = $fs.used / $fs.total
            $rowStatus = 'Pass'
            if ($fs.used -gt 0 -and $ratio -gt $threshold) {
                $rowStatus = 'Warning'
                $nodeStatus = 'Warning'
                $alerts.Add("$($node.display_name)/$($fs.file_system): $([Math]::Round($ratio * 100, 1))% (threshold $([Math]::Round($threshold * 100))%)")
            }
            $nodeRows.Add([PSCustomObject]@{
                Filesystem  = $fs.file_system
                Mount       = $fs.mount
                Type        = $fs.type
                Size        = ConvertTo-VcfCheckHumanReadableKb -Kb $fs.total
                Used        = ConvertTo-VcfCheckHumanReadableKb -Kb $fs.used
                Available   = ConvertTo-VcfCheckHumanReadableKb -Kb ($fs.total - $fs.used)
                UsedPercent = "$([Math]::Round($ratio * 100, 1))%"
                Status      = $rowStatus
            })
        }
        $transportNodeDetails.Add([PSCustomObject]@{
            HostName  = $node.display_name
            Status    = $nodeStatus
            DiskUsage = $nodeRows.ToArray()
        })
    }

    $sortedTransportNodeDetails = @($transportNodeDetails | Sort-Object -Property HostName)

    if ($alerts.Count -gt 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Warning `
            -TargetComponent $nsxFqdn -Detail "Filesystem(s) above threshold: $($alerts -join '; ')" `
            -ValidationCriteria $catalogEntry.validationCriteria -Remediation $catalogEntry.remediation `
            -HostDetails $sortedTransportNodeDetails -HostDetailsLabel 'Transport Nodes' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    return New-VcfCheckResult -CheckId $checkId -Status Pass `
        -TargetComponent $nsxFqdn -Detail "Checked $($transportNodes.Count) transport node(s); every filesystem is below its threshold." `
        -HostDetails $sortedTransportNodeDetails -HostDetailsLabel 'Transport Nodes' `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
