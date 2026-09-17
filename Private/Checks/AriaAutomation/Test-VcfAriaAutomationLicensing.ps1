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
#region AriaAutomation
function ConvertFrom-VcfCheckVracliLicenseTable {

    <#
        .SYNOPSIS
        Parses the fixed-width table printed by `vracli license --detailed`.

        .DESCRIPTION
        Helper for Test-VcfAriaAutomationLicensing. `vracli license --detailed` has no `--json`
        output mode; it prints a header row, a dashed separator row, and zero or more data rows.
        Column boundaries are derived from the separator row's dash groups rather than by
        splitting on whitespace, because cell values (e.g. Expiration, Last Seen) contain
        internal spaces. Empty/whitespace-only input and a table with a header but no data rows
        both mean no license is active, and both return an empty array.

        .PARAMETER Output
        The raw stdout of `vracli license --detailed`.

        .OUTPUTS
        [Object[]] One object per data row, with properties named after the table's column headers.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Output
    )

    if ([String]::IsNullOrWhiteSpace($Output)) {
        return @()
    }

    $lines = $Output -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
    if ($lines.Count -lt 2 -or $lines[1] -notmatch '^-+(\s+-+)*$') {
        throw [System.InvalidOperationException]::new('Output is not a recognized "vracli license --detailed" table (missing header/dash separator row).')
    }

    $headerLine = $lines[0]
    $columns = [regex]::Matches($lines[1], '-+') | ForEach-Object {
        [PSCustomObject]@{
            Name  = $headerLine.Substring($_.Index, [Math]::Min($_.Length, [Math]::Max($headerLine.Length - $_.Index, 0))).Trim()
            Start = $_.Index
        }
    }

    if ($lines.Count -eq 2) {
        return @()
    }

    $rows = for ($lineIndex = 2; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]
        $row = [ordered]@{}
        for ($colIndex = 0; $colIndex -lt $columns.Count; $colIndex++) {
            $start = $columns[$colIndex].Start
            if ($start -ge $line.Length) {
                $row[$columns[$colIndex].Name] = ''
                continue
            }
            $end = if ($colIndex -lt $columns.Count - 1) { [Math]::Min($columns[$colIndex + 1].Start, $line.Length) } else { $line.Length }
            $row[$columns[$colIndex].Name] = $line.Substring($start, $end - $start).Trim()
        }
        [PSCustomObject]$row
    }

    return @($rows)
}
function Test-VcfAriaAutomationLicensing {

    <#
        .SYNOPSIS
        Reports Aria Automation's active license entitlement and flags a missing/invalid license.

        .DESCRIPTION
        Calls Get-VcfCheckAriaAutomationTargets to connect to every known Aria Automation
        instance, then for each target with guestOS checks enabled (a VCenterFqdn configured on
        its endpoint) connects to that vCenter and runs `vracli license --detailed` via
        Invoke-VcfApplianceCommand against a single appliance node (license state is a
        cluster-wide Kubernetes custom object in Aria Automation, not per-node, so unlike
        Test-VcfAriaAutomationApplianceHealth this does not fan out across every VmNames entry).
        `vracli license` has no `--json` output mode, so the command's fixed-width table is
        parsed with ConvertFrom-VcfCheckVracliLicenseTable. No REST equivalent exists - Aria
        Automation's IaaS API spec has no license/licensing path at all, confirming this is a
        guestOS-only surface. `vracli license --detailed` has been observed to exit non-zero
        (e.g. code 61) while still printing a valid header-only table for an unlicensed system,
        so a non-zero exit code with output present is still parsed rather than treated as a
        hard failure; only a non-zero exit code with no output is reported as an Error.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Automation instance is known at all, or if a
          target has no VCenterFqdn configured (guestOS checks not enabled for that endpoint).
        - Error: A target's connection failed, the guestOS vCenter connection or credential
          could not be established, or the guestOS command failed with no usable output
          (VMware Tools not running, VM not found, non-zero exit code with empty output,
          unrecognized table output, etc.).
        - Fail: The table has no rows (Aria Automation is unlicensed), or none of its rows has
          Valid = 'True'.
        - Pass: At least one license row has Valid = 'True'.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Automation instance with guestOS
        checks enabled.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'aria_automation_licensing'
    $licenseCommand = 'vracli license --detailed'

    $targets = Get-VcfCheckAriaAutomationTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Automation is not deployed in this environment.' -SkipReasonTag 'Aria Automation not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Automation'
    }

    $results = foreach ($target in $targets) {
        $resultDisplayName = if ($targets.Count -gt 1) { "$DisplayName ($($target.Name))" } else { $DisplayName }

        if ($target.ConnectError) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception $target.ConnectError `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        $endpoint = $Context.AriaAutomationEndpoints | Where-Object { $_.Fqdn -eq $target.Fqdn }
        if (-not $endpoint -or [String]::IsNullOrWhiteSpace($endpoint.VCenterFqdn)) {
            New-VcfCheckResult -CheckId $checkId -Status Skipped `
                -TargetComponent $target.Fqdn `
                -Detail "GuestOS checks are not enabled for `"$($target.Fqdn)`" - a vCenter FQDN must be configured on this endpoint to run the licensing check." `
                -SkipReasonTag 'GuestOS checks not enabled' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        try {
            Connect-VcfCheckVCenter -Context $Context -Fqdn $endpoint.VCenterFqdn
            $rootCredential = Get-VcfCheckAriaVCenterRootCredential -Context $Context -Fqdn $endpoint.VCenterFqdn
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception "Failed to prepare guestOS checks against `"$($endpoint.VCenterFqdn)`": $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        if ($endpoint.VmNames.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Skipped `
                -TargetComponent $target.Fqdn `
                -Detail "No VM name is configured for `"$($target.Fqdn)`" - guestOS checks never guess a VM name, since a wrong guess could silently check the wrong node; add one in the environment editor to run this check." `
                -SkipReasonTag 'VM name not configured' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }
        $vmName = $endpoint.VmNames[0]
        $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $endpoint.VCenterFqdn -Credential $rootCredential -ScriptText $licenseCommand

        $hasParsableOutput = $commandResult.ErrorCategory -eq 'NonZeroExitCode' -and -not [String]::IsNullOrWhiteSpace($commandResult.ScriptOutput)
        if (-not $commandResult.Success -and -not $hasParsableOutput) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "[$($commandResult.ErrorCategory)] $($commandResult.ErrorMessage)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        try {
            $licenseRows = ConvertFrom-VcfCheckVracliLicenseTable -Output $commandResult.ScriptOutput
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "`"$licenseCommand`" on `"$vmName`" returned output that could not be parsed: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        if ($licenseRows.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Fail `
                -TargetComponent $target.Fqdn `
                -Detail 'Aria Automation has no active license.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        foreach ($row in $licenseRows) {
            if ($row.PSObject.Properties.Name -contains 'Key') {
                $row.PSObject.Properties.Remove('Key')
            }
        }
        $licenseTable = ($licenseRows | Format-Table -AutoSize | Out-String -Width 200).Trim()
        $validRows = @($licenseRows | Where-Object { $_.Valid -eq 'True' })

        if ($validRows.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Fail `
                -TargetComponent $target.Fqdn `
                -Detail "Aria Automation has no valid license active.`n`n$licenseTable" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        New-VcfCheckResult -CheckId $checkId -Status Pass `
            -TargetComponent $target.Fqdn `
            -Detail "Active license(s):`n`n$licenseTable" `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
    }

    return @($results)
}
#endregion
