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
function Get-VcfCheckRootAccountAgingDetail {

    <#
        .SYNOPSIS
        Retrieves best-effort `chage -l root` account-aging details for a vCenter appliance root account.

        .DESCRIPTION
        Supplements the SDDC Manager credential status in Test-VcfVcenterRootCredentialsValidity
        by querying Linux account-aging attributes (`chage -l root`) on the target vCenter appliance.

        Retrieves fields including last password change date, password inactive date, account expiry,
        minimum/maximum days between changes, and warning days prior to expiry.

        Executes commands via guest operations through the management vCenter. If VMware Tools is not
        running, network connectivity fails, or output cannot be parsed, field values default to 'Unknown'
        without failing the calling check.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER VCenterFqdn
        FQDN of the vCenter appliance whose root account is being inspected.

        .PARAMETER ManagementVCenterFqdn
        FQDN of the management vCenter to run the guest command through. If $null or empty, the lookup is skipped.

        .OUTPUTS
        [PSCustomObject] containing LastPasswordChange, PasswordInactive, AccountExpires,
        MinDaysBetweenChanges, MaxDaysBetweenChanges, and WarningDays properties.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [String]$VCenterFqdn,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$ManagementVCenterFqdn
    )

    $unknown = [PSCustomObject]@{
        LastPasswordChange    = 'Unknown'
        PasswordInactive      = 'Unknown'
        AccountExpires        = 'Unknown'
        MinDaysBetweenChanges = 'Unknown'
        MaxDaysBetweenChanges = 'Unknown'
        WarningDays           = 'Unknown'
    }

    if ([String]::IsNullOrEmpty($ManagementVCenterFqdn)) {
        return $unknown
    }

    try {
        $rootCredential = Get-VcfCheckComponentCredential -Context $Context -ResourceType VCENTER -AccountType USER -Fqdn $VCenterFqdn -Username 'root'
        $vmName = ($VCenterFqdn -split '\.')[0]
        $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $ManagementVCenterFqdn -Credential $rootCredential -ScriptText 'chage -l root'
        Remove-Variable -Name rootCredential -ErrorAction SilentlyContinue

        if (-not $commandResult.Success) {
            return $unknown
        }

        $fields = ConvertFrom-VcfCheckChageOutput -Lines ($commandResult.ScriptOutput -split "`n")
        $lookup = @{}
        foreach ($field in $fields) { $lookup[$field.Name] = $field.Value }

        $result = $unknown.PSObject.Copy()
        if ($lookup.ContainsKey('Last password change')) { $result.LastPasswordChange = $lookup['Last password change'] }
        if ($lookup.ContainsKey('Password inactive')) { $result.PasswordInactive = $lookup['Password inactive'] }
        if ($lookup.ContainsKey('Account expires')) { $result.AccountExpires = $lookup['Account expires'] }
        if ($lookup.ContainsKey('Minimum number of days between password change')) { $result.MinDaysBetweenChanges = $lookup['Minimum number of days between password change'] }
        if ($lookup.ContainsKey('Maximum number of days between password change')) { $result.MaxDaysBetweenChanges = $lookup['Maximum number of days between password change'] }
        if ($lookup.ContainsKey('Number of days of warning before password expires')) { $result.WarningDays = $lookup['Number of days of warning before password expires'] }
        return $result
    } catch {
        return $unknown
    }
}

