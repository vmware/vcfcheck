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
function Test-VcfAriaOpsCertificateExpiration {

    <#
        .SYNOPSIS
        Verifies that every certificate registered with Aria Operations is not expired or
        close to expiring.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsTargets to connect to every known Aria Operations instance (the
        SDDC-Manager-known one, plus any standalone endpoint declared on the environment - see
        Private/AriaOpsHelpers.ps1) and calls Get-VcfCheckAriaOpsCertificates (a thin wrapper
        around Invoke-VcfOpsGetAllCertificates) against each, returning one result per target.
        Parses each certificate's Expires date and compares it against WarningThresholdDays.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations instance is known at all.
        - Pass: Returns 'Pass' for a target if every certificate expires more than
          WarningThresholdDays away.
        - Warning: Returns 'Warning' for a target if one or more certificates are expired or
          expiring within WarningThresholdDays, or if a certificate's Expires date could not be
          parsed.
        - Error: Returns 'Error' for a target if connecting or querying it fails.

        Builds a detailed breakdown table ('Rows') of every certificate's IssuedTo, IssuedBy,
        ExpiryDate, DaysRemaining, and Status.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .PARAMETER WarningThresholdDays
        Number of days before expiry to raise a Warning instead of a Pass. Default 30.

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
    $checkId = 'aria_ops_certificate_expiration'

    $targets = Get-VcfCheckAriaOpsTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Operations is not deployed in this environment.' -SkipReasonTag 'Aria Operations not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Operations'
    }

    $now = Get-Date
    $exactFormats = @('ddd MMM dd HH:mm:ss \U\T\C yyyy')

    $results = foreach ($target in $targets) {
        $resultDisplayName = if ($targets.Count -gt 1) { "$DisplayName ($($target.Name))" } else { $DisplayName }

        if ($target.ConnectError) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception $target.ConnectError `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        try {
            $response = Get-VcfCheckAriaOpsCertificates -Connection $target.Connection
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for certificate details: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $certificates = @($response._Certificates)
        if ($certificates.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $target.Fqdn `
                -Detail 'No certificates were found registered with Aria Operations.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
            continue
        }

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $flagged = [System.Collections.Generic.List[String]]::new()

        foreach ($certificate in $certificates) {
            $expiryDate = Get-Date
            $parsed = [DateTime]::TryParseExact($certificate.Expires, $exactFormats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiryDate)
            if (-not $parsed) {
                $parsed = [DateTime]::TryParse($certificate.Expires, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiryDate)
            }
            if (-not $parsed) {
                $rows.Add([PSCustomObject]@{ IssuedTo = $certificate.IssuedTo; IssuedBy = $certificate.IssuedBy; ExpiryDate = $certificate.Expires; DaysRemaining = 'Unknown'; Status = 'Warning' })
                $flagged.Add("$($certificate.IssuedTo): unparseable expiration date `"$($certificate.Expires)`"")
                continue
            }

            $daysRemaining = [Math]::Floor(($expiryDate - $now).TotalDays)
            $certStatus = 'Pass'
            if ($expiryDate -lt $now) {
                $certStatus = 'Warning'
                $flagged.Add("$($certificate.IssuedTo) expired on $expiryDate")
            } elseif ($expiryDate -lt $now.AddDays($WarningThresholdDays)) {
                $certStatus = 'Warning'
                $flagged.Add("$($certificate.IssuedTo) expires on $expiryDate ($daysRemaining day(s) remaining)")
            }

            $rows.Add([PSCustomObject]@{ IssuedTo = $certificate.IssuedTo; IssuedBy = $certificate.IssuedBy; ExpiryDate = $expiryDate; DaysRemaining = [Math]::Max(0, $daysRemaining); Status = $certStatus })
        }

        if ($flagged.Count -eq 0) {
            $status = 'Pass'
            $detail = "All $($certificates.Count) certificate(s) registered with Aria Operations expire more than $WarningThresholdDays day(s) from now."
        } else {
            $status = 'Warning'
            $detail = ($flagged.ToArray()) -join '; '
        }

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows ($rows.ToArray() | Sort-Object -Property IssuedBy) `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations'
    }

    return @($results)
}
#endregion
