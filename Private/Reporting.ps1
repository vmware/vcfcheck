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
#region Reporting

function ConvertTo-VcfCheckReportJson {

    <#
        .SYNOPSIS
        Builds the aggregate run JSON object from a list of check results.

        .DESCRIPTION
        Produces the schema consumed by the bundled Python report server: a run-level summary
        (counts per status plus blockingFailures) and the full array of per-check result objects.

        .PARAMETER RunId
        Unique identifier for this run (e.g. a timestamp string).

        .PARAMETER SddcManagerFqdn
        The SDDC Manager this run was executed against.

        .PARAMETER CheckId
        The explicit check ID(s) that were requested for this run. Empty means every check
        in the catalog ran.

        .PARAMETER Results
        Array of VcfCheck.Result objects (from New-VcfCheckResult).

        .PARAMETER StartedAt
        UTC timestamp when the run began.

        .PARAMETER CompletedAt
        UTC timestamp when the run finished (or "now" for a partial/in-progress flush).

        .PARAMETER VcfVersion
        The running SDDC Manager's version string for this environment
        (Get-VcfCheckVcfVersion), e.g. "5.2.1.0-24305054". Empty when it could not be resolved -
        a non-fatal condition, see Invoke-VcfCheck.

        .OUTPUTS
        [PSCustomObject] ready for ConvertTo-Json.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$RunId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$SddcManagerFqdn = '',
        [Parameter(Mandatory = $false)] [String[]]$CheckId = @(),
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$Results,
        [Parameter(Mandatory = $true)] [DateTime]$StartedAt,
        [Parameter(Mandatory = $true)] [DateTime]$CompletedAt,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$VcfVersion = ''
    )

    $summary = [Ordered]@{
        total            = $Results.Count
        pass             = ($Results | Where-Object Status -eq 'Pass').Count
        warning          = ($Results | Where-Object Status -eq 'Warning').Count
        fail             = ($Results | Where-Object Status -eq 'Fail').Count
        error            = ($Results | Where-Object Status -eq 'Error').Count
        skipped          = ($Results | Where-Object Status -eq 'Skipped').Count
        blockingFailures = ($Results | Where-Object { $_.Status -eq 'Fail' -and $_.Blocking }).Count
    }

    return [PSCustomObject]@{
        runId           = $RunId
        toolVersion      = $Script:VcfCheckVersion
        vcfVersion       = $VcfVersion
        startedAt        = $StartedAt.ToUniversalTime().ToString('o')
        completedAt      = $CompletedAt.ToUniversalTime().ToString('o')
        sddcManagerFqdn  = $SddcManagerFqdn
        checkIds         = $CheckId
        summary          = $summary
        results          = $Results
    }
}
function Set-VcfCheckReportFileWithRetry {

    <#
        .SYNOPSIS
        Writes report content to a file, retrying on a transient Windows file-lock error.

        .DESCRIPTION
        The Python report server polls the same file (Tools/Start-VcfCheckServer.py's
        _load_latest_findings_json) while this engine is writing it, via Set-Content's non-atomic
        write. On Windows, a reader's open() call taken at the exact moment Set-Content holds its
        own exclusive write handle raises "The process cannot access the file because it is being
        used by another process" instead of the truncated-read race POSIX allows - confirmed live
        as an unhandled crash mid-run when this collided with the final (non-partial-flush) report
        write. A short retry-with-backoff treats that specific error as transient instead of
        letting it abort the entire run.

        .PARAMETER LiteralPath
        Path to the file to write.

        .PARAMETER Value
        Content to write.

        .OUTPUTS
        None.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$LiteralPath,
        [Parameter(Mandatory = $true)] [String]$Value
    )

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Set-Content -LiteralPath $LiteralPath -Value $Value -ErrorAction Stop
            return
        } catch [System.IO.IOException] {
            if ($attempt -eq $maxAttempts) {
                throw [System.InvalidOperationException]::new("Could not write report file `"$LiteralPath`" after $maxAttempts attempts: $($_.Exception.Message)")
            }
            Write-LogMessage -Type DEBUG -Message "Report file '$LiteralPath' was locked by another process (attempt $attempt/$maxAttempts); retrying."
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }
}
function Write-VcfCheckReport {

    <#
        .SYNOPSIS
        Writes a run report to disk as both <environmentName>-<runId>-findings.json and latest.json.

        .DESCRIPTION
        The bundled Python report server polls the output directory for these files - there is
        no network API between the PowerShell engine and the Python viewer. Called after every
        check completes (partial flush) so an interrupted run still yields a usable report, and
        once more at the end of the run with the final result set. The filename is keyed on the
        report's runId, so every flush for a given run overwrites the same file rather than
        accumulating a new file per check.

        .PARAMETER Report
        The object returned by ConvertTo-VcfCheckReportJson.

        .PARAMETER OutputPath
        Directory to write <environmentName>-<runId>-findings.json and latest.json into. Created if missing.

        .PARAMETER EnvironmentName
        Human-readable name of the environment (from environments.json), used in report filenames.
        When omitted, falls back to the run-<id>.json format for backwards compatibility.

        .OUTPUTS
        [String] path to the run-specific JSON file written.

        .EXAMPLE
        Write-VcfCheckReport -Report $report -OutputPath "$env:VcfCheckBaseDirectory\Findings" -EnvironmentName "VCF520-vRSLCM"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Report,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$OutputPath,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$EnvironmentName = ''
    )

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
    }

    $resultFragments = foreach ($result in $Report.results) {
        $resultJson = $null
        foreach ($depth in @(12, 8, 5, 3, 2)) {
            try {
                $resultJson = $result | ConvertTo-Json -Depth $depth -ErrorAction Stop
                break
            } catch {
                if ($depth -eq 2) {
                    throw $_
                }
                Write-LogMessage -Type DEBUG -Message "Result '$($result.CheckId)' serialization at -Depth $depth failed ($($_.Exception.Message)); retrying at a shallower depth."
            }
        }
        $resultJson
    }

    $reportWithoutResults = $Report | Select-Object -Property * -ExcludeProperty results
    $topJson = $reportWithoutResults | ConvertTo-Json -Depth 5
    $resultsArrayJson = '[' + ($resultFragments -join ',') + ']'
    $json = $topJson.TrimEnd().TrimEnd('}') + ',"results":' + $resultsArrayJson + '}'

    if ([String]::IsNullOrWhiteSpace($EnvironmentName)) {
        $runFilePath = Join-Path -Path $OutputPath -ChildPath "run-$($Report.runId).json"
    } else {
        $runFilePath = Join-Path -Path $OutputPath -ChildPath "$EnvironmentName-$($Report.runId)-findings.json"
    }
    $latestFilePath = Join-Path -Path $OutputPath -ChildPath 'latest.json'

    Set-VcfCheckReportFileWithRetry -LiteralPath $runFilePath -Value $json
    Set-VcfCheckReportFileWithRetry -LiteralPath $latestFilePath -Value $json

    return $runFilePath
}
function Get-VcfCheckTimestampedReportPath {

    <#
        .SYNOPSIS
        Builds a human-friendly, timestamp-based path for a completed run's report file.

        .DESCRIPTION
        Findings/report filenames are keyed on the run's internal run ID (e.g. a short hex
        string handed down by the bundled Python server) while the run is in progress, so every
        partial flush for that run overwrites the same file. Once the run is complete there is
        no further need for that consistency, and the run ID is not a useful lookup key for a
        human browsing the Findings folder - this swaps it for a "yyyyMMdd-HHmmss" timestamp.

        .PARAMETER Path
        Path to an existing report artifact (e.g. the findings JSON file) whose filename
        contains -RunId.

        .PARAMETER RunId
        The run ID currently embedded in the filename.

        .PARAMETER CompletedAt
        The run's completion time, used to build the replacement timestamp.

        .OUTPUTS
        [String] the new path, or the original -Path unchanged if -RunId was not found in the
        filename.

        .EXAMPLE
        Get-VcfCheckTimestampedReportPath -Path 'VCF52-VRSLCM-df248dbfd49b-findings.json' -RunId 'df248dbfd49b' -CompletedAt (Get-Date)
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$RunId,
        [Parameter(Mandatory = $true)] [DateTime]$CompletedAt
    )

    $leaf = Split-Path -Path $Path -Leaf
    if ($leaf -notmatch [Regex]::Escape($RunId)) {
        return $Path
    }

    $directory = Split-Path -Path $Path -Parent
    $timestamp = $CompletedAt.ToString('yyyyMMdd-HHmmss')
    $newLeaf = $leaf -replace [Regex]::Escape($RunId), $timestamp

    if ([String]::IsNullOrWhiteSpace($directory)) {
        return $newLeaf
    }
    return Join-Path -Path $directory -ChildPath $newLeaf
}
function Write-VcfCheckCheckProgress {

    <#
        .SYNOPSIS
        Prints a "[N/Total] Running <check>..." line before a check starts.

        .DESCRIPTION
        This module's own replacement for PowerCLI cmdlets' (Invoke-VMScript in particular)
        default Write-Progress rendering, which surfaces as raw, unstyled "[percent complete: N]"
        noise in the console - confirmed live to be genuinely confusing/unhelpful output, not
        useful progress information, since it reflects one internal API call's wait state rather
        than the run's actual progress. $ProgressPreference is set to SilentlyContinue for the
        whole run (see Invoke-VcfCheck) to suppress that noise; this function is the
        intentional replacement, so a live run is never completely silent between checks.

        .PARAMETER Index
        1-based position of this check in the run.

        .PARAMETER Total
        Total number of checks in this run.

        .PARAMETER CheckId
        The check ID.

        .PARAMETER DisplayName
        The check's human-readable title (Data/CheckCatalog.json's "displayName") - shown instead
        of -CheckId so a live run reads like the report a user will see, not the internal id.

        .OUTPUTS
        None. Writes directly to the console.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [Int]$Index,
        [Parameter(Mandatory = $true)] [Int]$Total,
        [Parameter(Mandatory = $true)] [String]$CheckId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$DisplayName = ''
    )

    $label = if ($DisplayName) { $DisplayName } else { $CheckId }
    Write-Host "[$Index/$Total] Running $label..." -ForegroundColor Gray
}
function Write-VcfCheckCheckOutcome {

    <#
        .SYNOPSIS
        Prints the one-line, color-coded outcome of a single check immediately after it runs.

        .DESCRIPTION
        Paired with Write-VcfCheckCheckProgress - together they give real-time, per-check
        feedback for a live run, replacing the raw PowerCLI progress-bar noise this project
        deliberately suppresses. Uses the same color convention as Write-VcfCheckConsoleSummary
        (Red = blocking fail, Yellow = fail/warning, DarkYellow = error, Green = pass).

        .PARAMETER Result
        The VcfCheck.Result object just produced for this check.

        .OUTPUTS
        None. Writes directly to the console.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Result
    )

    $color = switch ($Result.Status) {
        'Pass' { 'Green' }
        'Skipped' { 'DarkGray' }
        'Warning' { 'Yellow' }
        'Fail' { if ($Result.Blocking) { 'Red' } else { 'Yellow' } }
        'Error' { 'DarkYellow' }
        default { 'White' }
    }
    $suffix = if ($Result.Status -eq 'Fail' -and $Result.Blocking) { 'BLOCKING FAIL' } else { $Result.Status.ToUpperInvariant() }
    $baseLabel = if ($Result.DisplayName) { $Result.DisplayName } else { $Result.CheckId }
    $label = if ($Result.Component) { "$baseLabel [$($Result.Component)]" } elseif ($Result.Domain) { "$baseLabel [$($Result.Domain)]" } else { $baseLabel }
    $durationSuffix = if ($null -ne $Result.DurationMs) { " ($(Format-VcfCheckDuration -Milliseconds $Result.DurationMs))" } else { '' }

    Write-Host "  -> ${label}: $suffix$durationSuffix" -ForegroundColor $color
}
function Write-VcfCheckSubProgress {

    <#
        .SYNOPSIS
        Reports a long-running check's internal iteration progress (e.g. "host 3/12") for the
        browser UI to display alongside the per-check progress bar.

        .DESCRIPTION
        Writes a small progress.json into $Context.OutputPath - the same directory latest.json
        lives in - polled by the bundled Python server's /api/run/status endpoint and rendered by
        Tools/vcf-check-ui.html as a sub-progress line under "Current: <check name>". A check
        with only one item (or that never calls this) simply never gets a sub-progress line.

        Best-effort: a write failure here must never fail the check itself, so all errors are
        swallowed after a DEBUG log line.

        .PARAMETER Context
        The VcfCheck.Context object. No-ops if Context.OutputPath was never set (e.g. a check
        function invoked directly in a unit test, outside Invoke-VcfCheck).

        .PARAMETER Current
        1-based index of the item currently being processed.

        .PARAMETER Total
        Total number of items being iterated.

        .PARAMETER Label
        Human-readable name of the current item (e.g. an ESX host's name).

        .PARAMETER Unit
        What Current/Total are counting, rendered by the browser UI (e.g. "hosts", "poll
        attempts"). Defaults to 'hosts' - every caller before this parameter existed was a
        per-host loop, and the UI's rendering hardcoded "Scanning N/Total hosts" accordingly;
        this default preserves that exact wording for those callers unchanged.

        .OUTPUTS
        None.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [Int]$Current,
        [Parameter(Mandatory = $true)] [Int]$Total,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Label = '',
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Unit = 'hosts'
    )

    if ([String]::IsNullOrWhiteSpace($Context.OutputPath)) {
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $Context.OutputPath -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $Context.OutputPath -Force
        }
        $payload = [Ordered]@{
            current   = $Current
            total     = $Total
            label     = $Label
            unit      = $Unit
            updatedAt = [DateTime]::UtcNow.ToString('o')
        }
        $progressPath = Join-Path -Path $Context.OutputPath -ChildPath 'progress.json'
        Set-Content -LiteralPath $progressPath -Value ($payload | ConvertTo-Json -Depth 2) -ErrorAction Stop
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not write sub-progress file: $($_.Exception.Message)"
    }
}
function Clear-VcfCheckSubProgress {

    <#
        .SYNOPSIS
        Clears any sub-progress reported by the check that just finished, so a later, shorter
        check never displays a stale "host 12/12" line left over from a prior check.

        .DESCRIPTION
        Called by Invoke-VcfCheck immediately after every check returns, regardless of that
        check's status - not just the ones that call Write-VcfCheckSubProgress. Best-effort,
        same as Write-VcfCheckSubProgress.

        .PARAMETER Context
        The VcfCheck.Context object. No-ops if Context.OutputPath was never set.

        .OUTPUTS
        None.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ([String]::IsNullOrWhiteSpace($Context.OutputPath)) {
        return
    }

    $progressPath = Join-Path -Path $Context.OutputPath -ChildPath 'progress.json'
    try {
        if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
            Remove-Item -LiteralPath $progressPath -Force -ErrorAction Stop
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not clear sub-progress file: $($_.Exception.Message)"
    }
}
function Format-VcfCheckDuration {

    <#
        .SYNOPSIS
        Formats a duration in milliseconds as a short, human-readable string.

        .PARAMETER Milliseconds
        Duration in milliseconds (e.g. VcfCheck.Result's DurationMs).

        .OUTPUTS
        [String] "123ms" for sub-second durations, otherwise "12.3s".

        .EXAMPLE
        Format-VcfCheckDuration -Milliseconds 46150.85
        # '46.2s'
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [Double]$Milliseconds
    )

    if ($Milliseconds -lt 1000) {
        return "$([Math]::Round($Milliseconds))ms"
    }
    return "$([Math]::Round($Milliseconds / 1000, 1))s"
}
function Write-VcfCheckConsoleSummary {

    <#
        .SYNOPSIS
        Prints a human-readable pass/fail summary of a precheck run to the console.

        .DESCRIPTION
        Complements the JSON report (machine-readable, for the bundled web viewer) with a
        plain-text summary a user can read directly in their terminal without opening a browser:
        blocking failures first, then non-blocking failures, warnings, errors, then a one-line
        Pass/Skipped count. Every line includes the check's Detail/Exception text (already passed
        through Protect-VcfCheckLogMessage at result-creation time in New-VcfCheckResult),
        so "what failed and why" is visible without cross-referencing the JSON.

        .PARAMETER Results
        Array of VcfCheck.Result objects.

        .OUTPUTS
        None. Writes to the console.

        .EXAMPLE
        Write-VcfCheckConsoleSummary -Results $results
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$Results
    )

    $blockingFailures = @($Results | Where-Object { $_.Status -eq 'Fail' -and $_.Blocking })
    $nonBlockingFailures = @($Results | Where-Object { $_.Status -eq 'Fail' -and -not $_.Blocking })
    $warnings = @($Results | Where-Object { $_.Status -eq 'Warning' })
    $errors = @($Results | Where-Object { $_.Status -eq 'Error' })
    $passed = @($Results | Where-Object { $_.Status -eq 'Pass' })
    $skipped = @($Results | Where-Object { $_.Status -eq 'Skipped' })

    Write-Host ''
    Write-Host '===== VcfCheck summary =====' -ForegroundColor Cyan

    # Detail (and Remediation) can be multi-line (e.g. sddc_bom_check's per-component breakdown) -
    # a bare Write-Host "         $Text" only indents the first line, leaving every subsequent
    # line unindented and visually detached from the check it belongs to (confirmed live,
    # 2026-07-16). Every line gets the same indent/color instead.
    $writeIndentedLines = {
        Param ([String]$Text, [String]$Color)
        foreach ($line in ($Text -split "`r?`n")) {
            Write-Host "         $line" -ForegroundColor $Color
        }
    }

    if ($blockingFailures.Count -gt 0) {
        Write-Host ''
        Write-Host "BLOCKING FAILURES ($($blockingFailures.Count)) - will interrupt the upgrade:" -ForegroundColor Red
        foreach ($result in $blockingFailures) {
            Write-Host "  [FAIL] $($result.CheckId) - $($result.DisplayName)" -ForegroundColor Red
            & $writeIndentedLines $result.Detail 'Red'
            if ($result.Remediation) { & $writeIndentedLines "Remediation: $($result.Remediation)" 'Red' }
        }
    }

    if ($nonBlockingFailures.Count -gt 0) {
        Write-Host ''
        Write-Host "FAILURES ($($nonBlockingFailures.Count)):" -ForegroundColor Yellow
        foreach ($result in $nonBlockingFailures) {
            Write-Host "  [FAIL] $($result.CheckId) - $($result.DisplayName)" -ForegroundColor Yellow
            & $writeIndentedLines $result.Detail 'Yellow'
            if ($result.Remediation) { & $writeIndentedLines "Remediation: $($result.Remediation)" 'Yellow' }
        }
    }

    if ($warnings.Count -gt 0) {
        Write-Host ''
        Write-Host "WARNINGS ($($warnings.Count)):" -ForegroundColor Yellow
        foreach ($result in $warnings) {
            Write-Host "  [WARN] $($result.CheckId) - $($result.DisplayName)" -ForegroundColor Yellow
            & $writeIndentedLines $result.Detail 'Yellow'
            if ($result.Remediation) { & $writeIndentedLines "Remediation: $($result.Remediation)" 'Yellow' }
        }
    }

    if ($errors.Count -gt 0) {
        Write-Host ''
        Write-Host "TOOL ERRORS ($($errors.Count)) - the check itself could not complete:" -ForegroundColor DarkYellow
        foreach ($result in $errors) {
            $errorText = if (-not [String]::IsNullOrWhiteSpace($result.Exception)) { $result.Exception } else { $result.Detail }
            Write-Host "  [ERROR] $($result.CheckId) - $($result.DisplayName): $errorText" -ForegroundColor DarkYellow
        }
    }

    if ($skipped.Count -gt 0) {
        Write-Host ''
        Write-Host "SKIPPED ($($skipped.Count)) - not run, with reason:" -ForegroundColor DarkGray
        foreach ($result in $skipped) {
            Write-Host "  [SKIP] $($result.CheckId) - $($result.DisplayName)" -ForegroundColor DarkGray
            & $writeIndentedLines $result.Detail 'DarkGray'
        }
    }

    Write-Host ''
    Write-Host "Pass: $($passed.Count)  Skipped: $($skipped.Count)  Warning: $($warnings.Count)  Fail: $($nonBlockingFailures.Count)  Blocking Fail: $($blockingFailures.Count)  Error: $($errors.Count)  Total: $($Results.Count)" -ForegroundColor Cyan
    Write-Host '================================' -ForegroundColor Cyan
    Write-Host ''
}
function Export-VcfCheckReportCsv {

    <#
        .SYNOPSIS
        Exports a precheck run's results to a flat CSV file.

        .DESCRIPTION
        A portable, spreadsheet-friendly alternative to the JSON report - useful for sharing a
        run's results with a stakeholder who doesn't want to open the bundled web viewer (a plain
        tabular export alongside the primary report, not a replacement for it).

        Deliberately does not include Rows: each check defines its own row schema, so a run mixing
        several checks' Rows has no single consistent set of CSV columns to flatten them into.
        Rows is JSON/HTML-report-only - see ConvertTo-VcfCheckReportJson and
        Export-VcfCheckReportHtml.

        .PARAMETER Results
        Array of VcfCheck.Result objects.

        .PARAMETER Path
        Destination .csv file path.

        .OUTPUTS
        [String] the path written.

        .EXAMPLE
        Export-VcfCheckReportCsv -Results $results -Path "$env:VcfCheckBaseDirectory\Findings\run-20260716.csv"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$Results,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    $parentDirectory = Split-Path -Parent $Path
    if ($parentDirectory -and -not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parentDirectory -Force
    }

    $Results |
        Select-Object CheckId, Area, Domain, DomainType, Component, DisplayName, Status, Blocking, TargetComponent, Detail, Remediation, StartedAt, CompletedAt, DurationMs, Exception |
        Export-Csv -LiteralPath $Path -NoTypeInformation -ErrorAction Stop

    return $Path
}
function ConvertTo-VcfCheckHostHierarchyJson {

    <#
        .SYNOPSIS
        Converts hosts grouped by vCenter and cluster into a hierarchical JSON structure.

        .DESCRIPTION
        Takes a hashtable of vCenter FQDN → hosts and produces a JSON string where vCenter FQDN
        is the top-level key for readability:
        { "vcenter-fqdn": { "clusters": [ { "clusterName": "...", "esxHostNames": [...] }, ... ] }, ... }

        This improves readability in the UI and provides clean output for eventual JSON export.

        Handles both:
        - VMHost objects (uses .Parent.Name for cluster, .Name for host)
        - AdvancedSetting objects (uses .Entity.Parent.Name for cluster, .Entity.Name for host)

        .PARAMETER HostsByVcenter
        Hashtable where keys are vCenter FQDNs and values are collections of host objects (VMHost or AdvancedSetting).

        .OUTPUTS
        [String] Formatted JSON string with vCenter FQDN as top-level key, then Cluster → Hosts hierarchy.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [Hashtable]$HostsByVcenter
    )

    if ($HostsByVcenter.Count -eq 0) {
        return '{}'
    }

    $hierarchy = [Ordered]@{}

    foreach ($vcenterFqdn in ($HostsByVcenter.Keys | Sort-Object)) {
        $hosts = $HostsByVcenter[$vcenterFqdn]

        # Group hosts by cluster
        $hostsByCluster = @{}
        foreach ($hostItem in $hosts) {
            # Detect whether this is an AdvancedSetting (has Entity) or direct VMHost
            $vmHost = if ($hostItem.Entity) { $hostItem.Entity } else { $hostItem }
            $clusterName = $vmHost.Parent.Name
            $hostName = $vmHost.Name

            if (-not $hostsByCluster.ContainsKey($clusterName)) {
                $hostsByCluster[$clusterName] = @()
            }
            $hostsByCluster[$clusterName] += $hostName
        }

        # Build clusters array for this vCenter
        $clustersArray = @()
        foreach ($cluster in ($hostsByCluster.Keys | Sort-Object)) {
            $sortedHosts = @($hostsByCluster[$cluster] | Sort-Object)
            $clustersArray += @{
                clusterName = $cluster
                esxHostNames = $sortedHosts
            }
        }

        $hierarchy[$vcenterFqdn] = @{ clusters = $clustersArray }
    }

    # See Write-VcfCheckReport for why this is a single depth rather than a try/catch retry
    # loop - ConvertTo-Json does not throw on exceeding -Depth, it silently stringifies whatever
    # it finds past the limit, so a catch-based retry never actually recovers anything. This
    # structure only nests 3 levels deep (vCenter -> clusters -> clusterName/esxHostNames), so
    # -Depth 5 already has headroom.
    return $hierarchy | ConvertTo-Json -Depth 5
}
function ConvertTo-VcfCheckHtmlEncoded {

    <#
        .SYNOPSIS
        HTML-encodes a value for safe interpolation into Export-VcfCheckReportHtml's output.

        .DESCRIPTION
        The single shared escaping helper for the static HTML report - every dynamic value
        (Detail, Remediation, TargetComponent, a Rows cell, a derived table header, etc.) must
        pass through this before being interpolated into the document, since that data ultimately
        originates from live SDDC Manager/vCenter/NSX API responses and appliance command output,
        not trusted input. Wraps [System.Net.WebUtility]::HtmlEncode (available cross-platform on
        PowerShell 7) rather than System.Web.HttpUtility, which is not reliably available there.

        .PARAMETER Value
        The value to encode. Coerced to a string first if not already one; $null becomes an empty
        string.

        .OUTPUTS
        [String] the HTML-encoded value.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [Object]$Value = $null
    )

    if ($null -eq $Value) {
        return ''
    }
    return [System.Net.WebUtility]::HtmlEncode([String]$Value)
}
function ConvertTo-VcfCheckHtmlRemediationEncoded {

    <#
        .SYNOPSIS
        HTML-encodes a Remediation string, rendering any `[text](url)` markdown links it contains
        as clickable anchors.

        .DESCRIPTION
        CheckCatalog.json's remediation field sometimes links a Broadcom KB or techdocs page using
        markdown link syntax (e.g. "[KB 439473](https://knowledge.broadcom.com/...)"). The rest of
        the report has no markdown rendering, so without this the link shows up as literal bracket
        syntax instead of a clickable link. Runs ConvertTo-VcfCheckHtmlEncoded first so the whole
        string is safe to interpolate, then promotes the (now HTML-encoded) markdown link syntax to
        an <a> tag - the encoded text and URL are already entity-escaped at that point, so wrapping
        them in a tag afterwards introduces no unescaped content.

        .PARAMETER Value
        The remediation text to encode. Coerced to a string first if not already one; $null becomes
        an empty string.

        .OUTPUTS
        [String] the HTML-encoded value with any markdown links rendered as <a> tags.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [Object]$Value = $null
    )

    $encoded = ConvertTo-VcfCheckHtmlEncoded -Value $Value
    return [Regex]::Replace($encoded, '\[([^\]]+)\]\((https?://[^\s)]+)\)', '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
}
function Get-VcfCheckHtmlStatusClass {

    <#
        .SYNOPSIS
        Maps a result's Status/Blocking to the CSS status class shared by the report's nav,
        summary table, and detail cards.

        .DESCRIPTION
        Mirrors Write-VcfCheckCheckOutcome's console color convention exactly: a non-blocking
        Fail renders the same as a Warning, and only a blocking Fail gets its own treatment - kept
        identical here so the console, live viewer, and static report never disagree about how
        severe a given result looks.

        .PARAMETER Status
        The result's Status value.

        .PARAMETER Blocking
        The result's Blocking value.

        .OUTPUTS
        [String] one of pass|warning|fail|error|skipped.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [String]$Status,
        [Parameter(Mandatory = $false)] [Bool]$Blocking = $false
    )

    switch ($Status) {
        'Pass' { return 'pass' }
        'Skipped' { return 'skipped' }
        'Warning' { return 'warning' }
        'Fail' {
            if ($Blocking) { return 'fail' } else { return 'warning' }
        }
        'Error' { return 'error' }
        default { return 'skipped' }
    }
}
function Get-VcfCheckReportStylesheet {

    <#
        .SYNOPSIS
        Extracts the browser report's inline <style> block from Tools/vcf-check-ui.html so the
        static HTML report can embed the exact same CSS.

        .DESCRIPTION
        The single source of truth for this report's visual design is Tools/vcf-check-ui.html -
        both surfaces must always look identical, so this reads that file's own <style>...</style>
        text verbatim at generation time rather than maintaining a second, hand-written copy that
        can drift out of sync. Fails loudly (throws) when the file is missing or has no <style>
        block - there is no stale hand-written fallback to silently degrade to.

        .PARAMETER Path
        Path to vcf-check-ui.html. Defaults to Tools/vcf-check-ui.html relative to this module.

        .OUTPUTS
        [String] the CSS text between the <style> and </style> tags.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Path = (Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path '..' -ChildPath (Join-Path -Path 'Tools' -ChildPath 'vcf-check-ui.html')))
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [System.InvalidOperationException]::new("Cannot extract report stylesheet: `"$Path`" was not found.")
    }

    try {
        $html = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("Cannot extract report stylesheet: failed to read `"$Path`": $($_.Exception.Message)")
    }

    $styleMatch = [Regex]::Match($html, '<style>(.*?)</style>', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $styleMatch.Success) {
        throw [System.InvalidOperationException]::new("Cannot extract report stylesheet: no <style> block found in `"$Path`".")
    }

    return $styleMatch.Groups[1].Value
}
function Format-VcfCheckHtmlDocumentHead {

    <#
        .SYNOPSIS
        Builds the <head> element (title + inline styles) for the static HTML report.

        .DESCRIPTION
        A single inline <style> block, no external assets - this document must open standalone
        with no server. The CSS itself is extracted verbatim from Tools/vcf-check-ui.html by
        Get-VcfCheckReportStylesheet, not hand-written here, so the static report and the browser
        report's downloadable export always share one canonical stylesheet.

        Navigation is pure CSS (anchor links + native <details>/<summary> disclosure) -
        deliberately no <script> at all, so this document can never regress into the stored-XSS
        pattern.

        .PARAMETER Title
        Document <title> text. Must already be HTML-encoded by the caller.

        .OUTPUTS
        [String] the <head>...</head> markup.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [String]$Title
    )

    $stylesheet = Get-VcfCheckReportStylesheet
    return @"
<head>
<meta charset="utf-8">
<title>$Title</title>
<style>
$stylesheet
</style>
</head>
"@
}
function Format-VcfCheckHtmlSummaryTile {

    <#
        .SYNOPSIS
        Builds the static status/component count tiles for the HTML report.

        .DESCRIPTION
        Mirrors Tools/vcf-check-ui.html's buildExportTilesHtml() markup and classes
        (.tiles/.tile/.tile-<key>/.count/.label) exactly, but omits the .filter-check icon and
        the data-filter-key/data-area-filter-key attributes it uses to drive click-to-filter -
        this document has no script to respond to a click, so the tiles are purely visual here.

        .PARAMETER Summary
        The report's summary object (ConvertTo-VcfCheckReportJson), with blockingFailures/fail/
        warning/error/skipped/pass counts.

        .PARAMETER Results
        Array of VcfCheck.Result objects, used to compute the per-area tile counts.

        .OUTPUTS
        [String] the tiles markup.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Summary,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$Results
    )

    $statusTiles = [Ordered]@{
        blockingFailures = 'Blocking Failures'
        fail             = 'Fail'
        warning          = 'Warning'
        error            = 'Error'
        skipped          = 'Skipped'
        pass             = 'Pass'
    }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append('<div class="tiles-section"><p class="tiles-section-label">By status</p><div class="tiles">')
    foreach ($key in $statusTiles.Keys) {
        $count = [int]$Summary.$key
        $blockingClass = if ($key -eq 'blockingFailures') { ' blocking' } else { '' }
        $null = $sb.Append('<div class="tile tile-').Append($key).Append($blockingClass).Append('"><div class="count">').Append($count)
        $null = $sb.Append('</div><div class="label">').Append((ConvertTo-VcfCheckHtmlEncoded -Value $statusTiles[$key])).Append('</div></div>')
    }
    $null = $sb.Append('</div></div>')

    $areaOrder = [System.Collections.Generic.List[String]]::new()
    $areaCounts = @{}
    foreach ($result in $Results) {
        $area = if ($result.Area) { $result.Area } else { 'Other' }
        if (-not $areaCounts.ContainsKey($area)) {
            $areaCounts[$area] = 0
            $areaOrder.Add($area)
        }
        $areaCounts[$area]++
    }

    $null = $sb.Append('<div class="tiles-section"><p class="tiles-section-label">By component</p><div class="tiles">')
    foreach ($area in $areaOrder) {
        $null = $sb.Append('<div class="tile"><div class="count">').Append($areaCounts[$area])
        $null = $sb.Append('</div><div class="label">').Append((ConvertTo-VcfCheckHtmlEncoded -Value $area)).Append('</div></div>')
    }
    $null = $sb.Append('</div></div>')

    return $sb.ToString()
}
function Format-VcfCheckHtmlRunSummary {

    <#
        .SYNOPSIS
        Builds the run-level summary block (run id, SDDC Manager, versions, timestamps, counts).

        .DESCRIPTION
        The counts portion is Format-VcfCheckHtmlSummaryTile's static tile markup, matching
        Tools/vcf-check-ui.html's exported summary tiles - the run-metadata table above it (run
        id, SDDC Manager, versions, timestamps) has no equivalent in the browser report's export
        and stays PowerShell-report-specific.

        .PARAMETER Report
        The report object from ConvertTo-VcfCheckReportJson.

        .OUTPUTS
        [String] the summary block markup.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Report
    )

    $vcfVersionText = if ($Report.vcfVersion) { ConvertTo-VcfCheckHtmlEncoded -Value $Report.vcfVersion } else { '&mdash;' }
    $totalExecutionTimeText = '&mdash;'
    if ($Report.startedAt -and $Report.completedAt) {
        $totalExecutionTimeMs = ([DateTime]$Report.completedAt - [DateTime]$Report.startedAt).TotalMilliseconds
        if ($totalExecutionTimeMs -ge 0) { $totalExecutionTimeText = Format-VcfCheckDuration -Milliseconds $totalExecutionTimeMs }
    }
    $tilesHtml = Format-VcfCheckHtmlSummaryTile -Summary $Report.summary -Results @($Report.results)

    return @"
