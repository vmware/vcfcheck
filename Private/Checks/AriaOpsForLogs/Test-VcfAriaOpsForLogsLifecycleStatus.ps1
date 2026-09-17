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
function Test-VcfAriaOpsForLogsLifecycleStatus {

    <#
        .SYNOPSIS
        Validates Aria Operations for Logs' own reported version against Broadcom's public
        Interop Matrix upgrade-path status, queried directly from Aria Operations for Logs.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsForLogsTargets to connect to every Aria Operations for Logs instance
        declared on the environment (see Private/AriaOpsForLogsHelpers.ps1) and, for each, calls
        Get-VcfCheckAriaOpsForLogsVersion ('GET /api/v2/version') to obtain the installed version
        directly from its own API.

        Judges compliance in the same priority order as Test-VcfAriaOpsLifecycleStatus (see
        New-VcfCheckBomComplianceRow):
        1. PRIMARY - Broadcom's public Interop Matrix's own per-version-pair upgrade-path status
           (Get-VcfCheckInteropMatrixCompatibilityVerdict), component 'VRLI'.
        2. FALLBACK - a floor (>=) comparison against a minimum compatible version derived from
           the same shipped snapshot (Get-VcfCheckInteropMatrixMinimumCompatibleVersion), used
           when the Interop Matrix has no resolvable per-pair verdict for this exact installed
           version.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations for Logs instance is known at all.
        - Pass: Returns 'Pass' for a target if the Interop Matrix reports it Compatible with
          DestinationVersion, or its installed version meets or exceeds the derived floor.
        - Fail: Returns 'Fail' for a target if the Interop Matrix reports Incompatible, or (when
          no Interop Matrix verdict resolves) the installed version falls below the derived floor.
        - Pass (unconfirmed): Returns 'Pass' with an unconfirmed detail if neither the Interop
          Matrix verdict nor a derived floor could be resolved for DestinationVersion at all - an
          unconfirmed "cannot tell" is never reported as a blocking Fail.
        - Error: Returns 'Error' for a target if connecting or querying it fails.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER VcfDestinationRelease
        Same top-level destination-release selection Test-VcfSddcBomCheck accepts - a full
        concrete release, a release family (major.minor.patch), or 'latest'. A family or 'latest'
        is resolved to Aria Operations for Logs' own newest matching release via
        Resolve-VcfCheckInteropMatrixReleaseInFamily. Defaults to
        $Script:VcfCheckDefaultDestinationRelease ('latest').

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Operations for Logs instance.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$VcfDestinationRelease = $Script:VcfCheckDefaultDestinationRelease
    )

    $startedAt = Get-Date
    $checkId = 'aria_ops_for_logs_lifecycle_status'

    $targets = Get-VcfCheckAriaOpsForLogsTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Operations for Logs is not deployed in this environment.' -SkipReasonTag 'Aria Operations for Logs not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Operations for Logs'
    }

    $isDestinationReleaseFamily = ($VcfDestinationRelease -eq 'latest') -or ($VcfDestinationRelease -match '^\d+\.\d+\.\d+$')
    $destinationVersion = $VcfDestinationRelease
    if ($isDestinationReleaseFamily) {
        $resolvedRelease = Resolve-VcfCheckInteropMatrixReleaseInFamily -Component 'VRLI' -Family $VcfDestinationRelease
        if ($resolvedRelease) { $destinationVersion = $resolvedRelease }
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
            $installedVersion = Get-VcfCheckAriaOpsForLogsVersion -Session $target.Session
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for Logs for its version: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        $interopVerdict = $null
        try {
            $interopVerdict = Get-VcfCheckInteropMatrixCompatibilityVerdict -Component VRLI -InstalledVersion $installedVersion -DestinationVersion $destinationVersion -ErrorAction Stop
        } catch {
            Write-LogMessage -Type WARNING -Message "Interop Matrix compatibility lookup failed for Aria Operations for Logs ($installedVersion -> $destinationVersion): $($_.Exception.Message)"
        }
        $resolvedFloor = Get-VcfCheckInteropMatrixMinimumCompatibleVersion -Component VRLI -DestinationVersion $destinationVersion

        if (-not $interopVerdict -and -not $resolvedFloor) {
            $row = [PSCustomObject]@{
                Domain = 'N/A'; Component = 'Aria Operations for Logs'; Target = $target.Fqdn
                InstalledVersion = $installedVersion; MinimumDirectUpgradeVersion = 'N/A'
                ReadyforUpgrade = $true; FailureReason = 'N/A'
            }
            $status = 'Pass'
            $detail = "Could not confirm Aria Operations for Logs version $installedVersion against Broadcom's Interop Matrix for upgrade to $destinationVersion - no Interop Matrix data available for this pair."
        } else {
            $minVersionStr = if ($resolvedFloor) { $resolvedFloor } else { $installedVersion }
            $complianceRow = New-VcfCheckBomComplianceRow -Domain 'N/A' -Component 'Aria Operations for Logs' -Target $target.Fqdn `
                -InstalledVersion $installedVersion -MinimumVersion $minVersionStr `
                -InteropComponent VRLI -DestinationVersion $destinationVersion

            $row = [PSCustomObject]@{
                Domain                      = $complianceRow.Domain
                Component                   = $complianceRow.Component
                Target                      = $complianceRow.Target
                InstalledVersion            = $complianceRow.InstalledVersion
                MinimumDirectUpgradeVersion = if ($resolvedFloor) { $resolvedFloor } else { 'N/A' }
                ReadyforUpgrade             = $complianceRow.ReadyforUpgrade
                FailureReason               = $complianceRow.FailureReason
            }

            $status = if ($row.ReadyforUpgrade) { 'Pass' } else { 'Fail' }
            $detail = if ($row.ReadyforUpgrade) {
                "Aria Operations for Logs version $installedVersion meets the requirement for upgrade to $destinationVersion."
            } else {
                $row.FailureReason
            }
        }

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows @($row) `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
    }

    return @($results)
}
#endregion
