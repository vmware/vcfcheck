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
function Test-VcfNsxtFederationCheck {

    <#
        .SYNOPSIS
        Detects whether NSX Federation is configured on the management NSX Manager.

        .DESCRIPTION
        Queries GET /policy/api/v1/infra/federation-config via Get-VcfCheckNsxFederationConfig /
        Invoke-ReadFederationConfig to determine if NSX Federation site configuration is present.
        A 404 (endpoint not found) indicates no federation configuration exists, in which case the check
        returns a Skipped status.

        When federation configuration is detected, returns a Warning status with guidance pointing to
        the Global Manager upgrade instructions for VMware Cloud Foundation.

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

    return Invoke-VcfCheckNsxtCheck -Context $Context -CheckId 'nsxt_federation_check' -DisplayName $DisplayName -Body {
        param($Context, $NsxFqdn)
        try {
            $federationConfig = Get-VcfCheckNsxFederationConfig -Server $NsxFqdn
        } catch {
            if ($_.Exception.Message -match '404|not\s*found') {
                return [PSCustomObject]@{ Status = 'Skipped'; Detail = 'No NSX Federation site configuration detected; check is not applicable.'; SkipReasonTag = 'No NSX Federation' }
            }
            throw
        }

        return [PSCustomObject]@{
            Status = 'Warning'
            Detail = "NSX Federation site configuration detected (site path: $($federationConfig.SiteConfig.SitePath)). Global Managers require additional steps as part of the VCF 9 upgrade process - see [Upgrading NSX in a Federated Environment](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/deployment/upgrading-cloud-foundation/upgrade-the-management-domain-to-vmware-cloud-foundation-5-2/upgrading-nsx--to-version-9/upgrade-nsx-in-a-federated-environment.html)"
        }
    }
}
