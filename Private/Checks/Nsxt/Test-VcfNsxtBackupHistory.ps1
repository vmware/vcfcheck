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
function Test-VcfNsxtBackupHistory {

    <#
        .SYNOPSIS
        Checks NSX Manager's backup history per backup type.

        .DESCRIPTION
        Uses Invoke-GetBackupHistory (VMware.Sdk.Nsx.Policy) to retrieve backup status.
        Per-type backup records (cluster/node/inventory) come from ClusterBackupStatuses,
        NodeBackupStatuses, and InventoryBackupStatuses, each a list of BackupOperationStatus
        items exposing EndTime (epoch milliseconds) and Success (bool). Each type is judged
        independently: a type Fails if its most recent backup attempt failed or has no record,
        or if its last successful backup is older than 48 hours; Warns if the last successful
        backup is between 24 and 48 hours old; otherwise Passes. The overall result Fails if any
        type Fails, Warns if any type Warns (and none Fail), and Passes only when all three types
        Pass. The top-level Detail is a plain "Pass" when every type passes, since there is
        nothing actionable in the per-type backup timestamps in that case; per-type timestamps
        are still available in Rows and are included in Detail when the result is Warning or Fail.
        Destination is read separately from Invoke-GetBackupConfig's RemoteFileServer
        (Server/Port/DirectoryPath) and reported both at the top level and as a "Backup Target"
        column on every Rows entry, since the backup target does not change per backup type.

        Remediation overrides the catalog's default "configure and run a backup" text when every
        non-passing type's Reason is Stale (a backup exists and has succeeded before, it is just
        overdue) rather than Missing or FailedAttempt - "configure and run a backup" reads oddly
        when backups are already configured and succeeding, just not recently enough; those cases
        instead point at the backup schedule/frequency.

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

    return Invoke-VcfCheckNsxtCheck -Context $Context -CheckId 'nsxt_backup_history' -DisplayName $DisplayName -Body {
        param($Context, $NsxFqdn)
        $history = Get-VcfCheckNsxBackupHistory -Server $NsxFqdn
        $config = Get-VcfCheckNsxBackupConfig -Server $NsxFqdn
        $remote = $config.RemoteFileServer
        $destination = "$($remote.Server):$($remote.Port)$($remote.DirectoryPath)"
        $now = [DateTime]::UtcNow

        $typedBackups = @(
            @{ Name = 'Cluster'; Items = $history.ClusterBackupStatuses }
            @{ Name = 'Node'; Items = $history.NodeBackupStatuses }
            @{ Name = 'Inventory'; Items = $history.InventoryBackupStatuses }
        )

        $typeResults = @($typedBackups | ForEach-Object { Get-VcfCheckNsxBackupTypeStatus -Name $_.Name -Items $_.Items -Now $now -Destination $destination })

        $overallStatus = 'Pass'
        if ($typeResults | Where-Object { $_.Status -eq 'Fail' }) {
            $overallStatus = 'Fail'
        } elseif ($typeResults | Where-Object { $_.Status -eq 'Warning' }) {
            $overallStatus = 'Warning'
        }

        if ($overallStatus -eq 'Pass') {
            $detail = 'Pass'
        } else {
            $detailLines = @($typeResults | ForEach-Object { "$($_.Name): $($_.Status) - $($_.'Last Backup Date')" })
            $detail = $detailLines -join ' | '
        }

        $remediation = $null
        if ($overallStatus -ne 'Pass') {
            $nonPassingReasons = @($typeResults | Where-Object { $_.Status -ne 'Pass' } | Select-Object -ExpandProperty Reason)
            if (-not ($nonPassingReasons | Where-Object { $_ -ne 'Stale' })) {
                $remediation = 'The backup schedule appears to be configured and has succeeded before, but the most recent successful run is overdue - check System > Lifecycle Management > Backup & Restore for schedule/frequency issues, or trigger a manual backup now.'
            }
        }

        $rows = @($typeResults | Select-Object Name, 'Last Backup Date', 'Backup Target', Status)
        $outcome = [PSCustomObject]@{ Status = $overallStatus; Detail = $detail; Destination = $destination; Rows = $rows }
        if ($remediation) { $outcome | Add-Member -MemberType NoteProperty -Name 'Remediation' -Value $remediation }
        return $outcome
    }
}
function Get-VcfCheckNsxBackupTypeStatus {

    <#
        .SYNOPSIS
        Judges a single NSX Manager backup type against the 24h/48h freshness thresholds.

        .DESCRIPTION
        Fails when the most recent backup attempt for the type failed or no attempts exist, or
        when the last successful backup is older than 48 hours. Warns when the last successful
        backup is between 24 and 48 hours old. Otherwise Passes.

        The returned Reason ('Missing', 'FailedAttempt', 'Stale', or 'Pass') lets the caller pick
        a remediation message without re-deriving it from the Status/"Last Backup Date" text - a
        non-passing type with no prior successful backup needs different guidance than one that
        has succeeded before but is overdue.

        .PARAMETER Name
        The backup type name (Cluster, Node, or Inventory) used for display purposes.

        .PARAMETER Items
        The list of BackupOperationStatus items for this backup type.

        .PARAMETER Now
        The current UTC time used to compute backup age.

        .PARAMETER Destination
        The backup target (server, port, and directory) to display on the row.

        .OUTPUTS
        [PSObject] with Name, "Last Backup Date", "Backup Target", Status, and Reason properties.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Name,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [AllowNull()] [Object[]]$Items,
        [Parameter(Mandatory = $true)] [DateTime]$Now,
        [Parameter(Mandatory = $true)] [String]$Destination
    )

    $items = @($Items)
    if ($items.Count -eq 0) {
        return [PSCustomObject]@{ Name = $Name; 'Last Backup Date' = 'No backup on record.'; 'Backup Target' = $Destination; Status = 'Fail'; Reason = 'Missing' }
    }

    $lastAttempt = @($items | Sort-Object -Property EndTime -Descending | Select-Object -First 1)[0]
    if (-not $lastAttempt.Success) {
        return [PSCustomObject]@{ Name = $Name; 'Last Backup Date' = 'Most recent backup attempt failed.'; 'Backup Target' = $Destination; Status = 'Fail'; Reason = 'FailedAttempt' }
    }

    $lastSuccessTime = [DateTimeOffset]::FromUnixTimeMilliseconds($lastAttempt.EndTime).UtcDateTime
    $ageHours = ($Now - $lastSuccessTime).TotalHours

    if ($ageHours -gt 48) {
        return [PSCustomObject]@{ Name = $Name; 'Last Backup Date' = "$($lastSuccessTime.ToString('o')), more than 48 hours ago."; 'Backup Target' = $Destination; Status = 'Fail'; Reason = 'Stale' }
    }

    if ($ageHours -gt 24) {
        return [PSCustomObject]@{ Name = $Name; 'Last Backup Date' = "$($lastSuccessTime.ToString('o')), more than 24 hours ago."; 'Backup Target' = $Destination; Status = 'Warning'; Reason = 'Stale' }
    }

    return [PSCustomObject]@{ Name = $Name; 'Last Backup Date' = $lastSuccessTime.ToString('o'); 'Backup Target' = $Destination; Status = 'Pass'; Reason = 'Pass' }
}
