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
#region AriaOpsForLogs
function Test-VcfAriaOpsForLogsLogForwarderStatus {

    <#
        .SYNOPSIS
        Verifies that every log forwarder configured in Aria Operations for Logs is actively
        forwarding, not just present.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsForLogsTargets to connect to every Aria Operations for Logs instance
        declared on the environment (see Private/AriaOpsForLogsHelpers.ps1) and calls
        Get-VcfCheckAriaOpsForLogsLogForwarders (GET /api/v2/log-forwarder) against each. Unlike a
        configuration-presence read, this endpoint's forwarderStats.state field is the appliance's
        own live assessment of whether it is actually forwarding, so a forwarder that is configured
        but stalled is distinguished from one that is healthy.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations for Logs instance is known at all.
        - Pass: Returns 'Pass' for a target if no log forwarder is configured (this is a valid
          deployment state, not a failure), or if every configured forwarder reports
          forwarderStats.state 'ACTIVE'.
        - Warning: Returns 'Warning' for a target if any configured forwarder reports a
          forwarderStats.state other than 'ACTIVE'.
        - Error: Returns 'Error' for a target if connecting or querying it fails.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Operations for Logs instance.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'aria_ops_for_logs_log_forwarder_status'

    $targets = Get-VcfCheckAriaOpsForLogsTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Operations for Logs is not deployed in this environment.' -SkipReasonTag 'Aria Operations for Logs not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Operations for Logs'
    }

    $results = foreach ($target in $targets) {
        $resultDisplayName = if ($targets.Count -gt 1) { "$DisplayName ($($target.Name))" } else { $DisplayName }

        if ($target.ConnectError) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception $target.ConnectError `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        try {
            $forwarders = Get-VcfCheckAriaOpsForLogsLogForwarders -Session $target.Session
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for Logs for log forwarder status: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        if ($forwarders.Count -eq 0) {
            $row = [PSCustomObject]@{ Name = 'Not Configured'; Host = 'Not Configured'; State = 'Not Configured'; LogsForwarded = 'Not Configured'; LogsDropped = 'Not Configured' }
            New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $target.Fqdn -Detail 'No log forwarder is configured for Aria Operations for Logs.' -Rows @($row) `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $flagged = [System.Collections.Generic.List[String]]::new()

        foreach ($forwarder in $forwarders) {
            $state = if ($forwarder.forwarderStats.state) { $forwarder.forwarderStats.state } else { 'Not Configured' }
            $logsForwarded = if ($null -ne $forwarder.forwarderStats.logsForwarded) { $forwarder.forwarderStats.logsForwarded } else { 'Not Configured' }
            $logsDropped = if ($null -ne $forwarder.forwarderStats.logsDropped) { $forwarder.forwarderStats.logsDropped } else { 'Not Configured' }

            if ($state -ne 'ACTIVE') {
                $flagged.Add("`"$($forwarder.name)`" reports forwarder status `"$state`"")
            }

            $rows.Add([PSCustomObject]@{
                Name          = $forwarder.name
                Host          = $forwarder.host
                State         = $state
                LogsForwarded = $logsForwarded
                LogsDropped   = $logsDropped
            })
        }

        if ($flagged.Count -eq 0) {
            $status = 'Pass'
            $detail = "All $($forwarders.Count) log forwarder(s) report forwarder status `"ACTIVE`"."
        } else {
            $status = 'Warning'
            $detail = ($flagged.ToArray()) -join '; '
        }

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows $rows.ToArray() `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
    }

    return @($results)
}
#endregion
