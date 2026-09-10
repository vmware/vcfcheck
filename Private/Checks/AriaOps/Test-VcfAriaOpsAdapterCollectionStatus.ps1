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
function Test-VcfAriaOpsAdapterCollectionStatus {

    <#
        .SYNOPSIS
        Verifies that every Aria Operations adapter instance is actively collecting data.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsTargets to connect to every known Aria Operations instance (the
        SDDC-Manager-known one, plus any standalone endpoint declared on the environment - see
        Private/AriaOpsHelpers.ps1) and calls Get-VcfCheckAriaOpsAdapterInstances against each to
        enumerate every configured adapter instance, returning one result per target. For each
        adapter instance, calls Get-VcfCheckAriaOpsAdapterResources to retrieve its monitored
        resources and inspects their ResourceStatusStates entries for that adapter instance's Id.
        An adapter instance is considered healthy if at least one of its resources reports
        ResourceStatus 'DATA_RECEIVING' or 'OLD_DATA_RECEIVING'; it is flagged if every associated
        resource reports a down/no-data status (e.g. 'COLLECTOR_DOWN', 'NO_DATA_RECEIVING',
        'DOWN', 'ERROR'). Adapter instances with no associated resources are reported separately
        and do not count as a failure on their own.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations instance is known at all.
        - Pass: Returns 'Pass' for a target if every adapter instance with at least one resource
          is collecting data.
        - Fail: Returns 'Fail' for a target if one or more adapter instances report no resource
          in a collecting state.
        - Error: Returns 'Error' for a target if connecting or querying it fails, or the API
          returns no adapter instance data.

        Builds a detailed breakdown table ('Rows') of every adapter instance's Name,
        AdapterKindKey, ResourceCount, and Status.

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
    $checkId = 'aria_ops_adapter_collection_status'
    $collectingStatuses = @('DATA_RECEIVING', 'OLD_DATA_RECEIVING')

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
            $response = Get-VcfCheckAriaOpsAdapterInstances -Connection $target.Connection
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for adapter instances: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $adapters = @($response.AdapterInstancesInfoDto)
        if ($adapters.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception 'No adapter instance data returned from the Aria Operations API.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        Write-LogMessage -Type DEBUG -Message "Found $($adapters.Count) adapter instance(s) on `"$($target.Fqdn)`": $(($adapters | ForEach-Object { $_.ResourceKey.Name }) -join ', ')"

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $flagged = [System.Collections.Generic.List[String]]::new()

        foreach ($adapter in $adapters) {
            $adapterName = $adapter.ResourceKey.Name
            $adapterKind = $adapter.ResourceKey.AdapterKindKey

            try {
                $resourceResponse = Get-VcfCheckAriaOpsAdapterResources -CredentialInfo $target.CredentialInfo -AdapterId $adapter.Id
            } catch {
                $rows.Add([PSCustomObject]@{ Name = $adapterName; AdapterKindKey = $adapterKind; ResourceCount = 'Unknown'; Status = 'Fail' })
                $flagged.Add("$adapterName`: failed to query resources ($($_.Exception.Message))")
                continue
            }

            $resources = @($resourceResponse.ResourceList)
            $states = @($resources | ForEach-Object { $_.ResourceStatusStates } | Where-Object { $_ -and $_.AdapterInstanceId -eq $adapter.Id.ToString() })
            $isCollecting = [Bool](@($states | Where-Object { $_.ResourceStatus -in $collectingStatuses }).Count -gt 0)

            if ($states.Count -eq 0) {
                $adapterStatus = 'Unknown'
            } elseif ($isCollecting) {
                $adapterStatus = 'Pass'
            } else {
                $adapterStatus = 'Fail'
                $downStatuses = (@($states | ForEach-Object { $_.ResourceStatus } | Where-Object { $_ } | Select-Object -Unique)) -join ', '
                $flagged.Add("$adapterName`: no resource in a collecting state (reported: $downStatuses)")
            }

            $rows.Add([PSCustomObject]@{ Name = $adapterName; AdapterKindKey = $adapterKind; ResourceCount = $resources.Count; Status = $adapterStatus })
        }

        if ($flagged.Count -eq 0) {
            $status = 'Pass'
            $detail = "All $($adapters.Count) Aria Operations adapter instance(s) with monitored resources are collecting data."
        } else {
            $status = 'Fail'
            $detail = ($flagged.ToArray()) -join '; '
        }

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows ($rows.ToArray() | Sort-Object -Property Name) `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
    }

    return @($results)
}
#endregion
