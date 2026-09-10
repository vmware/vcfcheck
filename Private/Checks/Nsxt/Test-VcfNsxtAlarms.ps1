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
function Test-VcfNsxtAlarms {

    <#
        .SYNOPSIS
        Checks for open NSX Manager alarms.

        .DESCRIPTION
        Queries GET /api/v1/alarms?status=OPEN (NSX Manager Alarm/Event Framework) via
        Get-VcfCheckNsxAlarm / Invoke-VcfCheckNsxManagerApi to retrieve active alarms.

        Severity mapping evaluates as follows:
        - CRITICAL / HIGH -> Fail
        - MEDIUM / LOW / Unknown -> Warning

        Targets the management NSX Manager. Groups alarms by Summary and Severity, reporting an instance
        Count along with affected node names rather than duplicating rows per node.

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
    $checkId = 'nsxt_alarms'

    try {
        $nsxFqdn = Get-VcfCheckManagementNsxManagerFqdn -Context $Context
        $alarms = @(Get-VcfCheckNsxAlarm -Context $Context -Server $nsxFqdn)
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $nsxFqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $rows = @($alarms | Group-Object -Property Summary, Severity | ForEach-Object {
        $severity = [String]$_.Group[0].Severity
        if ([String]::IsNullOrWhiteSpace($severity)) { $severity = 'Unknown' }
        $rowStatus = if ($severity -in 'CRITICAL', 'HIGH') { 'Fail' } else { 'Warning' }
        $nodes = ($_.Group | ForEach-Object { $_.node_display_name } | Where-Object { $_ }) -join ', '
        [PSCustomObject]@{
            Severity = $severity
            Summary  = $_.Group[0].Summary
            Count    = $_.Count
            Nodes    = $nodes
            Status   = $rowStatus
        }
    })

    $failRows = @($rows | Where-Object Status -eq 'Fail')
    $warningRows = @($rows | Where-Object Status -eq 'Warning')

    if ($failRows.Count -gt 0) {
        $instanceCount = ($failRows | Measure-Object -Property Count -Sum).Sum
        $summaries = ($failRows | ForEach-Object { "$($_.Summary) (x$($_.Count))" }) -join '; '
        return New-VcfCheckResult -CheckId $checkId -Status Fail `
            -TargetComponent $nsxFqdn -Detail "$($failRows.Count) CRITICAL/HIGH-severity alarm type(s), $instanceCount instance(s): $summaries" `
            -Rows $rows -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    if ($warningRows.Count -gt 0) {
        $instanceCount = ($warningRows | Measure-Object -Property Count -Sum).Sum
        $summaries = ($warningRows | ForEach-Object { "$($_.Summary) (x$($_.Count))" }) -join '; '
        return New-VcfCheckResult -CheckId $checkId -Status Warning `
            -TargetComponent $nsxFqdn -Detail "$($warningRows.Count) MEDIUM/LOW-severity alarm type(s), $instanceCount instance(s): $summaries" `
            -Rows $rows -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    return New-VcfCheckResult -CheckId $checkId -Status Pass `
        -TargetComponent $nsxFqdn -Detail 'No open NSX Manager alarms.' `
        -Rows $rows -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
