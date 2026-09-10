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
<#
    .SYNOPSIS
    Command-line entry point for executing the VcfCheck module.

    .DESCRIPTION
    Accepts execution parameters via command-line arguments and reads SDDC Manager
    credential secrets directly from process environment variables (`VCFCHECK_SDDC_PASSWORD`
    and `VCFCHECK_ROOT_PASSWORD`).

    Converts plaintext credentials to SecureString objects, executes prechecks via `Invoke-VcfCheck`,
    and securely disposes of sensitive variables in memory upon completion.

    Exit codes:
    - 0: Precheck completed with no blocking failures.
    - 1: Precheck completed with one or more blocking failures.
    - 2: Precheck execution terminated unexpectedly due to an unhandled exception.

    .PARAMETER SddcManagerFqdn
    Fully qualified domain name of the SDDC Manager appliance. Forwarded to `Invoke-VcfCheck`.

    .PARAMETER SddcManagerUser
    Username for SDDC Manager authentication. Forwarded to `Invoke-VcfCheck`.

    .PARAMETER CheckId
    Comma-separated string of check IDs to execute. Defined as a single string to ensure consistent
    command-line argument binding across subprocess invocations.

    .PARAMETER Domain
    Optional comma-separated string of VCF workload domain names to scope execution.

    .PARAMETER RunId
    Optional unique execution run identifier. Forwarded to `Invoke-VcfCheck`.

    .PARAMETER EnvironmentName
    Optional human-readable environment name used for report generation.

    .PARAMETER OutputPath
    Directory path where precheck report artifacts are written. Defaults to `$env:VcfCheckBaseDirectory\Findings`.

    .PARAMETER ConnectivityTimeoutSeconds
    Timeout duration in seconds for REST and network connectivity checks. Defaults to 30 seconds.

    .PARAMETER VcfDestinationRelease
    Target VCF release version, release family (e.g., '9.1.0'), or 'latest'.

    .PARAMETER HealthSummaryMaxPollAttempts
    Forwarded to Invoke-VcfCheck's own -HealthSummaryMaxPollAttempts. 0 (default) leaves the
    'SDDC Manager Health Summary' check on its own built-in poll budget.

    .PARAMETER PreUpgradeCheckSetMaxPollAttempts
    Forwarded to Invoke-VcfCheck's own -PreUpgradeCheckSetMaxPollAttempts. 0 (default) leaves
    the 'SDDC Manager Pre-Upgrade Check-Set Assessment' check on its own built-in poll budget.

    .NOTES
    Serves as the launcher contract between external execution callers and the VcfCheck module.

    .EXAMPLE
    pwsh -NoProfile -NonInteractive -File Invoke-VcfCheckLauncher.ps1 -SddcManagerFqdn sddc.example.com -SddcManagerUser administrator@vsphere.local -CheckId "sddc_bom_check,sddc_check_failed_tasks"
#>

