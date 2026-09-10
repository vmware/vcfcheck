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
function Test-VcfNsxtCheckApiRate {

    <#
        .SYNOPSIS
        Checks NSX Manager's API rate-limiting configuration against the expected values, since
        non-default limits can break upgrades.

        .DESCRIPTION
        Queries NSX Manager's API rate-limiting configuration (/cluster/api-service) via Policy API
        (Get-VcfCheckNsxApiServiceConfig / Invoke-GetApiServiceConfig).

        Verifies that expected limits are configured:
        - ClientApiRateLimit == 100
        - ClientApiConcurrencyLimit == 40
        - GlobalApiConcurrencyLimit == 199
        - ConnectionTimeout == 30

        RedirectHost is informational only and does not affect the result. A missing value on any of
        the four core rate-limiting fields returns a Fail status, as an unconfirmed configuration
        presents a risk to upgrade operations.

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

    return Invoke-VcfCheckNsxtCheck -Context $Context -CheckId 'nsxt_check_api_rate' -DisplayName $DisplayName -Body {
        param($Context, $NsxFqdn)
        $expected = [Ordered]@{
            ClientApiRateLimit        = 100
            ClientApiConcurrencyLimit = 40
            GlobalApiConcurrencyLimit = 199
            ConnectionTimeout         = 30
        }
        $apiServiceConfig = Get-VcfCheckNsxApiServiceConfig -Server $NsxFqdn

        $missing = [System.Collections.Generic.List[String]]::new()
        $mismatched = [System.Collections.Generic.List[String]]::new()
        $rows = @()
        foreach ($field in $expected.Keys) {
            $value = $apiServiceConfig.$field
            $rows += [PSCustomObject]@{ Field = $field; CurrentValue = $value; ExpectedLimit = $expected[$field] }
            if ($null -eq $value) {
                $missing.Add($field)
                continue
            }
            if ([Int64]$value -ne $expected[$field]) {
                $mismatched.Add("$field=$value (expected $($expected[$field]))")
            }
        }
        $rows += [PSCustomObject]@{ Field = 'RedirectHost'; CurrentValue = $apiServiceConfig.RedirectHost; ExpectedLimit = $null }

        if ($missing.Count -gt 0) {
            return [PSCustomObject]@{ Status = 'Fail'; Detail = "Required field(s) missing from api-service config: $($missing -join '; '). Non-default NSX Manager API rate limits can break upgrades, so this cannot be confirmed."; Rows = $rows }
        }

        if ($mismatched.Count -gt 0) {
            return [PSCustomObject]@{ Status = 'Warning'; Detail = "Field(s) not at the expected value: $($mismatched -join '; '). Non-default NSX Manager API rate limits can break upgrades."; Rows = $rows }
        }

        return [PSCustomObject]@{ Status = 'Pass'; Detail = 'NSX Manager API rate-limiting configuration matches the expected values, which are required to avoid upgrade failures caused by non-default API rate limits.'; Rows = $rows }
    }
}
