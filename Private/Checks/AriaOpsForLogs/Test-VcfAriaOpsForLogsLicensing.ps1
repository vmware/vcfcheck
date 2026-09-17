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
function Test-VcfAriaOpsForLogsLicensing {

    <#
        .SYNOPSIS
        Reports Aria Operations for Logs' license state (per-license status, capacity, expiry)
        and warns on an inactive, error-flagged, or soon-to-expire non-infinite license.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsForLogsTargets to connect to every Aria Operations for Logs instance
        declared on the environment (see Private/AriaOpsForLogsHelpers.ps1) and calls
        'GET /api/v2/licenses' against each, returning one result per target.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Operations for Logs instance is known at all.
        - Pass: Returns 'Pass' for a target if every license is Active, reports no error, and (for
          non-infinite licenses) does not expire within WarningThresholdDays.
        - Warning: Returns 'Warning' for a target if any license is not 'Active', reports a
          non-empty error, or (for a non-infinite license) is expired or expiring within
          WarningThresholdDays.
        - Error: Returns 'Error' for a target if connecting or querying it fails.

        When the response's 'licenses' array is empty (no license key is installed), falls back to
        the response's top-level 'entitlementType'/'entitlement' fields - see
        Get-VcfCheckAriaOpsForLogsEntitlementResult - so a time-limited evaluation or an
        unlicensed instance is reported rather than silently passing with no data.

        Builds a detailed breakdown table ('Rows') of every license's expiration date (normalized
        to yyyy-MM-dd, or 'Infinite' when the license never expires), configuration, status, type,
        and error text. The license key itself is never included in the table.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .PARAMETER WarningThresholdDays
        Number of days before expiry to raise a Warning instead of a Pass, for a non-infinite
        license. Default 30.

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
    $checkId = 'aria_ops_for_logs_license'

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
            $response = Invoke-VcfCheckAriaOpsForLogsApi -Session $target.Session -Path '/api/v2/licenses'
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Operations for Logs for license information: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        $licenses = @($response.licenses)
        if ($licenses.Count -eq 0) {
            $entitlementResult = Get-VcfCheckAriaOpsForLogsEntitlementResult -Response $response -Now $now -WarningThresholdDays $WarningThresholdDays
            New-VcfCheckResult -CheckId $checkId -Status $entitlementResult.Status `
                -TargetComponent $target.Fqdn -Detail $entitlementResult.Detail -Rows $entitlementResult.Rows `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
            continue
        }

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $flagged = [System.Collections.Generic.List[String]]::new()

        foreach ($license in $licenses) {
            $isInfinite = [Bool]$license.infinite
            $expirationLabel = 'Infinite'
            if (-not $isInfinite -and $license.expirationDate) {
                $expirationDate = [DateTimeOffset]::FromUnixTimeMilliseconds($license.expirationDate).UtcDateTime
                $expirationLabel = $expirationDate.ToString('yyyy-MM-dd')
                $daysRemaining = [Math]::Floor(($expirationDate - $now).TotalDays)
                if ($expirationDate -lt $now) {
                    $flagged.Add("License `"$($license.configuration)`" expired on $expirationLabel")
                } elseif ($expirationDate -lt $now.AddDays($WarningThresholdDays)) {
                    $flagged.Add("License `"$($license.configuration)`" expires on $expirationLabel ($daysRemaining day(s) remaining)")
                }
            }

            if ($license.status -and $license.status -ne 'Active') {
                $flagged.Add("License `"$($license.configuration)`" has status `"$($license.status)`"")
            }
            if ($license.error) {
                $flagged.Add("License `"$($license.configuration)`" reported an error: $($license.error)")
            }

            $rows.Add([PSCustomObject]@{
                ExpirationDate = $expirationLabel
                Configuration  = $license.configuration
                Status         = $license.status
                LicenseType    = $license.typeEnum
                Error          = $license.error
            })
        }

        if ($flagged.Count -eq 0) {
            $status = 'Pass'
            $detail = "All $($licenses.Count) Aria Operations for Logs license(s) are active and, if not infinite, expire more than $WarningThresholdDays day(s) from now."
        } else {
            $status = 'Warning'
            $detail = ($flagged.ToArray()) -join '; '
        }

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows $rows.ToArray() `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Operations for Logs'
    }

    return @($results)
}
function Get-VcfCheckAriaOpsForLogsEntitlementResult {

    <#
        .SYNOPSIS
        Derives a Status/Detail/Rows result from Aria Operations for Logs' top-level
        entitlementType/entitlement fields when its 'licenses' array is empty.

        .DESCRIPTION
        'GET /api/v2/licenses' returns an empty 'licenses' array whenever no license key is
        installed - this is the normal shape for a VCF/VVF-entitled or evaluation-mode instance,
        not an error. Reports:
        - 'EVALUATION': Pass if entitlement.validUntil is more than WarningThresholdDays away;
          Warning if it is expired or expiring within WarningThresholdDays. Pass with no expiry
          detail if entitlement.validUntil is missing.
        - 'NO_LICENSE': Warning - no license is configured at all.
        - 'VCF_ENABLED' / 'VVF_ENABLED': Pass - entitled through the VCF/VVF subscription, no
          separate license key required.
        - Anything else (including a missing entitlementType): Pass, preserving the prior
          "no license information" message for backward compatibility with untyped responses.

        .PARAMETER Response
        The parsed JSON response from 'GET /api/v2/licenses'.

        .PARAMETER Now
        The current time, used to compute days remaining on an evaluation license.

        .PARAMETER WarningThresholdDays
        Number of days before an evaluation license's expiry to raise a Warning instead of a Pass.

        .OUTPUTS
        [PSCustomObject] with Status/Detail/Rows properties.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Response,
        [Parameter(Mandatory = $true)] [DateTime]$Now,
        [Parameter(Mandatory = $true)] [Int]$WarningThresholdDays
    )

    $entitlementType = $Response.entitlementType
    $entitlement = $Response.entitlement
    $row = [PSCustomObject]@{
        ExpirationDate = 'Infinite'
        Configuration  = $entitlementType
        Status         = $entitlementType
        LicenseType    = $entitlementType
        Error          = $null
    }

    switch ($entitlementType) {
        'EVALUATION' {
            $status = 'Pass'
            $detail = 'Aria Operations for Logs is running on a time-limited evaluation license.'
            if ($entitlement -and $entitlement.validUntil) {
                $validUntil = [DateTimeOffset]::FromUnixTimeMilliseconds($entitlement.validUntil).UtcDateTime
                $row.ExpirationDate = $validUntil.ToString('yyyy-MM-dd')
                $daysRemaining = [Math]::Floor(($validUntil - $Now).TotalDays)
                if ($validUntil -lt $Now) {
                    $status = 'Warning'
                    $detail = "The Aria Operations for Logs evaluation license expired on $($row.ExpirationDate)."
                } elseif ($validUntil -lt $Now.AddDays($WarningThresholdDays)) {
                    $status = 'Warning'
                    $detail = "Aria Operations for Logs is running on a time-limited evaluation license, expiring on $($row.ExpirationDate) ($daysRemaining day(s) remaining)."
                } else {
                    $detail = "Aria Operations for Logs is running on a time-limited evaluation license, expiring on $($row.ExpirationDate) ($daysRemaining day(s) remaining)."
                }
            }
        }
        'NO_LICENSE' {
            $status = 'Warning'
            $detail = 'No license is configured for Aria Operations for Logs.'
        }
        'VCF_ENABLED' {
            $status = 'Pass'
            $detail = "Aria Operations for Logs is entitled via $entitlementType and does not require a separate license key."
        }
        'VVF_ENABLED' {
            $status = 'Pass'
            $detail = "Aria Operations for Logs is entitled via $entitlementType and does not require a separate license key."
        }
        default {
            $status = 'Pass'
            $detail = 'No license information was returned by Aria Operations for Logs.'
        }
    }

    return [PSCustomObject]@{
        Status = $status
        Detail = $detail
        Rows   = @($row)
    }
}
#endregion
