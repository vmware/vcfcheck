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
#region Orchestrator

function Sort-VcfCheckChecksByArea {

    <#
        .SYNOPSIS
        Sorts checks by area in a defined order (Aria Suite, ESX, NSX, SDDC Manager, vCenter, vSAN, then others).

        .DESCRIPTION
        Takes an array of check objects and returns them sorted by area, with a predefined
        area order. Checks are grouped by component area and run sequentially, improving
        readability and making it easier to identify which component is having issues.

        .PARAMETER Checks
        Array of check objects (from Resolve-VcfCheckCheckList).

        .OUTPUTS
        [Object[]] sorted checks.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [Object[]]$Checks
    )

    $areaOrder = @('Aria Suite', 'ESX', 'NSX', 'SDDC Manager', 'vCenter', 'vSAN')
    $areaIndex = @{}
    for ($i = 0; $i -lt $areaOrder.Count; $i++) {
        $areaIndex[$areaOrder[$i]] = $i
    }

    return $Checks | Sort-Object {
        $index = $areaIndex[$_.Area]
        if ($null -eq $index) { [int]::MaxValue } else { $index }
    }
}
function Get-VcfCheckAreaDisplayName {

    <#
        .SYNOPSIS
        Returns the display name for a check area.

        .PARAMETER Area
        The technical area name from a check object.

        .OUTPUTS
        [String] the friendly display name for the area.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [String]$Area
    )

    $displayNames = @{
        'Aria Suite'      = 'Aria Suite'
        'ESX'             = 'ESX'
        'NSX'             = 'NSX'
        'SDDC Manager'    = 'SDDC Manager'
        'vCenter'         = 'vCenter'
        'vSAN'            = 'vSAN'
        'Sample'          = 'Sample'
    }

    return $displayNames[$Area] ?? $Area
}
function Invoke-VcfCheck {

    <#
        .SYNOPSIS
        Runs a set of VCF upgrade-readiness prechecks and writes a JSON report.

        .DESCRIPTION
        Resolves credentials (settings.json > explicit params > interactive prompt), connects
        to SDDC Manager, resolves the ordered check list from the catalog (Data/CheckCatalog.json)
        and/or explicit check IDs, then runs each check sequentially. Each check is invoked inside
        its own try/catch so one check's exception becomes an Error-status result row rather than
        aborting the whole run. The report is flushed to disk after every check (partial) and
        once more at the end (final), so an interrupted run still yields a usable report. All
        connections and cached credentials are torn down from a top-level finally block
        regardless of how the run ends.

        .PARAMETER CheckId
        One or more explicit check IDs to run. Empty (default) runs every check in the catalog.

        .PARAMETER Domain
        One or more VCF domain names to scope this run to (e.g. 'm01', 'w01'). When
        non-empty: Get-VcfCheckAllVCenterFqdns excludes every other domain's vCenters before
        any check connects to them, so per-domain checks (ESX/vSAN/NSX/vCenter) never touch an
        out-of-scope domain; and single-target checks (SDDC Manager, Aria Suite), which are always
        backfilled to the Management domain, are dropped from the run's results unless the
        Management domain is included. Empty (default) runs every domain, matching -CheckId's
        existing "empty means all" convention - no upfront validation against real domain names
        is performed.

        .PARAMETER SettingsPath
        Explicit path to settings.json. When omitted, resolved from $env:VcfCheckBaseDirectory.

        .PARAMETER SddcManagerFqdn
        Explicit SDDC Manager FQDN, overriding settings.json/interactive prompt.

        .PARAMETER SddcManagerUser
        Explicit SDDC Manager username, overriding settings.json/interactive prompt.

        .PARAMETER SddcManagerPassword
        Explicit SDDC Manager password as a SecureString. When omitted, the operator is prompted.

        .PARAMETER SddcManagerRootPassword
        Explicit SDDC Manager appliance root/OS password as a SecureString, for the checks that use
        Get-VcfCheckSddcManagerRootCredential (a credential not retrievable via the VCF
        credentials API, so normally resolved via an interactive Read-Host prompt). When supplied,
        it is cached on the run context up front so those checks run non-interactively instead of
        prompting. When omitted, those checks fall back to their normal interactive prompt - callers
        that cannot prompt (e.g. a non-interactive launcher) should instead exclude those check IDs
        from -CheckId rather than let them block on Read-Host.

        .PARAMETER OutputPath
        Directory to write run-<id>.json / latest.json into. Defaults to
        $env:VcfCheckBaseDirectory\Findings.

        .PARAMETER RunId
        Explicit run ID to use in the report output. When omitted, a timestamp-based ID is
        generated (yyyyMMdd-HHmmss format). Intended for use by the launcher or caller to ensure
        the report ID matches the managed run state.

        .PARAMETER NoSummary
        Skip the human-readable pass/fail console summary printed after the run completes
        (Write-VcfCheckConsoleSummary). The JSON report is always written regardless.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for the TCP reachability pre-flight check against SDDC Manager
        before failing fast with an actionable message, instead of waiting out whatever long
        default timeout the underlying PowerCLI connect cmdlet uses. Defaults to 30 seconds;
        raise it for a known-slow VPN/network path.

        .PARAMETER VcfDestinationRelease
        The VCF release to validate against - a full concrete release, a release family
        (major.minor.patch, e.g. '9.1.0'), or 'latest' - forwarded to Test-VcfSddcBomCheck's and
        Test-VcfVrslcmFetchProducts's own -VcfDestinationRelease when either check runs as part
        of this invocation. Omitted (default) leaves each check on its own built-in default.

        .PARAMETER HealthSummaryMaxPollAttempts
        Forwarded to Test-VcfSddcCheckHealthSummary's own -MaxPollAttempts when
        'sddc_check_health_summary' runs as part of this invocation. 0 (default) leaves the
        check on its own built-in default.

        .PARAMETER PreUpgradeCheckSetMaxPollAttempts
        Forwarded to Test-VcfSddcCheckUi's own -MaxPollAttempts when 'sddc_pre_check_ui' runs as
        part of this invocation. 0 (default) leaves the check on its own built-in default.

        .OUTPUTS
        [Object[]] the VcfCheck.Result objects produced by this run, or $null if -OutputPath
        was omitted and no base directory could be resolved (already logged, or the operator
        declined the offered setup - see Resolve-VcfCheckActiveBaseDirectory). A connection
        failure (network-unreachable, bad credentials, etc.) produces a single Blocking Error
        result (CheckId 'sddc_manager_connection') rather than a thrown exception - a failed run
        still yields a usable report and console summary, consistent with how a single check's
        exception is handled.

        .EXAMPLE
        Invoke-VcfCheck -CheckId sample -SddcManagerFqdn vcf01-sddcmgr01.example.com -SddcManagerUser administrator@vsphere.local
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'AriaOpsEndpointCredentials', Justification = 'Object[] of Fqdn/Username/Password triplets, not a password itself - each element''s Password field is already a SecureString.')]
    Param (
        [Parameter(Mandatory = $false)] [String[]]$CheckId = @(),
        [Parameter(Mandatory = $false)] [String[]]$Domain = @(),
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$SettingsPath = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$SddcManagerFqdn = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$SddcManagerUser = '',
        [Parameter(Mandatory = $false)] [AllowNull()] [SecureString]$SddcManagerPassword = $null,
        [Parameter(Mandatory = $false)] [AllowNull()] [SecureString]$SddcManagerRootPassword = $null,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$OutputPath = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$RunId = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$EnvironmentName = '',
        [Parameter(Mandatory = $false)] [Switch]$NoSummary,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 30,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$VcfDestinationRelease = '',
        [Parameter(Mandatory = $false)] [Int]$HealthSummaryMaxPollAttempts = 0,
        [Parameter(Mandatory = $false)] [Int]$PreUpgradeCheckSetMaxPollAttempts = 0,
        [Parameter(Mandatory = $false)] [Object[]]$AriaOpsEndpointCredentials = @()
    )

    # PowerCLI cmdlets (Invoke-VMScript in particular) render their own Write-Progress records as
    # raw "[percent complete: N]" console noise - confirmed live. Suppressed for the whole run;
    # Write-VcfCheckCheckProgress/Write-VcfCheckCheckOutcome are this module's own
    # intentional replacement, so a run is never silent between checks despite this.
    $ProgressPreference = 'SilentlyContinue'

    # PowerCLI 9 emits deprecation warnings when accessing properties on VMHost, Cluster, and
    # related SDK objects (State → ConnectionState, DrsMode → DrsAutomationLevel, etc.). These
    # are unavoidable when working with PowerCLI objects and not actionable in our code, so
    # suppress them to keep logs clean. Structured errors (from checks) still surface normally.
    $WarningPreference = 'SilentlyContinue'

    # Best-effort file logging (VcfCheckEngine-<date>.log under $env:VcfCheckBaseDirectory\Logs)
    # - never fatal, since a run with -OutputPath pointed elsewhere and no base directory set should
    # still work console-only. Initialize-VcfCheckLogging initializes logging for the run.
    if (-not [String]::IsNullOrWhiteSpace($env:VcfCheckBaseDirectory)) {
        try {
            Initialize-VcfCheckLogging | Out-Null
            Write-VcfCheckRuntimeInfo
        } catch {
            Write-Host "[WARNING] Could not initialize file logging: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "[DEBUG] VcfCheckBaseDirectory = '$env:VcfCheckBaseDirectory'" -ForegroundColor Gray
            Write-Host "[DEBUG] Exception: $($_ | Out-String)" -ForegroundColor Gray
        }
    }

    $allowInsecureTls = Resolve-VcfCheckAllowInsecureTls

    $resolvedOutputPath = $OutputPath
    if ([String]::IsNullOrWhiteSpace($resolvedOutputPath)) {
        $baseDirectory = Resolve-VcfCheckActiveBaseDirectory
        if ([String]::IsNullOrWhiteSpace($baseDirectory)) {
            return $null
        }
        $resolvedOutputPath = Join-Path -Path $baseDirectory -ChildPath $Script:CHECK_FINDINGS_DIR_NAME
    }

    # Get-VcfCheckSettings throws if settings.json exists but is missing SddcManagerFqdn/
    # SddcManagerUser - a real state for multi-environment configurations (settings.json there
    # only ever carries browser preferences like Theme/LogViewLevel, never those two keys) once
    # -SddcManagerFqdn/-SddcManagerUser are supplied explicitly, as every launcher-invoked run
    # does. $settings is only a fallback for either value below.
    $settings = $null
    try {
        $settings = Get-VcfCheckSettings -Path $SettingsPath
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not read settings.json (falling back to explicit parameters/interactive prompts): $($_.Exception.Message)"
    }
    $credential = Get-VcfCheckCredential -Settings $settings -SddcManagerFqdn $SddcManagerFqdn -SddcManagerUser $SddcManagerUser -SddcManagerPassword $SddcManagerPassword
    $Context = New-VcfCheckContext -Settings $settings
    $Context.AllowInsecureTls = $allowInsecureTls
    $Context.SelectedDomains = $Domain
    $Context.OutputPath = $resolvedOutputPath
    if ($SddcManagerRootPassword) {
        $Context.SddcManagerRootCredential = [PSCredential]::new('root', $SddcManagerRootPassword)
    }

    # Standalone Aria Operations endpoints (Private/Environments.ps1's Integrations field) are
    # attached to a saved environment, not SDDC Manager - resolve them here by EnvironmentName so
    # every Test-VcfAriaOps* check can fan out across them via Get-VcfCheckAriaOpsTargets.
    if (-not [String]::IsNullOrWhiteSpace($EnvironmentName)) {
        $matchedEnvironment = @(Get-VcfCheckEnvironments) | Where-Object { $_.Name -eq $EnvironmentName } | Select-Object -First 1
        if ($matchedEnvironment) {
            $Context.AriaOpsEndpoints = @(Get-VcfCheckEnvironmentAriaOpsEndpoints -Environment $matchedEnvironment)
        }
    }
    if ($Context.AriaOpsEndpoints -and @($Context.AriaOpsEndpoints).Count -gt 0) {
        # Never let an unresolvable Aria Operations endpoint credential (e.g. a headless,
        # -NonInteractive launcher run with no browser-supplied password for that endpoint) abort
        # the whole run - Get-VcfCheckAriaOpsTargets already reports an unresolved endpoint as a
        # per-target ConnectError, so every other check still runs normally.
        try {
            Resolve-VcfCheckAriaOpsEndpointCredentials -Context $Context -Endpoints $Context.AriaOpsEndpoints -PreSuppliedCredentials $AriaOpsEndpointCredentials
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not resolve credentials for one or more standalone Aria Operations endpoints: $($_.Exception.Message)"
        }
    }

    $runId = if ([String]::IsNullOrWhiteSpace($RunId)) { (Get-Date).ToString('yyyyMMdd-HHmmss') } else { $RunId }
    $startedAt = Get-Date
    $results = [System.Collections.Generic.List[Object]]::new()

    try {
        $connectionFailed = $false
        try {
            Connect-VcfCheckSddcManager -Context $Context -Fqdn $credential.Fqdn -User $credential.User -Password $credential.Password `
                -IgnoreInvalidCertificate:$allowInsecureTls -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
        } catch {
            Write-LogMessage -Type ERROR -Message "Could not connect to SDDC Manager `"$($credential.Fqdn)`": $($_.Exception.Message)"
            $results.Add((New-VcfCheckResult -CheckId 'sddc_manager_connection' -Area 'SDDC Manager' -DisplayName 'SDDC Manager Connection' -Status Error -Blocking `
                -TargetComponent $credential.Fqdn -Exception $_.Exception.Message `
                -ValidationCriteria 'A connection to SDDC Manager can be established before any checks run.' `
                -Remediation 'Verify network/VPN connectivity and DNS resolution to the SDDC Manager FQDN, that port 443 is reachable, and that the credentials are correct, then retry.' `
                -StartedAt $startedAt -CompletedAt (Get-Date)))
            $connectionFailed = $true
        }

        $vcfVersion = ''
        if (-not $connectionFailed) {
            try {
                $vcfVersion = Get-VcfCheckVcfVersion -Context $Context
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not resolve the VCF version for this run: $($_.Exception.Message)"
            }

            $checks = Resolve-VcfCheckCheckList -CheckId $CheckId

            $checksRequireRootCredential = @($checks | Where-Object { $_.RequiresSddcManagerRootCredential }).Count -gt 0
            if ($checksRequireRootCredential -and $Context.SddcManagerRootCredential) {
                Write-LogMessage -Type INFO -Message "Validating SDDC Manager root credential before checks begin..."
                $Script:VcfCheckCurrentCheckId = 'sddc_manager_root_validation'
                $credentialValidation = Test-VcfCheckSddcManagerRootCredential -Context $Context -RootCredential $Context.SddcManagerRootCredential
                $Script:VcfCheckCurrentCheckId = $null
                if (-not $credentialValidation.Success) {
                    Write-LogMessage -Type ERROR -Message "SDDC Manager root credential validation failed: $($credentialValidation.ErrorMessage)"
                    $results.Add((New-VcfCheckResult -CheckId 'sddc_manager_root_validation' -Area 'SDDC Manager' -DisplayName 'SDDC Manager Root Credential Validation' -Status Error -Blocking `
                        -TargetComponent $credential.Fqdn -Exception $credentialValidation.ErrorMessage `
                        -ValidationCriteria 'The SDDC Manager appliance root credential must be valid before any checks run.' `
                        -Remediation 'Verify the SDDC Manager appliance root password is correct and that the appliance is accessible via VMware Tools guest operations, then retry.' `
                        -StartedAt $startedAt -CompletedAt (Get-Date)))
                    $checks = @()
                }
            }

            if ($checks.Count -gt 0) {
                $checks = Sort-VcfCheckChecksByArea -Checks $checks
                Write-LogMessage -Type INFO -Message "Resolved $($checks.Count) check(s) to run. Checks will be organized by area: Aria Suite → ESX → NSX → SDDC Manager → vCenter → vSAN"
            } else {
                Write-LogMessage -Type INFO -Message "No checks to run."
            }

            $checkIndex = 0
            $currentArea = $null
            foreach ($check in $checks) {
                # Log when transitioning to a new area
                if ($check.Area -ne $currentArea) {
                    $currentArea = $check.Area
                    $areaDisplayName = Get-VcfCheckAreaDisplayName -Area $currentArea
                    Write-LogMessage -Type INFO -Message "Starting $areaDisplayName checks..."
                }
                $checkIndex++
                $functionInfo = Get-Command -Name $check.Function -ErrorAction SilentlyContinue
                $checkStartedAt = Get-Date
                # $check.DisplayName comes straight from the catalog (Resolve-VcfCheckCheckList) -
                # falls back to the raw ID only for a check ID the catalog doesn't know about.
                $checkDisplayName = if ($check.DisplayName) { $check.DisplayName } else { $check.Id }
                $Script:VcfCheckCurrentCheckId = $check.Id

                if (-not $NoSummary.IsPresent) {
                    Write-VcfCheckCheckProgress -Index $checkIndex -Total $checks.Count -CheckId $check.Id -DisplayName $checkDisplayName
                }

                if (-not $functionInfo) {
                    $result = New-VcfCheckResult -CheckId $check.Id -Area $check.Area -DisplayName $checkDisplayName `
                        -Status Error -Blocking:$check.Blocking -Exception "Check function `"$($check.Function)`" is not implemented." `
                        -StartedAt $checkStartedAt -CompletedAt (Get-Date)
                    Write-LogMessage -Type ERROR -Message "Check `"$($check.Id)`" has no implementation for function `"$($check.Function)`"."
                } else {
                    try {
                        # sddc_bom_check/vrslcm_fetch_products and sddc_check_health_summary/
                        # sddc_pre_check_ui are the only checks today with an orchestrator-level
                        # setting of their own; special-cased here rather than building a generic
                        # per-check-parameter pass-through for four consumers.
                        if ($check.Id -in @('sddc_bom_check', 'vrslcm_fetch_products') -and -not [String]::IsNullOrWhiteSpace($VcfDestinationRelease)) {
                            $result = & $check.Function -Context $Context -DisplayName $checkDisplayName -VcfDestinationRelease $VcfDestinationRelease
                        } elseif ($check.Id -eq 'sddc_check_health_summary' -and $HealthSummaryMaxPollAttempts -gt 0) {
                            $result = & $check.Function -Context $Context -DisplayName $checkDisplayName -MaxPollAttempts $HealthSummaryMaxPollAttempts
                        } elseif ($check.Id -eq 'sddc_pre_check_ui' -and $PreUpgradeCheckSetMaxPollAttempts -gt 0) {
                            $result = & $check.Function -Context $Context -DisplayName $checkDisplayName -MaxPollAttempts $PreUpgradeCheckSetMaxPollAttempts
                        } else {
                            $result = & $check.Function -Context $Context -DisplayName $checkDisplayName
                        }
                    } catch {
                        $result = New-VcfCheckResult -CheckId $check.Id -Area $check.Area -DisplayName $checkDisplayName `
                            -Status Error -Blocking:$check.Blocking -Exception $_.Exception.Message `
                            -StartedAt $checkStartedAt -CompletedAt (Get-Date)
                        Write-LogMessage -Type ERROR -Message "Check `"$($check.Id)`" threw: $($_.Exception.Message)"
                    }
                }

                $Script:VcfCheckCurrentCheckId = $null
                Clear-VcfCheckSubProgress -Context $Context

                # Checks that only ever target a single fleet-wide/management-only component
                # (SDDC Manager, Aria Suite) never pass -Domain to New-VcfCheckResult, since
                # they have no per-vCenter outcome to resolve a domain from. Backfill those blank
                # results to the real Management domain here, once, rather than touching every
                # such check's call sites - they are all implicitly Management-domain-scoped.
                # Checks that instead set -Component (e.g. Aria Operations, which has no VCF
                # domain of its own) are skipped here, so they keep showing a Component pill
                # instead of a misleading Domain pill.
                foreach ($resultItem in @($result)) {
                    if ([String]::IsNullOrWhiteSpace($resultItem.Domain) -and [String]::IsNullOrWhiteSpace($resultItem.Component)) {
                        try {
                            $managementDomain = Get-VcfCheckManagementDomain -Context $Context
                            $resultItem.Domain = [String]$managementDomain.Name
                            $resultItem.DomainType = 'MANAGEMENT'
                        } catch {
                            Write-LogMessage -Type DEBUG -Message "Could not backfill the Management domain onto check `"$($check.Id)`": $($_.Exception.Message)"
                        }
                    }
                }

                # Scope this run's recorded/logged output to the selected domains (if any). Cheap
                # single-target checks (SDDC Manager, Aria Suite) always run - they're backfilled
                # to Management above - and are simply dropped here when Management isn't in
                # scope, rather than trying to skip their invocation based on catalog Area.
                # Component-scoped checks (e.g. Aria Operations) have no Domain to backfill and
                # are not domain-specific, so they always survive this filter too.
                if ($Domain.Count -gt 0) {
                    $result = @($result | Where-Object {
                        $_.Domain -in $Domain -or (
                            [String]::IsNullOrWhiteSpace($_.Domain) -and
                            -not [String]::IsNullOrWhiteSpace($_.Component)
                        )
                    })
                }

                if (-not $NoSummary.IsPresent) {
                    foreach ($resultItem in @($result)) {
                        Write-VcfCheckCheckOutcome -Result $resultItem
                    }
                }

                $results.AddRange(@($result))

                $partialReport = ConvertTo-VcfCheckReportJson -RunId $runId -SddcManagerFqdn $credential.Fqdn -CheckId $CheckId -Results $results.ToArray() -StartedAt $startedAt -CompletedAt (Get-Date) -VcfVersion $vcfVersion
                $null = Write-VcfCheckReport -Report $partialReport -OutputPath $resolvedOutputPath -EnvironmentName $EnvironmentName
            }
        }
    } finally {
        $Script:VcfCheckCurrentCheckId = $null
        Disconnect-VcfCheckAll -Context $Context
    }

    $finalReport = ConvertTo-VcfCheckReportJson -RunId $runId -SddcManagerFqdn $credential.Fqdn -CheckId $CheckId -Results $results.ToArray() -StartedAt $startedAt -CompletedAt (Get-Date) -VcfVersion $vcfVersion
    $reportPath = Write-VcfCheckReport -Report $finalReport -OutputPath $resolvedOutputPath -EnvironmentName $EnvironmentName
    Write-LogMessage -Type INFO -Message "Run `"$runId`" complete. Report written to `"$reportPath`"."

    try {
        # Swaps the run ID in the findings filename for a completion timestamp, once the run is
        # done, so the file the user is left with is keyed on something human-friendly rather
        # than the internal run ID needed to keep partial flushes consistent during the run.
        $timestampedReportPath = Get-VcfCheckTimestampedReportPath -Path $reportPath -RunId $runId -CompletedAt (Get-Date)
        if ($timestampedReportPath -ne $reportPath) {
            Rename-Item -LiteralPath $reportPath -NewName (Split-Path -Path $timestampedReportPath -Leaf) -Force
            $reportPath = $timestampedReportPath
            Write-LogMessage -Type INFO -Message "Report renamed to `"$reportPath`" for easier lookup."
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not rename the findings report to a timestamp-based name: $($_.Exception.Message)"
    }

    try {
        # Derive the HTML filename from the JSON report's own filename so the two files
        # for one run always share the exact same timestamp/run ID.
        $reportLeaf = Split-Path -Path $reportPath -Leaf
        $htmlLeaf = if ($reportLeaf -match '-findings\.json$') {
            $reportLeaf -replace '-findings\.json$', '-report.html'
        } else {
            $reportLeaf -replace '^run-(.+)\.json$', 'report-$1.html'
        }
        $htmlPath = Export-VcfCheckReportHtml -Report $finalReport -Path (Join-Path -Path (Split-Path -Path $reportPath -Parent) -ChildPath $htmlLeaf)
        Write-LogMessage -Type INFO -Message "HTML report written to `"$htmlPath`"."
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not generate the HTML report: $($_.Exception.Message)"
    }

    if (-not $NoSummary.IsPresent) {
        Write-VcfCheckConsoleSummary -Results $results.ToArray()
    }

    return $results.ToArray()
}

#endregion Orchestrator
