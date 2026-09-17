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
#region AriaAutomation
function Test-VcfAriaAutomationVroIntegrationHealth {

    <#
        .SYNOPSIS
        Verifies that every vRO Orchestrator integration (embedded or externally registered)
        known to Aria Automation last reported a successful enumeration.

        .DESCRIPTION
        Calls Get-VcfCheckAriaAutomationTargets to connect to every known Aria Automation
        instance and calls GET /iaas/api/integrations against each, returning one result per
        target. Confirmed live against an 8.18 appliance that this endpoint requires an explicit
        apiVersion query parameter (unlike /iaas/api/cloud-accounts) and returns every
        integration Aria Automation knows about, but only the 'vro' integrationType carries a
        health-style field observed live (customProperties.enumerationTaskState). This check
        evaluates every 'vro' row - embedded or externally registered - and reports every other
        integrationType (embedded ABX, Ansible, GitHub, AD, etc.) as a non-failing, out-of-scope
        row: those integration types have no generic healthy/status field in the schema and are
        not planned to be ported to this check.

        Known limitation: enumerationTaskState is a point-in-time value with no accompanying
        timestamp field confirmed live yet, so this check cannot yet detect a vRO endpoint that
        went unreachable after its last successful enumeration and has not been re-enumerated
        since - that state still reads 'FINISHED' and passes. Closing that gap needs a live
        capture of the full customProperties payload on a real appliance to confirm whether a
        last-enumeration timestamp field exists to compare against a staleness threshold.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Automation instance is known at all.
        - Pass: Returns 'Pass' for a target if every 'vro' integration's enumerationTaskState is
          'FINISHED' (or no 'vro' integration is configured at all).
        - Fail: Returns 'Fail' for a target if a 'vro' integration's enumerationTaskState is
          anything other than 'FINISHED' (e.g. 'FAILED', 'RUNNING' held indefinitely).
        - Error: Returns 'Error' for a target if connecting or querying it fails.

        Builds a detailed breakdown table ('Rows') of every integration's Name, IntegrationType,
        EnumerationTaskState ('Not evaluated' for non-'vro' types), and Status ('Pass'/'Fail' for
        'vro' rows, 'Skipped' for every other integrationType).

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Automation instance.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'aria_automation_vro_integration_health'

    $targets = Get-VcfCheckAriaAutomationTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Automation is not deployed in this environment.' -SkipReasonTag 'Aria Automation not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Automation'
    }

    $results = foreach ($target in $targets) {
        $resultDisplayName = if ($targets.Count -gt 1) { "$DisplayName ($($target.Name))" } else { $DisplayName }

        if ($target.ConnectError) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception $target.ConnectError `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        try {
            $response = Invoke-VcfCheckAriaAutomationApi -CredentialInfo $target.CredentialInfo -Path '/iaas/api/integrations?apiVersion=2021-07-15'
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Automation for integrations: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        $integrations = @($response.content)
        if ($integrations.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $target.Fqdn -Detail 'No integrations are configured in Aria Automation.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        Write-LogMessage -Type DEBUG -Message "Found $($integrations.Count) integration(s) on `"$($target.Fqdn)`": $(($integrations | ForEach-Object { $_.name }) -join ', ')"

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $flagged = [System.Collections.Generic.List[String]]::new()

        foreach ($integration in $integrations) {
            if ($integration.integrationType -eq 'vro') {
                $enumerationTaskState = $integration.customProperties.enumerationTaskState
                $rowStatus = if ($enumerationTaskState -eq 'FINISHED') { 'Pass' } else { 'Fail' }
                $rows.Add([PSCustomObject]@{
                    Name                 = $integration.name
                    IntegrationType      = $integration.integrationType
                    EnumerationTaskState = $enumerationTaskState
                    Status               = $rowStatus
                })

                if ($enumerationTaskState -ne 'FINISHED') {
                    $flagged.Add("$($integration.name): last vRO enumeration reported state '$enumerationTaskState', expected 'FINISHED'")
                }
            } else {
                $rows.Add([PSCustomObject]@{
                    Name                 = $integration.name
                    IntegrationType      = $integration.integrationType
                    EnumerationTaskState = 'Not evaluated'
                    Status               = 'Skipped'
                })
            }
        }

        if ($flagged.Count -eq 0) {
            $status = 'Pass'
            $detail = 'Every vRO Orchestrator integration reports a successful enumeration (or none is configured).'
        } else {
            $status = 'Fail'
            $detail = ($flagged.ToArray()) -join '; '
        }

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows ($rows.ToArray() | Sort-Object -Property Name) `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
    }

    return @($results)
}
#endregion
