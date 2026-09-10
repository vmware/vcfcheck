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
function Test-VcfSddcCheckFailedTasks {

    <#
        .SYNOPSIS
        Checks for failed SDDC Manager tasks among the most recent tasks.

        .DESCRIPTION
        Queries SDDC Manager tasks using Invoke-VcfGetTasks (VCF.PowerCLI), fetching the specified
        number of tasks (-PageSize) and sorting them client-side in descending order by CreationTimestamp.

        Filters tasks with a Status of "Failed" (case-insensitive). Failed tasks are grouped by task Name
        to synthesize recurring failures into clear summary rows. Each row details:
        - Total failure count for that task type
        - Earliest (FirstOccurred) and most recent (LastOccurred) timestamp
        - Consolidated list of distinct failed sub-task names (Task.SubTasks) causing the task failure

        Client-side sorting is used to avoid API execution errors associated with server-side ordering parameters.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER PageSize
        How many of the most recent tasks to inspect. Default 100.

        .OUTPUTS
        [PSObject] a VcfCheck.Result.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateRange(1, 1000)] [Int]$PageSize = 100
    )

    $startedAt = Get-Date
    $checkId = 'sddc_check_failed_tasks'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }
    $validationCriteria = $catalogEntry.validationCriteria

    try {
        $tasks = @((Invoke-VcfGetTasks -PageSize $PageSize -ErrorAction Stop).Elements | Sort-Object -Property CreationTimestamp -Descending)
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $Context.SddcManagerFqdn -Exception $_.Exception.Message `
            -ValidationCriteria $validationCriteria -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $failedTasks = @($tasks | Where-Object { $_.Status -eq 'Failed' })

    if ($failedTasks.Count -gt 0) {
        $rows = @($failedTasks | Group-Object -Property Name | ForEach-Object {
            $timestamps = @($_.Group | Where-Object { $_.CreationTimestamp } | ForEach-Object { [DateTime]$_.CreationTimestamp } | Sort-Object)
            $failedSubTaskNames = @($_.Group | ForEach-Object { $_.SubTasks } | Where-Object { $_.Status -eq 'Failed' } |
                Select-Object -ExpandProperty Name -Unique)
            [PSCustomObject]@{
                Name           = $_.Name
                Count          = $_.Count
                FirstOccurred  = if ($timestamps.Count -gt 0) { $timestamps[0].ToString('o') } else { $null }
                LastOccurred   = if ($timestamps.Count -gt 0) { $timestamps[-1].ToString('o') } else { $null }
                FailedSubTasks = if ($failedSubTaskNames.Count -gt 0) { $failedSubTaskNames -join '; ' } else { $null }
            }
        } | Sort-Object -Property Count -Descending)

        $detail = "$($failedTasks.Count) failed task(s) found ($($rows.Count) unique task name(s))."
        return New-VcfCheckResult -CheckId $checkId -Status Fail `
            -TargetComponent $Context.SddcManagerFqdn -Detail $detail -Rows $rows `
            -ValidationCriteria $validationCriteria -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    return New-VcfCheckResult -CheckId $checkId -Status Pass `
        -TargetComponent $Context.SddcManagerFqdn -Detail "No failed tasks found among the $($tasks.Count) most recent tasks." `
        -ValidationCriteria $validationCriteria -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
}
