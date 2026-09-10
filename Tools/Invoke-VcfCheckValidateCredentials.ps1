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
    on the environment via `Connect-VcfCheckAriaOpsEndpoint`.

    Outputs a structured JSON payload to stdout detailing validation status, execution phases, and discovered domains:
    - `success`: Boolean indicating overall credential validation success.
    - `error`: Error message string if validation failed at the top level.
    - `phases`: Array of validation phase results (Network Reachability, SDDC Manager Authentication,
      Aria Suite Lifecycle Manager Connectivity, Aria Operations Network Reachability/Authentication per
      endpoint, ESX Host Connectivity, VMware Tools Status, SDDC Manager Root Authentication).
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

$sddcPassword = $null
$rootPassword = $null
$Context = $null
$phases = @()
$domains = @()

try {
    $sddcPassword = ConvertTo-SecureString -String $sddcPasswordPlainText -AsPlainText -Force
    $Context = New-VcfCheckContext
    $Context.AllowInsecureTls = Resolve-VcfCheckAllowInsecureTls

    Write-LogMessage -Type INFO -Message "Checking credentials for SDDC Manager `"$SddcManagerFqdn`" as `"$SddcManagerUser`"."
    try {
        Connect-VcfCheckSddcManager -Context $Context -Fqdn $SddcManagerFqdn -User $SddcManagerUser -Password $sddcPassword `
            -IgnoreInvalidCertificate:$Context.AllowInsecureTls -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
        Write-LogMessage -Type INFO -Message "Authentication successful: SDDC Manager `"$SddcManagerFqdn`"."
        $phases += @{ name = 'Network Reachability'; status = 'pass'; error = $null }
        $phases += @{ name = 'SDDC Manager Authentication'; status = 'pass'; error = $null }

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
                    Connect-VcfCheckAriaOpsEndpoint -Context $Context -Fqdn $ariaOpsEntry.Fqdn -Credential $ariaOpsCredential -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds | Out-Null
                    Write-LogMessage -Type INFO -Message "Authentication successful: Aria Operations `"$($ariaOpsEntry.Fqdn)`"."
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
            }
            Remove-Variable -Name ariaOpsCredentialsJson, ariaOpsCredentialEntries, ariaOpsSecurePassword, ariaOpsCredential -ErrorAction SilentlyContinue
        }
    } catch {
        $errorMsg = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Authentication failed: SDDC Manager `"$SddcManagerFqdn`" - $errorMsg"

        if ($errorMsg -match 'Could not reach.*on port \d+') {
            $phases += @{ name = 'Network Reachability'; status = 'fail'; error = 'SDDC Manager is not reachable on port 443. Check VPN/network connectivity, firewall rules, and DNS resolution.' }
        } elseif ($errorMsg -match '(?i)UNAUTHORIZED|not authorized|invalid credentials|incorrect.*password|authentication failed|401') {
            $phases += @{ name = 'Network Reachability'; status = 'pass'; error = $null }
            $phases += @{ name = 'SDDC Manager Authentication'; status = 'fail'; error = 'Invalid username or password. Verify your SDDC Manager credentials.' }
        } else {
            $phases += @{ name = 'Network Reachability'; status = 'pass'; error = $null }
            $phases += @{ name = 'SDDC Manager Authentication'; status = 'fail'; error = 'Check your network connectivity and SDDC Manager credentials.' }
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
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to resolve/connect to management vCenter: $($_.Exception.Message)"
            $phases += @{ name = 'VMware Tools Status'; status = 'fail'; error = 'Could not connect to the management vCenter. Verify SDDC Manager connection and management domain configuration.' }
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
                $phases += @{ name = 'ESX Host Connectivity'; status = 'fail'; error = $esxHostCheck.Error }
                $phases += @{ name = 'VMware Tools Status'; status = 'fail'; error = 'Could not verify ESX host connectivity. Resolve ESX host issues before retrying.' }
                @{
                    success = $false
                    error   = $null
                    phases  = $phases
                    domains = $domains
                } | ConvertTo-Json -Compress
                exit 1
            }
            Write-LogMessage -Type INFO -Message "ESX host `"$($esxHostCheck.Hostname)`" is reachable on required ports."
            $phases += @{ name = 'ESX Host Connectivity'; status = 'pass'; error = $null }
        }

        $rootCheck = Test-VcfCheckSddcManagerRootCredential -Context $Context -RootCredential $rootCredential
        Write-LogMessage -Type INFO -Message "Root credential validation completed. Success=$($rootCheck.Success)"

        if ($rootCheck.Success) {
            Write-LogMessage -Type INFO -Message "Root credential verified: SDDC Manager `"$SddcManagerFqdn`"."
            $phases += @{ name = 'VMware Tools Status'; status = 'pass'; error = $null }
            $phases += @{ name = 'SDDC Manager Root Authentication'; status = 'pass'; error = $null }
        } else {
            Write-LogMessage -Type WARNING -Message "Root credential check failed: SDDC Manager `"$SddcManagerFqdn`" - $($rootCheck.ErrorMessage)"

            if ($rootCheck.ErrorMessage -match 'The SSL connection could not be established') {
                $phases += @{ name = 'VMware Tools Status'; status = 'fail'; error = 'SSL connection to vCenter failed. Check your Set-PowerCLIConfiguration InvalidCertificateAction setting.' }
            } elseif ($rootCheck.ErrorMessage -match 'Failed to authenticate with the guest operating system') {
                $phases += @{ name = 'VMware Tools Status'; status = 'pass'; error = $null }
                $phases += @{ name = 'SDDC Manager Root Authentication'; status = 'fail'; error = 'Invalid root password. Verify the SDDC Manager appliance root password.' }
            } elseif ($rootCheck.ErrorMessage -match 'VMware Tools is not running' -or $rootCheck.ErrorCategory -eq 'ToolsNotRunning') {
                $phases += @{ name = 'VMware Tools Status'; status = 'fail'; error = 'VMware Tools is not running on the SDDC Manager appliance.' }
            } else {
                $phases += @{ name = 'VMware Tools Status'; status = 'fail'; error = $rootCheck.ErrorMessage }
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
    if ($Context) { Disconnect-VcfCheckAll -Context $Context }
    Remove-Variable -Name sddcPasswordPlainText, rootPasswordPlainText, sddcPassword, rootPassword -ErrorAction SilentlyContinue
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
