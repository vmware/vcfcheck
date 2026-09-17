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
function Test-VcfAriaAutomationFipsStatus {

    <#
        .SYNOPSIS
        Reports Aria Automation's FIPS mode setting via `vracli security fips`.

        .DESCRIPTION
        Calls Get-VcfCheckAriaAutomationTargets to connect to every known Aria Automation
        instance, then for each target with guestOS checks enabled (a VCenterFqdn configured on
        its endpoint) connects to that vCenter and runs `vracli security fips` via
        Invoke-VcfApplianceCommand against a single appliance node (FIPS mode is a cluster-wide
        setting in Aria Automation, not per-node, so unlike Test-VcfAriaAutomationApplianceHealth
        this does not fan out across every VmNames entry). This is purely informational - there
        is no Broadcom-mandated FIPS requirement, so the check always reports Pass once the
        setting is successfully read, regardless of whether FIPS is enabled or disabled.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Automation instance is known at all, or if a
          target has no VCenterFqdn configured (guestOS checks not enabled for that endpoint).
        - Error: A target's connection failed, the guestOS vCenter connection or credential
          could not be established, or the guestOS command failed or returned output that could
          not be parsed for a FIPS mode value.
        - Pass: The FIPS mode setting was read successfully (reported regardless of whether it
          is enabled or disabled).

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Automation instance with guestOS
        checks enabled.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'aria_automation_fips_status'
    $fipsCommand = 'vracli security fips'

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

        $endpoint = $Context.AriaAutomationEndpoints | Where-Object { $_.Fqdn -eq $target.Fqdn }
        if (-not $endpoint -or [String]::IsNullOrWhiteSpace($endpoint.VCenterFqdn)) {
            New-VcfCheckResult -CheckId $checkId -Status Skipped `
                -TargetComponent $target.Fqdn `
                -Detail "GuestOS checks are not enabled for `"$($target.Fqdn)`" - a vCenter FQDN must be configured on this endpoint to run the FIPS status check." `
                -SkipReasonTag 'GuestOS checks not enabled' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        try {
            Connect-VcfCheckVCenter -Context $Context -Fqdn $endpoint.VCenterFqdn
            $rootCredential = Get-VcfCheckAriaVCenterRootCredential -Context $Context -Fqdn $endpoint.VCenterFqdn
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception "Failed to prepare guestOS checks against `"$($endpoint.VCenterFqdn)`": $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        if ($endpoint.VmNames.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Skipped `
                -TargetComponent $target.Fqdn `
                -Detail "No VM name is configured for `"$($target.Fqdn)`" - guestOS checks never guess a VM name, since a wrong guess could silently check the wrong node; add one in the environment editor to run this check." `
                -SkipReasonTag 'VM name not configured' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }
        $vmName = $endpoint.VmNames[0]
        $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $endpoint.VCenterFqdn -Credential $rootCredential -ScriptText $fipsCommand

        if (-not $commandResult.Success) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "[$($commandResult.ErrorCategory)] $($commandResult.ErrorMessage)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        $fipsMatch = [Regex]::Match($commandResult.ScriptOutput, 'FIPS mode:\s*(\S+)')
        if (-not $fipsMatch.Success) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "`"$fipsCommand`" on `"$vmName`" returned output that could not be parsed for a FIPS mode value." `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        New-VcfCheckResult -CheckId $checkId -Status Pass -Informational `
            -TargetComponent $target.Fqdn -Detail "FIPS mode: $($fipsMatch.Groups[1].Value)." `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
    }

    return @($results)
}
#endregion
