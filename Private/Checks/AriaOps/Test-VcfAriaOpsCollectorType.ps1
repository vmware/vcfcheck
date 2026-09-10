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
function Test-VcfAriaOpsCollectorType {

    <#
        .SYNOPSIS
        Reports the Type of every Aria Operations collector (ARC vs. Cloud Proxy vs. other).

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsTargets to connect to every known Aria Operations instance (the
        SDDC-Manager-known one, plus any standalone endpoint declared on the environment - see
        Private/AriaOpsHelpers.ps1) and calls Get-VcfCheckAriaOpsCollectors against each,
        returning one result per target. This is an inventory check with no pass/fail threshold -
        it exists purely to surface each collector's deployment type (INTERNAL/REMOTE/CLOUD_PROXY/
        AAP/OTHER) for reviewer visibility, since the collector-status check (State) doesn't
        distinguish which collectors are Cloud Proxies vs. legacy remote collectors.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations instance is known at all.
        - Pass: Always returns 'Pass' when collector data is available - there is no failing
          condition for this check.
        - Error: Returns 'Error' for a target if connecting or querying it fails, or the API
          returns no collector data.

        Builds a detailed breakdown table ('Rows') of every collector's Name, HostName, and Type.

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
    $checkId = 'aria_ops_collector_type'

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
            $response = Get-VcfCheckAriaOpsCollectors -Connection $target.Connection
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for collector type: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $collectors = @($response.Collector)
        if ($collectors.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception 'No collector data returned from the Aria Operations API.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $typeCounts = $collectors | Group-Object -Property Type
        $summary = ($typeCounts | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
        $detail = "$($collectors.Count) Aria Operations collector(s) found: $summary."

        $rows = @($collectors | ForEach-Object {
            [PSCustomObject]@{
                Name     = $_.Name
                HostName = Resolve-VcfCheckAriaOpsCollectorFqdn -CredentialInfo $target.CredentialInfo -Collector $_
                Type     = $_.Type
            }
        })

        New-VcfCheckResult -CheckId $checkId -Status Pass `
            -TargetComponent $target.Fqdn -Detail $detail -Rows $rows `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
    }

    return @($results)
}
#endregion
