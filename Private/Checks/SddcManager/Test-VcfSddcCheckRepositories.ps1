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
function Test-VcfSddcCheckRepositories {

    <#
        .SYNOPSIS
        Checks SDDC Manager's configured depot (Broadcom repository) account status.

        .DESCRIPTION
        Queries SDDC Manager depot settings via Invoke-VcfGetDepotSettings to inspect configured
        online (VmwareAccount) and offline (OfflineAccount) depot accounts.

        Evaluates account status properties:
        - Only 'DEPOT_CONNECTION_SUCCESSFUL' is treated as healthy (Pass).
        - Any other status (e.g., 'DEPOT_USER_NOT_SET', 'DEPOT_INVALID_CREDENTIAL') or an unconfigured
          depot state returns a Fail result.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

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
    $checkId = 'sddc_check_repositories'

    try {
        $depotSettings = Invoke-VcfGetDepotSettings -ErrorAction Stop
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $Context.SddcManagerFqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $accounts = [Ordered]@{
        'Online Depot'  = $depotSettings.VmwareAccount
        'Offline Depot' = $depotSettings.OfflineAccount
    }

    $configured = $accounts.GetEnumerator() | Where-Object { $_.Value -and -not [String]::IsNullOrWhiteSpace($_.Value.Status) }

    if (-not $configured) {
        return New-VcfCheckResult -CheckId $checkId -Status Fail `
            -TargetComponent $Context.SddcManagerFqdn -Detail 'No depot account (online or offline) appears to be configured.' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $unhealthy = @($configured | Where-Object { $_.Value.Status -ne 'DEPOT_CONNECTION_SUCCESSFUL' })

    if ($unhealthy.Count -gt 0) {
        $details = ($unhealthy | ForEach-Object {
            $msg = if ($_.Value.Message) { ": $($_.Value.Message)" } else { '' }
            "$($_.Key) [$($_.Value.Status)]$msg"
        }) -join '; '
        return New-VcfCheckResult -CheckId $checkId -Status Fail `
            -TargetComponent $Context.SddcManagerFqdn -Detail $details `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $details = ($configured | ForEach-Object {
        "$($_.Key) [$($_.Value.Status)]"
    }) -join '; '
    return New-VcfCheckResult -CheckId $checkId -Status Pass `
        -TargetComponent $Context.SddcManagerFqdn -Detail $details `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
