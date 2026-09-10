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
#region Aria

function Test-VcfCheckAriaNodeDiskSpace {

    <#
        .SYNOPSIS
        Runs and evaluates `df -h` for a single Aria appliance node's guest OS credential.

        .DESCRIPTION
        Helper for Test-VcfAriaApplianceDiskSpace. Resolves the appliance's short VM name from
        -Fqdn, runs `df -h` via Invoke-VcfApplianceCommand (guest operations through vCenter, not
        a direct SSH session), and parses the result with ConvertFrom-VcfCheckDfOutput.
        `tmpfs`/`shm`/`overlay` filesystem rows are dropped before evaluation and before being
        returned in Rows - these are container-managed in-memory or per-container overlay
        mounts on the appliance, not disk space a reader can act on.

        Evaluates used-space percentage on each of /, /storage/db, /storage/core, and /storage/log
        against -MountThresholds. A mount not present on the appliance (e.g. products without a
        separate /storage/db volume) is skipped rather than treated as an error.

        .PARAMETER VCenterFqdn
        FQDN of the already-connected vCenter that manages the appliance VM.

        .PARAMETER Fqdn
        Appliance FQDN as registered in SDDC Manager. Its hostname label is used as the vCenter VM name.

        .PARAMETER Product
        Friendly product name (e.g. "Aria Operations") to include in Detail messages.

        .PARAMETER Credential
        Guest OS credential (e.g. root) to authenticate the guest operation.

        .PARAMETER MountThresholds
        Ordered hashtable keyed by mount path, each value a hashtable with WarnPercent (used% at
        which to report Warning) and FailPercent (used% at which to report Full/blocking failure).

        .OUTPUTS
        [PSCustomObject] with Fqdn, Status ('Pass'/'Warning'/'Full'/'Error'), Detail, and Rows
        (parsed df output, empty on failure) properties. Each Rows entry carries its own Status
        ('Pass'/'Warning'/'Fail') for monitored mounts, 'N/A' for mounts outside -MountThresholds.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VCenterFqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Product,
        [Parameter(Mandatory = $true)] [PSCredential]$Credential,
        [Parameter(Mandatory = $true)] [System.Collections.Specialized.OrderedDictionary]$MountThresholds
    )

    $vmName = ($Fqdn -split '\.')[0]
    $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $VCenterFqdn -Fqdn $Fqdn `
        -Credential $Credential -ScriptText 'df -h'

    if (-not $commandResult.Success) {
        return [PSCustomObject]@{
            Fqdn          = $Fqdn
            Status        = 'Error'
            Detail        = "Unable to retrieve disk space data from `"$Fqdn`": $($commandResult.ErrorMessage)"
            CommandResult = $commandResult
            Rows          = @()
        }
    }

    $diskRows = @(ConvertFrom-VcfCheckDfOutput -ScriptOutput $commandResult.ScriptOutput |
        Where-Object { $_.Filesystem -notin @('tmpfs', 'shm', 'overlay') })
    if ($diskRows.Count -eq 0) {
        return [PSCustomObject]@{
            Fqdn          = $Fqdn
            Status        = 'Error'
            Detail        = "`"df -h`" on `"$Fqdn`" returned no parseable output."
            CommandResult = $null
            Rows          = @()
        }
    }

    $rows = @($diskRows | ForEach-Object {
        [PSCustomObject]@{
            Filesystem  = $_.Filesystem
            Size        = $_.Size
            Used        = $_.Used
            Available   = $_.Available
            UsedPercent = $_.UsedPercent
            MountedOn   = $_.MountedOn
            Status      = 'N/A'
        }
    })

    $monitoredMounts = $diskRows | Where-Object { $MountThresholds.Contains($_.MountedOn) }
    if ($monitoredMounts.Count -eq 0) {
        return [PSCustomObject]@{
            Fqdn          = $Fqdn
            Status        = 'Pass'
            Detail        = "$Product (`"$Fqdn`") does not have any of the monitored mount points (`"$($MountThresholds.Keys -join '", "')`") - nothing to check."
            CommandResult = $null
            Rows          = $rows
        }
    }

    $mountDetails = [System.Collections.Generic.List[String]]::new()
    $worstStatus = 'Pass'
    $statusRank = @{ Pass = 0; Warning = 1; Full = 2 }
    foreach ($mount in $monitoredMounts) {
        $usedPercent = [int]($mount.UsedPercent.TrimEnd('%'))
        $thresholds = $MountThresholds[$mount.MountedOn]
        if ($usedPercent -ge $thresholds.FailPercent) {
            $mountStatus = 'Full'
            $mountDetails.Add("$($mount.MountedOn) is at $usedPercent% utilization (full) on $Product (`"$Fqdn`").")
        } elseif ($usedPercent -gt $thresholds.WarnPercent) {
            $mountStatus = 'Warning'
            $mountDetails.Add("$($mount.MountedOn) is at $usedPercent% utilization on $Product (`"$Fqdn`"), above the recommended maximum of $($thresholds.WarnPercent)%.")
        } else {
            $mountStatus = 'Pass'
            $mountDetails.Add("$($mount.MountedOn) is at $usedPercent% utilization on $Product (`"$Fqdn`").")
        }
        if ($statusRank[$mountStatus] -gt $statusRank[$worstStatus]) {
            $worstStatus = $mountStatus
        }
        $rowStatus = if ($mountStatus -eq 'Full') { 'Fail' } else { $mountStatus }
        foreach ($row in @($rows | Where-Object { $_.MountedOn -eq $mount.MountedOn })) {
            $row.Status = $rowStatus
        }
    }

    return [PSCustomObject]@{
        Fqdn          = $Fqdn
        Status        = $worstStatus
        Detail        = ($mountDetails -join ' ')
        CommandResult = $null
        Rows          = $rows
    }
}
function Test-VcfAriaApplianceDiskSpace {

    <#
        .SYNOPSIS
        Verifies that /, /storage/db, /storage/core, and /storage/log are within their utilization
        thresholds on every deployed Aria Suite appliance.

        .DESCRIPTION
        Enumerates every Aria Suite product with credentials registered in SDDC Manager (VRSLCM,
        VRLI, VROPS, VRA, WSA) via Invoke-VcfGetCredentials, then for each SSH-credentialed node
        runs Test-VcfCheckAriaNodeDiskSpace - which runs `df -h` on the appliance through
        vCenter guest operations (Invoke-VcfApplianceCommand), the same login mechanism as
        Test-VcfVrslcmRootPasswordExpiration. Reports per-node sub-progress via
        Write-VcfCheckSubProgress as each appliance node is checked, ensuring real-time status updates.

        Returns a single VcfCheck.Result with one HostDetails entry per appliance node (see
        Format-VcfCheckHtmlHostDetailCard), rendering one collapsible section per appliance
        under a single check entry. The top-level Status is the worst-of-all-nodes status
        (Error > Warning > Pass > Skipped, with Skipped only winning if every node was skipped).

        Outcome behavior (per appliance node, folded into the top-level result's HostDetails):
        - Skipped: Node skipped if VMware Tools was not running on that appliance.
        - Error (blocking failure): Any monitored mount (/, /storage/db, /storage/core,
          /storage/log) is at 100% utilization.
        - Warning: Any monitored mount exceeds its warn threshold (/ above 90%, /storage/db
          above 80%, /storage/core above 97%, /storage/log above 90%) without reaching 100%, or
          its disk space data could not be retrieved or parsed.
        - Pass: Every monitored mount present on the node is within its warn threshold.

        Top-level Error: Returned if SDDC Manager's credential inventory or the management
        vCenter connection cannot be established at all (no per-node data available yet), or if
        any node's monitored mounts reach 100% utilization.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [PSObject] A single VcfCheck.Result with one HostDetails entry per checked Aria Suite
        appliance node.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'aria_appliance_disk_space_report'
    $mountThresholds = [ordered]@{
        '/'             = @{ WarnPercent = 90; FailPercent = 100 }
        '/storage/db'   = @{ WarnPercent = 80; FailPercent = 100 }
        '/storage/core' = @{ WarnPercent = 97; FailPercent = 100 }
        '/storage/log'  = @{ WarnPercent = 90; FailPercent = 100 }
    }
    $products = @('VRSLCM', 'VRLI', 'VROPS', 'VRA', 'WSA')
    $productFriendlyNames = @{
        'VRSLCM' = 'Aria Suite Lifecycle Manager'
        'VRLI'   = 'Aria Operations for Logs'
        'VROPS'  = 'Aria Operations'
        'VRA'    = 'Aria Automation'
        'WSA'    = 'Workspace ONE Access'
    }

    try {
        $connection = Get-VcfCheckVrslcmConnection -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    if (-not $connection) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Suite Lifecycle Manager is not deployed in this environment.' `
            -SkipReasonTag 'vRSLCM not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    try {
        $vcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $connection.Fqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $nodeTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($product in $products) {
        try {
            $response = Invoke-VcfGetCredentials -ResourceType $product -ErrorAction Stop
        } catch {
            continue
        }
        $friendlyProduct = if ($productFriendlyNames.ContainsKey($product)) { $productFriendlyNames[$product] } else { $product }
        $entries = @($response.Elements) | Where-Object { $_.CredentialType -eq 'SSH' } |
            Group-Object -Property { $_.Resource.ResourceName } | ForEach-Object { $_.Group[0] }
        foreach ($entry in $entries) {
            $nodeTasks.Add([PSCustomObject]@{ FriendlyProduct = $friendlyProduct; Entry = $entry })
        }
    }

    $nodeTasks = [System.Collections.Generic.List[PSCustomObject]]($nodeTasks | Sort-Object -Property { $_.Entry.Resource.ResourceName })

    if ($nodeTasks.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Pass `
            -TargetComponent $connection.Fqdn `
            -Detail 'No Aria Suite appliance nodes with SSH credentials were found in SDDC Manager.' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $severityByStatus = @{ Error = 4; Warning = 3; Pass = 2; Skipped = 1 }
    $hostDetails = [System.Collections.Generic.List[PSCustomObject]]::new()
    $nodeIndex = 0
    foreach ($nodeTask in $nodeTasks) {
        $nodeIndex++
        $entry = $nodeTask.Entry
        $nodeFqdn = $entry.Resource.ResourceName
        Write-VcfCheckSubProgress -Context $Context -Current $nodeIndex -Total $nodeTasks.Count `
            -Label $nodeFqdn -Unit 'appliance nodes'
        $secure = ConvertTo-SecureStringForCredential -PlainText $entry.Password
        $nodeCredential = [PSCredential]::new($entry.Username, $secure)

        $outcome = Test-VcfCheckAriaNodeDiskSpace -VCenterFqdn $vcenterFqdn -Fqdn $nodeFqdn `
            -Product $nodeTask.FriendlyProduct -Credential $nodeCredential -MountThresholds $mountThresholds
        Remove-Variable -Name nodeCredential, secure -ErrorAction SilentlyContinue

        if ($outcome.CommandResult) {
            if ($outcome.CommandResult.ErrorCategory -eq 'ToolsNotRunning') {
                $nodeStatus = 'Skipped'
                $nodeDetail = "This check cannot run without VMware Tools running on the target appliance - skipped for now. $($outcome.CommandResult.ErrorMessage)"
            } else {
                $nodeStatus = 'Warning'
                $nodeDetail = $outcome.CommandResult.ErrorMessage
            }
            $hostDetails.Add([PSCustomObject]@{
                HostName = $nodeFqdn
                Product  = $nodeTask.FriendlyProduct
                Status   = $nodeStatus
                Detail   = $nodeDetail
            })
            continue
        }

        $nodeStatus = switch ($outcome.Status) {
            'Full'  { 'Error' }
            'Error' { 'Warning' }
            default { $outcome.Status }
        }
        $hostDetails.Add([PSCustomObject]@{
            HostName  = $nodeFqdn
            Product   = $nodeTask.FriendlyProduct
            Status    = $nodeStatus
            Detail    = $outcome.Detail
            DiskUsage = $outcome.Rows
        })
    }

    $overallStatus = ($hostDetails | Sort-Object -Property { $severityByStatus[$_.Status] } -Descending | Select-Object -First 1).Status
    $statusCounts = $hostDetails | Group-Object -Property Status
    $summaryParts = @($statusCounts | ForEach-Object { "$($_.Count) $($_.Name)" })
    $overallDetail = "Checked $($hostDetails.Count) Aria Suite appliance node(s): $($summaryParts -join ', ')."

    $problemNodes = @($hostDetails | Where-Object { $_.Status -eq 'Warning' -or $_.Status -eq 'Error' })
    if ($problemNodes.Count -gt 0) {
        $problemDescriptions = @($problemNodes | ForEach-Object { "$($_.HostName) ($($_.Product)): $($_.Status)" })
        $overallDetail += ' Appliances needing attention: ' + ($problemDescriptions -join '; ') + '.'
    }

    return New-VcfCheckResult -CheckId $checkId -Status $overallStatus `
        -TargetComponent $connection.Fqdn -Detail $overallDetail -HostDetails $hostDetails.ToArray() `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
#endregion
