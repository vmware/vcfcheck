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
function Test-VcfSddcCheckLicenseKey {

    <#
        .SYNOPSIS
        Checks all VCF-managed license keys for expiration.

        .DESCRIPTION
        Queries all VCF-managed license keys via Invoke-VcfGetLicenseKeys (VCF.PowerCLI) and
        inspects each key's validity and expiration details (LicenseKeyValidity.ExpiryDate).

        Evaluates license keys against configured thresholds:
        - Expired: Returns Fail if any license key's expiration date is in the past.
        - Expiring Soon: Returns Warning if any key expires within the specified WarningThresholdDays.
        - Pass: Returns Pass if all keys are valid and outside the warning window.

        Outputs a structured Rows breakdown table listing ProductType, Description, Status,
        ExpiryDate, and DaysRemaining for every evaluated key. Keys without an expiration date
        (such as perpetual licenses reporting "NEVER_EXPIRES") display "Never expires". For security,
        raw license key strings are omitted from output details.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER WarningThresholdDays
        Number of days before expiry to raise a Warning instead of a Pass. Default 30.

        .OUTPUTS
        [PSObject] a VcfCheck.Result.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateRange(1, 3650)] [Int]$WarningThresholdDays = 30
    )

    $startedAt = Get-Date
    $checkId = 'sddc_check_license_key'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }
    $validationCriteria = $catalogEntry.validationCriteria

    try {
        $licenseKeys = @((Invoke-VcfGetLicenseKeys -ErrorAction Stop).Elements)
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $Context.SddcManagerFqdn -Exception $_.Exception.Message `
            -ValidationCriteria $validationCriteria -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $now = Get-Date
    $expired = [System.Collections.Generic.List[String]]::new()
    $expiringSoon = [System.Collections.Generic.List[String]]::new()
    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($licenseKey in $licenseKeys) {
        $expiryDate = $licenseKey.LicenseKeyValidity.ExpiryDate
        $label = if ([String]::IsNullOrWhiteSpace($licenseKey.Description)) {
            $licenseKey.ProductType
        } else {
            "$($licenseKey.ProductType) ($($licenseKey.Description))"
        }

        if (-not $expiryDate) {
            $rows.Add([PSCustomObject]@{
                    ProductType   = $licenseKey.ProductType
                    Description   = $licenseKey.Description
                    Status        = 'Never expires'
                    ExpiryDate    = 'N/A'
                    DaysRemaining = 'N/A'
                })
            continue
        }

        $expiryDateTime = [DateTime]$expiryDate
        $daysRemaining = [Math]::Ceiling(($expiryDateTime - $now).TotalDays)

        if ($expiryDateTime -lt $now) {
            $expired.Add($label)
            $rowStatus = 'Expired'
        } elseif ($expiryDateTime -lt $now.AddDays($WarningThresholdDays)) {
            $expiringSoon.Add($label)
            $rowStatus = 'Expiring soon'
        } else {
            $rowStatus = 'OK'
        }

        $rows.Add([PSCustomObject]@{
                ProductType   = $licenseKey.ProductType
                Description   = $licenseKey.Description
                Status        = $rowStatus
                ExpiryDate    = $expiryDateTime.ToString('yyyy-MM-dd')
                DaysRemaining = $daysRemaining
            })
    }

    if ($expired.Count -gt 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Fail `
            -TargetComponent $Context.SddcManagerFqdn -Detail "Expired license key(s): $($expired -join '; ')" `
            -Rows $rows.ToArray() -ValidationCriteria $validationCriteria -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    if ($expiringSoon.Count -gt 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Warning `
            -TargetComponent $Context.SddcManagerFqdn -Detail "License key(s) expiring within $WarningThresholdDays day(s): $($expiringSoon -join '; ')" `
            -Rows $rows.ToArray() -ValidationCriteria $validationCriteria -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    return New-VcfCheckResult -CheckId $checkId -Status Pass `
        -TargetComponent $Context.SddcManagerFqdn -Detail "Checked $($licenseKeys.Count) license key(s); none expired or expiring soon." `
        -Rows $rows.ToArray() -ValidationCriteria $validationCriteria -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
}
