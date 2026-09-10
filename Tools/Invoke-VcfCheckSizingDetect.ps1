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
    Command-line entry point for executing live vCenter sizing auto-detection against an SDDC Manager environment.

    .DESCRIPTION
    Connects to SDDC Manager, resolves management and workload domain vCenter appliances, and collects live host counts,
    virtual machine counts, appliance sizing specifications, and vSphere Supervisor presence.

    Reads SDDC Manager credentials directly from process environment variables (`VCFCHECK_SDDC_PASSWORD`) and returns
    a compressed JSON payload to stdout containing:
    - `managementDomainVCenter`: Sizing snapshot for the management domain vCenter appliance.
    - `workloadDomainVCenters`: Array of sizing snapshots for deployed workload domain vCenter appliances.

    Each snapshot details:
    - Current host and virtual machine inventory counts.
    - Active vSphere Supervisor deployment state.
    - Measured appliance VM specifications (vCPU, RAM, storage).
    - Matched VCSA deployment size tiers and storage preset keys.
    - Recommended deployment size tiers for upgrade capacity planning.

    On failure, outputs a JSON error payload (`{"error": "message"}`) and exits with code 1.

    .PARAMETER SddcManagerFqdn
    Fully qualified domain name of the SDDC Manager appliance.

    .PARAMETER SddcManagerUser
    Username for SDDC Manager authentication.

    .PARAMETER ConnectivityTimeoutSeconds
    Maximum duration in seconds to wait for SDDC Manager network connectivity verification. Defaults to 30 seconds.

    .NOTES
    Acts as the entry point contract for sizing detection execution.

    .EXAMPLE
    pwsh -NoProfile -NonInteractive -File Invoke-VcfCheckSizingDetect.ps1 -SddcManagerFqdn sddc.example.com -SddcManagerUser administrator@vsphere.local
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
    @{ error = "Could not load the VcfCheck module from `"$modulePath`": $($_.Exception.Message)" } | ConvertTo-Json -Compress
    exit 1
}

try {
    Initialize-VcfCheckLogging | Out-Null
} catch {
    # Logging is best-effort here - detection must still work when $env:VcfCheckBaseDirectory
    # is unset (e.g. a first-run environment) - so this is written to the error stream rather
    # than aborting, and there is nowhere else to report it since logging itself failed to init.
    Write-Verbose "Sizing detection: could not initialize logging: $($_.Exception.Message)"
}

$sddcPasswordPlainText = $env:VCFCHECK_SDDC_PASSWORD
if ([String]::IsNullOrEmpty($sddcPasswordPlainText)) {
    Write-LogMessage -Type ERROR -Message 'Sizing detection aborted: VCFCHECK_SDDC_PASSWORD environment variable was not set.'
    @{ error = 'VCFCHECK_SDDC_PASSWORD environment variable was not set.' } | ConvertTo-Json -Compress
    exit 1
}

$sddcPassword = $null
$Context = $null

try {
    $sddcPassword = ConvertTo-SecureStringForCredential -PlainText $sddcPasswordPlainText
    $Context = New-VcfCheckContext
    $Context.AllowInsecureTls = Resolve-VcfCheckAllowInsecureTls

    Write-LogMessage -Type INFO -Message "Sizing detection: connecting to SDDC Manager `"$SddcManagerFqdn`" as `"$SddcManagerUser`"."
    Write-VcfCheckSizingProgress -Step 'connecting to SDDC Manager' -VCenterFqdn $SddcManagerFqdn
    Connect-VcfCheckSddcManager -Context $Context -Fqdn $SddcManagerFqdn -User $SddcManagerUser -Password $sddcPassword `
        -IgnoreInvalidCertificate:$Context.AllowInsecureTls -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds

    $managementDomainName = (Get-VcfCheckManagementDomain -Context $Context).Name
    $managementVCenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
    $allVCenterFqdns = @(Get-VcfCheckAllVCenterFqdns -Context $Context)
    $treatmentData = Get-VcfCheckBrownfieldTreatmentData

    Write-LogMessage -Type INFO -Message "Sizing detection: connecting to management domain `"$managementDomainName`" vCenter `"$managementVCenterFqdn`"."
    Write-VcfCheckSizingProgress -Step 'connecting to vCenter' -DomainName $managementDomainName -VCenterFqdn $managementVCenterFqdn
    Connect-VcfCheckVCenter -Context $Context -Fqdn $managementVCenterFqdn
    $managementSnapshot = Get-VcfCheckSizingSnapshotForVCenter -DomainName $managementDomainName -VCenterFqdn $managementVCenterFqdn -ApplianceInventoryServers @($managementVCenterFqdn) -TreatmentData $treatmentData

    $workloadDomainSnapshots = @()
    foreach ($workloadVCenterFqdn in ($allVCenterFqdns | Where-Object { $_ -ne $managementVCenterFqdn })) {
        $workloadDomainName = Get-VcfCheckVCenterDomainName -Context $Context -Fqdn $workloadVCenterFqdn
        Write-LogMessage -Type INFO -Message "Sizing detection: connecting to workload domain `"$workloadDomainName`" vCenter `"$workloadVCenterFqdn`"."
        Write-VcfCheckSizingProgress -Step 'connecting to vCenter' -DomainName $workloadDomainName -VCenterFqdn $workloadVCenterFqdn
        Connect-VcfCheckVCenter -Context $Context -Fqdn $workloadVCenterFqdn

        # VCF deploys every vCenter appliance, including workload domain ones, onto the
        # management domain's cluster, so the workload vCenter's own appliance VM is normally
        # only visible in the management vCenter's inventory, not its own - search there first.
        $workloadDomainSnapshots += Get-VcfCheckSizingSnapshotForVCenter -DomainName $workloadDomainName -VCenterFqdn $workloadVCenterFqdn -ApplianceInventoryServers @($managementVCenterFqdn, $workloadVCenterFqdn) -TreatmentData $treatmentData
    }

    @{
        managementDomainVCenter = $managementSnapshot
        workloadDomainVCenters  = $workloadDomainSnapshots
    } | ConvertTo-Json -Compress -Depth 5
    exit 0
} catch {
    $errorMsg = $_.Exception.Message
    Write-LogMessage -Type ERROR -Message "Sizing detection failed for `"$SddcManagerFqdn`": $errorMsg"
    @{ error = $errorMsg } | ConvertTo-Json -Compress
    exit 1
} finally {
    $sddcPasswordPlainText = $null
    if ($Context) { Disconnect-VcfCheckAll -Context $Context }
    Remove-Variable -Name sddcPasswordPlainText, sddcPassword -ErrorAction SilentlyContinue
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
