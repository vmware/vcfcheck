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
#region AriaOpsForLogs
function Test-VcfCheckAriaOpsForLogsNodeSshServerStatus {

    <#
        .SYNOPSIS
        Runs and evaluates `systemctl is-active sshd` for a single Aria Operations for Logs
        appliance node.

        .DESCRIPTION
        Helper for Test-VcfAriaOpsForLogsSshServerStatus. `systemctl is-active <unit>` prints a
        single status word and exits non-zero for any state other than "active", so the command
        is run with a trailing "|| true" to keep Invoke-VcfApplianceCommand's Success flag tied
        to whether the guest-ops call itself worked rather than to the sshd unit's state.

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

    $sshStatusCommand = 'systemctl is-active sshd || true'
    $commandResult = Invoke-VcfApplianceCommand -VmName $VmName -Server $VCenterFqdn -Credential $Credential -ScriptText $sshStatusCommand

    if (-not $commandResult.Success) {
        return [PSCustomObject]@{
            HostName = $VmName
            Status   = 'Error'
            Detail   = "[$($commandResult.ErrorCategory)] $($commandResult.ErrorMessage)"
        }
    }

    $sshState = ($commandResult.ScriptOutput | Out-String).Trim()

    if ($sshState -eq 'inactive') {
        return [PSCustomObject]@{
            HostName = $VmName
            Status   = 'Pass'
            Detail   = 'SSH server (sshd) is inactive.'
        }
    }

    if ($sshState -eq 'active') {
        return [PSCustomObject]@{
            HostName = $VmName
            Status   = 'Warning'
            Detail   = 'SSH server (sshd) is active - disable it when not needed for troubleshooting.'
        }
    }

    return [PSCustomObject]@{
        HostName = $VmName
        Status   = 'Error'
        Detail   = "`"$sshStatusCommand`" on `"$VmName`" returned an unrecognized sshd state: `"$sshState`"."
    }
}
function Test-VcfAriaOpsForLogsSshServerStatus {

    <#
        .SYNOPSIS
        Runs `systemctl is-active sshd` on every Aria Operations for Logs appliance node and
        warns on any node where the SSH server is active.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsForLogsTargets to connect to every known Aria Operations for
        Logs instance, then for each target with guestOS checks enabled (a VCenterFqdn
        configured on its endpoint) connects to that vCenter and runs
        Test-VcfCheckAriaOpsForLogsNodeSshServerStatus against every VM name configured on the
        endpoint (Private/Environments.ps1's VmNames field), falling back to the FQDN's hostname
        label for a single-node appliance without an explicit VmNames entry. Reports per-node
        sub-progress via Write-VcfCheckSubProgress as each node is checked.

        Outcome behavior (per target, folded into one VcfCheck.Result with one HostDetails entry
        per appliance node):
        - Skipped: Returns 'Skipped' if no Aria Operations for Logs instance is known at all, or
          if a target has no VCenterFqdn configured (guestOS checks not enabled for that
          endpoint).
        - Error: A target's connection failed, the guestOS vCenter connection or credential
          could not be established, or a node's guestOS command failed or returned an
          unrecognized sshd state.
        - Warning: A node's SSH server is active.
        - Pass: Every node's SSH server is inactive.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Operations for Logs instance with
        guestOS checks enabled.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'aria_ops_for_logs_ssh_server_status'

    $targets = Get-VcfCheckAriaOpsForLogsTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Operations for Logs is not deployed in this environment.' -SkipReasonTag 'Aria Operations for Logs not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Operations for Logs'
    }

    $results = foreach ($target in $targets) {
        $resultDisplayName = if ($targets.Count -gt 1) { "$DisplayName ($($target.Name))" } else { $DisplayName }

        if ($target.ConnectError) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception $target.ConnectError `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        $endpoint = $Context.AriaOpsForLogsEndpoints | Where-Object { $_.Fqdn -eq $target.Fqdn }
        if (-not $endpoint -or [String]::IsNullOrWhiteSpace($endpoint.VCenterFqdn)) {
            New-VcfCheckResult -CheckId $checkId -Status Skipped `
                -TargetComponent $target.Fqdn `
                -Detail "GuestOS checks are not enabled for `"$($target.Fqdn)`" - a vCenter FQDN must be configured on this endpoint to run appliance SSH server checks." `
                -SkipReasonTag 'GuestOS checks not enabled' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        try {
            Connect-VcfCheckVCenter -Context $Context -Fqdn $endpoint.VCenterFqdn
            $rootCredential = Get-VcfCheckAriaVCenterRootCredential -Context $Context -Fqdn $endpoint.VCenterFqdn
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception "Failed to prepare guestOS checks against `"$($endpoint.VCenterFqdn)`": $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        if ($endpoint.VmNames.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Skipped `
                -TargetComponent $target.Fqdn `
                -Detail "No VM name(s) are configured for `"$($target.Fqdn)`" - guestOS checks never guess a VM name, since a wrong guess could silently check only one node of a multi-node deployment; add the VM name(s) in the environment editor to run this check." `
                -SkipReasonTag 'VM name(s) not configured' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }
        $nodeNames = @($endpoint.VmNames)
        $hostDetails = [System.Collections.Generic.List[PSCustomObject]]::new()
        $nodeIndex = 0
        foreach ($vmName in $nodeNames) {
            $nodeIndex++
            Write-VcfCheckSubProgress -Context $Context -Current $nodeIndex -Total $nodeNames.Count `
                -Label $vmName -Unit 'Aria Operations for Logs appliance nodes'
            $hostDetails.Add((Test-VcfCheckAriaOpsForLogsNodeSshServerStatus -VmName $vmName -VCenterFqdn $endpoint.VCenterFqdn -Credential $rootCredential))
        }

        $severityByStatus = @{ Error = 3; Warning = 2; Pass = 1 }
        $targetStatus = ($hostDetails | Sort-Object -Property { $severityByStatus[$_.Status] } -Descending | Select-Object -First 1).Status
        $statusCounts = $hostDetails | Group-Object -Property Status
        $targetDetail = "Checked SSH server status on $($hostDetails.Count) Aria Operations for Logs appliance node(s) on `"$($target.Fqdn)`": $(($statusCounts | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ')."

        New-VcfCheckResult -CheckId $checkId -Status $targetStatus `
            -TargetComponent $target.Fqdn -Detail $targetDetail -HostDetails $hostDetails.ToArray() -HostDetailsLabel 'Appliance Nodes' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
    }

    return @($results)
}
#endregion
