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
function Test-VcfNsxtLatencyProfileCheck {

    <#
        .SYNOPSIS
        Checks for NSX latency-monitoring profiles with physical NIC latency stats enabled.

        .DESCRIPTION
        Checks for NSX latency-monitoring profiles with physical NIC (pNIC) latency stats enabled,
        which can block upgrades (KB 376769). Queries profiles via Invoke-ListPolicyLatencyProfiles
        (VMware.Sdk.Nsx.Policy) and evaluates each profile's PnicLatencyEnabled property.

        Per KB 376769, this condition only affects upgrades from NSX 4.2.1.2 and earlier. Versions
        4.2.1.2 and later are unaffected, so the check is skipped on those versions.

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

    $minimumFixedVersion = [Version]::new(4, 2, 1, 2)

    return Invoke-VcfCheckNsxtCheck -Context $Context -CheckId 'nsxt_latency_profile_check' -DisplayName $DisplayName -Body {
        param($Context, $NsxFqdn)
        try {
            $nsxVersion = Get-VcfCheckNsxManagerVersion -Context $Context -Server $NsxFqdn
        } catch {
            return [PSCustomObject]@{ Status = 'Error'; Detail = $_.Exception.Message; Blocking = $true }
        }

        if ($nsxVersion -and $nsxVersion -ge $minimumFixedVersion) {
            return [PSCustomObject]@{ Status = 'Skipped'; Detail = "NSX Manager is on $nsxVersion (4.2.1.2 or later); pNIC latency stats no longer block the upgrade."; SkipReasonTag = 'not applicable on this NSX version' }
        }

        try {
            $profiles = @(Get-VcfCheckNsxLatencyProfile -Server $NsxFqdn)
        } catch {
            return [PSCustomObject]@{ Status = 'Error'; Detail = $_.Exception.Message; Blocking = $true }
        }

        $enabledProfiles = @($profiles | Where-Object { $_.PnicLatencyEnabled })

        if ($enabledProfiles.Count -gt 0) {
            $profileNames = ($enabledProfiles | ForEach-Object { $_.DisplayName }) -join '; '
            $detail = "pNIC latency stats enabled on: $profileNames. Disable pNIC latency stats on these profiles before upgrading, " +
                'or see https://knowledge.broadcom.com/external/article/376769/nsx-manager-upgrade-prechecks-failure-fo.html ' +
                'for a work-around.'
            return [PSCustomObject]@{ Status = 'Fail'; Detail = $detail; Blocking = $true }
        }

        if ($profiles.Count -eq 0) {
            return [PSCustomObject]@{ Status = 'Pass'; Detail = 'No NSX latency-monitoring profiles are configured; pNIC latency stats are not applicable.'; Blocking = $true }
        }

        return [PSCustomObject]@{ Status = 'Pass'; Detail = "Checked $($profiles.Count) latency profile(s); none have pNIC latency stats enabled."; Blocking = $true }
    }
}
