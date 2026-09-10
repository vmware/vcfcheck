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
function Test-VcfNsxtCheckNappIntelligence {

    <#
        .SYNOPSIS
        Checks NSX Application Platform (NAPP) registration/connectivity status.

        .DESCRIPTION
        Uses Invoke-ListNappRegistrations (VMware.Sdk.Nsx.Policy) and the registration's
        IsDisconnected/Status fields to verify NSX Application Platform (NAPP) cluster
        connectivity. A disconnected NAPP cluster returns Fail, indicating the Application
        Platform cannot be reached from NSX Manager. Reports Skipped when NSX Application Platform
        is not registered, as this represents a valid environment state.

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

    return Invoke-VcfCheckNsxtCheck -Context $Context -CheckId 'nsxt_check_napp_intelligence' -DisplayName $DisplayName -Body {
        param($Context, $NsxFqdn)
        $registrations = @(Get-VcfCheckNsxNappRegistration -Server $NsxFqdn)

        if ($registrations.Count -eq 0) {
            return [PSCustomObject]@{ Status = 'Skipped'; Detail = 'NSX Application Platform is not registered.'; SkipReasonTag = 'NAPP not registered' }
        }

        $disconnected = @($registrations | Where-Object { $_.IsDisconnected })

        if ($disconnected.Count -gt 0) {
            $clusterNames = ($disconnected | ForEach-Object { $_.ClusterName }) -join '; '
            return [PSCustomObject]@{ Status = 'Fail'; Detail = "Disconnected NAPP cluster(s): $clusterNames" }
        }

        return [PSCustomObject]@{ Status = 'Pass'; Detail = "Checked $($registrations.Count) NAPP registration(s); all connected." }
    }
}
