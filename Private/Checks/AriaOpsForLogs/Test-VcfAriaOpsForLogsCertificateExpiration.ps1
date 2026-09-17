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
#region AriaOpsForLogs
function Test-VcfAriaOpsForLogsCertificateExpiration {

    <#
        .SYNOPSIS
        Verifies that Aria Operations for Logs' appliance certificate is not expired or close to
        expiring.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsForLogsTargets to connect to every Aria Operations for Logs instance
        declared on the environment (see Private/AriaOpsForLogsHelpers.ps1) and calls
        Get-VcfCheckAriaOpsForLogsCertificate (GET /api/v2/certificate) against each, returning one
        result per target. Parses the certificate's validityPeriod.until date and compares it
        against WarningThresholdDays.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations for Logs instance is known at all.
        - Pass: Returns 'Pass' for a target if the certificate expires more than
          WarningThresholdDays away.
        - Warning: Returns 'Warning' for a target if the certificate is expired or expiring within
          WarningThresholdDays, or if its expiration date could not be parsed.
        - Error: Returns 'Error' for a target if connecting or querying it fails.

        Unlike Aria Operations' certificate inventory, this product's API exposes no SAN or
        signature-algorithm field - only owner/issuer distinguished names and a validity period -
        so this check evaluates expiration only.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .PARAMETER WarningThresholdDays
        Number of days before expiry to raise a Warning instead of a Pass. Default 30.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Operations for Logs instance.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateRange(1, 3650)] [Int]$WarningThresholdDays = 30
    )

    $startedAt = Get-Date
    $checkId = 'aria_ops_for_logs_certificate_expiration'

    $targets = Get-VcfCheckAriaOpsForLogsTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Operations for Logs is not deployed in this environment.' -SkipReasonTag 'Aria Operations for Logs not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Operations for Logs'
    }

    $now = Get-Date

    $results = foreach ($target in $targets) {
        $resultDisplayName = if ($targets.Count -gt 1) { "$DisplayName ($($target.Name))" } else { $DisplayName }

        if ($target.ConnectError) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception $target.ConnectError `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        try {
            $certificate = Get-VcfCheckAriaOpsForLogsCertificate -Session $target.Session
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for Logs for certificate details: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        if (-not $certificate) {
            New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $target.Fqdn `
                -Detail 'No certificate information was returned by Aria Operations for Logs.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        $commonName = $certificate.owner.commonName
        $issuedBy = $certificate.issuer.commonName
        $expiresRaw = $certificate.validityPeriod.until

        $expiryDate = Get-Date
        $parsed = [DateTime]::TryParse($expiresRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiryDate)

        if (-not $parsed) {
            $row = [PSCustomObject]@{ CommonName = $commonName; IssuedBy = $issuedBy; ExpiryDate = $expiresRaw; DaysRemaining = 'Unknown'; Status = 'Warning' }
            $status = 'Warning'
            $detail = "$commonName`: unparseable expiration date `"$expiresRaw`""
        } else {
            $daysRemaining = [Math]::Floor(($expiryDate - $now).TotalDays)
            if ($expiryDate -lt $now) {
                $status = 'Warning'
                $detail = "$commonName expired on $expiryDate"
            } elseif ($expiryDate -lt $now.AddDays($WarningThresholdDays)) {
                $status = 'Warning'
                $detail = "$commonName expires on $expiryDate ($daysRemaining day(s) remaining)"
            } else {
                $status = 'Pass'
                $detail = "The certificate for `"$commonName`" expires more than $WarningThresholdDays day(s) from now."
            }
            $row = [PSCustomObject]@{ CommonName = $commonName; IssuedBy = $issuedBy; ExpiryDate = $expiryDate; DaysRemaining = [Math]::Max(0, $daysRemaining); Status = $status }
        }

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows @($row) `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
    }

    return @($results)
}
#endregion