[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SddcManagerFqdn,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SddcManagerUser,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CheckId,
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Domain = '',
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$RunId = '',
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$EnvironmentName = '',
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$OutputPath = '',
    [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 30,
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$VcfDestinationRelease = '',
    [Parameter(Mandatory = $false)] [Int]$HealthSummaryMaxPollAttempts = 0,
    [Parameter(Mandatory = $false)] [Int]$PreUpgradeCheckSetMaxPollAttempts = 0
)

$checkIds = @($CheckId -split ',' | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
if ($checkIds.Count -eq 0) {
    Write-Host 'ERROR: -CheckId did not contain any non-empty check ids after splitting on commas.' -ForegroundColor Red
    exit 1
}

$domains = @($Domain -split ',' | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })

# Suppress PSStyle ANSI escape codes so captured output remains plain text.
if ($null -ne $PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

if ([String]::IsNullOrWhiteSpace($env:VcfCheckBaseDirectory) -and [String]::IsNullOrWhiteSpace($OutputPath)) {
    Write-Host 'ERROR: VcfCheckBaseDirectory is not set and -OutputPath was not provided. Run Initialize-VcfCheck first.' -ForegroundColor Red
    exit 1
}

# Resolve module manifest location via environment override or relative path fallback.
$envModulePsd1 = ([String]$env:VCFCHECK_MODULE_PSD1).Trim()
if (-not [String]::IsNullOrWhiteSpace($envModulePsd1) -and (Test-Path -LiteralPath $envModulePsd1 -PathType Leaf)) {
    $modulePath = $envModulePsd1
} else {
    $modulePath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'VcfCheck.psd1'
}
try {
    Import-Module -Name $modulePath -Force -ErrorAction Stop
} catch {
    Write-Host "ERROR: Could not load the VcfCheck module from `"$modulePath`": $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$sddcPasswordPlainText = $env:VCFCHECK_SDDC_PASSWORD
if ([String]::IsNullOrEmpty($sddcPasswordPlainText)) {
    Write-Host 'ERROR: VCFCHECK_SDDC_PASSWORD environment variable was not set.' -ForegroundColor Red
    exit 1
}

$sddcPassword = $null
$rootPassword = $null
$ariaOpsEndpointCredentials = @()
try {
    $sddcPassword = ConvertTo-SecureString -String $sddcPasswordPlainText -AsPlainText -Force

    $rootPasswordPlainText = $env:VCFCHECK_ROOT_PASSWORD
    if (-not [String]::IsNullOrEmpty($rootPasswordPlainText)) {
        $rootPassword = ConvertTo-SecureString -String $rootPasswordPlainText -AsPlainText -Force
    }

    # Standalone Aria Operations endpoint passwords (Environment.Integrations), collected
    # session-only by the browser - see Tools/Start-VcfCheckServer.py's _resolve_aria_ops_credentials.
    $ariaOpsCredentialsJson = $env:VCFCHECK_ARIAOPS_CREDENTIALS_JSON
    if (-not [String]::IsNullOrEmpty($ariaOpsCredentialsJson)) {
        try {
            $ariaOpsEndpointCredentials = @(ConvertFrom-Json -InputObject $ariaOpsCredentialsJson -ErrorAction Stop | ForEach-Object {
                [PSCustomObject]@{ Fqdn = $_.Fqdn; Password = (ConvertTo-SecureString -String $_.Password -AsPlainText -Force) }
            })
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not parse VCFCHECK_ARIAOPS_CREDENTIALS_JSON: $($_.Exception.Message)"
            $ariaOpsEndpointCredentials = @()
        }
    }

    $invokeParams = @{
        SddcManagerFqdn            = $SddcManagerFqdn
        SddcManagerUser            = $SddcManagerUser
        SddcManagerPassword        = $sddcPassword
        CheckId                    = $checkIds
        ConnectivityTimeoutSeconds = $ConnectivityTimeoutSeconds
    }
    if ($rootPassword) {
        $invokeParams['SddcManagerRootPassword'] = $rootPassword
    }
    if ($domains.Count -gt 0) {
        $invokeParams['Domain'] = $domains
    }
    if (-not [String]::IsNullOrWhiteSpace($OutputPath)) {
        $invokeParams['OutputPath'] = $OutputPath
    }
    if (-not [String]::IsNullOrWhiteSpace($RunId)) {
        $invokeParams['RunId'] = $RunId
    }
    if (-not [String]::IsNullOrWhiteSpace($EnvironmentName)) {
        $invokeParams['EnvironmentName'] = $EnvironmentName
    }
    if (-not [String]::IsNullOrWhiteSpace($VcfDestinationRelease)) {
        $invokeParams['VcfDestinationRelease'] = $VcfDestinationRelease
    }
    if ($HealthSummaryMaxPollAttempts -gt 0) {
        $invokeParams['HealthSummaryMaxPollAttempts'] = $HealthSummaryMaxPollAttempts
    }
    if ($PreUpgradeCheckSetMaxPollAttempts -gt 0) {
        $invokeParams['PreUpgradeCheckSetMaxPollAttempts'] = $PreUpgradeCheckSetMaxPollAttempts
    }
    if ($ariaOpsEndpointCredentials.Count -gt 0) {
        $invokeParams['AriaOpsEndpointCredentials'] = $ariaOpsEndpointCredentials
    }

    $results = Invoke-VcfCheck @invokeParams

    $hasBlockingFailure = @($results | Where-Object { $_.Blocking -and $_.Status -in @('Fail', 'Error') }).Count -gt 0
    exit ([Int]$hasBlockingFailure)
} catch {
    # Log terminating execution errors and exit with code 2.
    Write-LogMessage -Type ERROR -Message "Run terminated unexpectedly: $($_.Exception.Message)"
    exit 2
} finally {
    $sddcPasswordPlainText = $null
    $env:VCFCHECK_ARIAOPS_CREDENTIALS_JSON = $null
    Remove-Variable -Name sddcPasswordPlainText, rootPasswordPlainText, sddcPassword, rootPassword, ariaOpsCredentialsJson, ariaOpsEndpointCredentials -ErrorAction SilentlyContinue
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
