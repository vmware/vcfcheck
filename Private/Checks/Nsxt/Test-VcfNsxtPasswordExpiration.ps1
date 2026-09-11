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
function Get-VcfCheckNsxCredentialExpiration {

    <#
        .SYNOPSIS
        Resolves password-expiration details for a set of NSX credential Ids of one resource type.

        .DESCRIPTION
        Wraps Initialize-VcfCredentialsExpirationSpec/Invoke-VcfGetPasswordExpiration, polling
        Invoke-VcfGetPasswordExpirationByTaskID until the task completes.
        CredentialsExpirationSpec requires a single -ResourceType per request, so NSX Manager and
        NSX Edge credentials (different resource types) must be resolved in separate calls - see
        Test-VcfNsxtPasswordExpiration, which calls this once per resource type.

        .PARAMETER ResourceType
        NSXT_MANAGER or NSXT_EDGE.

        .PARAMETER Ids
        Credential Ids to resolve. Returns an empty array immediately if none are supplied.

        .PARAMETER MaxPollAttempts
        Maximum number of status polls before giving up.

        .PARAMETER PollDelaySeconds
        Delay between polls.

        .OUTPUTS
        [Object[]] CredentialExpirationCheck elements (Id, Username, Resource, Expiry).
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ResourceType,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [String[]]$Ids,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$MaxPollAttempts = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$PollDelaySeconds = 5
    )

    if (@($Ids).Count -eq 0) {
        return @()
    }

    $spec = Initialize-VcfCredentialsExpirationSpec -ResourceType $ResourceType -CredentialIds @($Ids)
    $task = Invoke-VcfGetPasswordExpiration -CredentialsExpirationSpec $spec -ErrorAction Stop

    $status = [String]$task.Status
    $attempt = 0
    while ($status -match 'IN_?PROGRESS|PENDING' -and $attempt -lt $MaxPollAttempts) {
        Start-Sleep -Seconds $PollDelaySeconds
        $task = Invoke-VcfGetPasswordExpirationByTaskID -Id $task.Id -ErrorAction Stop
        $status = [String]$task.Status
        $attempt++
    }

    if ($status -match 'IN_?PROGRESS|PENDING') {
        throw [System.Exception]::new("Credential-expiration task `"$($task.Id)`" for `"$ResourceType`" did not complete after $MaxPollAttempts poll(s).")
    }

    return @($task.Elements)
}
function Resolve-VcfCheckNsxMissingExpiration {

    <#
        .SYNOPSIS
        Retries password-expiration lookup for credentials a batched task returned without a
        usable Expiry element.

        .DESCRIPTION
        SDDC Manager's credential-expiration task occasionally completes without an Expiry
        element (or with a blank ExpiryDate) for one or more credentials in a large batch,
        even though the same credential resolves cleanly when queried on its own. This
        re-submits just the missing credential Ids as a second, smaller task and merges any
        results back in before Test-VcfNsxtPasswordExpiration falls back to reporting Error.

        .PARAMETER Credentials
        The full set of Credential elements for one resource type.

        .PARAMETER Expirations
        The Expiry-bearing elements returned by the initial batched lookup.

        .PARAMETER ResourceType
        NSXT_MANAGER or NSXT_EDGE.

        .PARAMETER MaxPollAttempts
        Maximum number of status polls before giving up on the retry task.

        .PARAMETER PollDelaySeconds
        Delay between polls for the retry task.

        .OUTPUTS
        [Object[]] The original Expirations plus any resolved on retry.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [PSObject[]]$Credentials,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$Expirations,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ResourceType,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 60)] [Int]$MaxPollAttempts,
        [Parameter(Mandatory = $true)] [ValidateRange(0, 300)] [Int]$PollDelaySeconds
    )

    $missingIds = @($Credentials | Where-Object {
        $credentialId = $_.Id
        $expiry = ($Expirations | Where-Object { $_.Id -eq $credentialId } | Select-Object -First 1)
        -not $expiry -or -not $expiry.Expiry -or [String]::IsNullOrEmpty($expiry.Expiry.ExpiryDate)
    } | Select-Object -ExpandProperty Id)

    if ($missingIds.Count -eq 0) {
        return $Expirations
    }

    Write-LogMessage -Type WARNING -Message "Password-expiration task for `"$ResourceType`" omitted $($missingIds.Count) credential(s); retrying individually."

    try {
        $retryExpirations = @(Get-VcfCheckNsxCredentialExpiration -ResourceType $ResourceType -Ids $missingIds -MaxPollAttempts $MaxPollAttempts -PollDelaySeconds $PollDelaySeconds)
    } catch {
        Write-LogMessage -Type ERROR -Message "Retry of password-expiration lookup for `"$ResourceType`" failed: $($_.Exception.Message)"
        return $Expirations
    }

    return @($Expirations) + @($retryExpirations)
}
function ConvertTo-VcfCheckNsxCredentialRow {

    <#
        .SYNOPSIS
        Evaluates a single NSX Manager/Edge account's password expiry and auto-rotation policy.

        .DESCRIPTION
        Helper for Test-VcfNsxtPasswordExpiration. Combines a Credential element (Username,
        Resource, AutoRotatePolicy) from Invoke-VcfGetCredentials with its matching Expiry
        (ExpirationDetails) from Get-VcfCheckNsxCredentialExpiration. Fail if already expired;
        Warning if expiring within -WarningThresholdDays (regardless of rotation policy); Error
        if expiry could not be determined. Automatic rotation being disabled does not by itself
        raise a Warning, since a password more than -WarningThresholdDays from expiry is not at
        risk of blocking the upgrade. When rotation is disabled, the Detail text adds a
        heads-up that manual action will be required to rotate the password.

        .PARAMETER Account
        A Credential element (Username, Resource.ResourceName, AutoRotatePolicy).

        .PARAMETER Expiry
        The matching ExpirationDetails object, or $null if none was found.

        .PARAMETER Errors
        Any Error elements SDDC Manager returned alongside the expiration-check result for this
        credential (e.g. because it could not reach the resource). Used to explain an Error
        status instead of reporting it as a bare unknown.

        .PARAMETER WarningThresholdDays
        Number of days before expiry to raise a Warning instead of a Pass.

        .OUTPUTS
        [PSCustomObject] with Hostname, Username, 'Expiry Date', 'Days Until', Status,
        'Rotation Schedule', 'Next Rotation', Detail.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Account,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Expiry,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$Errors,
        [Parameter(Mandatory = $true)] [Int32]$WarningThresholdDays
    )

    $hostname = $Account.Resource.ResourceName
    $username = $Account.Username
    $rotationEnabled = [bool]$Account.AutoRotatePolicy
    $rotationSchedule = if ($rotationEnabled) { "Every $($Account.AutoRotatePolicy.FrequencyInDays) day(s)" } else { 'Disabled' }
    $nextRotation = if ($rotationEnabled) { $Account.AutoRotatePolicy.NextSchedule } else { 'N/A' }

    if (-not $Expiry -or [String]::IsNullOrEmpty($Expiry.ExpiryDate)) {
        $reason = ''
        $firstError = @($Errors) | Select-Object -First 1
        if ($firstError -and $firstError.ErrorCode -eq 'PASSWORD_MANAGER_RESOURCE_CREDENTIALS_NOT_FOUND') {
            $reason = " SDDC Manager has lost contact with this NSX resource; log in to NSX Manager directly to verify the account and rotate the password."
        } elseif ($firstError) {
            $reason = " SDDC Manager reports `"$($firstError.ErrorCode)`": $($firstError.Message)"
        }
        return [PSCustomObject]@{
            Hostname            = $hostname
            Username            = $username
            'Expiry Date'       = 'Unknown'
            'Days Until'        = 'Unknown'
            Status              = 'Error'
            'Rotation Schedule' = $rotationSchedule
            'Next Rotation'     = $nextRotation
            Detail              = "Could not determine password expiry for `"$username`" on `"$hostname`".$reason"
        }
    }

    $expiryDate = [DateTime]::Parse($Expiry.ExpiryDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $daysUntilExpiry = [Math]::Floor(($expiryDate - [DateTime]::UtcNow).TotalDays)
    $rotationDetail = 'automatic rotation is disabled in SDDC Manager; manual action will be required to rotate this password'
    if ($rotationEnabled) {
        $rotationDetail = "automatic rotation is enabled every $($Account.AutoRotatePolicy.FrequencyInDays) day(s) via SDDC Manager"
    }

    if ($Expiry.Status -eq 'EXPIRED' -or $daysUntilExpiry -lt 0) {
        return [PSCustomObject]@{
            Hostname = $hostname; Username = $username; 'Expiry Date' = $Expiry.ExpiryDate; 'Days Until' = $daysUntilExpiry
            Status = 'Fail'; 'Rotation Schedule' = $rotationSchedule; 'Next Rotation' = $nextRotation
            Detail = "The `"$username`" account password on `"$hostname`" has already expired; $rotationDetail."
        }
    }
    if ($Expiry.Status -eq 'EXPIRING' -or $daysUntilExpiry -lt $WarningThresholdDays) {
        return [PSCustomObject]@{
            Hostname = $hostname; Username = $username; 'Expiry Date' = $Expiry.ExpiryDate; 'Days Until' = $daysUntilExpiry
            Status = 'Warning'; 'Rotation Schedule' = $rotationSchedule; 'Next Rotation' = $nextRotation
            Detail = "The `"$username`" account password on `"$hostname`" expires in $daysUntilExpiry day(s); $rotationDetail."
        }
    }
    return [PSCustomObject]@{
        Hostname = $hostname; Username = $username; 'Expiry Date' = $Expiry.ExpiryDate; 'Days Until' = $daysUntilExpiry
        Status = 'Pass'; 'Rotation Schedule' = $rotationSchedule; 'Next Rotation' = $nextRotation
        Detail = "The `"$username`" account password on `"$hostname`" expires in $daysUntilExpiry day(s); $rotationDetail."
    }
}
function Test-VcfNsxtPasswordExpiration {

    <#
        .SYNOPSIS
        Checks local admin/audit/root account password expiration and auto-rotation policy on
        every NSX Manager and NSX Edge node registered with SDDC Manager.

        .DESCRIPTION
        Queries the SDDC Manager credentials API (Invoke-VcfGetCredentials -ResourceType
        NSXT_MANAGER/NSXT_EDGE -AccountType SYSTEM) to retrieve local system accounts across all
        domains. Password expiry details are obtained via Initialize-VcfCredentialsExpirationSpec and
        Invoke-VcfGetPasswordExpiration (wrapped in Get-VcfCheckNsxCredentialExpiration).
        Each account is evaluated by ConvertTo-VcfCheckNsxCredentialRow and reported as a row
        (Hostname, Username, 'Expiry Date', 'Days Until', Status, 'Rotation Schedule', 'Next Rotation')
        in the result's breakdown table.

        Overall status is the worst of every row's status (Fail > Error/Warning > Pass).

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER WarningThresholdDays
        Number of days before expiry to raise a Warning instead of a Pass. Default 30.

        .PARAMETER MaxPollAttempts
        Maximum number of status polls before giving up. Default 10.

        .PARAMETER PollDelaySeconds
        Delay between polls. Default 5.

        .OUTPUTS
        [PSObject] a VcfCheck.Result.
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
    $checkId = 'nsxt_password_expiration'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }
    $validationCriteria = $catalogEntry.validationCriteria
    $remediation = $catalogEntry.remediation

    try {
        $managerCredentials = @((Invoke-VcfGetCredentials -ResourceType NSXT_MANAGER -AccountType SYSTEM -ErrorAction Stop).Elements)
        $edgeCredentials = @((Invoke-VcfGetCredentials -ResourceType NSXT_EDGE -AccountType SYSTEM -ErrorAction Stop).Elements)
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Area NSX -Status Error `
            -Exception $_.Exception.Message -ValidationCriteria $validationCriteria -Remediation $remediation -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    try {
        $managerExpirations = @(Get-VcfCheckNsxCredentialExpiration -ResourceType NSXT_MANAGER -Ids @($managerCredentials.Id) -MaxPollAttempts $MaxPollAttempts -PollDelaySeconds $PollDelaySeconds)
        $edgeExpirations = @(Get-VcfCheckNsxCredentialExpiration -ResourceType NSXT_EDGE -Ids @($edgeCredentials.Id) -MaxPollAttempts $MaxPollAttempts -PollDelaySeconds $PollDelaySeconds)
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Area NSX -Status Error `
            -Exception $_.Exception.Message -ValidationCriteria $validationCriteria -Remediation $remediation -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $managerExpirations = Resolve-VcfCheckNsxMissingExpiration -Credentials $managerCredentials -Expirations $managerExpirations -ResourceType NSXT_MANAGER -MaxPollAttempts $MaxPollAttempts -PollDelaySeconds $PollDelaySeconds
    $edgeExpirations = Resolve-VcfCheckNsxMissingExpiration -Credentials $edgeCredentials -Expirations $edgeExpirations -ResourceType NSXT_EDGE -MaxPollAttempts $MaxPollAttempts -PollDelaySeconds $PollDelaySeconds

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($credential in $managerCredentials) {
        $match = $managerExpirations | Where-Object { $_.Id -eq $credential.Id } | Select-Object -First 1
        $rows.Add((ConvertTo-VcfCheckNsxCredentialRow -Account $credential -Expiry $match.Expiry -Errors $match.Errors -WarningThresholdDays $WarningThresholdDays))
    }
    foreach ($credential in $edgeCredentials) {
        $match = $edgeExpirations | Where-Object { $_.Id -eq $credential.Id } | Select-Object -First 1
        $rows.Add((ConvertTo-VcfCheckNsxCredentialRow -Account $credential -Expiry $match.Expiry -Errors $match.Errors -WarningThresholdDays $WarningThresholdDays))
    }

    $reportRows = @($rows | ForEach-Object { [PSCustomObject]@{
        Hostname            = $_.Hostname
        Username            = $_.Username
        'Expiry Date'       = $_.'Expiry Date'
        'Days Until'        = $_.'Days Until'
        Status              = $_.Status
        'Rotation Schedule' = $_.'Rotation Schedule'
        'Next Rotation'     = $_.'Next Rotation'
        Detail              = $_.Detail
    } })
    $reportRows = @($reportRows | Sort-Object -Property Hostname, Username)

    $failures = @($rows | Where-Object { $_.Status -eq 'Fail' })
    $warningsAndErrors = @($rows | Where-Object { $_.Status -eq 'Warning' -or $_.Status -eq 'Error' })

    $managerNodeCount = @($managerCredentials | Select-Object -ExpandProperty Resource | Select-Object -ExpandProperty ResourceName -Unique).Count
    $edgeNodeCount = @($edgeCredentials | Select-Object -ExpandProperty Resource | Select-Object -ExpandProperty ResourceName -Unique).Count

    if ($failures.Count -gt 0) {
        $status = 'Fail'
        $detail = "$($failures.Count) account password(s) have already expired. See the results table below for details."
    } elseif ($warningsAndErrors.Count -gt 0) {
        $status = 'Warning'
        $detail = "$($warningsAndErrors.Count) account password(s) expire within $WarningThresholdDays day(s) or could not be checked. See the results table below for details."
    } else {
        $status = 'Pass'
        $detail = "Checked $($rows.Count) account(s) across $managerNodeCount NSX Manager(s) and $edgeNodeCount NSX Edge node(s); none expire within $WarningThresholdDays day(s)."
    }

    return New-VcfCheckResult -CheckId $checkId -Area NSX -Status $status `
        -Detail $detail -Rows $reportRows -ValidationCriteria $validationCriteria -Remediation $remediation `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
}
