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
function Test-VcfNsxtComputeManagerStatus {

    <#
        .SYNOPSIS
        Checks that every NSX Manager compute manager (vCenter registration) is registered and connected.

        .DESCRIPTION
        Queries GET /api/v1/fabric/compute-managers to list compute managers, then per-manager GET
        /api/v1/fabric/compute-managers/{id}/status (NSX Manager fabric API) to evaluate health.
        Passes only if every compute manager's registration_status is "registered" (case-insensitive)
        AND connection_status is "up" (case-insensitive); otherwise returns Fail.

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
    $checkId = 'nsxt_compute_manager_status'

    try {
        $nsxFqdn = Get-VcfCheckManagementNsxManagerFqdn -Context $Context
        $computeManagers = @((Invoke-VcfCheckNsxManagerApi -Context $Context -Fqdn $nsxFqdn -Path '/api/v1/fabric/compute-managers').results)
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $nsxFqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    if ($computeManagers.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -TargetComponent $nsxFqdn -Detail 'No compute managers are registered with NSX Manager.' -SkipReasonTag 'no compute managers' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $notHealthy = [System.Collections.Generic.List[String]]::new()
    foreach ($cm in $computeManagers) {
        try {
            $status = Invoke-VcfCheckNsxManagerApi -Context $Context -Fqdn $nsxFqdn -Path "/api/v1/fabric/compute-managers/$($cm.id)/status"
        } catch {
            return New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $nsxFqdn -Exception $_.Exception.Message `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }
        $registrationStatus = [String]$status.registration_status
        $connectionStatus = [String]$status.connection_status
        if ($registrationStatus.ToLowerInvariant() -ne 'registered' -or $connectionStatus.ToLowerInvariant() -ne 'up') {
            $notHealthy.Add("$($cm.display_name): registration=$registrationStatus, connection=$connectionStatus")
        }
    }

    if ($notHealthy.Count -gt 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Fail `
            -TargetComponent $nsxFqdn -Detail "Compute manager(s) not healthy: $($notHealthy -join '; ')" `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    return New-VcfCheckResult -CheckId $checkId -Status Pass `
        -TargetComponent $nsxFqdn -Detail "Checked $($computeManagers.Count) compute manager(s); all are registered and connected." `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
