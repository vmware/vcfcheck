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
#region Aria

function Get-VcfCheckVrslcmCertificateEnvironmentMap {

    <#
        .SYNOPSIS
        Builds a vmid -> environment/product label lookup from vRSLCM's environments API.

        .DESCRIPTION
        Helper for Test-VcfVrslcmCertificateExpiration. vRSLCM's locker certificate list
        ('/lcm/locker/api/v2/certificates') returns only a bare "vmid" per certificate - no
        product or environment name. Calling '/lcm/lcops/api/v2/environments?status=COMPLETED'
        separately and indexing every product's "certificateId" back to its environment/product
        name is the only way to label which appliance a given certificate belongs to.

        .PARAMETER Connection
        The object returned by Get-VcfCheckVrslcmConnection.

        .OUTPUTS
        [Hashtable] keyed by certificate vmid, each value a "<environmentName>/<productId>" label.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Connection
    )

    $map = @{}
    $environments = Invoke-VcfCheckVrslcmApi -Connection $Connection -Path '/lcm/lcops/api/v2/environments?status=COMPLETED'
    foreach ($environment in @($environments)) {
        foreach ($product in @($environment.products)) {
            if ($product.certificateId) {
                $map[$product.certificateId] = "$($environment.environmentName)/$($product.id)"
            }
        }
    }
    return $map
}
function Test-VcfVrslcmCertificateExpiration {

    <#
        .SYNOPSIS
        Checks certificate expiration for Aria Suite Lifecycle Manager and every registered Aria product.

        .DESCRIPTION
        Queries vRSLCM's certificate locker ('/lcm/locker/api/v2/certificates') for every
        certificate it manages—covering vRSLCM itself and every Aria product (VRLI, VROPS,
        VRA, WSA) it has deployed or registered. The list endpoint returns bare certificate IDs,
        so expiration dates ("validity.expiresOn") are queried via the per-certificate detail
        endpoint ('/lcm/locker/api/v2/certificates/{vmid}'). Sub-progress is reported via
        Write-VcfCheckSubProgress during iterations. Fails if any certificate has expired;
        warns if any certificate expires within the warning threshold (default 30 days).
        Labels each certificate with its owning environment and product via
        Get-VcfCheckVrslcmCertificateEnvironmentMap.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if Aria Suite Lifecycle Manager is not deployed in the
          environment.
        - Pass: Returns 'Pass' if every certificate is valid beyond the warning threshold.
        - Warning: Returns 'Warning' if one or more certificates expire within
          -WarningThresholdDays, or one or more could not be checked due to an API or data issue,
          and none has expired.
        - Fail: Returns 'Fail' if one or more certificates have already expired.
        - Error: Returns 'Error' if SDDC Manager's credential inventory or the vRSLCM API call
          fails.

        The Detail message provides categorized findings for expired, expiring-soon, and uncheckable
        certificates, attaching remediation documentation where applicable. Constructs a breakdown
        table ('Rows') containing Endpoint, Alias, ExpiryDate, DaysRemaining, and Status per
        certificate.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .PARAMETER WarningThresholdDays
        Number of days before expiry to raise a Warning instead of a Pass. Default 30.

        .OUTPUTS
        [PSObject] A single VcfCheck.Result object.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateRange(1, 3650)] [Int]$WarningThresholdDays = 30
    )

    $startedAt = Get-Date
    $checkId = 'vrslcm_certificate_expiration'

    try {
        $connection = Get-VcfCheckVrslcmConnection -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    if (-not $connection) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Suite Lifecycle Manager is not deployed in this environment.' -SkipReasonTag 'vRSLCM not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    try {
        $certificateList = Invoke-VcfCheckVrslcmApi -Connection $connection -Path '/lcm/locker/api/v2/certificates'
        $certificates = @($certificateList.certificates)
        $environmentMap = Get-VcfCheckVrslcmCertificateEnvironmentMap -Connection $connection
    } catch {
        $friendlyMessage = ConvertTo-VcfCheckFriendlyVrslcmError -Fqdn $connection.Fqdn -ErrorMessage $_.Exception.Message
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $connection.Fqdn -Exception $friendlyMessage `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    if ($certificates.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Pass `
            -TargetComponent $connection.Fqdn `
            -Detail 'No certificates were found in the Aria Suite Lifecycle Manager certificate locker.' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $now = Get-Date
    $replaceKbLink = 'https://techdocs.broadcom.com/us/en/vmware-cis/aria/aria-suite-lifecycle/8-12/vmware-aria-suite-lifecycle-installation-upgrade-and-management-8-12/managing-environments/managing-vrealize-suite-products-in-a-private-cloud/replace-certificate-for-vrslcm-products.html'
    $replaceKbTitle = 'Replace certificate for VMware Aria Suite Lifecycle products'

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $expired = [System.Collections.Generic.List[String]]::new()
    $expiringSoon = [System.Collections.Generic.List[String]]::new()
    $unableToCheck = [System.Collections.Generic.List[String]]::new()
    $certIndex = 0
    foreach ($certificate in $certificates) {
        $certIndex++
        Write-VcfCheckSubProgress -Context $Context -Current $certIndex -Total $certificates.Count `
            -Label $certificate.alias -Unit 'certificates'

        $endpoint = 'Aria Suite Lifecycle Manager'
        if ($certificate.vmid -and $environmentMap.ContainsKey($certificate.vmid)) {
            $endpoint = $environmentMap[$certificate.vmid]
        }

        try {
            $certDetail = Invoke-VcfCheckVrslcmApi -Connection $connection -Path "/lcm/locker/api/v2/certificates/$($certificate.vmid)"
        } catch {
            # A failed detail call or unparseable date indicates an API/data issue rather than
            # an expiring certificate, so it is tracked separately from expiration warnings.
            $rows.Add([PSCustomObject]@{ Endpoint = $endpoint; Alias = $certificate.alias; ExpiryDate = 'Unknown'; DaysRemaining = 'Unknown'; Status = 'Error' })
            $unableToCheck.Add("$endpoint ($($certificate.alias)): unable to retrieve certificate details: $($_.Exception.Message)")
            continue
        }

        $expiryDate = Get-Date
        if (-not [DateTime]::TryParse($certDetail.validity.expiresOn, [ref]$expiryDate)) {
            $rows.Add([PSCustomObject]@{ Endpoint = $endpoint; Alias = $certificate.alias; ExpiryDate = $certDetail.validity.expiresOn; DaysRemaining = 'Unknown'; Status = 'Error' })
            $unableToCheck.Add("$endpoint ($($certificate.alias)): unparseable expiration date `"$($certDetail.validity.expiresOn)`"")
            continue
        }

        $daysRemaining = [Math]::Floor(($expiryDate - $now).TotalDays)
        $certStatus = 'Pass'
        if ($expiryDate -lt $now) {
            $certStatus = 'Expired'
            $expired.Add("$endpoint ($($certificate.alias)) expired on $expiryDate")
        } elseif ($expiryDate -lt $now.AddDays($WarningThresholdDays)) {
            $certStatus = 'Expiring Soon'
            $expiringSoon.Add("$endpoint ($($certificate.alias)) expires on $expiryDate ($daysRemaining day(s) remaining)")
        }

        $rows.Add([PSCustomObject]@{ Endpoint = $endpoint; Alias = $certificate.alias; ExpiryDate = $expiryDate; DaysRemaining = [Math]::Max(0, $daysRemaining); Status = $certStatus })
    }

    $rows = @($rows | Sort-Object -Property Endpoint)

    # Output distinct lines for each finding category to ensure clear reporting.
    $detailLines = [System.Collections.Generic.List[String]]::new()
    $status = $null
    if ($expired.Count -gt 0) {
        $status = 'Fail'
        $detailLines.Add("Expired - replace before proceeding: $($expired -join '; '). See [$replaceKbTitle]($replaceKbLink).")
    }
    if ($expiringSoon.Count -gt 0) {
        if (-not $status) { $status = 'Warning' }
        $detailLines.Add("Expiring within $WarningThresholdDays day(s) - replace before they expire: $($expiringSoon -join '; '). See [$replaceKbTitle]($replaceKbLink).")
    }
    if ($unableToCheck.Count -gt 0) {
        if (-not $status) { $status = 'Warning' }
        $detailLines.Add("Could not be checked due to an Aria Suite Lifecycle Manager API/data issue (not a certificate expiration problem) - investigate Aria Suite Lifecycle Manager's connectivity and locker health: $($unableToCheck -join '; ')")
    }

    if ($detailLines.Count -gt 0) {
        $detail = $detailLines -join "`n"
    } else {
        $status = 'Pass'
        $detail = "Checked $($certificates.Count) certificate(s) in the Aria Suite Lifecycle Manager certificate locker; none expired or expiring soon."
    }

    return New-VcfCheckResult -CheckId $checkId -Status $status `
        -TargetComponent $connection.Fqdn -Detail $detail -Rows @($rows) `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
#endregion
