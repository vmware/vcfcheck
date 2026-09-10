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
    Diagnoses credential mismatch results from Test-VcfVrslcmValidateVcenterCredentials by inspecting all locker entries for a vCenter username.

    .DESCRIPTION
    Queries all locker password entries stored in Aria Suite Lifecycle Manager for a target vCenter username via
    `/lcm/locker/api/passwords`.

    Decrypts each matching locker entry using appliance root credentials via `/lcm/locker/api/passwords/view/{vmid}` and
    validates the decrypted password directly against the target vCenter Server REST session endpoint (`https://{VcHost}/rest/com/vmware/cis/session`).

    Distinguishes genuine password mismatches from false positives caused by duplicate or stale locker entries for the same username.

    Connects to SDDC Manager to retrieve registered Aria Suite Lifecycle Manager connection details and appliance root credentials.

    .PARAMETER SddcManagerFqdn
    Fully qualified domain name of the SDDC Manager appliance.

    .PARAMETER SddcManagerUser
    Username for SDDC Manager authentication.

    .PARAMETER Username
    The target vCenter account username to inspect in Aria Suite Lifecycle Manager locker entries.

    .PARAMETER VcHost
    Fully qualified domain name or IP address of the target vCenter Server to validate credentials against.

    .NOTES
    Reads SDDC Manager password credentials directly from process environment variable `VCFCHECK_SDDC_PASSWORD`.

    .EXAMPLE
    $env:VCFCHECK_SDDC_PASSWORD = '...'
    pwsh -NoProfile -NonInteractive -File Invoke-VcfCheckVrslcmLockerDiagnostic.ps1 `
        -SddcManagerFqdn m01-sddcmgr01.example.com -SddcManagerUser administrator@vsphere.local `
        -Username svc-xint-lcm01-m01-vc01@vsphere.local -VcHost m01-vc01.example.com
#>

[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SddcManagerFqdn,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SddcManagerUser,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Username,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcHost
)

if ($null -ne $PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

$modulePath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'VcfCheck.psd1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

$sddcPasswordPlainText = $env:VCFCHECK_SDDC_PASSWORD
if ([String]::IsNullOrEmpty($sddcPasswordPlainText)) {
    Write-Error 'VCFCHECK_SDDC_PASSWORD environment variable was not set.'
    exit 1
}

$Context = $null
try {
    $sddcPassword = ConvertTo-SecureString -String $sddcPasswordPlainText -AsPlainText -Force
    $Context = New-VcfCheckContext
    $Context.AllowInsecureTls = Resolve-VcfCheckAllowInsecureTls
    Connect-VcfCheckSddcManager -Context $Context -Fqdn $SddcManagerFqdn -User $SddcManagerUser -Password $sddcPassword `
        -IgnoreInvalidCertificate:$Context.AllowInsecureTls

    $connection = Get-VcfCheckVrslcmConnection -Context $Context
    if (-not $connection) {
        Write-Error 'Aria Suite Lifecycle Manager is not registered with this SDDC Manager.'
        exit 1
    }

    $rootCredential = Get-VcfCheckVrslcmRootCredential -Context $Context
    if (-not $rootCredential) {
        Write-Error 'SDDC Manager returned no root (SSH) credential for Aria Suite Lifecycle Manager.'
        exit 1
    }
    $rootPassword = $rootCredential.GetNetworkCredential().Password

    $lockerEntries = @(Invoke-VcfCheckVrslcmApi -Connection $connection -Path '/lcm/locker/api/passwords')
    $matchingEntries = @($lockerEntries | Where-Object { $_.userName -eq $Username })

    Write-Host "Found $($matchingEntries.Count) locker entry(ies) for username `"$Username`" in Aria Suite Lifecycle Manager `"$($connection.Fqdn)`"." -ForegroundColor Cyan
    if ($matchingEntries.Count -eq 0) {
        exit 0
    }
    if ($matchingEntries.Count -gt 1) {
        Write-Host "More than one locker entry exists for this username - validation checks evaluate the first entry returned, so stale duplicate entries may conceal valid credentials." -ForegroundColor Yellow
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    for ($i = 0; $i -lt $matchingEntries.Count; $i++) {
        $entry = $matchingEntries[$i]
        $vmid = @($entry.vmid) | Select-Object -First 1
        $outcome = 'Unvalidated'
        $note = $null

        if ([String]::IsNullOrWhiteSpace($vmid)) {
            $note = 'Missing vmid.'
        } else {
            try {
                $passwordResponse = Invoke-VcfCheckVrslcmApi -Connection $connection -Method POST `
                    -Path "/lcm/locker/api/passwords/view/$vmid" -Body @{ rootPassword = $rootPassword }
            } catch {
                $passwordResponse = $null
                $note = "Decrypt call failed: $($_.Exception.Message)"
            }

            if ($passwordResponse -and $passwordResponse.password) {
                $credential = [PSCredential]::new($Username, (ConvertTo-SecureStringForCredential -PlainText $passwordResponse.password))
                try {
                    Invoke-RestMethod -Uri "https://$VcHost/rest/com/vmware/cis/session" -Method POST `
                        -Credential $credential -Authentication Basic -SkipCertificateCheck:$Context.AllowInsecureTls -TimeoutSec 10 -ErrorAction Stop | Out-Null
                    $outcome = 'MatchesVCenter'
                } catch {
                    $outcome = 'DoesNotMatchVCenter'
                    $note = $_.Exception.Message
                }
                Remove-Variable -Name credential -ErrorAction SilentlyContinue
            } elseif (-not $note) {
                $note = 'Decrypt call returned no password.'
            }
            Remove-Variable -Name passwordResponse -ErrorAction SilentlyContinue
        }

        $results.Add([PSCustomObject]@{
            Index   = $i
            Vmid    = $vmid
            Outcome = $outcome
            Note    = $note
        })
    }

    $results | Format-Table -AutoSize | Out-Host

    if (@($results | Where-Object { $_.Outcome -eq 'MatchesVCenter' }).Count -gt 0) {
        Write-Host "At least one locker entry's decrypted password IS accepted by `"$VcHost`" - if CredentialMismatch was reported, a different duplicate entry was likely evaluated." -ForegroundColor Green
    } else {
        Write-Host "No locker entry's decrypted password was accepted by `"$VcHost`" - this indicates a genuine credential mismatch." -ForegroundColor Red
    }
} finally {
    $sddcPasswordPlainText = $null
    if ($Context) { Disconnect-VcfCheckAll -Context $Context }
    Remove-Variable -Name sddcPasswordPlainText, sddcPassword, rootPassword, rootCredential -ErrorAction SilentlyContinue
}