<div>
<h1>VCF Check Report</h1>
<table>
<tr><th>Run ID</th><td>$(ConvertTo-VcfCheckHtmlEncoded -Value $Report.runId)</td></tr>
<tr><th>SDDC Manager</th><td>$(ConvertTo-VcfCheckHtmlEncoded -Value $Report.sddcManagerFqdn)</td></tr>
<tr><th>VCF Version</th><td>$vcfVersionText</td></tr>
<tr><th>Tool Version</th><td>$(ConvertTo-VcfCheckHtmlEncoded -Value $Report.toolVersion)</td></tr>
<tr><th>Started</th><td>$(ConvertTo-VcfCheckHtmlEncoded -Value $Report.startedAt)</td></tr>
<tr><th>Completed</th><td>$(ConvertTo-VcfCheckHtmlEncoded -Value $Report.completedAt)</td></tr>
<tr><th>Total Execution Time</th><td>$totalExecutionTimeText</td></tr>
</table>
$tilesHtml
</div>
"@
}
function Format-VcfCheckHtmlNav {

    <#
        .SYNOPSIS
        Builds the sidebar navigation, grouped by Area, one status-dot link per result.

        .DESCRIPTION
        Matches Tools/vcf-check-ui.html's buildExportNav() markup and classes exactly
        (.export-nav/.export-nav-group-title/.export-nav-link) - grouped by Area only, not nested
        by Domain, since nesting would make the sidebar deeply repetitive for a multi-domain run
        (the same check names repeating under every domain). A result whose Domain is non-empty
        gets "[Domain]" appended to its link label instead.

        .PARAMETER Results
        Array of VcfCheck.Result objects, in report order.

        .OUTPUTS
        [String] the <nav>...</nav> markup.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$Results
    )

    $areaGroups = [Ordered]@{}
    for ($index = 0; $index -lt $Results.Count; $index++) {
        $result = $Results[$index]
        $area = if ($result.Area) { $result.Area } else { 'Other' }
        if (-not $areaGroups.Contains($area)) {
            $areaGroups[$area] = [System.Collections.Generic.List[Object]]::new()
        }
        $areaGroups[$area].Add(@{ Result = $result; Index = $index })
    }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append('<nav class="export-nav"><a href="#top">&uarr; Summary</a>')

    foreach ($area in $areaGroups.Keys) {
        $null = $sb.Append('<div class="export-nav-group-title">').Append((ConvertTo-VcfCheckHtmlEncoded -Value $area)).Append('</div>')
        foreach ($entry in $areaGroups[$area]) {
            $result = $entry.Result
            $baseLabel = if ($result.DisplayName) { $result.DisplayName } else { $result.CheckId }
            $label = $baseLabel
            if ($result.Component) { $label = "$baseLabel [$($result.Component)]" } elseif ($result.Domain) { $label = "$baseLabel [$($result.Domain)]" }
            $null = $sb.Append('<a class="export-nav-link ').Append((ConvertTo-VcfCheckHtmlEncoded -Value $result.Status)).Append('" href="#check-').Append($entry.Index).Append('">').Append((ConvertTo-VcfCheckHtmlEncoded -Value $label)).Append('</a>')
        }
    }

    $null = $sb.Append('</nav>')
    return $sb.ToString()
}
function Format-VcfCheckHtmlSummaryTable {

    <#
        .SYNOPSIS
        Builds the run's summary table: one row per result, linking to its detail card.

        .PARAMETER Results
        Array of VcfCheck.Result objects, in report order.

        .OUTPUTS
        [String] the <table>...</table> markup.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$Results
    )

    $totalDurationMs = ($Results | Where-Object { $null -ne $_.DurationMs } | Measure-Object -Property DurationMs -Sum).Sum
    if (-not $totalDurationMs) { $totalDurationMs = 0 }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append('<h2>Summary</h2><table class="rows-table"><tr><th>No.</th><th>Check</th><th>Area</th><th>Domain / Component</th><th>Domain Type</th><th>Status</th><th>Duration</th><th>%</th></tr>')

    for ($index = 0; $index -lt $Results.Count; $index++) {
        $result = $Results[$index]
        $statusClass = Get-VcfCheckHtmlStatusClass -Status $result.Status -Blocking ([Bool]$result.Blocking)
        $percent = 0
        if ($totalDurationMs -gt 0 -and $result.DurationMs) {
            $percent = [Math]::Round(($result.DurationMs / $totalDurationMs) * 100, 1)
        }
        $duration = ''
        if ($null -ne $result.DurationMs) { $duration = Format-VcfCheckDuration -Milliseconds $result.DurationMs }
        $baseLabel = if ($result.DisplayName) { $result.DisplayName } else { $result.CheckId }

        $null = $sb.Append('<tr><td>').Append($index + 1).Append('</td><td><a href="#check-').Append($index).Append('">')
        $null = $sb.Append((ConvertTo-VcfCheckHtmlEncoded -Value $baseLabel)).Append('</a></td><td>')
        $null = $sb.Append((ConvertTo-VcfCheckHtmlEncoded -Value $result.Area)).Append('</td><td>')
        $domainOrComponent = if ($result.Component) { $result.Component } else { $result.Domain }
        $null = $sb.Append((ConvertTo-VcfCheckHtmlEncoded -Value $domainOrComponent)).Append('</td><td>')
        $null = $sb.Append((ConvertTo-VcfCheckHtmlEncoded -Value $result.DomainType)).Append('</td><td class="cell-').Append($statusClass).Append('">')
        $statusLabel = $result.Status
        if ($result.Status -eq 'Skipped' -and $result.Detail) { $statusLabel = "Skipped - $($result.Detail)" }
        $null = $sb.Append((ConvertTo-VcfCheckHtmlEncoded -Value $statusLabel)).Append('</td><td>')
        $null = $sb.Append((ConvertTo-VcfCheckHtmlEncoded -Value $duration)).Append('</td><td>').Append($percent).Append('%</td></tr>')
    }

    $null = $sb.Append('</table>')
    return $sb.ToString()
}
function ConvertTo-VcfCheckNormalizedExpiryDateText {

    <#
        .SYNOPSIS
        Reformats an expiration-date column's display text to YYYY-MM-DD.

        .DESCRIPTION
        Check functions emit expiration dates in several different formats (full ISO 8601,
        raw vendor-API strings, culture-default .NET DateTime text, "Never", free-text day
        counts). This normalizes only the report/UI display text for columns whose name looks
        like an expiration date (matches "Expir...Date", e.g. ExpiryDate, ExpirationDate,
        "Expiry Date"), a "Next Rotation" column, or a "Last Backup Date" column; the
        underlying JSON result is untouched since this runs on the already-stringified table
        cell, not the check's Rows object. A value that isn't a parseable date (e.g. "Never",
        or a "Last Backup Date" cell with a trailing "more than 48 hours ago." suffix) is
        returned unchanged.

        .PARAMETER ColumnName
        The row's property name for this cell, before camelCase-to-space label formatting.

        .PARAMETER Value
        The cell's already-stringified display text.

        .OUTPUTS
        [String]
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [String]$ColumnName,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Value
    )

    if ($ColumnName -notmatch 'Expir.*Date|Next Rotation|Last Backup Date' -or [String]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $parsedDate = [DateTime]::MinValue
    $parsed = [DateTime]::TryParse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsedDate
    )
    if (-not $parsed) {
        return $Value
    }
    return $parsedDate.ToString('yyyy-MM-dd')
}
function Format-VcfCheckHtmlRowsTable {

    <#
        .SYNOPSIS
        Renders a check result's structured Rows as an HTML table with the "rows-table" class,
        matching Tools/vcf-check-ui.html's rowsToHtml()/renderRowsTable() output exactly.

        .DESCRIPTION
        Column headers are derived from the FIRST row's own property names, in that row's
        property order - every subsequent row reads that same fixed list of property names (a row
        missing one of those properties renders an empty cell; an extra property on a later row
        not present on the first is ignored) rather than shifting columns per row. This is a
        deliberate, documented behavior: a check's own Rows are expected to share one schema.

        Any cell whose trimmed value case-insensitively matches a known status word
        (Pass/Fail/Warning/Error/Skipped/GREEN/YELLOW/RED) gets the matching status CSS class,
        scoped by the "rows-table" class to the same --pass/--warning/--fail/--error/--skipped
        variables the browser report's rows tables use.

        A cell value that is a collection with more than one item (e.g. a check reporting several
        vLCM components for one cluster) renders as a bulleted list instead of being flattened to a
        single delimited string - a run-on "A; B; C" cell is hard to scan once a cluster has more
        than one or two entries. A single-item collection renders as plain text, matching every other
        cell.

        A column present on $Rows[0] but blank (null/empty/whitespace) on every row is dropped
        entirely, rather than rendering as an empty column - e.g. a "Message" property some checks
        only populate for unhealthy rows and leave $null everywhere else.

        A cell that is blank (null/empty/whitespace) on a row where the column is otherwise kept
        renders as "N/A" rather than an empty <td>, so a reviewer can distinguish "queried and
        found nothing" from a rendering gap.

        .PARAMETER Rows
        Array of PSCustomObject "table rows". $null or empty returns an empty string (no <table>
        emitted at all).

        .OUTPUTS
        [String] the <table>...</table> markup, or an empty string when Rows is empty/absent.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$Rows = @()
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return ''
    }

    # $Rows[0] is expected to be a PSCustomObject "row" - if a caller instead handed a bare
    # string (e.g. a nested object flattened to text by a ConvertTo-Json -Depth cutoff upstream;
    # see Write-VcfCheckReport), $Rows[0].PSObject.Properties only exposes .Length, rendering
    # a single misleading "Length" column instead of the string's actual content. Fall back to a
    # single "Value" column so a caller passing malformed rows still gets a readable table.
    $columns = if ($Rows[0] -is [String]) {
        @('Value')
    } else {
        @($Rows[0].PSObject.Properties | Select-Object -ExpandProperty Name) | Where-Object {
            $column = $_
            $Rows | Where-Object { $_ -isnot [String] -and $_.PSObject.Properties[$column] -and -not [String]::IsNullOrWhiteSpace([String]$_.PSObject.Properties[$column].Value) }
        }
    }
    $statusClasses = @{
        'PASS' = 'pass'; 'GREEN' = 'pass'
        'WARNING' = 'warning'; 'YELLOW' = 'warning'
        'FAIL' = 'fail'; 'RED' = 'fail'
        'ERROR' = 'error'
        'SKIPPED' = 'skipped'
    }
    $noTransformColumns = @('UsedPercent')

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append('<table class="rows-table"><tr>')
    foreach ($column in $columns) {
        $label = if ($column -in $noTransformColumns) { $column } else { $column -creplace '([a-z])([A-Z])', '$1 $2' }
        if ($label -eq 'Capacity GB') { $label = 'Capacity (GB)' }
        if ($label -eq 'Host Name') { $label = 'Hostname/IP' }
        $null = $sb.Append('<th>').Append((ConvertTo-VcfCheckHtmlEncoded -Value $label)).Append('</th>')
    }
    $null = $sb.Append('</tr>')

    foreach ($row in $Rows) {
        $null = $sb.Append('<tr>')
        foreach ($column in $columns) {
            $cellValue = $null
            if ($row -is [String]) {
                if ($column -eq 'Value') { $cellValue = $row }
            } elseif ($row.PSObject.Properties[$column]) {
                $cellValue = $row.PSObject.Properties[$column].Value
            }
            $isMultiValueCell = ($cellValue -isnot [String]) -and ($cellValue -is [System.Collections.IEnumerable])
            if ($isMultiValueCell) {
                $cellItems = @($cellValue)
            }

            if ($isMultiValueCell -and $cellItems.Count -gt 1) {
                $listHtml = [System.Text.StringBuilder]::new()
                $null = $listHtml.Append('<ul class="cell-list">')
                foreach ($item in $cellItems) {
                    $itemText = ConvertTo-VcfCheckNormalizedExpiryDateText -ColumnName $column -Value ([String]$item)
                    $null = $listHtml.Append('<li>').Append((ConvertTo-VcfCheckHtmlEncoded -Value $itemText)).Append('</li>')
                }
                $null = $listHtml.Append('</ul>')
                $null = $sb.Append('<td>').Append($listHtml.ToString()).Append('</td>')
            } else {
                $cellText = if ($isMultiValueCell) { [String]$cellItems[0] } else { [String]$cellValue }
                $cellText = ConvertTo-VcfCheckNormalizedExpiryDateText -ColumnName $column -Value $cellText
                if ([String]::IsNullOrWhiteSpace($cellText)) { $cellText = 'N/A' }
                $cellClass = $statusClasses[$cellText.Trim().ToUpperInvariant()]
                $classAttribute = ''
                if ($cellClass) { $classAttribute = " class=`"cell-$cellClass`"" }
                $null = $sb.Append('<td').Append($classAttribute).Append('>').Append((ConvertTo-VcfCheckHtmlEncoded -Value $cellText)).Append('</td>')
            }
        }
        $null = $sb.Append('</tr>')
    }

    $null = $sb.Append('</table>')
    return $sb.ToString()
}
function Format-VcfCheckHtmlHostDetailFieldValue {

    <#
        .SYNOPSIS
        Returns the display value for a host detail summary field, matching
        Tools/ui/common.js's hostDetailFieldValue().

        .DESCRIPTION
        CpuCompatibility's and CpuDeprecationStatus' raw enum values, and CpuCompatibilityMatchedSeries'/
        CpuDeprecationMatchedSeries' "no match" case, all need friendlier display text than the
        raw HostDetails value.

        .PARAMETER FieldName
        The PSCustomObject property name (e.g. 'CpuCompatibility').

        .PARAMETER Value
        The raw property value.

        .OUTPUTS
        [String] the display value.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [String]$FieldName,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object]$Value
    )

    if ($null -eq $Value -or ($Value -is [String] -and [string]::IsNullOrEmpty($Value))) {
        if ($FieldName -in @('CpuCompatibilityMatchedSeries', 'CpuDeprecationMatchedSeries')) {
            return 'N/A'
        }
        return ''
    }

    if ($FieldName -eq 'CpuCompatibility' -and $Value -eq 'NotListed') {
        return 'Not Supported'
    }

    if ($FieldName -eq 'CpuDeprecationStatus' -and $Value -eq 'None') {
        return 'Not Deprecated'
    }

    return $Value
}
function Format-VcfCheckHtmlHostSummaryBar {

    <#
        .SYNOPSIS
        Renders the "Hosts" summary bar shown above a check result's per-host detail cards,
        matching Tools/ui/common.js's VcfCheckUI.renderHostSummaryBar() markup exactly.

        .DESCRIPTION
        Tallies each host's CPU status via Get-VcfCheckHtmlHostCpuStatus and renders a total
        host-count pill alongside a compatible/deprecated/unsupported pill for each non-zero
        count, so an operator can see the overall CPU compatibility mix without expanding any
        cluster or host card.

        .PARAMETER HostDetails
        Array of per-host PSCustomObjects.

        .OUTPUTS
        [String] the "host-summary-bar" markup.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [Object[]]$HostDetails
    )

    $counts = [Ordered]@{ Compatible = 0; Deprecated = 0; Unsupported = 0 }
    foreach ($hostDetail in $HostDetails) {
        $cpuStatus = Get-VcfCheckHtmlHostCpuStatus -HostDetail $hostDetail
        if ($cpuStatus) {
            $counts[$cpuStatus]++
        }
    }
    $hasCpuCounts = ($counts.Compatible + $counts.Deprecated + $counts.Unsupported) -gt 0

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append('<div class="host-summary-bar"><span class="host-summary-label">Hosts</span>')
    $totalBadgeClass = if ($hasCpuCounts) { 'cluster-badge neutral' } else { 'cluster-badge' }
    $totalLabel = "$($HostDetails.Count) host$(if ($HostDetails.Count -eq 1) { '' } else { 's' })"
    $null = $sb.Append('<span class="').Append($totalBadgeClass).Append('">').Append($totalLabel).Append('</span>')
    foreach ($status in @('Compatible', 'Deprecated', 'Unsupported')) {
        if ($counts[$status] -eq 0) { continue }
        $statusClass = $status.ToLowerInvariant()
        $null = $sb.Append('<span class="cluster-badge ').Append($statusClass).Append('">').Append($counts[$status]).Append(' ').Append($statusClass).Append('</span>')
    }
    $null = $sb.Append('</div>')

    return $sb.ToString()
}
function Format-VcfCheckHtmlHostDetailCard {

    <#
        .SYNOPSIS
        Renders a check result's per-host structured data as one collapsible <details> section
        per host, matching Tools/vcf-check-ui.html's hostDetailsToHtml() markup exactly.

        .DESCRIPTION
        Unlike Format-VcfCheckHtmlRowsTable (one flat table for the whole result), each host
        gets its own native HTML <details class="host-details"> block - collapsed by default, no
        JavaScript required - so a report with many hosts stays scannable. A host's own hardware
        summary fields (any property whose value is not itself an array) render as a plain
        key/value table; array-valued properties (NetworkAdapters, StorageAdapters, StorageDevices,
        etc.) each render as their own "rows-table" sub-table via Format-VcfCheckHtmlRowsTable,
        using the property name (space-separated from PascalCase) as its heading.

        .PARAMETER HostDetails
        Array of per-host PSCustomObjects. $null or empty returns an empty string (no markup
        emitted at all). Must include a HostName property, used as the <summary> label.

        .OUTPUTS
        [String] the concatenated <details>...</details> markup, or an empty string when
        HostDetails is empty/absent.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$HostDetails = @()
    )

    if (-not $HostDetails -or $HostDetails.Count -eq 0) {
        return ''
    }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append((Format-VcfCheckHtmlHostSummaryBar -HostDetails $HostDetails))

    foreach ($hostDetail in $HostDetails) {
        $summaryFields = [Ordered]@{}
        $arrayFields = [Ordered]@{}
        $clusterName = $null

        foreach ($property in $hostDetail.PSObject.Properties) {
            $propName = $property.Name
            $propValue = $property.Value

            if ($propName -eq 'HostName') {
                continue
            }

            if ($propName -eq 'ClusterName') {
                $clusterName = if ($propValue) { $propValue } else { $null }
                continue
            }

            if ($propValue -is [Array]) {
                $arrayFields[$propName] = @($propValue)
            } else {
                $summaryFields[$propName] = $propValue
            }
        }

        $summaryLabel = (ConvertTo-VcfCheckHtmlEncoded -Value $hostDetail.HostName)
        if ($clusterName -and -not [string]::IsNullOrWhiteSpace($clusterName)) {
            $summaryLabel += ' <span class="cluster-badge">' + (ConvertTo-VcfCheckHtmlEncoded -Value $clusterName) + '</span>'
        }

        $cpuStatus = Get-VcfCheckHtmlHostCpuStatus -HostDetail $hostDetail
        if ($cpuStatus) {
            $cpuStatusLabel = @{ Compatible = 'Compatible CPU'; Deprecated = 'Deprecated CPU'; Unsupported = 'Unsupported CPU' }[$cpuStatus]
            $summaryLabel += ' <span class="cpu-status-badge ' + $cpuStatus.ToLowerInvariant() + '">' + $cpuStatusLabel + '</span>'
        }

        $null = $sb.Append('<details class="host-details"><summary>').Append($summaryLabel).Append('</summary><div class="host-details-body">')

        $null = $sb.Append('<table class="host-detail-summary">')
        foreach ($fieldName in $summaryFields.Keys) {
            $label = if ($fieldName -eq 'CpuCompatibility') {
                'VCF 9.1 CPU Compatibility'
            } else {
                ($fieldName -creplace '([a-z])([A-Z])', '$1 $2') -creplace '\bCpu\b', 'CPU'
            }
            $value = Format-VcfCheckHtmlHostDetailFieldValue -FieldName $fieldName -Value $summaryFields[$fieldName]
            $null = $sb.Append('<tr><th>').Append((ConvertTo-VcfCheckHtmlEncoded -Value $label)).Append('</th><td>')
            $null = $sb.Append((ConvertTo-VcfCheckHtmlEncoded -Value $value)).Append('</td></tr>')
        }
        $null = $sb.Append('</table>')

        foreach ($fieldName in $arrayFields.Keys) {
            $subTable = Format-VcfCheckHtmlRowsTable -Rows $arrayFields[$fieldName]
            if ($subTable) {
                $label = ($fieldName -creplace '([a-z])([A-Z])', '$1 $2') -creplace '\bCpu\b', 'CPU'
                $null = $sb.Append('<h4>').Append((ConvertTo-VcfCheckHtmlEncoded -Value $label)).Append('</h4>').Append($subTable)
            }
        }

        $null = $sb.Append('</div></details>')
    }

    return $sb.ToString()
}
function Get-VcfCheckHtmlHostCpuStatus {

    <#
        .SYNOPSIS
        Classifies a host's CPU as Compatible/Deprecated/Unsupported for the "Compatible/Deprecated/
        Unsupported CPU" badge, matching Tools/ui/common.js's hostCpuStatus() exactly.

        .PARAMETER HostDetail
        A single per-host PSCustomObject, as passed to Format-VcfCheckHtmlHostDetailCard.

        .OUTPUTS
        [String] 'Compatible', 'Deprecated', or 'Unsupported'; $null if the host has neither a
        CpuCompatibility nor a CpuDeprecationStatus property (i.e. this is not the CPU check).
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [Object]$HostDetail
    )

    if ($HostDetail.CpuCompatibility -eq 'NotListed' -or $HostDetail.CpuDeprecationStatus -eq 'Discontinued') {
        return 'Unsupported'
    }
    if ($HostDetail.CpuDeprecationStatus -eq 'Deprecated') {
        return 'Deprecated'
    }
    if ($HostDetail.CpuCompatibility -eq 'Compatible') {
        return 'Compatible'
    }
    return $null
}
function Format-VcfCheckHtmlResultCardDetail {

    <#
        .SYNOPSIS
        Builds the dt/dd field pairs inside one result row's <dl class="result-detail">, matching
        Tools/vcf-check-ui.html's resultToHtml() field list and order exactly.

        .DESCRIPTION
        Order is Target, Destination, Detail, Validation Criteria, Remediation, Exception, then a
        Results entry for any structured Rows table and a Hosts (or HostDetailsLabel) entry for
        any HostDetails - the same list resultToHtml() builds and filters. A field whose value is
        null/empty/whitespace is omitted entirely. Remediation is only shown for Fail/Warning/
        Error statuses, and Validation Criteria is omitted for Skipped results, mirroring
        resultToHtml()'s showRemediation/isSkipped checks.

        .PARAMETER Result
        The VcfCheck.Result object.

        .OUTPUTS
        [String] the concatenated <dt>/<dd> pairs.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Result
    )

    # ESX/vSAN/Tanzu-area checks run per-vCenter and their TargetComponent is always a vCenter
    # FQDN, not an ESX host or vSAN cluster - see New-VcfCheckPerDomainResults in
    # Connections.ps1.
    $targetTypeLabels = @{
        'ESX' = 'vCenter'; 'vSAN' = 'vCenter'; 'vCenter' = 'vCenter'; 'Tanzu' = 'vCenter'
        'NSX' = 'NSX Manager'; 'SDDC Manager' = 'SDDC Manager'; 'Aria Suite' = 'Aria Suite Lifecycle Manager'
    }
    # A couple of SDDC-Manager-area checks route through the same per-vCenter merge helpers as
    # the ESX/vSAN checks above, so their TargetComponent is a vCenter FQDN too, despite the
    # "SDDC Manager" area - the Area-based table alone would mislabel these as targeting SDDC
    # Manager itself.
    $targetTypeOverridesByCheckId = @{
        'sddc_check_vlcm_vum'               = 'vCenter'
        'sddc_cluster_resource_utilization' = 'vCenter'
        'sddc_check_cores_and_vsan_tib'     = 'vCenter'
        'aria_ops_adapter_collection_status' = 'Aria Operations'
        'aria_ops_collector_status'         = 'Aria Operations'
        'aria_ops_critical_alerts'          = 'Aria Operations'
        'aria_ops_certificate_expiration'   = 'Aria Operations'
        'aria_ops_collector_type'           = 'Aria Operations'
        'aria_ops_lifecycle_status'         = 'Aria Operations'
        'aria_ops_license'                  = 'Aria Operations'
        'aria_ops_sizing_overview'          = 'Aria Operations'
    }
    $targetComponentText = $Result.TargetComponent
    if (-not [String]::IsNullOrWhiteSpace($targetComponentText)) {
        $targetTypeLabel = $targetTypeOverridesByCheckId[$Result.CheckId]
        if (-not $targetTypeLabel -and $targetTypeLabels.ContainsKey($Result.Area)) { $targetTypeLabel = $targetTypeLabels[$Result.Area] }
        if ($targetTypeLabel) { $targetComponentText = "${targetTypeLabel}: $targetComponentText" }
    }

    $isSkipped = $Result.Status -eq 'Skipped'
    $showRemediation = $Result.Status -in @('Fail', 'Warning', 'Error')

    $fields = [Ordered]@{
        'Target'      = $targetComponentText
        'Destination' = $Result.Destination
        'Detail'      = $Result.Detail
    }
    if (-not $isSkipped) { $fields['Validation Criteria'] = $Result.ValidationCriteria }
    if ($showRemediation) { $fields['Remediation'] = $Result.Remediation }
    $fields['Exception'] = $Result.Exception

    $sb = [System.Text.StringBuilder]::new()
    foreach ($fieldName in $fields.Keys) {
        $fieldValue = $fields[$fieldName]
        if ([String]::IsNullOrWhiteSpace([String]$fieldValue)) { continue }
        $encodedFieldValue = if ($fieldName -eq 'Remediation') { ConvertTo-VcfCheckHtmlRemediationEncoded -Value $fieldValue } else { ConvertTo-VcfCheckHtmlEncoded -Value $fieldValue }
        $null = $sb.Append('<dt>').Append((ConvertTo-VcfCheckHtmlEncoded -Value $fieldName)).Append('</dt><dd>').Append($encodedFieldValue).Append('</dd>')
    }

    $rowsTable = Format-VcfCheckHtmlRowsTable -Rows $Result.Rows
    if ($rowsTable) {
        $null = $sb.Append('<dt>Results</dt><dd>').Append($rowsTable).Append('</dd>')
    }

    $hostDetailCards = Format-VcfCheckHtmlHostDetailCard -HostDetails $Result.HostDetails
    if ($hostDetailCards) {
        $hostDetailsLabel = if ($Result.HostDetailsLabel) { $Result.HostDetailsLabel } else { 'Hosts' }
        $null = $sb.Append('<dt>').Append((ConvertTo-VcfCheckHtmlEncoded -Value $hostDetailsLabel)).Append('</dt><dd>').Append($hostDetailCards).Append('</dd>')
    }

    return $sb.ToString()
}
function Format-VcfCheckHtmlResultCard {

    <#
        .SYNOPSIS
        Builds one result's row: badge/name/area header plus its Detail/Exception/Rows/host
        fields, matching Tools/vcf-check-ui.html's exported resultToHtml() markup and classes
        exactly (.result-row/.result-summary/.badge/.result-name/.result-area/.result-detail).

        .DESCRIPTION
        Wrapped in a native <details>/<summary> pair (in place of resultToHtml()'s always-open
        <dl class="result-detail open">) so the row still collapses/expands with no JavaScript -
        per the HTML living-standard "revealing algorithm" a browser auto-expands it when the nav
        (Format-VcfCheckHtmlNav) or summary table (Format-VcfCheckHtmlSummaryTable) links to its
        #check-<Index> anchor.

        .PARAMETER Result
        The VcfCheck.Result object.

        .PARAMETER Index
        The result's position in the report's results array - used as the row's anchor id
        (#check-<Index>), since a per-domain split can repeat the same CheckId across several
        results, so CheckId alone cannot serve as a unique anchor.

        .OUTPUTS
        [String] the <details>...</details> markup for this one result.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Result,
        [Parameter(Mandatory = $true)] [Int]$Index
    )

    $baseLabel = if ($Result.DisplayName) { $Result.DisplayName } else { $Result.CheckId }
    $duration = ''
    if ($null -ne $Result.DurationMs) { $duration = Format-VcfCheckDuration -Milliseconds $Result.DurationMs }

    $domainHtml = ''
    if ($Result.Component) {
        $domainHtml = " <span class=`"result-domain result-domain-component`">Component: $(ConvertTo-VcfCheckHtmlEncoded -Value $Result.Component)</span>"
    } elseif ($Result.Domain) {
        $domainModifier = ''
        if ($Result.DomainType -eq 'MANAGEMENT') { $domainModifier = ' result-domain-management' } elseif ($Result.DomainType) { $domainModifier = ' result-domain-workload' }
        $domainHtml = " <span class=`"result-domain$domainModifier`">Domain: $(ConvertTo-VcfCheckHtmlEncoded -Value $Result.Domain)</span>"
    }
    $infoOnlyHtml = ''
    if ($Result.Informational) { $infoOnlyHtml = ' <span class="result-info-only">Info-only</span>' }
    $skipReasonHtml = ''
    if ($Result.Status -eq 'Skipped' -and $Result.Detail) {
        $skipReasonHtml = " <span class=`"result-skip-reason`">Skipped Reason: $(ConvertTo-VcfCheckHtmlEncoded -Value $Result.Detail)</span>"
    }

    $detailsHtml = Format-VcfCheckHtmlResultCardDetail -Result $Result

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append('<details class="result-row" id="check-').Append($Index).Append('"><summary class="result-summary">')
    $null = $sb.Append('<span class="badge ').Append((ConvertTo-VcfCheckHtmlEncoded -Value $Result.Status)).Append('">').Append((ConvertTo-VcfCheckHtmlEncoded -Value $Result.Status)).Append('</span>')
    $null = $sb.Append('<span class="result-name"><span class="result-name-text">').Append((ConvertTo-VcfCheckHtmlEncoded -Value $baseLabel)).Append('</span>')
    $null = $sb.Append(' <span class="result-area">(').Append((ConvertTo-VcfCheckHtmlEncoded -Value $Result.Area)).Append(')</span>').Append($domainHtml).Append($infoOnlyHtml).Append($skipReasonHtml).Append('</span>')
    $null = $sb.Append('</summary><dl class="result-detail open">').Append($detailsHtml).Append('</dl>')
    if ($duration) {
        $null = $sb.Append('<div class="check-duration-badge">').Append((ConvertTo-VcfCheckHtmlEncoded -Value "$duration to execute")).Append('</div>')
    }
    $null = $sb.Append('</details>')
    return $sb.ToString()
}
function Format-VcfCheckHtmlSkipGroup {

    <#
        .SYNOPSIS
        Wraps every Skipped result's row inside one collapsed-by-default group, so a run with
        many skipped checks (e.g. optional components not deployed) doesn't push the checks a
        reader actually cares about further down the page.

        .DESCRIPTION
        Uses the same .skip-group/.skip-group-count/.skip-group-body classes Tools/vcf-check-ui.html
        defines for its live-view renderSkipGroupRow (the exported HTML file has no skip grouping
        at all - it lists every result inline), wrapped in a native <details>/<summary> pair for a
        script-free collapse/expand, same pattern as Format-VcfCheckHtmlResultCard. Each skipped
        result keeps its own #check-<Index> anchor and remains its own nested
        Format-VcfCheckHtmlResultCard row - the nav and summary table links still work, since a
        browser auto-expands every ancestor <details> up to a same-page anchor target.

        .PARAMETER SkippedResults
        Array of (Result, Index) pairs, each a Hashtable with keys Result and Index, for every
        result whose Status is Skipped, in report order.

        .OUTPUTS
        [String] the <details class="skip-group">...</details> markup, or an empty string when
        SkippedResults is empty.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$SkippedResults
    )

    if ($SkippedResults.Count -eq 0) {
        return ''
    }

    $countLabel = "$($SkippedResults.Count) check$(if ($SkippedResults.Count -ne 1) { 's' }) skipped"
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append('<details class="result-row skip-group"><summary class="result-summary">')
    $null = $sb.Append('<span class="result-name"><span class="result-name-text">Skipped Checks</span></span>')
    $null = $sb.Append('<span class="skip-group-count">').Append((ConvertTo-VcfCheckHtmlEncoded -Value $countLabel)).Append('</span></summary>')
    $null = $sb.Append('<div class="skip-group-body open">')
    foreach ($entry in $SkippedResults) {
        $null = $sb.Append((Format-VcfCheckHtmlResultCard -Result $entry.Result -Index $entry.Index))
    }
    $null = $sb.Append('</div></details>')
    return $sb.ToString()
}
function Format-VcfCheckHtmlDocument {

    <#
        .SYNOPSIS
        Assembles the full static HTML document for a precheck run report.

        .DESCRIPTION
        Wraps <main> (run summary/tiles/results) and Format-VcfCheckHtmlNav's <nav> in a
        div#top.export-layout, matching Tools/vcf-check-ui.html's buildHtmlExportContent() body
        structure and CSS ordering exactly, so the two reports lay out identically.

        .PARAMETER Report
        The report object from ConvertTo-VcfCheckReportJson.

        .PARAMETER Title
        Document title, not yet HTML-encoded - this function encodes it once for the <title>.

        .PARAMETER Theme
        Either 'light' or 'dark'. Matches Tools/vcf-check-ui.html's own body.light CSS toggle so
        the static report opens in the same theme the user last chose there. Defaults to 'dark',
        the CSS default when no body class is present.

        .OUTPUTS
        [String] the complete HTML document.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Report,
        [Parameter(Mandatory = $true)] [String]$Title,
        [Parameter(Mandatory = $false)] [ValidateSet('light', 'dark')] [String]$Theme = 'dark'
    )

    $results = @($Report.results)
    $encodedTitle = ConvertTo-VcfCheckHtmlEncoded -Value $Title
    $bodyClass = if ($Theme -eq 'light') { ' class="light"' } else { '' }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append('<!DOCTYPE html><html lang="en">')
    $null = $sb.Append((Format-VcfCheckHtmlDocumentHead -Title $encodedTitle))
    $null = $sb.Append('<body').Append($bodyClass).Append('><div id="top" class="export-layout"><main>')
    $null = $sb.Append((Format-VcfCheckHtmlRunSummary -Report $Report))
    $null = $sb.Append((Format-VcfCheckHtmlSummaryTable -Results $results))
    $null = $sb.Append('<h2>Check Details</h2><div id="results">')

    # Skipped results are pulled out of the main flow and rendered once, together, inside a
    # single collapsed group at the end - see Format-VcfCheckHtmlSkipGroup. Original array
    # index is preserved per result (not renumbered) so #check-<Index> anchors from the nav and
    # summary table still resolve to the right row regardless of where it landed in the DOM.
    $skippedEntries = [System.Collections.Generic.List[Object]]::new()
    for ($index = 0; $index -lt $results.Count; $index++) {
        $result = $results[$index]
        if ($result.Status -eq 'Skipped') {
            $skippedEntries.Add(@{ Result = $result; Index = $index })
        } else {
            $null = $sb.Append((Format-VcfCheckHtmlResultCard -Result $result -Index $index))
        }
    }
    $null = $sb.Append((Format-VcfCheckHtmlSkipGroup -SkippedResults $skippedEntries))
    $null = $sb.Append('</div></main>')
    $null = $sb.Append((Format-VcfCheckHtmlNav -Results $results))
    $null = $sb.Append('</div></body></html>')
    return $sb.ToString()
}
function Export-VcfCheckReportHtml {

    <#
        .SYNOPSIS
        Writes a self-contained, static HTML report for a precheck run - no server required.

        .DESCRIPTION
        Consumes the same $Report object ConvertTo-VcfCheckReportJson already produces (run
        id, SDDC Manager FQDN, vcfVersion, summary, results[]), so there is exactly one source of
        truth for report data rather than a second parallel data-shaping path. Composed from small
        Format-VcfCheckHtml* helpers (nav/summary/rows/cards), each independently testable, whose
        markup and CSS classes mirror Tools/vcf-check-ui.html's own exported HTML report exactly.
        Every dynamic value is routed through ConvertTo-VcfCheckHtmlEncoded before being
        interpolated. Deliberately has no <script> element at all (pure CSS plus native
        <details>/<summary> disclosure and anchor-link navigation) - a static, open-once artifact
        has no need for it, and omitting it removes an entire class of DOM-injection risk outright
        rather than mitigating it.

        .PARAMETER Report
        The report object from ConvertTo-VcfCheckReportJson.

        .PARAMETER Path
        Destination .html file path. Parent directory is created if missing.

        .PARAMETER Title
        Optional document title override. Defaults to "VCF Check Report - <SddcManagerFqdn> -
        <RunId>".

        .PARAMETER Theme
        Either 'light' or 'dark'. When omitted, resolved from the browser's saved preference via
        Get-VcfCheckThemePreference so this static report opens in the same theme as the browser
        report, rather than always falling back to the CSS default (dark).

        .OUTPUTS
        [String] the path written.

        .EXAMPLE
        Export-VcfCheckReportHtml -Report $report -Path "$env:VcfCheckBaseDirectory\Findings\report.html"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Report,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Title = '',
        [Parameter(Mandatory = $false)] [ValidateSet('', 'light', 'dark')] [String]$Theme = ''
    )

    $parentDirectory = Split-Path -Parent $Path
    if ($parentDirectory -and -not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parentDirectory -Force
    }

    $resolvedTitle = $Title
    if ([String]::IsNullOrWhiteSpace($resolvedTitle)) {
        $resolvedTitle = "VCF Check Report - $($Report.sddcManagerFqdn) - $($Report.runId)"
    }

    $resolvedTheme = $Theme
    if ([String]::IsNullOrWhiteSpace($resolvedTheme)) {
        $resolvedTheme = Get-VcfCheckThemePreference
    }

    $html = Format-VcfCheckHtmlDocument -Report $Report -Title $resolvedTitle -Theme $resolvedTheme
    Set-Content -LiteralPath $Path -Value $html -ErrorAction Stop -Encoding utf8

    return $Path
}

#endregion Reporting
