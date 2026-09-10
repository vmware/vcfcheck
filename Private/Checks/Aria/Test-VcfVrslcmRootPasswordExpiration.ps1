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

function ConvertFrom-VcfCheckChageOutput {

    <#
        .SYNOPSIS
        Parses `chage -l <user>` output into a name/value field list.

        .DESCRIPTION
        Helper for Test-VcfVrslcmRootPasswordExpiration. `chage -l` prints one "Label: Value" line
        per field (e.g. "Password expires: never") - splits each line on the first colon only, since
        some values (e.g. dates like "Aug 05, 2026") contain no colon but labels always do.

        .PARAMETER Lines
        Raw stdout lines captured from the guest command.

        .OUTPUTS
        [PSCustomObject[]] one entry per parsed line, each with Name and Value properties.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [String[]]$Lines
    )

    $fields = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($line in @($Lines)) {
        $parts = $line -split ':', 2
        if ($parts.Count -eq 2) {
            $fields.Add([PSCustomObject]@{ Name = $parts[0].Trim(); Value = $parts[1].Trim() })
        }
    }
    return @($fields)
}
function Test-VcfCheckAriaNodePasswordExpiration {

    <#
        .SYNOPSIS
        Runs and evaluates `chage -l` for a single Aria appliance node's guest OS credential.

        .DESCRIPTION
        Helper for Test-VcfVrslcmRootPasswordExpiration. Resolves the appliance's short VM name
        from -Fqdn, runs `chage -l <Username>` via Invoke-VcfApplianceCommand (guest operations
        through vCenter, not a direct SSH session), and parses the result with
        ConvertFrom-VcfCheckChageOutput.

        A finite "Maximum number of days between password change" (chage's default fresh-appliance
        value is 99999, effectively "never") or a "Password expires" date means the account is
        configured to expire. A parseable "Password expires" date in the past is a Fail (root is
        already locked out); a date less than 30 days away is a Warning; any other finite
        expiration is also a Warning. Aria appliances are not expected to rotate their guest OS
        root password on a schedule - an expired root account can silently block SSH-based
        maintenance and LCM operations.

        .PARAMETER VCenterFqdn
        FQDN of the already-connected vCenter that manages the appliance VM.

        .PARAMETER Fqdn
        Appliance FQDN as registered in SDDC Manager. Its hostname label is used as the vCenter VM name.

        .PARAMETER Product
        Friendly product name (e.g. "Aria Operations") to include in Detail messages.

        .PARAMETER Username
        Guest OS account to check (the SSH credential's username, typically "root").

        .PARAMETER Credential
        Guest OS credential for -Username.

        .OUTPUTS
        [PSCustomObject] with Fqdn, Username, Status ('Pass'/'Warning'/'Fail'/'Error'), Detail,
        ExpirationDate, DaysRemaining, and Fields (the parsed chage output, empty on failure)
        properties.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VCenterFqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Product,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Username,
        [Parameter(Mandatory = $true)] [PSCredential]$Credential
    )

    $vmName = ($Fqdn -split '\.')[0]
    $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $VCenterFqdn -Fqdn $Fqdn `
        -Credential $Credential -ScriptText "chage -l $Username"

    if (-not $commandResult.Success) {
        return [PSCustomObject]@{
            Fqdn           = $Fqdn
            Username       = $Username
            Status         = 'Error'
            Detail         = "Unable to retrieve password expiration data from `"$Fqdn`": $($commandResult.ErrorMessage)"
            ExpirationDate = 'Unknown'
            DaysRemaining  = 'Unknown'
            Fields         = @()
        }
    }

    $lines = @($commandResult.ScriptOutput -split "`r?`n") | Where-Object { $_ -ne '' }
    if ($lines.Count -eq 0) {
        return [PSCustomObject]@{
            Fqdn           = $Fqdn
            Username       = $Username
            Status         = 'Error'
            Detail         = "`"chage -l $Username`" on `"$Fqdn`" returned no output."
            ExpirationDate = 'Unknown'
            DaysRemaining  = 'Unknown'
            Fields         = @()
        }
    }

    $fields = ConvertFrom-VcfCheckChageOutput -Lines $lines
    if ($fields.Count -eq 0) {
        return [PSCustomObject]@{
            Fqdn           = $Fqdn
            Username       = $Username
            Status         = 'Error'
            Detail         = "`"chage -l $Username`" on `"$Fqdn`" returned no parseable output."
            ExpirationDate = 'Unknown'
            DaysRemaining  = 'Unknown'
            Fields         = @()
        }
    }

    $maxDaysField = $fields | Where-Object { $_.Name -eq 'Maximum number of days between password change' } | Select-Object -First 1
    $expiresField = $fields | Where-Object { $_.Name -eq 'Password expires' } | Select-Object -First 1
    $maxDays = 0
    $expiresDate = Get-Date
    $expirationDate = 'Never'
    $daysRemainingDisplay = 'N/A'
    if ($expiresField -and $expiresField.Value -ne 'never' -and [DateTime]::TryParse($expiresField.Value, [ref]$expiresDate)) {
        $expirationDate = $expiresField.Value
        $daysRemaining = [Math]::Ceiling(($expiresDate - (Get-Date)).TotalDays)
        $daysRemainingDisplay = [Math]::Max(0, $daysRemaining)
        if ($daysRemaining -lt 0) {
            $status = 'Fail'
            $detail = "Root password for $Product on `"$Fqdn`" expired on $($expiresField.Value)."
        } elseif ($daysRemaining -lt 30) {
            $status = 'Warning'
            $detail = "Root password for $Product on `"$Fqdn`" expires on $($expiresField.Value) ($daysRemaining day(s) remaining)."
        } else {
            $status = 'Pass'
            $detail = "Root password for $Product on `"$Fqdn`" expires on $($expiresField.Value) ($daysRemaining day(s) remaining) - more than 30 days away."
        }
    } elseif ($maxDaysField -and [Int32]::TryParse($maxDaysField.Value, [ref]$maxDays) -and $maxDays -lt 99999) {
        $expirationDate = "$maxDays day(s) after last change"
        $daysRemainingDisplay = $maxDays
        if ($maxDays -lt 30) {
            $status = 'Warning'
            $detail = "Root password for $Product on `"$Fqdn`" is set to expire after $maxDays day(s)."
        } else {
            $status = 'Pass'
            $detail = "Root password for $Product on `"$Fqdn`" is set to expire after $maxDays day(s) - more than 30 days away."
        }
    } elseif ($expiresField -and $expiresField.Value -ne 'never') {
        $status = 'Warning'
        $expirationDate = $expiresField.Value
        $detail = "Root password for $Product on `"$Fqdn`" expires on $($expiresField.Value)."
    } else {
        $status = 'Pass'
        $detail = "Root password for $Product on `"$Fqdn`" does not expire."
    }

    return [PSCustomObject]@{
        Fqdn           = $Fqdn
        Username       = $Username
        Status         = $status
        Detail         = $detail
        ExpirationDate = $expirationDate
        DaysRemaining  = $daysRemainingDisplay
        Fields         = $fields
    }
}
function Test-VcfVrslcmRootPasswordExpiration {

    <#
        .SYNOPSIS
        Checks root password expiration settings on every deployed Aria Suite appliance node.

        .DESCRIPTION
        Enumerates every Aria Suite product with credentials registered in SDDC Manager (vRSLM,
        VRLI, VROPS, VRA, WSA) via Invoke-VcfGetCredentials, then for each SSH-credentialed node
        runs Test-VcfCheckAriaNodePasswordExpiration - which executes `chage -l <user>` on the
        appliance through vCenter guest operations (Invoke-VcfApplianceCommand). Reports per-node
        sub-progress via Write-VcfCheckSubProgress as each appliance node is checked to ensure
        real-time status updates during execution.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if Aria Suite Lifecycle Manager is not deployed in the environment.
        - Pass: Returns 'Pass' if every registered node's root password is set to never expire.
        - Warning: Returns 'Warning' if one or more nodes has a finite password expiration configured
          (including one expiring in fewer than 30 days), or a node's expiration data could not be
          retrieved, and no node's password has already expired.
        - Fail: Returns 'Fail' if one or more nodes' root password has already expired.
        - Error: Returns 'Error' if SDDC Manager's credential inventory or the management vCenter
          connection cannot be established at all.

        Constructs a breakdown table ('Rows') of Product, Fqdn, Username, ExpirationDate,
        DaysRemaining, and Status per node.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [PSObject] A single VcfCheck.Result object.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'vrslcm_root_password_expiration'
    $products = @('VRSLCM', 'VRLI', 'VROPS', 'VRA', 'WSA')
    $productFriendlyNames = @{
        'VRSLCM' = 'Aria Suite Lifecycle Manager'
        'VRLI'   = 'Aria Operations for Logs'
        'VROPS'  = 'Aria Operations'
        'VRA'    = 'Aria Automation'
        'WSA'    = 'Workspace ONE Access'
    }

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
        $vcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $connection.Fqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $nodeTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($product in $products) {
        try {
            $response = Invoke-VcfGetCredentials -ResourceType $product -ErrorAction Stop
        } catch {
            continue
        }
        $friendlyProduct = if ($productFriendlyNames.ContainsKey($product)) { $productFriendlyNames[$product] } else { $product }
        $entries = @($response.Elements) | Where-Object { $_.CredentialType -eq 'SSH' }
        foreach ($entry in $entries) {
            $nodeTasks.Add([PSCustomObject]@{ FriendlyProduct = $friendlyProduct; Entry = $entry })
        }
    }

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[String]]::new()
    $warnings = [System.Collections.Generic.List[String]]::new()

    $nodeIndex = 0
    foreach ($nodeTask in $nodeTasks) {
        $nodeIndex++
        $entry = $nodeTask.Entry
        $nodeFqdn = $entry.Resource.ResourceName
        Write-VcfCheckSubProgress -Context $Context -Current $nodeIndex -Total $nodeTasks.Count `
            -Label $nodeFqdn -Unit 'appliance nodes'
        $secure = ConvertTo-SecureStringForCredential -PlainText $entry.Password
        $nodeCredential = [PSCredential]::new($entry.Username, $secure)

        $outcome = Test-VcfCheckAriaNodePasswordExpiration -VCenterFqdn $vcenterFqdn `
            -Fqdn $nodeFqdn -Product $nodeTask.FriendlyProduct -Username $entry.Username -Credential $nodeCredential
        Remove-Variable -Name nodeCredential, secure -ErrorAction SilentlyContinue

        if ($outcome.Status -eq 'Fail') {
            $failures.Add($outcome.Detail)
        } elseif ($outcome.Status -ne 'Pass') {
            $warnings.Add($outcome.Detail)
        }
        $rows.Add([PSCustomObject]@{
            Product        = $nodeTask.FriendlyProduct
            Fqdn           = $outcome.Fqdn
            Username       = $outcome.Username
            ExpirationDate = $outcome.ExpirationDate
            DaysRemaining  = $outcome.DaysRemaining
            Status         = $outcome.Status
        })
    }

    $rows = [System.Collections.Generic.List[PSCustomObject]]($rows | Sort-Object -Property Product)

    if ($rows.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Pass `
            -TargetComponent $connection.Fqdn `
            -Detail 'No Aria Suite appliance nodes with SSH credentials were found in SDDC Manager.' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    if ($failures.Count -gt 0) {
        $status = 'Fail'
        $detail = "One or more Aria Suite appliance nodes have an expired root password: $($failures -join '; ')"
        if ($warnings.Count -gt 0) {
            $detail += " Additional nodes have a root password expiration configured or could not be checked: $($warnings -join '; ')"
        }
    } elseif ($warnings.Count -gt 0) {
        $status = 'Warning'
        $detail = "One or more Aria Suite appliance nodes have a root password expiration configured or could not be checked: $($warnings -join '; ')"
    } else {
        $status = 'Pass'
        $expiringCount = @($rows | Where-Object { $_.ExpirationDate -ne 'Never' }).Count
        if ($expiringCount -gt 0) {
            $detail = "Root password on every Aria Suite appliance node is at least 30 days from expiration ($expiringCount node(s) have a configured expiration)."
        } else {
            $detail = 'Root password on every Aria Suite appliance node is set to never expire.'
        }
    }

    return New-VcfCheckResult -CheckId $checkId -Status $status `
        -TargetComponent $connection.Fqdn -Detail $detail -Rows @($rows) `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
#endregion
