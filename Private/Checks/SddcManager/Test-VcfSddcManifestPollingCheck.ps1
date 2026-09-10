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
function Test-VcfSddcManifestPollingCheck {

    <#
        .SYNOPSIS
        Checks that SDDC Manager's LCM manifest polling is enabled.

        .DESCRIPTION
        Inspects SDDC Manager's LCM properties file
        (/opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties) via Invoke-VcfApplianceCommand
        using vCenter guest operations and the SDDC Manager root credential.

        Evaluates the configuration setting:
        - Pass: `lcm.core.enableManifestPolling=true` is explicitly set in the properties file.
        - Warning: Manifest polling is disabled or set to a non-true value.
        - Error: Appliance command execution fails.

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
    $checkId = 'sddc_manifest_polling_check'

    try {
        $vcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
        $rootCredential = Get-VcfCheckSddcManagerRootCredential -Context $Context
        $vmName = ($Context.SddcManagerFqdn -split '\.')[0]

        $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $vcenterFqdn -Credential $rootCredential `
            -ScriptText 'grep lcm.core.enableManifestPolling /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties'

        if (-not $commandResult.Success) {
            return New-VcfCheckApplianceCommandFailureResult -CommandResult $commandResult -CheckId $checkId `
                -TargetComponent $vmName -StartedAt $startedAt
        }

        if ($commandResult.ScriptOutput -match 'lcm\.core\.enableManifestPolling=true') {
            return New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $vmName -Detail 'LCM manifest polling is enabled.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        return New-VcfCheckResult -CheckId $checkId -Status Warning `
            -TargetComponent $vmName -Detail "LCM manifest polling is not enabled (raw output: $($commandResult.ScriptOutput.Trim()))." `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }
}
