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
function Test-VcfCheckAriaAutomationNodeDiskSpace {

    <#
        .SYNOPSIS
        Runs and evaluates `vracli disk-mgr` for a single Aria Automation appliance node.

        .DESCRIPTION
        Helper for Test-VcfAriaAutomationDiskSpace. Runs `vracli disk-mgr` on the named VM via
        Invoke-VcfApplianceCommand (guest operations through vCenter, not a direct SSH session)
        and parses its plain-text, per-mount output (there is no JSON option for this vracli
        subcommand) into a used-percent figure per mount, evaluated against the same
        Warn/Fail tiers used by Test-VcfAriaApplianceDiskSpace for the equivalent mount, mapped
        by best-fit mount name: '/' and '/home' use the '/' tier (Warn 90/Fail 100), '/data' uses
        the '/storage/db' tier (Warn 80/Fail 100), '/var/log' uses the '/storage/log' tier
        (Warn 90/Fail 100), and any other/unexpected mount defaults to the '/' tier.

        .PARAMETER VmName
        The appliance node's vCenter inventory VM name.

        .PARAMETER VCenterFqdn
        FQDN of the already-connected vCenter that manages the appliance VM.

        .PARAMETER Credential
        GuestOS root credential to authenticate the guest operation.

        .OUTPUTS
        [PSCustomObject] with HostName, Status ('Pass'/'Warning'/'Error'), Detail, and Mounts
        (parsed per-mount usage, empty on failure) properties.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VmName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VCenterFqdn,
        [Parameter(Mandatory = $true)] [PSCredential]$Credential
    )

    $mountThresholds = [ordered]@{
        '/'        = @{ WarnPercent = 90; FailPercent = 100 }
        '/data'    = @{ WarnPercent = 80; FailPercent = 100 }
        '/var/log' = @{ WarnPercent = 90; FailPercent = 100 }
        '/home'    = @{ WarnPercent = 90; FailPercent = 100 }
    }
    $defaultThreshold = @{ WarnPercent = 90; FailPercent = 100 }

    $diskCommand = 'vracli disk-mgr'
    $commandResult = Invoke-VcfApplianceCommand -VmName $VmName -Server $VCenterFqdn -Credential $Credential -ScriptText $diskCommand

    if (-not $commandResult.Success) {
        return [PSCustomObject]@{
            HostName = $VmName
            Status   = 'Error'
            Detail   = "[$($commandResult.ErrorCategory)] $($commandResult.ErrorMessage)"
            Mounts   = @()
        }
    }

    $mountMatches = [Regex]::Matches($commandResult.ScriptOutput, '(?m)^/dev/\S+\(([^)]+)\):\s*\r?\n\s*Total size:\s*(\S+)\s*\r?\n\s*Free:\s*\S+\((\d+\.?\d*)%\)')
    if ($mountMatches.Count -eq 0) {
        return [PSCustomObject]@{
            HostName = $VmName
            Status   = 'Error'
            Detail   = "`"$diskCommand`" on `"$VmName`" returned output that could not be parsed for disk usage."
            Mounts   = @()
        }
    }

    $mountRows = @($mountMatches | ForEach-Object {
        $mountPath = $_.Groups[1].Value
        $totalSize = $_.Groups[2].Value
        $freePercent = [Double]$_.Groups[3].Value
        $usedPercent = [Math]::Round(100 - $freePercent, 1)
        $threshold = if ($mountThresholds.Contains($mountPath)) { $mountThresholds[$mountPath] } else { $defaultThreshold }

        $mountStatus = if ($usedPercent -ge $threshold.FailPercent) { 'Full' }
        elseif ($usedPercent -gt $threshold.WarnPercent) { 'Warning' }
        else { 'Pass' }

        [PSCustomObject]@{
            Mount       = $mountPath
            TotalSize   = $totalSize
            UsedPercent = $usedPercent
            Status      = $mountStatus
        }
    })

    $statusRank = @{ Pass = 0; Warning = 1; Full = 2 }
    $worstMount = $mountRows | Sort-Object -Property { $statusRank[$_.Status] } -Descending | Select-Object -First 1
    $mountSummary = ($mountRows | ForEach-Object { "$($_.Mount): $($_.UsedPercent)% used" }) -join ', '

    $nodeStatus = switch ($worstMount.Status) {
        'Full' { 'Error' }
        'Warning' { 'Warning' }
        default { 'Pass' }
    }

    return [PSCustomObject]@{
        HostName = $VmName
        Status   = $nodeStatus
        Detail   = $mountSummary
        Mounts   = $mountRows
    }
}
function Test-VcfAriaAutomationDiskSpace {

    <#
        .SYNOPSIS
        Runs `vracli disk-mgr` on every Aria Automation appliance node and flags any node with a
        mount approaching or at capacity.

        .DESCRIPTION
        Calls Get-VcfCheckAriaAutomationTargets to connect to every known Aria Automation
        instance, then for each target with guestOS checks enabled (a VCenterFqdn configured on
        its endpoint) connects to that vCenter and runs Test-VcfCheckAriaAutomationNodeDiskSpace
        against every VM name configured on the endpoint (Private/Environments.ps1's VmNames
        field), falling back to the FQDN's hostname label for a single-node appliance without an
        explicit VmNames entry. Reports per-node sub-progress via Write-VcfCheckSubProgress as
        each node is checked.

        Outcome behavior (per target, folded into one VcfCheck.Result with one HostDetails entry
        per appliance node):
        - Skipped: Returns 'Skipped' if no Aria Automation instance is known at all, or if a
          target has no VCenterFqdn configured (guestOS checks not enabled for that endpoint).
        - Error: A target's connection failed, the guestOS vCenter connection or credential
          could not be established, a node's guestOS command failed or returned unparsable
          output, or a mount is at/above its Fail threshold.
        - Warning: A mount is above its Warn threshold but below its Fail threshold.
        - Pass: Every mount on every node is within its Warn threshold.

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
    $checkId = 'aria_automation_disk_space'

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
                -Detail "GuestOS checks are not enabled for `"$($target.Fqdn)`" - a vCenter FQDN must be configured on this endpoint to run appliance disk space checks." `
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
            $hostDetails.Add((Test-VcfCheckAriaAutomationNodeDiskSpace -VmName $vmName -VCenterFqdn $endpoint.VCenterFqdn -Credential $rootCredential))
        }

        $severityByStatus = @{ Error = 3; Warning = 2; Pass = 1 }
        $targetStatus = ($hostDetails | Sort-Object -Property { $severityByStatus[$_.Status] } -Descending | Select-Object -First 1).Status
        $statusCounts = $hostDetails | Group-Object -Property Status
        $targetDetail = "Checked disk space on $($hostDetails.Count) Aria Automation appliance node(s) on `"$($target.Fqdn)`": $(($statusCounts | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ')."

        New-VcfCheckResult -CheckId $checkId -Status $targetStatus `
            -TargetComponent $target.Fqdn -Detail $targetDetail -HostDetails $hostDetails.ToArray() -HostDetailsLabel 'Appliance Nodes' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
    }

    return @($results)
}
#endregion
