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
function Test-VcfNsxtCheckNodeInstallUpgrade {

    <#
        .SYNOPSIS
        Checks that NSX Manager's node install/upgrade service is enabled and bound to an IP address.

        .DESCRIPTION
        Queries GET /api/v1/node/services/install-upgrade (NSX Manager node-service API)
        via Invoke-VcfCheckNsxManagerApi, inspecting service_properties.enabled and
        service_properties.enabled_on. Pass condition requires the service to be enabled AND
        enabled_on to be configured as a valid IPv4 address (rather than a hostname or FQDN).

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
    $checkId = 'nsxt_check_node_install_upgrade'
    $ipv4Pattern = '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'

    try {
        $nsxFqdn = Get-VcfCheckManagementNsxManagerFqdn -Context $Context
        $response = Invoke-VcfCheckNsxManagerApi -Context $Context -Fqdn $nsxFqdn -Path '/api/v1/node/services/install-upgrade'
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $nsxFqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $properties = $response.service_properties
    if (-not $properties) {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $nsxFqdn -Detail 'service_properties missing from the API response.' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $enabledOn = [String]$properties.enabled_on
    $isIp = $enabledOn -match $ipv4Pattern

    if (-not $properties.enabled -or -not $isIp) {
        return New-VcfCheckResult -CheckId $checkId -Status Fail `
            -TargetComponent $nsxFqdn -Detail "enabled=$($properties.enabled), enabled_on=`"$enabledOn`" (IPv4: $isIp)" `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    return New-VcfCheckResult -CheckId $checkId -Status Pass `
        -TargetComponent $nsxFqdn -Detail "Service is enabled and bound to $enabledOn." `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
