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
function Test-VcfSddcCheckHealthSummary {

    <#
        .SYNOPSIS
        Runs SDDC Manager's health-summary check and reports its overall status.

        .DESCRIPTION
        Executes an SDDC Manager health-summary task and reports its status based on the task verdict
        (COMPLETED_WITH_SUCCESS -> Pass, COMPLETED_WITH_FAILURE -> Fail).

        To avoid security risks associated with downloading and extracting archive files over REST APIs,
        this cmdlet reads task status fields directly via Invoke-VcfStartHealthCheck and
        Invoke-VcfGetHealthCheckStatus.

        Itemized health details (DNS lookup status, password expiry, certificate status, NTP sync,
        and per-service health) are contained within the generated health report archive. To review
        detailed findings, use the SDDC Manager UI or Invoke-VcfExportHealthCheckByID.

        Polled using an initial 90-second wait followed by up to 24 attempts at 30-second intervals
        (13.5 minutes total) to accommodate full execution while maintaining a bounded poll duration.
        Polling also stops early, before the full budget, if a sub-task already reporting
        IN_PROGRESS/PENDING stops changing across StallPollThreshold consecutive polls - SDDC Manager
        has been observed to leave a health-summary task permanently "IN_PROGRESS" after one of its
        sub-tasks (e.g. VSAN-CHECK) fails, so waiting out the full budget in that case only delays the
        result. Sub-task sets made up entirely of terminal statuses (e.g. only "Pre-Validation:
        Successful" reported so far, with later categories not yet started) never count toward the
        stall threshold, since that reflects normal SDDC Manager pacing rather than a stalled task.

        Configures an explicit HealthSummarySpec (enabling all 11 health-check categories, Force, and
        SummaryReport) scoped to IncludeAllDomains and IncludeFreeHosts, evaluating SDDC Manager across
        all domains in a single request.

        SDDC Manager permits only one health-summary task at a time. If a task is already active,
        Resolve-VcfCheckInProgressHealthCheckId detects the OPERATION_IN_PROGRESS response and
        attaches to the running task Id to poll its completion status.

        Reports and logs sub-task details by inspecting SDDC Manager's generic task system
        (Invoke-VcfGetTask), retrieving category-level status (Task.SubTasks) for additional context
        without requiring file extraction.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER InitialDelaySeconds
        Delay before the first status poll, giving the task time to leave its initial
        not-yet-started state before polling begins. Default 90.

        .PARAMETER MaxPollAttempts
        Maximum number of status polls before giving up. Default 40.

        .PARAMETER PollDelaySeconds
        Delay between polls. Default 30.

        .PARAMETER StallPollThreshold
        Number of consecutive polls with an unchanged set of sub-task name/status pairs, where at
        least one sub-task is still IN_PROGRESS/PENDING, before polling is abandoned as stalled, even
        though MaxPollAttempts has not been reached. Default 4.

        .OUTPUTS
        [PSObject] a VcfCheck.Result.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateRange(0, 600)] [Int]$InitialDelaySeconds = 90,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$MaxPollAttempts = 24,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$PollDelaySeconds = 30,
        [Parameter(Mandatory = $false)] [ValidateRange(2, 20)] [Int]$StallPollThreshold = 4
    )

    $startedAt = Get-Date
    $checkId = 'sddc_check_health_summary'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }

    try {
        $spec = New-VcfCheckHealthSummarySpec
        $task = Invoke-VcfStartHealthCheck -HealthSummarySpec $spec -ErrorAction Stop
    } catch {
        $inProgressTaskId = Resolve-VcfCheckInProgressHealthCheckId -ErrorMessage $_.Exception.Message
        if ([String]::IsNullOrWhiteSpace($inProgressTaskId)) {
            return New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $Context.SddcManagerFqdn -Exception $_.Exception.Message `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
        }
        $task = [PSCustomObject]@{ Id = $inProgressTaskId; Status = '' }
    }

    $status = [String]$task.Status
    $subTasks = Get-VcfCheckHealthSummarySubTaskList -Id $task.Id
    Write-VcfCheckHealthSummarySubTaskLog -SubTasks $subTasks
    Write-VcfCheckHealthSummaryProgress -Context $Context -Attempt 0 -MaxAttempts $MaxPollAttempts -Status $status -StartedAt $startedAt -SubTasks $subTasks

    if ($InitialDelaySeconds -gt 0) {
        Start-Sleep -Seconds $InitialDelaySeconds
    }

    $attempt = 0
    $stallCount = 0
    $previousSubTaskSignature = Get-VcfCheckHealthSummarySubTaskSignature -SubTasks $subTasks
    while (([String]::IsNullOrWhiteSpace($status) -or $status -match 'IN_?PROGRESS|PENDING') -and $attempt -lt $MaxPollAttempts -and $stallCount -lt $StallPollThreshold) {
        try {
            $task = Invoke-VcfGetHealthCheckStatus -Id $task.Id -ErrorAction Stop
        } catch {
            return New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $Context.SddcManagerFqdn -Exception $_.Exception.Message `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
        }
        $status = [String]$task.Status
        $subTasks = Get-VcfCheckHealthSummarySubTaskList -Id $task.Id
        Write-VcfCheckHealthSummarySubTaskLog -SubTasks $subTasks
        $attempt++
        Write-VcfCheckHealthSummaryProgress -Context $Context -Attempt $attempt -MaxAttempts $MaxPollAttempts -Status $status -StartedAt $startedAt -SubTasks $subTasks

        $subTaskSignature = Get-VcfCheckHealthSummarySubTaskSignature -SubTasks $subTasks
        $hasNonTerminalSubTask = @($subTasks | Where-Object { $_ -and $_.Status -notmatch 'SUCCE|COMPLET|FAIL' }).Count -gt 0
        if ([String]::IsNullOrEmpty($subTaskSignature) -or -not $hasNonTerminalSubTask) {
            $stallCount = 0
        } elseif ($subTaskSignature -eq $previousSubTaskSignature) {
            $stallCount++
        } else {
            $stallCount = 0
        }
        $previousSubTaskSignature = $subTaskSignature

        if (([String]::IsNullOrWhiteSpace($status) -or $status -match 'IN_?PROGRESS|PENDING') -and $attempt -lt $MaxPollAttempts -and $stallCount -lt $StallPollThreshold) {
            Start-Sleep -Seconds $PollDelaySeconds
        }
    }

    $subTaskRows = @($subTasks | Where-Object { $_ } | ForEach-Object {
            [PSCustomObject]@{
                SubTask = $_.Name
                Status  = $_.Status
                Error   = if (@($_.Errors).Count -gt 0) {
                    (@($_.Errors | Where-Object { $_ } | ForEach-Object {
                                if ($_.Message) { $_.Message } elseif ($_.Label) { $_.Label } else { $null }
                            } | Where-Object { $_ }) -join '; ')
                } else { $null }
            }
        })
    $failedSubTaskNames = @($subTasks | Where-Object { $_ -and $_.Status -match 'FAIL' } | ForEach-Object { $_.Name })
    $elapsedSeconds = [Int][Math]::Round(((Get-Date) - $startedAt).TotalSeconds)
    Write-LogMessage -Type DEBUG -Message "Health-summary task `"$($task.Id)`" polling ended after $attempt/$MaxPollAttempts attempt(s) and $elapsedSeconds second(s) with status `"$status`"."

    if ([String]::IsNullOrWhiteSpace($status) -or $status -match 'IN_?PROGRESS|PENDING') {
        $inProgressSubTaskNames = @($subTasks | Where-Object { $_ -and $_.Status -match 'IN_?PROGRESS|PENDING' } | ForEach-Object { $_.Name })
        $stalled = $stallCount -ge $StallPollThreshold -and $attempt -lt $MaxPollAttempts
        if ($stalled) {
            Write-LogMessage -Type WARNING -Message "Health-summary task `"$($task.Id)`" abandoned after $stallCount consecutive poll(s) with unchanged sub-task status ($elapsedSeconds second(s) elapsed) while still reporting `"$status`"."
            $detail = "Health-summary task `"$($task.Id)`" stopped making progress: sub-task status was unchanged across $stallCount consecutive poll(s) ($elapsedSeconds second(s))."
        } else {
            Write-LogMessage -Type WARNING -Message "Health-summary task `"$($task.Id)`" hit its poll budget ($MaxPollAttempts attempt(s), $elapsedSeconds second(s) elapsed) while still reporting `"$status`"."
            $detail = "Health-summary task `"$($task.Id)`" did not complete after $MaxPollAttempts poll(s) ($elapsedSeconds second(s))."
        }
        if ($inProgressSubTaskNames.Count -gt 0) {
            $detail += " Still in progress: $($inProgressSubTaskNames -join ', ')."
        }
        if ($failedSubTaskNames.Count -gt 0) {
            $detail += " Already failed: $($failedSubTaskNames -join ', ')."
        }
        $remediation = 'Review the health-summary results in the SDDC Manager UI. If the task is still ' +
        'progressing normally, consider increasing the Health Summary poll budget in Settings and re-running the check.'
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $Context.SddcManagerFqdn -Detail $detail -Remediation $remediation `
            -Rows $subTaskRows -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    if ($status -match 'COMPLETED_WITH_SUCCESS|SUCCESS') {
        return New-VcfCheckResult -CheckId $checkId -Status Pass `
            -TargetComponent $Context.SddcManagerFqdn -Detail "Health-summary task `"$($task.Id)`" completed with status `"$status`"." `
            -Rows $subTaskRows -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    if ($status -match 'COMPLETED_WITH_FAILURE|FAIL') {
        $detail = "Health-summary task `"$($task.Id)`" completed with status `"$status`"."
        if ($failedSubTaskNames.Count -gt 0) {
            $detail += " Failed sub-task(s): $($failedSubTaskNames -join ', ')."
        }
        return New-VcfCheckResult -CheckId $checkId -Status Fail `
            -TargetComponent $Context.SddcManagerFqdn -Detail $detail `
            -Rows $subTaskRows -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    return New-VcfCheckResult -CheckId $checkId -Status Error `
        -TargetComponent $Context.SddcManagerFqdn -Detail "Health-summary task `"$($task.Id)`" completed with unexpected status `"$status`"." `
        -Rows $subTaskRows -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
}
function Resolve-VcfCheckInProgressHealthCheckId {

    <#
        .SYNOPSIS
        Extracts an already-running health-summary task's Id from
        Invoke-VcfStartHealthCheck's OPERATION_IN_PROGRESS error message, if present.

        .DESCRIPTION
        SDDC Manager permits only one health-summary task at a time and rejects concurrent requests
        with an OPERATION_IN_PROGRESS error. Parses the active task GUID from the exception message
        so execution can attach to and poll the running task.

        .PARAMETER ErrorMessage
        The exception message text to check (Invoke-VcfStartHealthCheck's $_.Exception.Message).

        .OUTPUTS
        [String] the in-progress task's Id, or $null if ErrorMessage does not match an
        OPERATION_IN_PROGRESS error.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$ErrorMessage
    )

    if ([String]::IsNullOrWhiteSpace($ErrorMessage) -or $ErrorMessage -notmatch 'OPERATION_IN_PROGRESS') {
        return $null
    }

    $match = [Regex]::Match($ErrorMessage, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($match.Success) {
        return $match.Value
    }
    return $null
}
function New-VcfCheckHealthSummarySpec {

    <#
        .SYNOPSIS
        Builds the explicit HealthSummarySpec submitted by Test-VcfSddcCheckHealthSummary.

        .DESCRIPTION
        Constructs a HealthSummarySpec with all 11 health-check categories enabled, Force set to $true,
        SkipKnownHostCheck set to $false, and SummaryReport set to $true.

        Scopes the check to IncludeAllDomains and IncludeFreeHosts. Omits obsolete parameters to maintain
        compatibility with the API schema.

        .OUTPUTS
        [PSObject] a VMware.Bindings.Vcf.SddcManager.Model.HealthSummarySpec.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param ()

    $config = Initialize-VcfHealthSummaryConfig -Force $true -SkipKnownHostCheck $false
    $includeItems = Initialize-VcfHealthSummaryIncludeItems -SummaryReport $true
    $option = Initialize-VcfHealthSummaryOption -Config $config -Include $includeItems

    $scope = Initialize-VcfHealthSummaryScope -IncludeAllDomains $true -IncludeFreeHosts $true

    $healthChecks = Initialize-VcfHealthChecks -ServicesHealth $true -NtpHealth $true -GeneralHealth $true `
        -CertificateHealth $true -PasswordHealth $true -ConnectivityHealth $true -ComputeHealth $true `
        -StorageHealth $true -DnsHealth $true -HardwareCompatibilityHealth $true -VersionHealth $true

    return Initialize-VcfHealthSummarySpec -Options $option -Scope $scope -HealthChecks $healthChecks
}
function Write-VcfCheckHealthSummaryProgress {

    <#
        .SYNOPSIS
        Reports Test-VcfSddcCheckHealthSummary's poll progress via Write-VcfCheckSubProgress.

        .PARAMETER Context
        The VcfCheck.Context object, passed straight through to Write-VcfCheckSubProgress.

        .PARAMETER Attempt
        1-based poll attempt number so far (0 before the first poll).

        .PARAMETER MaxAttempts
        The check's MaxPollAttempts, used as the sub-progress Total.

        .PARAMETER Status
        The health-summary task's current Status string. May be blank/whitespace before SDDC
        Manager assigns one.

        .PARAMETER StartedAt
        When Test-VcfSddcCheckHealthSummary started, used to compute elapsed time for the label.

        .PARAMETER SubTasks
        Best-effort per-category sub-task detail from Get-VcfCheckHealthSummarySubTaskList (each
        with Name/Status), used to append a "N/M sub-tasks complete" count - and, once any have
        failed, their names - to the label. Empty/$null if none were resolved.

        .OUTPUTS
        None.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [Int]$Attempt,
        [Parameter(Mandatory = $true)] [Int]$MaxAttempts,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Status,
        [Parameter(Mandatory = $true)] [DateTime]$StartedAt,
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject[]]$SubTasks = @()
    )

    $elapsed = (Get-Date) - $StartedAt
    $elapsedText = "{0}m {1}s" -f [Int][Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
    $statusText = if ([String]::IsNullOrWhiteSpace($Status)) { 'starting' } else { $Status }
    $label = "Health-summary task status: $statusText (elapsed $elapsedText)"

    $subTasks = @($SubTasks | Where-Object { $_ })
    if ($subTasks.Count -gt 0) {
        $completeCount = @($subTasks | Where-Object { $_.Status -match 'SUCCE|COMPLET|FAIL' }).Count
        $label += " - $completeCount/$($subTasks.Count) sub-tasks complete"
        $failedNames = @($subTasks | Where-Object { $_.Status -match 'FAIL' } | ForEach-Object { $_.Name })
        if ($failedNames.Count -gt 0) {
            $label += ", failed: $($failedNames -join ', ')"
        }
    }

    Write-VcfCheckSubProgress -Context $Context -Current $Attempt -Total $MaxAttempts -Label $label -Unit 'poll attempts'
}
function Get-VcfCheckHealthSummarySubTaskList {

    <#
        .SYNOPSIS
        Queries health-summary sub-tasks via SDDC Manager's task system.

        .DESCRIPTION
        Retrieves category-level sub-tasks (Task.SubTasks) associated with the health-summary task Id
        using Invoke-VcfGetTask. Provides sub-task status details for logging and progress reporting.

        Returns an empty array if the task Id is not found or if the query fails.

        .PARAMETER Id
        The health-summary task's Id.

        .OUTPUTS
        [PSObject[]] the task's SubTasks (each with Name/Status/Errors), or an empty array.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Id
    )

    try {
        $task = Invoke-VcfGetTask -Id $Id -ErrorAction Stop
        return @($task.SubTasks | Where-Object { $_ })
    } catch {
        return @()
    }
}
function Get-VcfCheckHealthSummarySubTaskSignature {

    <#
        .SYNOPSIS
        Builds a comparable signature of sub-task name/status pairs for stall detection.

        .DESCRIPTION
        Joins each sub-task's Name and Status into a single sorted string so
        Test-VcfSddcCheckHealthSummary can detect when consecutive polls report no change to an
        in-progress sub-task, indicating SDDC Manager has stopped making progress on the
        health-summary task.

        .PARAMETER SubTasks
        Sub-tasks from Get-VcfCheckHealthSummarySubTaskList. Returns an empty string if empty/$null.

        .OUTPUTS
        [String] the sub-task signature, or an empty string when no sub-tasks are available.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject[]]$SubTasks = @()
    )

    $subTasks = @($SubTasks | Where-Object { $_ } | Sort-Object -Property Name)
    if ($subTasks.Count -eq 0) {
        return ''
    }
    return (($subTasks | ForEach-Object { "$($_.Name):$($_.Status)" }) -join '|')
}
function Write-VcfCheckHealthSummarySubTaskLog {

    <#
        .SYNOPSIS
        Logs health-summary sub-task names and statuses.

        .PARAMETER SubTasks
        Sub-tasks from Get-VcfCheckHealthSummarySubTaskList. No-ops if empty/$null.

        .OUTPUTS
        None.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject[]]$SubTasks = @()
    )

    foreach ($subTask in @($SubTasks | Where-Object { $_ })) {
        Write-LogMessage -Type DEBUG -Message "Health-summary sub-task `"$($subTask.Name)`": $($subTask.Status)."
    }
}
