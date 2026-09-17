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
#region AriaAutomation
function Test-VcfAriaAutomationCloudAccountHealth {

    <#
        .SYNOPSIS
        Verifies that every Aria Automation cloud account reports a healthy connection to its
        underlying cloud provider.

        .DESCRIPTION
        Calls Get-VcfCheckAriaAutomationTargets to connect to every known Aria Automation
        instance (the SDDC-Manager-known one, plus any standalone endpoint declared on the
        environment - see Private/AriaAutomationHelpers.ps1) and calls
        GET /iaas/api/cloud-accounts against each, returning one result per target. A cloud
        account is flagged when its Healthy property is $false - per the IaaS API schema this
        means there is no connectivity to the cloud provider or the stored credentials are
        invalid. A cloud account in maintenance mode is noted in its row but does not on its own
        fail the check, since maintenance mode is an intentional administrative state.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Automation instance is known at all.
        - Pass: Returns 'Pass' for a target if every cloud account reports Healthy = true.
        - Fail: Returns 'Fail' for a target if one or more cloud accounts report Healthy = false.
        - Error: Returns 'Error' for a target if connecting or querying it fails.

        Builds a detailed breakdown table ('Rows') of every cloud account's Name,
        CloudAccountType, Healthy, and InMaintenanceMode.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Automation instance.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'aria_automation_cloud_account_health'

    $targets = Get-VcfCheckAriaAutomationTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Automation is not deployed in this environment.' -SkipReasonTag 'Aria Automation not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Automation'
    }

    $results = foreach ($target in $targets) {
        $resultDisplayName = if ($targets.Count -gt 1) { "$DisplayName ($($target.Name))" } else { $DisplayName }

        if ($target.ConnectError) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception $target.ConnectError `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        try {
            $response = Invoke-VcfCheckAriaAutomationApi -CredentialInfo $target.CredentialInfo -Path '/iaas/api/cloud-accounts'
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Automation for cloud accounts: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        $cloudAccounts = @($response.content)
        if ($cloudAccounts.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $target.Fqdn -Detail 'No cloud accounts are configured in Aria Automation.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        Write-LogMessage -Type DEBUG -Message "Found $($cloudAccounts.Count) cloud account(s) on `"$($target.Fqdn)`": $(($cloudAccounts | ForEach-Object { $_.name }) -join ', ')"

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $flagged = [System.Collections.Generic.List[String]]::new()

        foreach ($cloudAccount in $cloudAccounts) {
            $isHealthy = [Bool]$cloudAccount.healthy
            $rows.Add([PSCustomObject]@{
                Name               = $cloudAccount.name
                CloudAccountType   = $cloudAccount.cloudAccountType
                Healthy            = $isHealthy
                InMaintenanceMode  = [Bool]$cloudAccount.inMaintenanceMode
            })

            if (-not $isHealthy) {
                $flagged.Add("$($cloudAccount.name): no connectivity to the cloud provider or invalid credentials")
            }
        }

        if ($flagged.Count -eq 0) {
            $status = 'Pass'
            $detail = "All $($cloudAccounts.Count) Aria Automation cloud account(s) report a healthy connection to their cloud provider."
        } else {
            $status = 'Fail'
            $detail = ($flagged.ToArray()) -join '; '
        }

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows ($rows.ToArray() | Sort-Object -Property Name) `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
    }

    return @($results)
}
#endregion
