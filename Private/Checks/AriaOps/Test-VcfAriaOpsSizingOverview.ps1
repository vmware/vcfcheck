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
function Test-VcfAriaOpsSizingOverview {

    <#
        .SYNOPSIS
        Reports Aria Operations' own self-monitored CPU/memory/disk/network/object-count metrics
        for reviewer visibility.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsTargets to connect to every known Aria Operations instance (the
        SDDC-Manager-known one, plus any standalone endpoint declared on the environment - see
        Private/AriaOpsHelpers.ps1), resolves the instance's self-monitoring adapter kind key via
        Get-VcfCheckAriaOpsSelfMonitoringAdapterKind (discovered from the instance's own adapter
        inventory rather than a hardcoded key - a hardcoded 'VCOPS_VCOPS_ADAPTER' guess was
        confirmed live to return zero resources, see ARIA_OPS_CONNECTOR_PLAN.md), enumerates that
        adapter's resources via Get-VcfCheckAriaOpsSelfMonitoringResources (the cluster and
        node(s) Aria Operations' own dashboards chart), and pulls their latest stats via
        Get-VcfCheckAriaOpsResourceStats.

        This is an inventory check with no numeric pass/fail threshold: the exact StatKey names
        Aria Operations reports for CPU/memory/disk/network/object-count metrics have not been
        confirmed live against a real instance (see ARIA_OPS_CONNECTOR_PLAN.md), so no numeric
        threshold is evaluated. Instead, every returned StatKey whose name matches a
        sizing-related keyword (cpu, mem, disk, network/net, storage, object, latency, capacity)
        is attributed to its resource for reviewer interpretation - a deliberately broad,
        name-based filter rather than a hardcoded key list, so it degrades gracefully if key
        names differ across versions.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations instance is known at all. A
          per-resource kind that never publishes sizing metrics (Watchdog, Admin UI, Adapter,
          Collector, Controller, ManagementPackGroup - see $noSizingMetricsResourceKindPattern)
          also reports its own row as Skipped rather than Warning, with a Detail explaining why,
          since it reporting zero sizing metrics is expected, not a sign of a stale/disconnected
          resource.
        - Warning: Returns 'Warning' if any self-monitoring resource of a kind that normally
          does publish sizing metrics reported zero of them (a stale or disconnected
          self-monitoring resource).
        - Pass: Returns 'Pass' when every self-monitoring resource that can report sizing
          metrics reported at least one.
        - Error: Returns 'Error' for a target if connecting or querying it fails, no
          self-monitoring adapter instance is found, or the API returns no self-monitoring
          resource data.

        Builds a per-resource breakdown ('HostDetails') with each resource's Status
        (Pass/Warning/Skipped) and the sizing-related metrics it reported, rendered as one
        collapsible card per resource with an alphabetized key/value table of its metrics -
        matching Test-VcfAriaApplianceDiskSpace's per-node card pattern. A metric whose
        latest data point is missing still appears in that table, with its value shown as
        'N/A' rather than being silently omitted.

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
    $checkId = 'aria_ops_sizing_overview'
    $sizingKeyPattern = '(?i)cpu|mem|disk|network|net_|net\||storage|object|latency|capacity'
    $noSizingMetricsResourceKindPattern = '(?i)watchdog|admin ui|adapter|collector|controller|managementpackgroup'

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
            $adapterKindKey = Get-VcfCheckAriaOpsSelfMonitoringAdapterKind -Connection $target.Connection
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to resolve Aria Operations' self-monitoring adapter kind: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        if (-not $adapterKindKey) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception 'No self-monitoring adapter instance was found on Aria Operations.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        try {
            $resourceResponse = Get-VcfCheckAriaOpsSelfMonitoringResources -Connection $target.Connection -AdapterKindKey $adapterKindKey
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for self-monitoring resources: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $resources = @($resourceResponse.ResourceList) | Where-Object { $_ -and $_.Identifier }
        if ($resources.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception 'No self-monitoring resource data returned from the Aria Operations API.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $resourceIds = @($resources | ForEach-Object { [Guid]$_.Identifier })
        try {
            $statsResponse = Get-VcfCheckAriaOpsResourceStats -Connection $target.Connection -ResourceId $resourceIds
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for self-monitoring stats: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $metricsByResourceId = @{}
        foreach ($resourceStats in @($statsResponse.Values)) {
            $matchedStats = @($resourceStats.StatList.Stat) | Where-Object { $_.StatKey.Key -match $sizingKeyPattern }
            $metricPairs = foreach ($stat in $matchedStats) {
                $value = @($stat.Data) | Select-Object -Last 1
                if ($null -eq $value -or [String]::IsNullOrWhiteSpace([String]$value)) {
                    $value = 'N/A'
                }
                [PSCustomObject]@{ Key = $stat.StatKey.Key; Value = $value }
            }
            $metricsByResourceId[$resourceStats.ResourceId.ToString()] = @($metricPairs | Sort-Object -Property Key)
        }

        $hostDetails = [System.Collections.Generic.List[PSObject]]::new()
        foreach ($resource in $resources) {
            $metrics = @($metricsByResourceId[$resource.Identifier.ToString()])
            $rowStatus = if ($metrics.Count -gt 0) {
                'Pass'
            } elseif ($resource.ResourceKey.Name -match $noSizingMetricsResourceKindPattern) {
                'Skipped'
            } else {
                'Warning'
            }
            $rowDetail = if ($rowStatus -eq 'Skipped') {
                'This resource kind does not publish sizing-related metrics - skipped, not a sign of a stale or disconnected resource.'
            } else {
                $null
            }
            $hostDetails.Add([PSCustomObject]@{
                HostName = $resource.ResourceKey.Name
                Status   = $rowStatus
                Detail   = $rowDetail
                Metrics  = $metrics
            })
        }

        $warningCount = @($hostDetails | Where-Object { $_.Status -eq 'Warning' }).Count
        $skippedCount = @($hostDetails | Where-Object { $_.Status -eq 'Skipped' }).Count
        $detail = if ($warningCount -gt 0) {
            "$($resources.Count) Aria Operations self-monitoring resource(s) found; $warningCount reporting no sizing-related metrics."
        } elseif ($skippedCount -gt 0) {
            "$($resources.Count) Aria Operations self-monitoring resource(s) found; $skippedCount are resource kinds that do not publish sizing-related metrics."
        } else {
            "$($resources.Count) Aria Operations self-monitoring resource(s) found, all reporting sizing-related metrics."
        }
        $overallStatus = if ($warningCount -gt 0) { 'Warning' } else { 'Pass' }

        New-VcfCheckResult -CheckId $checkId -Status $overallStatus `
            -TargetComponent $target.Fqdn -Detail $detail -HostDetails $hostDetails.ToArray() `
            -HostDetailsLabel 'Resources' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
    }

    return @($results)
}
#endregion
