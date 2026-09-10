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
function Test-VcfSddcLockTable {

    <#
        .SYNOPSIS
        Checks SDDC Manager's internal platform.lock table for stale/held locks.

        .DESCRIPTION
        Queries SDDC Manager's internal Postgres database (`platform` DB, `lock` table) via
        Invoke-VcfApplianceCommand using vCenter guest operations against the SDDC Manager VM.

        Resolves the appropriate `psql` binary path via Get-VcfCheckPsqlExecutablePath and connects
        as user `postgres` over TCP loopback to execute `SELECT * FROM lock;`.

        Evaluation logic:
        - Pass: No rows found in the platform.lock table.
        - Fail: One or more rows found in the platform.lock table, indicating an active or stale LCM lock.
        - Error: Appliance command execution fails or returns database error output.

        On Fail, populates the result's `Rows` table with all column fields from each retrieved lock row
        to assist in identifying the locked resource or operation.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [PSObject] a VcfCheck.Result. On Fail, Rows contains one object per platform.lock row,
        with a property per database column.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'sddc_lock_table'

    try {
        $vcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
        $rootCredential = Get-VcfCheckSddcManagerRootCredential -Context $Context
        $vmName = ($Context.SddcManagerFqdn -split '\.')[0]
        $psqlPath = Get-VcfCheckPsqlExecutablePath -VcfVersion (Get-VcfCheckVcfVersion -Context $Context)

        $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $vcenterFqdn -Credential $rootCredential `
            -ScriptText "$psqlPath -h localhost -U postgres -d platform -A -F '|' -P footer=off -c `"SELECT * FROM lock;`""

        if (-not $commandResult.Success) {
            return New-VcfCheckApplianceCommandFailureResult -CommandResult $commandResult -CheckId $checkId `
                -TargetComponent $vmName -StartedAt $startedAt
        }

        if ($commandResult.ScriptOutput -cmatch 'ERROR') {
            return New-VcfCheckResult -CheckId $checkId -Status Error -Blocking `
                -TargetComponent $vmName -Detail "Unexpected psql output: $($commandResult.ScriptOutput)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        $outputLines = @($commandResult.ScriptOutput -split "`r?`n" | Where-Object { $_.Trim() })
        if ($outputLines.Count -eq 0) {
            return New-VcfCheckResult -CheckId $checkId -Status Pass -Blocking `
                -TargetComponent $vmName -Detail 'No rows found in the platform.lock table.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        $columns = $outputLines[0] -split '\|'
        $lockRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($line in $outputLines | Select-Object -Skip 1) {
            $values = $line -split '\|'
            $row = [Ordered]@{}
            for ($i = 0; $i -lt $columns.Count; $i++) {
                $row[$columns[$i]] = if ($i -lt $values.Count) { $values[$i] } else { '' }
            }
            $lockRows.Add([PSCustomObject]$row)
        }

        if ($lockRows.Count -eq 0) {
            return New-VcfCheckResult -CheckId $checkId -Status Pass -Blocking `
                -TargetComponent $vmName -Detail 'No rows found in the platform.lock table.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        return New-VcfCheckResult -CheckId $checkId -Status Fail -Blocking `
            -TargetComponent $vmName -Detail "$($lockRows.Count) row(s) found in the platform.lock table." `
            -Rows @($lockRows) -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error -Blocking `
            -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }
}
