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
function Test-VcfSddcVxManagerTable {

    <#
        .SYNOPSIS
        Checks SDDC Manager's internal platform.vx_manager table for error rows.

        .DESCRIPTION
        Queries SDDC Manager's internal Postgres database (`platform` DB, `vx_manager` table) via
        Invoke-VcfApplianceCommand using vCenter guest operations against the SDDC Manager VM.

        First verifies whether the environment is VxRail-managed by querying the management vCenter's
        `config.SDDC.Deployed.Type` advanced setting via Get-VcfCheckSddcType. If the deployment type
        is not `VCF-VxRail`, the check returns a Skipped status as the `vx_manager` table is only
        populated on VxRail-integrated environments.

        For VxRail deployments, resolves the `psql` path via Get-VcfCheckPsqlExecutablePath and
        executes `SELECT * FROM vx_manager;` as user `postgres` over TCP loopback.

        Evaluation logic:
        - Skipped: Environment is not VxRail-managed (`config.SDDC.Deployed.Type` is not `VCF-VxRail`).
        - Pass: Query succeeds and no `ERROR` text is present in the table output.
        - Warning: `ERROR` substring is detected within the output.
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
    $checkId = 'sddc_vx_manager_table'

    try {
        $vcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn

        $sddcType = Get-VcfCheckSddcType -Server $vcenterFqdn
        if ($sddcType -ne 'VCF-VxRail') {
            $detail = if ([String]::IsNullOrWhiteSpace($sddcType)) {
                'VxRail was not detected on this SDDC (could not resolve the SDDC type) - skipping the VxRail Manager Table check.'
            } else {
                "VxRail was not detected on this SDDC (SDDC type: `"$sddcType`") - skipping the VxRail Manager Table check."
            }
            return New-VcfCheckResult -CheckId $checkId -Status Skipped `
                -TargetComponent $Context.SddcManagerFqdn -Detail $detail -SkipReasonTag 'Not VxRail-Managed' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        $rootCredential = Get-VcfCheckSddcManagerRootCredential -Context $Context
        $vmName = ($Context.SddcManagerFqdn -split '\.')[0]
        $psqlPath = Get-VcfCheckPsqlExecutablePath -VcfVersion (Get-VcfCheckVcfVersion -Context $Context)

        $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $vcenterFqdn -Credential $rootCredential `
            -ScriptText "$psqlPath -h localhost -U postgres -d platform -t -c `"SELECT * FROM vx_manager;`""

        if (-not $commandResult.Success) {
            return New-VcfCheckApplianceCommandFailureResult -CommandResult $commandResult -CheckId $checkId `
                -TargetComponent $vmName -StartedAt $startedAt
        }

        if ($commandResult.ScriptOutput -match 'ERROR') {
            return New-VcfCheckResult -CheckId $checkId -Status Warning `
                -TargetComponent $vmName -Detail "ERROR found in vx_manager table output: $($commandResult.ScriptOutput.Trim())" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        return New-VcfCheckResult -CheckId $checkId -Status Pass `
            -TargetComponent $vmName -Detail 'No ERROR rows found in the platform.vx_manager table.' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }
}
