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
#region AriaOps
function Test-VcfAriaOpsCriticalAlerts {

    <#
        .SYNOPSIS
        Verifies that Aria Operations has no active Critical or Immediate alerts.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsTargets to connect to every known Aria Operations instance (the
        SDDC-Manager-known one, plus any standalone endpoint declared on the environment - see
        Private/AriaOpsHelpers.ps1) and calls Get-VcfCheckAriaOpsCriticalAlerts (a thin wrapper
        around Invoke-VcfOpsQueryAlert) against each with a query for active alerts of
        'CRITICAL' or 'IMMEDIATE' criticality, returning one result per target.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations instance is known at all.
        - Pass: Returns 'Pass' for a target if no active Critical/Immediate alerts are found.
        - Fail: Returns 'Fail' for a target if one or more active Critical/Immediate alerts are
          found.
        - Error: Returns 'Error' for a target if connecting or querying it fails.

        Builds a detailed breakdown table ('Rows') of every matching alert's definition name,
        resource name/kind (resolved from the alert's ResourceId via Get-VcfCheckAriaOpsResource,
        since the alert itself only carries the raw id), criticality, status, and start time.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Operations instance.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'aria_ops_critical_alerts'

    $targets = Get-VcfCheckAriaOpsTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Operations is not deployed in this environment.' -SkipReasonTag 'Aria Operations not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Operations'
    }

    $results = foreach ($target in $targets) {
        $resultDisplayName = if ($targets.Count -gt 1) { "$DisplayName ($($target.Name))" } else { $DisplayName }

        if ($target.ConnectError) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception $target.ConnectError `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        try {
            $response = Get-VcfCheckAriaOpsCriticalAlerts -Connection $target.Connection
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for active critical alerts: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $alerts = @($response._Alerts)

        if ($alerts.Count -eq 0) {
            $status = 'Pass'
            $detail = 'No active Critical or Immediate alerts were found in Aria Operations.'
        } else {
            $status = 'Fail'
            $detail = "$($alerts.Count) active Critical/Immediate alert(s) were found in Aria Operations."
        }

        $resourceNames = @{}
        foreach ($resourceId in @($alerts.ResourceId | Select-Object -Unique)) {
            $parsedResourceId = [Guid]::Empty
            if (-not [Guid]::TryParse($resourceId, [ref]$parsedResourceId)) {
                $resourceNames[$resourceId] = $null
                Write-LogMessage -Type DEBUG -Message "Skipping resource name resolution for Aria Operations resource id `"$resourceId`" - not a valid GUID (known VMware.Sdk.Vcf.Ops deserialization defect on Alert.ResourceId, see AriaOpsHelpers.ps1 file header)."
                continue
            }
            try {
                $resourceNames[$resourceId] = (Get-VcfCheckAriaOpsResource -CredentialInfo $target.CredentialInfo -ResourceId $parsedResourceId).ResourceKey.Name
            } catch {
                $resourceNames[$resourceId] = $null
                Write-LogMessage -Type WARNING -Message "Could not resolve Aria Operations resource id `"$resourceId`" to a name: $($_.Exception.Message)"
            }
        }

        $rows = @($alerts | ForEach-Object {
            $resourceName = $resourceNames[$_.ResourceId]
            [PSCustomObject]@{
                AlertDefinition = $_.AlertDefinitionName
                Resource        = if ($resourceName) { $resourceName } else { $_.ResourceId }
                Criticality     = $_.AlertLevel
                Status          = $_.Status
                StartTime       = [DateTimeOffset]::FromUnixTimeMilliseconds($_.StartTimeUTC).UtcDateTime.ToString('yyyy-MM-dd')
            }
        })

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows $rows `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
    }

    return @($results)
}
#endregion
