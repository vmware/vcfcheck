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
function Test-VcfCheckAriaAutomationNodeNtpStatus {

    <#
        .SYNOPSIS
        Runs and evaluates `vracli ntp status --local` for a single Aria Automation appliance node.

        .DESCRIPTION
        Helper for Test-VcfAriaAutomationNtpStatus. Runs `vracli ntp status --local` on the named
        VM via Invoke-VcfApplianceCommand (guest operations through vCenter, not a direct SSH
        session) and parses the "System clock synchronized" and "NTP service" lines from its
        plain-text output (there is no JSON option for this vracli subcommand). Passes only when
        the clock is synchronized ("yes") and the NTP service is active ("active"); any other
        observed value for either field is treated as a failure rather than enumerated
        individually.

        .PARAMETER VmName
        The appliance node's vCenter inventory VM name.

        .PARAMETER VCenterFqdn
        FQDN of the already-connected vCenter that manages the appliance VM.

        .PARAMETER Credential
        GuestOS root credential to authenticate the guest operation.

        .OUTPUTS
        [PSCustomObject] with HostName, Status ('Pass'/'Warning'/'Error'), and Detail properties.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VmName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VCenterFqdn,
        [Parameter(Mandatory = $true)] [PSCredential]$Credential
    )

    $ntpCommand = 'vracli ntp status --local'
    $commandResult = Invoke-VcfApplianceCommand -VmName $VmName -Server $VCenterFqdn -Credential $Credential -ScriptText $ntpCommand

    if (-not $commandResult.Success) {
        return [PSCustomObject]@{
            HostName = $VmName
            Status   = 'Error'
            Detail   = "[$($commandResult.ErrorCategory)] $($commandResult.ErrorMessage)"
        }
    }

    $output = $commandResult.ScriptOutput
    $syncMatch = [Regex]::Match($output, 'System clock synchronized:\s*(\S+)')
    $serviceMatch = [Regex]::Match($output, 'NTP service:\s*(\S+)')

    if (-not $syncMatch.Success -or -not $serviceMatch.Success) {
        return [PSCustomObject]@{
            HostName = $VmName
            Status   = 'Error'
            Detail   = "`"$ntpCommand`" on `"$VmName`" returned output that could not be parsed for NTP status."
        }
    }

    $synchronized = $syncMatch.Groups[1].Value
    $ntpService = $serviceMatch.Groups[1].Value

    if ($synchronized -eq 'yes' -and $ntpService -eq 'active') {
        return [PSCustomObject]@{
            HostName = $VmName
            Status   = 'Pass'
            Detail   = "System clock synchronized: $synchronized, NTP service: $ntpService."
        }
    }

    return [PSCustomObject]@{
        HostName = $VmName
        Status   = 'Warning'
        Detail   = "System clock synchronized: $synchronized, NTP service: $ntpService."
    }
}
function Test-VcfAriaAutomationNtpStatus {

    <#
        .SYNOPSIS
        Runs `vracli ntp status --local` on every Aria Automation appliance node and flags any
        node whose clock is not synchronized or whose NTP service is not active.

        .DESCRIPTION
        Calls Get-VcfCheckAriaAutomationTargets to connect to every known Aria Automation
        instance, then for each target with guestOS checks enabled (a VCenterFqdn configured on
        its endpoint) connects to that vCenter and runs Test-VcfCheckAriaAutomationNodeNtpStatus
        against every VM name configured on the endpoint (Private/Environments.ps1's VmNames
        field), falling back to the FQDN's hostname label for a single-node appliance without an
        explicit VmNames entry. Reports per-node sub-progress via Write-VcfCheckSubProgress as
        each node is checked.

        Outcome behavior (per target, folded into one VcfCheck.Result with one HostDetails entry
        per appliance node):
        - Skipped: Returns 'Skipped' if no Aria Automation instance is known at all, or if a
          target has no VCenterFqdn configured (guestOS checks not enabled for that endpoint).
        - Error: A target's connection failed, the guestOS vCenter connection or credential
          could not be established, or a node's guestOS command failed or returned unparsable
          output.
        - Warning: A node's clock is not synchronized or its NTP service is not active.
        - Pass: Every node's clock is synchronized and its NTP service is active.

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
    $checkId = 'aria_automation_ntp_status'

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
                -Detail "GuestOS checks are not enabled for `"$($target.Fqdn)`" - a vCenter FQDN must be configured on this endpoint to run appliance NTP checks." `
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
                -Detail "No VM name(s) are configured for `"$($target.Fqdn)`" - guestOS checks never guess a VM name, since a wrong guess could silently check only one node of a multi-node deployment; add the VM name(s) in the environment editor to run this check." `
                -SkipReasonTag 'VM name(s) not configured' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }
        $nodeNames = @($endpoint.VmNames)
        $hostDetails = [System.Collections.Generic.List[PSCustomObject]]::new()
        $nodeIndex = 0
        foreach ($vmName in $nodeNames) {
            $nodeIndex++
            Write-VcfCheckSubProgress -Context $Context -Current $nodeIndex -Total $nodeNames.Count `
                -Label $vmName -Unit 'Aria Automation appliance nodes'
            $hostDetails.Add((Test-VcfCheckAriaAutomationNodeNtpStatus -VmName $vmName -VCenterFqdn $endpoint.VCenterFqdn -Credential $rootCredential))
        }

        $severityByStatus = @{ Error = 3; Warning = 2; Pass = 1 }
        $targetStatus = ($hostDetails | Sort-Object -Property { $severityByStatus[$_.Status] } -Descending | Select-Object -First 1).Status
        $statusCounts = $hostDetails | Group-Object -Property Status
        $targetDetail = "Checked NTP status on $($hostDetails.Count) Aria Automation appliance node(s) on `"$($target.Fqdn)`": $(($statusCounts | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ')."

        New-VcfCheckResult -CheckId $checkId -Status $targetStatus `
            -TargetComponent $target.Fqdn -Detail $targetDetail -HostDetails $hostDetails.ToArray() -HostDetailsLabel 'Appliance Nodes' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
    }

    return @($results)
}
#endregion
