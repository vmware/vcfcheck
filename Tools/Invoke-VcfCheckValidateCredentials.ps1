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
    Command-line entry point for validating SDDC Manager and appliance root credentials.

    .DESCRIPTION
    Connects to SDDC Manager to validate provided API credentials and discover deployed workload domains.
    Reads SDDC Manager and root passwords directly from process environment variables (`VCFCHECK_SDDC_PASSWORD`
    and `VCFCHECK_ROOT_PASSWORD`).

    When `VCFCHECK_ROOT_PASSWORD` is supplied, additionally verifies SDDC Manager appliance root credentials
    via `Test-VcfCheckSddcManagerRootCredential` by executing guest operations commands against the SDDC Manager VM.

    When `VCFCHECK_ARIAOPS_CREDENTIALS_JSON` is supplied (a JSON array of `{Name, Fqdn, Username, Password}`),
    additionally verifies reachability and authentication for each standalone Aria Operations endpoint declared
    on the environment via `Connect-VcfCheckAriaOpsEndpoint`. `VCFCHECK_ARIAAUTOMATION_CREDENTIALS_JSON` does the
    same for standalone Aria Automation endpoints via `Connect-VcfCheckAriaAutomationEndpoint`, and
    `VCFCHECK_ARIAOPSFORLOGS_CREDENTIALS_JSON` does the same for standalone Aria Operations for Logs endpoints via
    `Connect-VcfCheckAriaOpsForLogsEndpoint`.

    Outputs a structured JSON payload to stdout detailing validation status, execution phases, and discovered domains:
    - `success`: Boolean indicating overall credential validation success.
    - `error`: Error message string if validation failed at the top level.
    - `phases`: Array of validation phase results (Network Reachability, SDDC Manager Authentication,
      Aria Suite Lifecycle Manager Connectivity, Aria Operations/Aria Automation Network Reachability/
      Authentication per endpoint, ESX Host Connectivity, VMware Tools Status, SDDC Manager Root Authentication).
    - `domains`: Array of discovered VCF domain names and domain types.

    Writes audit log entries using `Write-LogMessage` throughout the validation process.

    .PARAMETER SddcManagerFqdn
    Fully qualified domain name of the SDDC Manager appliance.

    .PARAMETER SddcManagerUser
    Username for SDDC Manager authentication.

    .PARAMETER ConnectivityTimeoutSeconds
    Maximum duration in seconds to wait for TCP reachability checks. Defaults to 30 seconds.

    .NOTES
    Acts as the entry point contract for credential validation execution.

    .EXAMPLE
    pwsh -NoProfile -NonInteractive -File Invoke-VcfCheckValidateCredentials.ps1 -SddcManagerFqdn sddc.example.com -SddcManagerUser administrator@vsphere.local
#>

