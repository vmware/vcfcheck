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
function Test-VcfAriaOpsForLogsVsphereIntegrationStatus {

    <#
        .SYNOPSIS
        Verifies that every vCenter Server integration configured in Aria Operations for Logs is
        actively collecting, not just present.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsForLogsTargets to connect to every Aria Operations for Logs instance
        declared on the environment (see Private/AriaOpsForLogsHelpers.ps1) and calls
        Get-VcfCheckAriaOpsForLogsVsphereIntegrations (GET /api/v2/vsphere) against each. Unlike a
        configuration-presence read, this endpoint's collectionStatus field is the appliance's own
        live assessment of whether it is actually collecting from that vCenter Server, so a
        vCenter that is configured but no longer reachable is distinguished from one that is
        healthy.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations for Logs instance is known at all.
        - Pass: Returns 'Pass' for a target if no vCenter Server integration is configured (this is
          a valid deployment state, not a failure), or if every configured integration reports
          collectionStatus 'Collecting'.
        - Warning: Returns 'Warning' for a target if any configured integration reports a
          collectionStatus other than 'Collecting', using collectionStatusDetails for the reason
          when present.
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
    $checkId = 'aria_ops_for_logs_vsphere_integration_status'

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
            $integrations = Get-VcfCheckAriaOpsForLogsVsphereIntegrations -Session $target.Session
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for Logs for vCenter Server integration status: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        if ($integrations.Count -eq 0) {
            $row = [PSCustomObject]@{ Hostname = 'Not Configured'; CollectionStatus = 'Not Configured'; CollectionStatusDetails = 'Not Configured' }
            New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $target.Fqdn -Detail 'No vCenter Server integration is configured for Aria Operations for Logs.' -Rows @($row) `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $flagged = [System.Collections.Generic.List[String]]::new()

        foreach ($integration in $integrations) {
            $status = if ($integration.collectionStatus) { $integration.collectionStatus } else { 'Not Configured' }
            $details = if ($integration.collectionStatusDetails) { $integration.collectionStatusDetails } else { 'Not Configured' }

            if ($status -ne 'Collecting') {
                $flagged.Add("`"$($integration.hostname)`" reports collection status `"$status`" ($details)")
            }

            $rows.Add([PSCustomObject]@{
                Hostname                = $integration.hostname
                CollectionStatus        = $status
                CollectionStatusDetails = $details
            })
        }

        if ($flagged.Count -eq 0) {
            $status = 'Pass'
            $detail = "All $($integrations.Count) vCenter Server integration(s) report collection status `"Collecting`"."
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
