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
function Test-VcfSddcManagerDiskSpace {

    <#
        .SYNOPSIS
        Reports disk space usage on the SDDC Manager appliance.

        .DESCRIPTION
        Queries filesystem utilization (`df -h`) on the SDDC Manager appliance via
        Invoke-VcfApplianceCommand using vCenter guest operations and the SDDC Manager root credential.

        Parses the output using ConvertFrom-VcfCheckDfOutput and populates a structured Rows table
        detailing filesystem usage (Filesystem, Size, Used, Available, UsedPercent, MountedOn).

        Status returns Pass when filesystem details are successfully retrieved, or Error if command
        execution fails.

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
    $checkId = 'sddc_check_the_space'

    try {
        $vcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
        $rootCredential = Get-VcfCheckSddcManagerRootCredential -Context $Context
        $vmName = ($Context.SddcManagerFqdn -split '\.')[0]

        $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $vcenterFqdn -Credential $rootCredential `
            -ScriptText 'df -h'

        if (-not $commandResult.Success) {
            return New-VcfCheckApplianceCommandFailureResult -CommandResult $commandResult -CheckId $checkId `
                -TargetComponent $vmName -StartedAt $startedAt
        }

        return New-VcfCheckResult -CheckId $checkId -Status Pass `
            -TargetComponent $vmName -Detail "Successfully retrieved filesystem details" `
            -Rows (ConvertFrom-VcfCheckDfOutput -ScriptOutput $commandResult.ScriptOutput) `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }
}
