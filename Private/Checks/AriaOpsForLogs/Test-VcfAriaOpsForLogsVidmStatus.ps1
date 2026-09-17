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
function Test-VcfAriaOpsForLogsVidmStatus {

    <#
        .SYNOPSIS
        Verifies that Aria Operations for Logs' vIDM auth-source integration, if configured, is
        actually connected.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsForLogsTargets to connect to every Aria Operations for Logs instance
        declared on the environment (see Private/AriaOpsForLogsHelpers.ps1) and calls
        Get-VcfCheckAriaOpsForLogsVidmStatus (GET /api/v2/vidm/status) against each. The endpoint's state
        field is the appliance's own live assessment of the vIDM connection, not a static
        configuration read.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations for Logs instance is known at all.
        - Pass: Returns 'Pass' for a target if vIDM is not configured (state 'UNCONFIGURED' - a
          valid deployment state, not a failure), or if state is 'CONNECTED'.
        - Warning: Returns 'Warning' for a target if state is 'DISCONNECTED'.
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
    $checkId = 'aria_ops_for_logs_vidm_status'

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
            $state = Get-VcfCheckAriaOpsForLogsVidmStatus -Session $target.Session
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for Logs for vIDM connection status: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        $row = [PSCustomObject]@{ State = if ($state) { $state } else { 'Not Configured' } }

        if (-not $state -or $state -eq 'UNCONFIGURED') {
            New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $target.Fqdn -Detail 'vIDM is not configured as an auth source for Aria Operations for Logs.' -Rows @($row) `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        if ($state -eq 'CONNECTED') {
            New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $target.Fqdn -Detail 'Aria Operations for Logs reports vIDM connection status "CONNECTED".' -Rows @($row) `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        New-VcfCheckResult -CheckId $checkId -Status Warning `
            -TargetComponent $target.Fqdn -Detail "Aria Operations for Logs reports vIDM connection status `"$state`"." -Rows @($row) `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
    }

    return @($results)
}
#endregion
