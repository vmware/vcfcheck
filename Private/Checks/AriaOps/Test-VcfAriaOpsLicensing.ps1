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
#region AriaOps
function Test-VcfAriaOpsLicensing {

    <#
        .SYNOPSIS
        Reports Aria Operations' license entitlement (edition, capacity/usage, license type,
        expiration) and warns on an expired or soon-to-expire non-perpetual license.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsTargets to connect to every known Aria Operations instance (the
        SDDC-Manager-known one, plus any standalone endpoint declared on the environment - see
        Private/AriaOpsHelpers.ps1) and calls a new Get-VcfCheckAriaOpsLicenseEntitlement (a REST
        fallback wrapper around '/suite-api/api/product/licensing/entitlement' - no
        VMware.Sdk.Vcf.Ops cmdlet covers this endpoint) against each, returning one result per
        target.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations instance is known at all.
        - Pass: Returns 'Pass' for a target if no license expires within WarningThresholdDays (a
          'PERMANENT' license type is never flagged, regardless of its reported expirationDate).
        - Warning: Returns 'Warning' for a target if a non-'PERMANENT' license is expired or
          expiring within WarningThresholdDays.
        - Error: Returns 'Error' for a target if connecting or querying it fails.

        Builds a detailed breakdown table ('Rows') of every license's expiration date (normalized
        to yyyy-MM-dd), capacity, edition, license type, statuses, and license key. A real key
        (a single token with no whitespace) has its last four characters redacted as 'X'; an
        EVALUATION license's 'licenseKey' is a product description rather than a key (e.g.
        'Evaluation - VMware vRealize Operations Management Suite') and is left untouched since
        there is no key material in it to redact. The suite-api's licensing entitlement endpoint
        does not return a usage figure - actual usage is only reported as free text inside
        'statuses' (e.g. 'Only powered on VMs will count towards the license usage').

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .PARAMETER WarningThresholdDays
        Number of days before expiry to raise a Warning instead of a Pass, for a non-'PERMANENT'
        license. Default 30.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Operations instance.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateRange(1, 3650)] [Int]$WarningThresholdDays = 30
    )

    $startedAt = Get-Date
    $checkId = 'aria_ops_license'

    $targets = Get-VcfCheckAriaOpsTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Operations is not deployed in this environment.' -SkipReasonTag 'Aria Operations not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Operations'
    }

    $now = Get-Date

    $results = foreach ($target in $targets) {
        $resultDisplayName = if ($targets.Count -gt 1) { "$DisplayName ($($target.Name))" } else { $DisplayName }

        if ($target.ConnectError) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception $target.ConnectError `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        try {
            $response = Get-VcfCheckAriaOpsLicenseEntitlement -CredentialInfo $target.CredentialInfo
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for license entitlement: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $licenses = @($response.solutionLicenses)
        if ($licenses.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $target.Fqdn `
                -Detail 'No license entitlement information was returned by Aria Operations.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $flagged = [System.Collections.Generic.List[String]]::new()

        foreach ($license in $licenses) {
            $expirationDate = [DateTimeOffset]::FromUnixTimeMilliseconds($license.expirationDate).UtcDateTime
            $daysRemaining = [Math]::Floor(($expirationDate - $now).TotalDays)
            $statuses = ($license.statuses) -join '; '

            $redactedLicenseKey = $null
            if ($null -ne $license.licenseKey) {
                $licenseKey = ([String]$license.licenseKey).Trim()
                if ($licenseKey -match '\s') {
                    $redactedLicenseKey = $licenseKey
                } else {
                    $visibleLength = [Math]::Max(0, $licenseKey.Length - 4)
                    $redactedLicenseKey = $licenseKey.Substring(0, $visibleLength) + ('X' * ($licenseKey.Length - $visibleLength))
                }
            }

            $rows.Add([PSCustomObject]@{
                ExpirationDate = $expirationDate.ToString('yyyy-MM-dd')
                Capacity       = if ($null -ne $license.capacity) { ([String]$license.capacity).Trim() } else { $null }
                Edition        = $license.edition
                LicenseType    = $license.licenseType
                LicenseKey     = $redactedLicenseKey
                Statuses       = $statuses
            })

            if ($license.licenseType -eq 'PERMANENT') {
                continue
            }
            if ($expirationDate -lt $now) {
                $flagged.Add("$($license.edition) license expired on $($expirationDate.ToString('yyyy-MM-dd'))")
            } elseif ($expirationDate -lt $now.AddDays($WarningThresholdDays)) {
                $flagged.Add("$($license.edition) license expires on $($expirationDate.ToString('yyyy-MM-dd')) ($daysRemaining day(s) remaining)")
            }
        }

        if ($flagged.Count -eq 0) {
            $status = 'Pass'
            $detail = "All $($licenses.Count) Aria Operations license(s) are permanent or expire more than $WarningThresholdDays day(s) from now."
        } else {
            $status = 'Warning'
            $detail = ($flagged.ToArray()) -join '; '
        }

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows $rows.ToArray() `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
    }

    return @($results)
}
#endregion