[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SddcManagerFqdn,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SddcManagerUser,
    [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 30
)

if ($null -ne $PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

$envModulePsd1 = ([String]$env:VCFCHECK_MODULE_PSD1).Trim()
if (-not [String]::IsNullOrWhiteSpace($envModulePsd1) -and (Test-Path -LiteralPath $envModulePsd1 -PathType Leaf)) {
    $modulePath = $envModulePsd1
} else {
    $modulePath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'VcfCheck.psd1'
}
try {
    Import-Module -Name $modulePath -Force -ErrorAction Stop
} catch {
    @{ success = $false; error = "Could not load the VcfCheck module from `"$modulePath`": $($_.Exception.Message)" } | ConvertTo-Json -Compress
    exit 1
}

try {
    Initialize-VcfCheckLogging | Out-Null
} catch {
    # Logging initialization is best-effort when base directory environment variables are unconfigured.
}

$sddcPasswordPlainText = $env:VCFCHECK_SDDC_PASSWORD
if ([String]::IsNullOrEmpty($sddcPasswordPlainText)) {
    Write-LogMessage -Type ERROR -Message 'Credential check aborted: VCFCHECK_SDDC_PASSWORD environment variable was not set.'
    @{ success = $false; error = 'VCFCHECK_SDDC_PASSWORD environment variable was not set.' } | ConvertTo-Json -Compress
    exit 1
}

$credentialProgressPath = $null
if (-not [String]::IsNullOrWhiteSpace($env:VcfCheckBaseDirectory)) {
    $credentialProgressPath = Join-Path -Path $env:VcfCheckBaseDirectory.Trim() -ChildPath 'validate-credentials-progress.json'
}

function Write-CredentialCheckProgress {
    Param (
        [Parameter(Mandatory = $true)] [Array]$Phases
    )
    # Best-effort mid-run status for the browser UI to poll; the final stdout JSON stays authoritative.
    if (-not $credentialProgressPath) { return }
    try {
        Set-Content -LiteralPath $credentialProgressPath -Value (@{ phases = $Phases } | ConvertTo-Json -Depth 4 -Compress) -ErrorAction Stop
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not write credential check progress file: $($_.Exception.Message)"
    }
}

function Set-CredentialCheckPhase {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mutates an in-memory phase list local to this script''s own run, not external system state - no destructive action for -WhatIf/-Confirm to gate.')]
    Param (
        [Parameter(Mandatory = $true)] [String]$Name,
        [Parameter(Mandatory = $true)] [String]$Status,
        [Parameter(Mandatory = $false)] [String]$ErrorMessage
    )
    # Updates a phase already in $script:phases in place (e.g. a callback's early "pass" later
    # confirmed or overridden by the caller's own final determination) rather than appending a
    # second entry for the same name - keeps $script:phases the single source of truth so every
    # progress write and the final stdout JSON agree on one entry per phase name.
    $existingPhase = $script:phases | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($existingPhase) {
        $existingPhase.status = $Status
        $existingPhase.error = $ErrorMessage
    } else {
        $script:phases += @{ name = $Name; status = $Status; error = $ErrorMessage }
    }
    Write-CredentialCheckProgress -Phases $script:phases
}

$sddcPassword = $null
$rootPassword = $null
$Context = $null
$phases = @()
$domains = @()
Write-CredentialCheckProgress -Phases $phases

try {
    $sddcPassword = ConvertTo-SecureString -String $sddcPasswordPlainText -AsPlainText -Force
    $Context = New-VcfCheckContext
    $Context.AllowInsecureTls = Resolve-VcfCheckAllowInsecureTls

    Write-LogMessage -Type INFO -Message "Checking credentials for SDDC Manager `"$SddcManagerFqdn`" as `"$SddcManagerUser`"."
    try {
        Connect-VcfCheckSddcManager -Context $Context -Fqdn $SddcManagerFqdn -User $SddcManagerUser -Password $sddcPassword `
            -IgnoreInvalidCertificate:$Context.AllowInsecureTls -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds `
            -OnReachable { Set-CredentialCheckPhase -Name 'Network Reachability' -Status 'pass' }
        Write-LogMessage -Type INFO -Message "Authentication successful: SDDC Manager `"$SddcManagerFqdn`"."
        Set-CredentialCheckPhase -Name 'Network Reachability' -Status 'pass'
        Set-CredentialCheckPhase -Name 'SDDC Manager Authentication' -Status 'pass'

        try {
            $sddcManagerVersion = Get-VcfCheckVcfVersion -Context $Context
            Write-LogMessage -Type INFO -Message "SDDC Manager `"$SddcManagerFqdn`" version: $sddcManagerVersion."
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not retrieve SDDC Manager version for `"$SddcManagerFqdn`": $($_.Exception.Message)"
        }

        try {
            $nsxManagerFqdn = Get-VcfCheckManagementNsxManagerFqdn -Context $Context
            Connect-VcfCheckNsxManager -Context $Context -Fqdn $nsxManagerFqdn
            $nsxManagerVersion = Get-VcfCheckNsxManagerVersion -Context $Context -Server $nsxManagerFqdn
            Write-LogMessage -Type INFO -Message "NSX Manager `"$nsxManagerFqdn`" version: $nsxManagerVersion."
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not retrieve NSX Manager version: $($_.Exception.Message)"
        }

        # Populate VCF domain inventory for UI selection filters.
        try {
            $domains = @((Invoke-VcfGetDomains -ErrorAction Stop).Elements | ForEach-Object { @{ name = [String]$_.Name; type = [String]$_.Type } })
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not retrieve VCF domains for `"$SddcManagerFqdn`": $($_.Exception.Message)"
        }

        # Verify Aria Suite Lifecycle Manager TCP connectivity if registered with SDDC Manager.
        try {
            $vrslcmConnection = Get-VcfCheckVrslcmConnection -Context $Context
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not resolve Aria Suite Lifecycle Manager connection details: $($_.Exception.Message)"
            $vrslcmConnection = $null
        }
        if ($vrslcmConnection) {
            Write-LogMessage -Type INFO -Message "Checking TCP reachability to Aria Suite Lifecycle Manager `"$($vrslcmConnection.Fqdn)`" on port 443..."
            if (Test-VcfCheckTcpConnectivity -ComputerName $vrslcmConnection.Fqdn -Port 443 -TimeoutSeconds $ConnectivityTimeoutSeconds) {
                Write-LogMessage -Type INFO -Message "Aria Suite Lifecycle Manager `"$($vrslcmConnection.Fqdn)`" is reachable on TCP port 443."
                $phases += @{ name = 'Aria Suite Lifecycle Manager Connectivity'; status = 'pass'; error = $null }
            } else {
                Write-LogMessage -Type WARNING -Message "Aria Suite Lifecycle Manager `"$($vrslcmConnection.Fqdn)`" is not reachable on port 443."
                $phases += @{
                    name   = 'Aria Suite Lifecycle Manager Connectivity'
                    status = 'fail'
                    error  = "Aria Suite Lifecycle Manager (`"$($vrslcmConnection.Fqdn)`") is not reachable on port 443. Check VPN/network connectivity, firewall rules, and DNS resolution. Aria Suite checks will fail or time out until this is resolved."
                }
            }
            Write-CredentialCheckProgress -Phases $phases
        }

        # Validate reachability and authentication for each standalone Aria Operations endpoint
        # (Environment.Integrations) that the browser supplied a session-only password for.
        $ariaOpsCredentialsJson = $env:VCFCHECK_ARIAOPS_CREDENTIALS_JSON
        if (-not [String]::IsNullOrEmpty($ariaOpsCredentialsJson)) {
            try {
                $ariaOpsCredentialEntries = @(ConvertFrom-Json -InputObject $ariaOpsCredentialsJson -ErrorAction Stop)
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not parse VCFCHECK_ARIAOPS_CREDENTIALS_JSON: $($_.Exception.Message)"
                $ariaOpsCredentialEntries = @()
            }

            foreach ($ariaOpsEntry in $ariaOpsCredentialEntries) {
                $ariaOpsLabel = $ariaOpsEntry.Fqdn
                $ariaOpsSecurePassword = ConvertTo-SecureString -String $ariaOpsEntry.Password -AsPlainText -Force
                $ariaOpsCredential = [PSCredential]::new($ariaOpsEntry.Username, $ariaOpsSecurePassword)

                Write-LogMessage -Type INFO -Message "Checking credentials for Aria Operations `"$($ariaOpsEntry.Fqdn)`" as `"$($ariaOpsEntry.Username)`"."
                try {
                    $ariaOpsConnection = Connect-VcfCheckAriaOpsEndpoint -Context $Context -Fqdn $ariaOpsEntry.Fqdn -Credential $ariaOpsCredential -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
                    Write-LogMessage -Type INFO -Message "Authentication successful: Aria Operations `"$($ariaOpsEntry.Fqdn)`"."
                    try {
                        $ariaOpsVersion = Get-VcfCheckAriaOpsVersion -Connection $ariaOpsConnection
                        Write-LogMessage -Type INFO -Message "Aria Operations `"$($ariaOpsEntry.Fqdn)`" version: $ariaOpsVersion."
                    } catch {
                        Write-LogMessage -Type WARNING -Message "Could not retrieve Aria Operations version for `"$($ariaOpsEntry.Fqdn)`": $($_.Exception.Message)"
                    }
                    $phases += @{ name = "Aria Operations Network Reachability ($ariaOpsLabel)"; status = 'pass'; error = $null }
                    $phases += @{ name = "Aria Operations Authentication ($ariaOpsLabel)"; status = 'pass'; error = $null }
                } catch {
                    $ariaOpsErrorMsg = $_.Exception.Message
                    Write-LogMessage -Type WARNING -Message "Authentication failed: Aria Operations `"$($ariaOpsEntry.Fqdn)`" - $ariaOpsErrorMsg"

                    if ($ariaOpsErrorMsg -match 'Could not reach.*on port \d+') {
                        $phases += @{ name = "Aria Operations Network Reachability ($ariaOpsLabel)"; status = 'fail'; error = "Aria Operations (`"$($ariaOpsEntry.Fqdn)`") is not reachable on port 443. Check VPN/network connectivity, firewall rules, and DNS resolution." }
                    } else {
                        $phases += @{ name = "Aria Operations Network Reachability ($ariaOpsLabel)"; status = 'pass'; error = $null }
                        $phases += @{ name = "Aria Operations Authentication ($ariaOpsLabel)"; status = 'fail'; error = "Invalid username or password for Aria Operations (`"$($ariaOpsEntry.Fqdn)`"). Verify the credential entered for this endpoint." }
                    }
                }
                Write-CredentialCheckProgress -Phases $phases
            }
            Remove-Variable -Name ariaOpsCredentialsJson, ariaOpsCredentialEntries, ariaOpsSecurePassword, ariaOpsCredential -ErrorAction SilentlyContinue
        }

        # Validate reachability and authentication for each standalone Aria Automation endpoint
        # (Environment.Integrations) that the browser supplied a session-only password for.
        $ariaAutomationCredentialsJson = $env:VCFCHECK_ARIAAUTOMATION_CREDENTIALS_JSON
        if (-not [String]::IsNullOrEmpty($ariaAutomationCredentialsJson)) {
            try {
                $ariaAutomationCredentialEntries = @(ConvertFrom-Json -InputObject $ariaAutomationCredentialsJson -ErrorAction Stop)
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not parse VCFCHECK_ARIAAUTOMATION_CREDENTIALS_JSON: $($_.Exception.Message)"
                $ariaAutomationCredentialEntries = @()
            }

            foreach ($ariaAutomationEntry in $ariaAutomationCredentialEntries) {
                $ariaAutomationLabel = $ariaAutomationEntry.Fqdn
                $ariaAutomationSecurePassword = ConvertTo-SecureString -String $ariaAutomationEntry.Password -AsPlainText -Force
                $ariaAutomationCredential = [PSCredential]::new($ariaAutomationEntry.Username, $ariaAutomationSecurePassword)

                Write-LogMessage -Type INFO -Message "Checking credentials for Aria Automation `"$($ariaAutomationEntry.Fqdn)`" as `"$($ariaAutomationEntry.Username)`"."
                try {
                    $ariaAutomationConnection = Connect-VcfCheckAriaAutomationEndpoint -Context $Context -Fqdn $ariaAutomationEntry.Fqdn -Credential $ariaAutomationCredential -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
                    Write-LogMessage -Type INFO -Message "Authentication successful: Aria Automation `"$($ariaAutomationEntry.Fqdn)`"."
                    try {
                        $ariaAutomationVersion = Get-VcfCheckAriaAutomationVersion -CredentialInfo $ariaAutomationConnection
                        Write-LogMessage -Type INFO -Message "Aria Automation `"$($ariaAutomationEntry.Fqdn)`" version: $ariaAutomationVersion."
                    } catch {
                        Write-LogMessage -Type WARNING -Message "Could not retrieve Aria Automation version for `"$($ariaAutomationEntry.Fqdn)`": $($_.Exception.Message)"
                    }
                    $phases += @{ name = "Aria Automation Network Reachability ($ariaAutomationLabel)"; status = 'pass'; error = $null }
                    $phases += @{ name = "Aria Automation Authentication ($ariaAutomationLabel)"; status = 'pass'; error = $null }
                } catch {
                    $ariaAutomationErrorMsg = $_.Exception.Message
                    Write-LogMessage -Type WARNING -Message "Authentication failed: Aria Automation `"$($ariaAutomationEntry.Fqdn)`" - $ariaAutomationErrorMsg"

                    if ($ariaAutomationErrorMsg -match 'Could not reach.*on port \d+') {
                        $phases += @{ name = "Aria Automation Network Reachability ($ariaAutomationLabel)"; status = 'fail'; error = "Aria Automation (`"$($ariaAutomationEntry.Fqdn)`") is not reachable on port 443. Check VPN/network connectivity, firewall rules, and DNS resolution." }
                    } else {
                        $phases += @{ name = "Aria Automation Network Reachability ($ariaAutomationLabel)"; status = 'pass'; error = $null }
                        $phases += @{ name = "Aria Automation Authentication ($ariaAutomationLabel)"; status = 'fail'; error = "Invalid username or password for Aria Automation (`"$($ariaAutomationEntry.Fqdn)`"). Verify the credential entered for this endpoint." }
                    }
                }
                Write-CredentialCheckProgress -Phases $phases
            }
            Remove-Variable -Name ariaAutomationCredentialsJson, ariaAutomationCredentialEntries, ariaAutomationSecurePassword, ariaAutomationCredential -ErrorAction SilentlyContinue
        }

        # Validate reachability and authentication for each standalone Aria Operations for Logs
        # endpoint (Environment.Integrations) that the browser supplied a session-only password for.
        $ariaOpsForLogsCredentialsJson = $env:VCFCHECK_ARIAOPSFORLOGS_CREDENTIALS_JSON
        if (-not [String]::IsNullOrEmpty($ariaOpsForLogsCredentialsJson)) {
            try {
                $ariaOpsForLogsCredentialEntries = @(ConvertFrom-Json -InputObject $ariaOpsForLogsCredentialsJson -ErrorAction Stop)
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not parse VCFCHECK_ARIAOPSFORLOGS_CREDENTIALS_JSON: $($_.Exception.Message)"
                $ariaOpsForLogsCredentialEntries = @()
            }

            foreach ($ariaOpsForLogsEntry in $ariaOpsForLogsCredentialEntries) {
                $ariaOpsForLogsLabel = $ariaOpsForLogsEntry.Fqdn
                $ariaOpsForLogsSecurePassword = ConvertTo-SecureString -String $ariaOpsForLogsEntry.Password -AsPlainText -Force
                $ariaOpsForLogsCredential = [PSCredential]::new($ariaOpsForLogsEntry.Username, $ariaOpsForLogsSecurePassword)

                Write-LogMessage -Type INFO -Message "Checking credentials for Aria Operations for Logs `"$($ariaOpsForLogsEntry.Fqdn)`" as `"$($ariaOpsForLogsEntry.Username)`"."
                try {
                    $ariaOpsForLogsSession = Connect-VcfCheckAriaOpsForLogsEndpoint -Context $Context -Fqdn $ariaOpsForLogsEntry.Fqdn -Credential $ariaOpsForLogsCredential -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
                    Write-LogMessage -Type INFO -Message "Authentication successful: Aria Operations for Logs `"$($ariaOpsForLogsEntry.Fqdn)`"."
                    try {
                        $ariaOpsForLogsVersion = Get-VcfCheckAriaOpsForLogsVersion -Session $ariaOpsForLogsSession
                        Write-LogMessage -Type INFO -Message "Aria Operations for Logs `"$($ariaOpsForLogsEntry.Fqdn)`" version: $ariaOpsForLogsVersion."
                    } catch {
                        Write-LogMessage -Type WARNING -Message "Could not retrieve Aria Operations for Logs version for `"$($ariaOpsForLogsEntry.Fqdn)`": $($_.Exception.Message)"
                    }
                    $phases += @{ name = "Aria Operations for Logs Network Reachability ($ariaOpsForLogsLabel)"; status = 'pass'; error = $null }
                    $phases += @{ name = "Aria Operations for Logs Authentication ($ariaOpsForLogsLabel)"; status = 'pass'; error = $null }
                } catch {
                    $ariaOpsForLogsErrorMsg = $_.Exception.Message
                    Write-LogMessage -Type WARNING -Message "Authentication failed: Aria Operations for Logs `"$($ariaOpsForLogsEntry.Fqdn)`" - $ariaOpsForLogsErrorMsg"

                    if ($ariaOpsForLogsErrorMsg -match 'Could not reach.*on port \d+') {
                        $phases += @{ name = "Aria Operations for Logs Network Reachability ($ariaOpsForLogsLabel)"; status = 'fail'; error = "Aria Operations for Logs (`"$($ariaOpsForLogsEntry.Fqdn)`") is not reachable on port 9543. Check VPN/network connectivity, firewall rules, and DNS resolution." }
                    } else {
                        $phases += @{ name = "Aria Operations for Logs Network Reachability ($ariaOpsForLogsLabel)"; status = 'pass'; error = $null }
                        $phases += @{ name = "Aria Operations for Logs Authentication ($ariaOpsForLogsLabel)"; status = 'fail'; error = "Invalid username or password for Aria Operations for Logs (`"$($ariaOpsForLogsEntry.Fqdn)`"). Verify the credential entered for this endpoint." }
                    }
                }
                Write-CredentialCheckProgress -Phases $phases
            }
            Remove-Variable -Name ariaOpsForLogsCredentialsJson, ariaOpsForLogsCredentialEntries, ariaOpsForLogsSecurePassword, ariaOpsForLogsCredential -ErrorAction SilentlyContinue
        }
    } catch {
        $errorMsg = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Authentication failed: SDDC Manager `"$SddcManagerFqdn`" - $errorMsg"

        if ($errorMsg -match 'Could not reach.*on port \d+') {
            Set-CredentialCheckPhase -Name 'Network Reachability' -Status 'fail' -ErrorMessage 'SDDC Manager is not reachable on port 443. Check VPN/network connectivity, firewall rules, and DNS resolution.'
        } elseif ($errorMsg -match '(?i)UNAUTHORIZED|not authorized|invalid credentials|incorrect.*password|authentication failed|401') {
            Set-CredentialCheckPhase -Name 'Network Reachability' -Status 'pass'
            Set-CredentialCheckPhase -Name 'SDDC Manager Authentication' -Status 'fail' -ErrorMessage 'Invalid username or password. Verify your SDDC Manager credentials.'
        } else {
            Set-CredentialCheckPhase -Name 'Network Reachability' -Status 'pass'
            Set-CredentialCheckPhase -Name 'SDDC Manager Authentication' -Status 'fail' -ErrorMessage 'Check your network connectivity and SDDC Manager credentials.'
        }

        @{
            success = $false
            error   = $null
            phases  = $phases
        } | ConvertTo-Json -Compress
        exit 1
    }

    $rootPasswordPlainText = $env:VCFCHECK_ROOT_PASSWORD
    if (-not [String]::IsNullOrEmpty($rootPasswordPlainText)) {
        $rootPassword = ConvertTo-SecureString -String $rootPasswordPlainText -AsPlainText -Force
        $rootCredential = [PSCredential]::new('root', $rootPassword)

        Write-LogMessage -Type INFO -Message "Starting SDDC Manager root credential validation for `"$SddcManagerFqdn`"."
        Write-LogMessage -Type INFO -Message "Resolving management domain vCenter and connecting..."

        try {
            $vcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
            Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
            Write-LogMessage -Type DEBUG -Message "Connected to management vCenter `"$vcenterFqdn`"."

            $vcenterVersion = ($global:DefaultVIServers | Where-Object { $_.Name -eq $vcenterFqdn } | Select-Object -First 1).Version
            Write-LogMessage -Type INFO -Message "vCenter `"$vcenterFqdn`" version: $vcenterVersion."
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to resolve/connect to management vCenter: $($_.Exception.Message)"
            Set-CredentialCheckPhase -Name 'VMware Tools Status' -Status 'fail' -ErrorMessage 'Could not connect to the management vCenter. Verify SDDC Manager connection and management domain configuration.'
            @{
                success = $false
                error   = $null
                phases  = $phases
                domains = $domains
            } | ConvertTo-Json -Compress
            exit 1
        }

        $vmName = ($SddcManagerFqdn -split '\.')[0]
        $esxHostCheck = Test-VcfCheckEsxHostConnectivity -Context $Context -VcenterFqdn $vcenterFqdn -VmName $vmName -TimeoutSeconds $ConnectivityTimeoutSeconds

        # Evaluate ESX host reachability if host object resolution succeeded.
        if ($esxHostCheck.Hostname) {
            if (-not $esxHostCheck.Success) {
                Write-LogMessage -Type WARNING -Message "ESX host connectivity check failed: $($esxHostCheck.Error)"
                Set-CredentialCheckPhase -Name 'ESX Host Connectivity' -Status 'fail' -ErrorMessage $esxHostCheck.Error
                Set-CredentialCheckPhase -Name 'VMware Tools Status' -Status 'fail' -ErrorMessage 'Could not verify ESX host connectivity. Resolve ESX host issues before retrying.'
                @{
                    success = $false
                    error   = $null
                    phases  = $phases
                    domains = $domains
                } | ConvertTo-Json -Compress
                exit 1
            }
            Write-LogMessage -Type INFO -Message "ESX host `"$($esxHostCheck.Hostname)`" is reachable on required ports."
            Set-CredentialCheckPhase -Name 'ESX Host Connectivity' -Status 'pass'
        }

        # OnToolsRunning fires as soon as VMware Tools is confirmed running on the appliance,
        # before the guest command that verifies the root credential itself is attempted - lets
        # the UI flip "VMware Tools Status" to pass without waiting on root authentication too.
        $rootCheck = Test-VcfCheckSddcManagerRootCredential -Context $Context -RootCredential $rootCredential `
            -OnToolsRunning { Set-CredentialCheckPhase -Name 'VMware Tools Status' -Status 'pass' }
        Write-LogMessage -Type INFO -Message "Root credential validation completed. Success=$($rootCheck.Success)"

        if ($rootCheck.Success) {
            Write-LogMessage -Type INFO -Message "Root credential verified: SDDC Manager `"$SddcManagerFqdn`"."
            Set-CredentialCheckPhase -Name 'VMware Tools Status' -Status 'pass'
            Set-CredentialCheckPhase -Name 'SDDC Manager Root Authentication' -Status 'pass'
        } else {
            Write-LogMessage -Type WARNING -Message "Root credential check failed: SDDC Manager `"$SddcManagerFqdn`" - $($rootCheck.ErrorMessage)"

            if ($rootCheck.ErrorMessage -match 'The SSL connection could not be established') {
                Set-CredentialCheckPhase -Name 'VMware Tools Status' -Status 'fail' -ErrorMessage 'SSL connection to vCenter failed. Check your Set-PowerCLIConfiguration InvalidCertificateAction setting.'
            } elseif ($rootCheck.ErrorMessage -match 'Failed to authenticate with the guest operating system') {
                Set-CredentialCheckPhase -Name 'VMware Tools Status' -Status 'pass'
                Set-CredentialCheckPhase -Name 'SDDC Manager Root Authentication' -Status 'fail' -ErrorMessage 'Invalid root password. Verify the SDDC Manager appliance root password.'
            } elseif ($rootCheck.ErrorMessage -match 'VMware Tools is not running' -or $rootCheck.ErrorCategory -eq 'ToolsNotRunning') {
                Set-CredentialCheckPhase -Name 'VMware Tools Status' -Status 'fail' -ErrorMessage 'VMware Tools is not running on the SDDC Manager appliance.'
            } else {
                Set-CredentialCheckPhase -Name 'VMware Tools Status' -Status 'fail' -ErrorMessage $rootCheck.ErrorMessage
            }

            @{
                success = $false
                error   = $null
                phases  = $phases
                domains = $domains
            } | ConvertTo-Json -Compress
            exit 1
        }
    }

    @{
        success = $true
        error   = $null
        phases  = $phases
        domains = $domains
    } | ConvertTo-Json -Compress
    exit 0
} catch {
    Write-LogMessage -Type ERROR -Message "Credential validation failed: $($_.Exception.Message)"
    if ($phases.Count -eq 0) {
        $phases = @(
            @{ name = 'Network Reachability'; status = 'fail'; error = 'Unexpected error during network check.' }
        )
    }
    @{
        success = $false
        error   = $null
        phases  = $phases
    } | ConvertTo-Json -Compress
    exit 1
} finally {
    $sddcPasswordPlainText = $null
    $rootPasswordPlainText = $null
    $env:VCFCHECK_ARIAOPS_CREDENTIALS_JSON = $null
    $env:VCFCHECK_ARIAAUTOMATION_CREDENTIALS_JSON = $null
    $env:VCFCHECK_ARIAOPSFORLOGS_CREDENTIALS_JSON = $null
    if ($Context) { Disconnect-VcfCheckAll -Context $Context }
    Remove-Variable -Name sddcPasswordPlainText, rootPasswordPlainText, sddcPassword, rootPassword -ErrorAction SilentlyContinue
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