function Test-VcfVcenterRootCredentialsValidity {

    <#
        .SYNOPSIS
        Checks the vCenter appliance root account password expiry and auto-rotation policy.

        .DESCRIPTION
        Validates vCenter appliance root account password expiration and automatic rotation policies via
        the SDDC Manager credentials API.

        Retrieves root credential details via Invoke-VcfGetCredentials, executes a password expiration task
        via Invoke-VcfGetPasswordExpiration, and polls until completion using Invoke-VcfGetPasswordExpirationByTaskID.

        Evaluation logic:
        - Fail: Root account password is expired.
        - Warning: Root account password expires within WarningThresholdDays (default 30 days).
        - Pass: Root account password is active and beyond WarningThresholdDays.
        - Error: Root account credentials cannot be retrieved or expiration tasks fail/time out.

        Additionally enriches each result row with Linux `chage -l root` account-aging details via
        Get-VcfCheckRootAccountAgingDetail using guest operations.

        Populates a structured Rows table detailing Account, Status, Expiry Date, Rotation Schedule, Next Rotation,
        Last Password Change, Password Inactive, Account Expires, Min/Max Days Between Changes, and Warning Days.
        Delegates per-vCenter outcome aggregation to New-VcfCheckPerDomainResults.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .PARAMETER WarningThresholdDays
        Number of days before expiry to raise a Warning instead of a Pass. Default 30.

        .PARAMETER MaxPollAttempts
        Maximum number of status polls before giving up. Default 10.

        .PARAMETER PollDelaySeconds
        Delay between polls in seconds. Default 5.

        .OUTPUTS
        [PSObject[]] Per-vCenter check results generated by New-VcfCheckPerDomainResults.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateRange(1, 3650)] [Int]$WarningThresholdDays = 30,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$MaxPollAttempts = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$PollDelaySeconds = 5
    )

    $startedAt = Get-Date
    $checkId = 'vcenter_root_credentials_validity'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }
    $blocking = Get-VcfCheckBlockingStatusFromCatalog -CheckId $checkId
    $validationCriteria = $catalogEntry.validationCriteria
    $remediation = $catalogEntry.remediation

    try {
        $vcenterFqdns = Get-VcfCheckAllVCenterFqdns -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Area vCenter -Status Error `
            -Exception $_.Exception.Message -ValidationCriteria $validationCriteria -Remediation $remediation -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $managementVCenterFqdn = $null
    try {
        $managementVCenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        Connect-VcfCheckVCenter -Context $Context -Fqdn $managementVCenterFqdn
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not connect to the management vCenter for root account-aging detail via guest ops - `"Rows`" will show `"Unknown`" for those columns: $($_.Exception.Message)"
        $managementVCenterFqdn = $null
    }

    $outcomes = foreach ($vcenterFqdn in $vcenterFqdns) {
        $iterationStartedAt = Get-Date
        $outcome = & {
            try {
                $rootCredential = @((Invoke-VcfGetCredentials -ResourceType VCENTER -AccountType USER -ResourceName $vcenterFqdn -ErrorAction Stop).Elements) |
                    Where-Object { $_.Username -eq 'root' } | Select-Object -First 1
            } catch {
                return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = $_.Exception.Message; Rows = @(); Blocking = $blocking }
            }

            if (-not $rootCredential) {
                return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = "No root account credential found for `"$vcenterFqdn`"."; Rows = @(); Blocking = $blocking }
            }

            try {
                $spec = Initialize-VcfCredentialsExpirationSpec -ResourceType VCENTER -CredentialIds @($rootCredential.Id)
                $task = Invoke-VcfGetPasswordExpiration -CredentialsExpirationSpec $spec -ErrorAction Stop
            } catch {
                return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = $_.Exception.Message; Rows = @(); Blocking = $blocking }
            }

            $status = [String]$task.Status
            $attempt = 0
            while ($status -match 'IN_?PROGRESS|PENDING' -and $attempt -lt $MaxPollAttempts) {
                Start-Sleep -Seconds $PollDelaySeconds
                try {
                    $task = Invoke-VcfGetPasswordExpirationByTaskID -Id $task.Id -ErrorAction Stop
                } catch {
                    return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = $_.Exception.Message; Rows = @(); Blocking = $blocking }
                }
                $status = [String]$task.Status
                $attempt++
            }

            if ($status -match 'IN_?PROGRESS|PENDING') {
                return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = "Credential-expiration task `"$($task.Id)`" did not complete after $MaxPollAttempts poll(s)."; Rows = @(); Blocking = $blocking }
            }

            $expiryElement = $task.Elements | Where-Object { $_.Username -eq 'root' } | Select-Object -First 1
            $expiry = $expiryElement.Expiry
            $rotationEnabled = [bool]$rootCredential.AutoRotatePolicy
            $rotationDetail = 'automatic rotation is disabled in SDDC Manager; manual action will be required to rotate this password'
            if ($rotationEnabled) {
                $rotationDetail = "automatic rotation is enabled every $($rootCredential.AutoRotatePolicy.FrequencyInDays) day(s) via SDDC Manager"
            }

            $agingDetail = Get-VcfCheckRootAccountAgingDetail -Context $Context -VCenterFqdn $vcenterFqdn -ManagementVCenterFqdn $managementVCenterFqdn

            $rows = @([PSCustomObject]@{
                Account                  = 'root'
                Status                   = [String]$expiry.Status
                'Expiry Date'            = if ([String]::IsNullOrEmpty($expiry.ExpiryDate)) { 'Unknown' } else { $expiry.ExpiryDate }
                'Rotation Schedule'      = if ($rotationEnabled) { "Every $($rootCredential.AutoRotatePolicy.FrequencyInDays) day(s)" } else { 'Disabled' }
                'Next Rotation'          = if ($rotationEnabled) { $rootCredential.AutoRotatePolicy.NextSchedule } else { 'N/A' }
                'Last Password Change'   = $agingDetail.LastPasswordChange
                'Password Inactive'      = $agingDetail.PasswordInactive
                'Account Expires'        = $agingDetail.AccountExpires
                'Min Days Between Changes' = $agingDetail.MinDaysBetweenChanges
                'Max Days Between Changes' = $agingDetail.MaxDaysBetweenChanges
                'Warning Days'           = $agingDetail.WarningDays
            })

            if ([String]::IsNullOrEmpty($expiry.ExpiryDate)) {
                return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = 'Could not determine password expiry for the root account.'; Rows = $rows; Blocking = $blocking }
            }

            $expiryDate = [DateTime]::Parse($expiry.ExpiryDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            $daysUntilExpiry = [Math]::Floor(($expiryDate - [DateTime]::UtcNow).TotalDays)

            if ($expiry.Status -eq 'EXPIRED' -or $daysUntilExpiry -lt 0) {
                return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Fail'; Detail = "Root password expired on $($expiry.ExpiryDate); $rotationDetail."; Rows = $rows; Blocking = $blocking }
            }
            if ($expiry.Status -eq 'EXPIRING' -or $daysUntilExpiry -lt $WarningThresholdDays) {
                return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Warning'; Detail = "Root password expires in $daysUntilExpiry day(s); $rotationDetail."; Rows = $rows; Blocking = $blocking }
            }
            return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Pass'; Detail = "Root password expires in $daysUntilExpiry day(s); $rotationDetail."; Rows = $rows; Blocking = $blocking }
        }
        $outcome | Add-Member -NotePropertyName StartedAt -NotePropertyValue $iterationStartedAt -Force
        $outcome | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date) -Force
        $outcome
    }

    return New-VcfCheckPerDomainResults -Context $Context -PerVCenterOutcome $outcomes -CheckId $checkId -Area vCenter `
        -ValidationCriteria $validationCriteria -Remediation $remediation -StartedAt $startedAt -DisplayName $displayName
}
