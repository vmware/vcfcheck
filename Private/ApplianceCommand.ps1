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
#region ApplianceCommand
#
# Guest OS command execution via VMware Tools guest operations. Provides proactive VMware Tools
# status checking (fail immediately rather than timing out), exit-code handling, and error
# classification so callers receive deterministic pass/fail semantics with actionable error messages.
#
# Get-VM and Invoke-VMScript are wrapped for unit testing: PowerCLI's parameter binding
# transformations occur before Pester mocks, making direct testing impossible. Wrappers with
# plain parameter types bypass this, enabling full test coverage of the business logic.

function Get-VcfCheckVM {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VM (see file header for why this wrapper exists).
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$VmName,
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-VM -Name $VmName -Server $Server -ErrorAction Stop
}
function Get-VcfCheckVMsByServer {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VM -Server (see file header for why this wrapper exists).
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-VM -Server $Server -ErrorAction Stop
}
function Get-VcfApplianceHostAddresses {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around [System.Net.Dns]::GetHostAddresses.
    #>
    [CmdletBinding()]
    [OutputType([String[]])]
    Param (
        [Parameter(Mandatory = $true)] [String]$Fqdn
    )
    return @([System.Net.Dns]::GetHostAddresses($Fqdn) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
}
function Find-VcfCheckVMByToolsIpAddress {

    <#
        .SYNOPSIS
        Falls back to locating an appliance VM by its VMware Tools-reported IP address when a
        name lookup fails.

        .DESCRIPTION
        Helper for Invoke-VcfApplianceCommand. Resolves -Fqdn to an IPv4 address via DNS, then
        scans every VM on -Server for a VMware Tools guest IP matching it - covers the case where
        an appliance is registered in SDDC Manager under an FQDN whose hostname label does not
        match the VM's inventory display name (confirmed live: a WSA/Workspace ONE Access node
        with no vCenter VM named after its FQDN's short hostname).

        .PARAMETER Fqdn
        Appliance FQDN to resolve to an IP address.

        .PARAMETER Server
        FQDN of the already-connected vCenter to search.

        .OUTPUTS
        The matching VM object, or $null if DNS resolution fails or no VM's guest IP matches.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server
    )

    try {
        $ipAddress = Get-VcfApplianceHostAddresses -Fqdn $Fqdn | Select-Object -First 1
    } catch {
        Write-LogMessage -Type DEBUG -Message "DNS resolution failed for `"$Fqdn`": $($_.Exception.Message)"
        return $null
    }
    if (-not $ipAddress) {
        return $null
    }

    try {
        $vms = Get-VcfCheckVMsByServer -Server $Server
    } catch {
        return $null
    }

    $match = $vms | Where-Object { @($_.Guest.IPAddress) -contains $ipAddress } | Select-Object -First 1
    if ($match) {
        Write-LogMessage -Type DEBUG -Message "Resolved `"$Fqdn`" to IP `"$ipAddress`" and matched VM `"$($match.Name)`" by VMware Tools guest IP."
    }
    return $match
}
function Invoke-VcfCheckVMScript {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-VMScript (see file header for why this wrapper exists).

        .DESCRIPTION
        Invoke-VMScript writes its own "[percent complete: N]" progress record while it waits on
        the guest operation - confirmed live that this renders as raw, unstyled noise in the
        console (Write-Progress's default host rendering), unrelated to and inconsistent with
        this module's own Write-LogMessage-based console output. Suppressed by setting
        $ProgressPreference to SilentlyContinue for the scope of this function only - a plain
        (non-$script:/$global:) variable assignment in PowerShell is function-scoped and reverts
        automatically on return, so this has no effect on the caller's session preference.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$VmName,
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [String]$ScriptText,
        [Parameter(Mandatory = $true)] [PSCredential]$Credential,
        [Parameter(Mandatory = $true)] [Int]$ToolsWaitSecs
    )
    $ProgressPreference = 'SilentlyContinue'
    return Invoke-VMScript -VM $VmName -Server $Server -ScriptText $ScriptText -GuestCredential $Credential -ToolsWaitSecs $ToolsWaitSecs -ErrorAction Stop
}
function Get-VcfApplianceErrorCategory {
    <#
        .SYNOPSIS
        Classifies an Invoke-VMScript exception message into a stable error category.

        .DESCRIPTION
        Pure string matching, no PowerCLI calls - kept as its own function so the
        classification rules are unit-testable independent of any live/mocked cmdlet call.

        .PARAMETER ErrorMessage
        The exception message text to classify.

        .OUTPUTS
        [String] one of VmNotFound, GuestAuthenticationFailed, ToolsNotRunning,
        TlsConnectionFailed, or Unknown.

        .NOTES
        TlsConnectionFailed (originally named UntrustedCertificate) was renamed after live-lab
        testing showed the top-level "The SSL connection could not be established" message can
        wrap a variety of unrelated inner causes (confirmed case: an IOException "unexpected EOF"
        from a TLS handshake being dropped mid-negotiation, not a certificate-trust decision at
        all) - "untrusted certificate" was an incorrect assumption baked into the category name.
        Do not assume Set-PowerCLIConfiguration -InvalidCertificateAction Ignore or any other
        certificate-trust override will resolve this category; the real cause needs the full
        exception chain (see $_.Exception.InnerException), which this classifier deliberately
        does not have access to.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$ErrorMessage
    )

    $category = switch -Regex ($ErrorMessage) {
        'Value cannot be found for the mandatory parameter VM' { 'VmNotFound'; break }
        'Failed to authenticate with the guest operating system' { 'GuestAuthenticationFailed'; break }
        'The guest operations agent could not be contacted' { 'ToolsNotRunning'; break }
        'The SSL connection could not be established' { 'TlsConnectionFailed'; break }
        default { 'Unknown' }
    }
    return $category
}
function New-VcfCheckApplianceCommandResult {

    <#
        .SYNOPSIS
        Builds a standardized result object for an appliance command execution.

        .PARAMETER Success
        Whether the command succeeded.

        .PARAMETER ExitCode
        The exit code from the guest command (null if the guest operation itself failed).

        .PARAMETER ScriptOutput
        The captured output from the guest command (null if not applicable).

        .PARAMETER ErrorCategory
        One of VmNotFound, GuestAuthenticationFailed, ToolsNotRunning, TlsConnectionFailed, NonZeroExitCode, or Unknown.

        .PARAMETER ErrorMessage
        Human-readable error message (populated only on failure).

        .OUTPUTS
        [PSCustomObject] with PSTypeName 'VcfCheck.ApplianceCommandResult'.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [Bool]$Success,
        [Parameter(Mandatory = $false)] [AllowNull()] [Int]$ExitCode = $null,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$ScriptOutput = $null,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$ErrorCategory = $null,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$ErrorMessage = $null
    )

    return [PSCustomObject]@{
        PSTypeName    = 'VcfCheck.ApplianceCommandResult'
        Success       = $Success
        ExitCode      = $ExitCode
        ScriptOutput  = $ScriptOutput
        ErrorCategory = $ErrorCategory
        ErrorMessage  = $ErrorMessage
    }
}
function Invoke-VcfApplianceCommand {

    <#
        .SYNOPSIS
        Runs a guest-OS command inside an appliance VM via VMware Tools guest operations.

        .DESCRIPTION
        Wraps Invoke-VMScript. The target VM is addressed by bare display name + -Server
        (not a Get-VM object lookup) - this requires PowerCLI's DefaultVIServerMode to be
        'Multiple' (set at module import) so more than one vCenter can stay connected at once.

        Before invoking the script, proactively checks that VMware Tools is actually running on
        the target VM and returns a ToolsNotRunning result immediately rather than waiting on
        Invoke-VMScript to time out and fail with a generic error.

        On failure, classifies the exception message against known PowerCLI/Invoke-VMScript
        error text (bad VM name, bad guest credentials, guest-ops agent down, untrusted cert) so
        callers can give an actionable error rather than a raw exception string.

        If the initial name lookup finds no VM and -Fqdn is supplied, falls back to
        Find-VcfCheckVMByToolsIpAddress before giving up - resolves -Fqdn via DNS and matches
        it against every VM's VMware Tools-reported guest IP on -Server.

        A script that runs but exits non-zero (Invoke-VMScript itself does not throw for this -
        it only throws when the guest-ops call itself fails) is also reported as a failure with
        ErrorCategory 'NonZeroExitCode' and an ErrorMessage naming the exit code and any captured
        output - confirmed live that without this, a caller reading only .ErrorMessage on failure
        (e.g. vcenter_machine_ssl_mismatch's lstool.py call) saw a blank Detail with no indication
        of what went wrong.

        A guest-ops call that fails with ErrorCategory 'TlsConnectionFailed' or 'Unknown' is
        retried up to 3 attempts total (10 second delay between attempts) before being reported
        as a failure, matching the retry pattern already used by Invoke-VcfCheckVrslcmApi
        (VrslcmHelpers.ps1) - both categories have been observed live to wrap transient network
        blips (a dropped TLS handshake, a momentarily unreachable guest-ops agent) rather than a
        durable condition, unlike 'VmNotFound', 'GuestAuthenticationFailed', and 'ToolsNotRunning'
        (checked before any guest-ops call is attempted, or caused by something retrying cannot
        fix) or 'NonZeroExitCode' (the guest command ran to completion; an immediate re-run would
        not change its outcome).

        .PARAMETER VmName
        Display name of the target VM in vCenter inventory (e.g. the short hostname).

        .PARAMETER Server
        FQDN of the already-connected vCenter that manages this VM.

        .PARAMETER Fqdn
        Optional appliance FQDN to fall back to resolving by VMware Tools guest IP address if
        -VmName is not found in vCenter inventory.

        .PARAMETER Credential
        Guest OS credential (e.g. root) to authenticate the guest operation.

        .PARAMETER ScriptText
        Bash command/script to run inside the guest. ScriptType is intentionally left at its
        Invoke-VMScript default (Bash) - every appliance guest this tool targets is Photon/Linux.

        .PARAMETER ToolsWaitSecs
        Seconds to wait for VMware Tools guest operations to become available. Default 30.

        .OUTPUTS
        [PSCustomObject] with PSTypeName 'VcfCheck.ApplianceCommandResult': Success (bool),
        ExitCode (int or $null), ScriptOutput (string or $null), ErrorCategory (string or $null),
        ErrorMessage (string or $null).

        .EXAMPLE
        Invoke-VcfApplianceCommand -VmName 'vcf01' -Server 'm01-vc01.example.com' -Credential $rootCred -ScriptText 'df -h /'
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VmName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Fqdn = '',
        [Parameter(Mandatory = $true)] [PSCredential]$Credential,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ScriptText,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 300)] [Int]$ToolsWaitSecs = 30
    )

    try {
        $vm = Get-VcfCheckVM -VmName $VmName -Server $Server
    } catch {
        $vm = $null
        if (-not [String]::IsNullOrWhiteSpace($Fqdn)) {
            $vm = Find-VcfCheckVMByToolsIpAddress -Fqdn $Fqdn -Server $Server
        }
        if (-not $vm) {
            return New-VcfCheckApplianceCommandResult -Success $false -ErrorCategory 'VmNotFound' `
                -ErrorMessage "No VM named `"$VmName`" found on `"$Server`"."
        }
        Write-LogMessage -Type DEBUG -Message "`"$VmName`" not found by name on `"$Server`" - using `"$($vm.Name)`" resolved via VMware Tools IP address instead."
        $VmName = $vm.Name
    }

    if ($vm.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') {
        Write-LogMessage -Type WARNING -Message "VMware Tools is not running on `"$VmName`" (status: $($vm.ExtensionData.Guest.ToolsRunningStatus))."
        return New-VcfCheckApplianceCommandResult -Success $false -ErrorCategory 'ToolsNotRunning' `
            -ErrorMessage "VMware Tools is not running on `"$VmName`" (status: $($vm.ExtensionData.Guest.ToolsRunningStatus))."
    }

    $maxAttempts = 3
    $retryDelaySeconds = 10
    $transientErrorCategories = @('TlsConnectionFailed', 'Unknown')

    Write-LogMessage -Type DEBUG -Message "Invoking Invoke-VMScript on `"$VmName`" with command: $ScriptText"
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $result = Invoke-VcfCheckVMScript -VmName $VmName -Server $Server -ScriptText $ScriptText -Credential $Credential -ToolsWaitSecs $ToolsWaitSecs
            Write-LogMessage -Type DEBUG -Message "Invoke-VMScript succeeded. ExitCode=$($result.ExitCode)"
            break
        } catch {
            # The top-level message alone can be misleading - "The SSL connection could not be
            # established" turned out (against a live lab) to wrap an unrelated IOException
            # ("unexpected EOF") rather than a certificate-trust decision. Walk the full chain so the
            # real cause is visible in the result rather than just the generic wrapper text.
            $messages = [System.Collections.Generic.List[String]]::new()
            $currentException = $_.Exception
            while ($currentException) {
                $messages.Add($currentException.Message)
                $currentException = $currentException.InnerException
            }
            $errorMessage = $messages -join ' | '
            $category = Get-VcfApplianceErrorCategory -ErrorMessage $_.Exception.Message

            if ($transientErrorCategories -contains $category -and $attempt -lt $maxAttempts) {
                Write-LogMessage -Type DEBUG -Message "Transient error invoking Invoke-VMScript on `"$VmName`" (attempt $attempt of $maxAttempts). Category=$category. Error=$errorMessage. Retrying in $retryDelaySeconds seconds."
                Start-Sleep -Seconds $retryDelaySeconds
                continue
            }

            Write-LogMessage -Type ERROR -Message "Invoke-VMScript failed on `"$VmName`". Category=$category. Error=$errorMessage"
            return New-VcfCheckApplianceCommandResult -Success $false -ErrorCategory $category -ErrorMessage $errorMessage
        }
    }

    if ($result.ExitCode -ne 0) {
        $exitMessage = "Guest command exited with code $($result.ExitCode)."
        if (-not [String]::IsNullOrWhiteSpace($result.ScriptOutput)) {
            $exitMessage = "$exitMessage Output: $($result.ScriptOutput.Trim())"
        }
        Write-LogMessage -Type ERROR -Message "Invoke-VMScript on `"$VmName`" exited non-zero. $exitMessage"
        return New-VcfCheckApplianceCommandResult -Success $false -ExitCode $result.ExitCode -ScriptOutput $result.ScriptOutput `
            -ErrorCategory 'NonZeroExitCode' -ErrorMessage $exitMessage
    }

    return New-VcfCheckApplianceCommandResult -Success $true -ExitCode $result.ExitCode -ScriptOutput $result.ScriptOutput
}
function New-VcfCheckApplianceCommandFailureResult {

    <#
        .SYNOPSIS
        Turns a failed ApplianceCommandResult into the appropriate VcfCheck.Result - Skipped
        when VMware Tools isn't running, Error for every other failure category.

        .DESCRIPTION
        Invoke-VcfApplianceCommand proactively checks VMware Tools' running status before ever
        attempting a guest operation, and reports that specific case via ErrorCategory
        'ToolsNotRunning' rather than a generic failure. Every check built on top of it treats
        that case as Skipped, not Error, via this shared helper - VMware Tools being stopped on
        an appliance (mid-patch, recently rebooted, etc.) is a normal, expected condition, not a
        defect in the check itself or something requiring the same investigation a genuine
        execution failure (bad VM name, bad guest credentials, guest-ops agent down) does.

        .PARAMETER CommandResult
        The ApplianceCommandResult returned by a failed Invoke-VcfApplianceCommand call
        (Success = $false).

        .PARAMETER CheckId
        .PARAMETER Area
        .PARAMETER DisplayName
        .PARAMETER TargetComponent
        .PARAMETER ValidationCriteria
        .PARAMETER Remediation
        .PARAMETER StartedAt
        Passed straight through to New-VcfCheckResult when supplied; omitted parameters let
        New-VcfCheckResult resolve them from Data/CheckCatalog.json by -CheckId instead - the
        expected path for every real check, so its own catalog entry stays the single source of
        truth instead of a second copy living in the check's own file.

        .OUTPUTS
        [PSObject] a VcfCheck.Result with Status Skipped (ToolsNotRunning) or Error (anything
        else).
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CommandResult,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CheckId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Area = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$TargetComponent = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$ValidationCriteria = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Remediation = '',
        [Parameter(Mandatory = $true)] [DateTime]$StartedAt
    )

    $resultParams = @{
        TargetComponent = $TargetComponent
        StartedAt       = $StartedAt
        CompletedAt     = (Get-Date)
    }
    if ($PSBoundParameters.ContainsKey('Area')) { $resultParams['Area'] = $Area }
    if ($PSBoundParameters.ContainsKey('DisplayName')) { $resultParams['DisplayName'] = $DisplayName }
    if ($PSBoundParameters.ContainsKey('ValidationCriteria')) { $resultParams['ValidationCriteria'] = $ValidationCriteria }

    if ($CommandResult.ErrorCategory -eq 'ToolsNotRunning') {
        return New-VcfCheckResult -CheckId $CheckId -Status Skipped `
            -Detail "This check cannot run without VMware Tools running on the target appliance - skipped for now. $($CommandResult.ErrorMessage)" `
            -SkipReasonTag 'VMware Tools not running' `
            @resultParams
    }

    if ($PSBoundParameters.ContainsKey('Remediation')) { $resultParams['Remediation'] = $Remediation }
    return New-VcfCheckResult -CheckId $CheckId -Status Error -Exception $CommandResult.ErrorMessage @resultParams
}
function Invoke-VcfCheckVCenterApplianceCliCheck {

    <#
        .SYNOPSIS
        Shared driver for a vCenter-appliance check that runs one guest-OS CLI command per
        vCenter and parses its output.

        .DESCRIPTION
        Factors out the identical skeleton previously duplicated across Test-VcfVcenterCRLs,
        Test-VcfVcenterMachineIdCheck, Test-VcfVcenterVmdirDatabaseSizeCheck, and
        Test-VcfVcenterVmdirLocalStateCheck: resolve the catalog entry, iterate every vCenter
        SDDC Manager knows about (Get-VcfCheckAllVCenterFqdns), connect and fetch the guest
        root credential through the management vCenter (every vCenter appliance VM - including a
        workload domain's - is hosted on the management domain's compute, never on the vCenter it
        represents), run -ScriptText via Invoke-VcfApplianceCommand, handle the ToolsNotRunning/
        error cases, and turn the per-vCenter outcomes into one VcfCheck.Result per domain via
        New-VcfCheckPerDomainResults. Each check now supplies only its -ScriptText and a
        -ParseOutcome scriptblock for the logic that's actually specific to it.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER CheckId
        The catalog check ID (e.g. 'vcenter_machine_id_check'), used to resolve displayName,
        validationCriteria, remediation, and blocking status from Data/CheckCatalog.json.

        .PARAMETER ScriptText
        Guest-OS command to run on each vCenter appliance via Invoke-VcfApplianceCommand.

        .PARAMETER ParseOutcome
        Scriptblock invoked once per vCenter with the successful ApplianceCommandResult as its
        first positional argument. Must return a PSCustomObject with Status/Detail/Rows
        properties - Rows may be omitted or empty.

        .PARAMETER DisplayName
        Overrides the catalog's displayName when supplied.

        .OUTPUTS
        [PSObject] a VcfCheck.Result.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CheckId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ScriptText,
        [Parameter(Mandatory = $true)] [ScriptBlock]$ParseOutcome,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $catalogEntry = (Get-VcfCheckCatalog)[$CheckId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }
    $validationCriteria = $catalogEntry.validationCriteria
    $remediation = $catalogEntry.remediation
    $blocking = Get-VcfCheckBlockingStatusFromCatalog -CheckId $CheckId

    try {
        $vcenterFqdns = Get-VcfCheckAllVCenterFqdns -Context $Context
        $managementVCenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $CheckId -Area vCenter -Status Error `
            -Exception $_.Exception.Message -ValidationCriteria $validationCriteria -Remediation $remediation -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $outcomes = foreach ($vcenterFqdn in $vcenterFqdns) {
        $iterationStartedAt = Get-Date
        $outcome = & {
            try {
                Connect-VcfCheckVCenter -Context $Context -Fqdn $managementVCenterFqdn
                $rootCredential = Get-VcfCheckComponentCredential -Context $Context -ResourceType VCENTER -AccountType USER -Fqdn $vcenterFqdn -Username 'root'
                $vmName = ($vcenterFqdn -split '\.')[0]

                $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $managementVCenterFqdn -Credential $rootCredential -ScriptText $ScriptText

                if (-not $commandResult.Success) {
                    if ($commandResult.ErrorCategory -eq 'ToolsNotRunning') {
                        $detail = "This check cannot run without VMware Tools running on the target appliance - skipped for now. $($commandResult.ErrorMessage)"
                        return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Skipped'; Detail = $detail; Blocking = $blocking; Rows = @() }
                    }
                    return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = $commandResult.ErrorMessage; Blocking = $blocking; Rows = @() }
                }

                $parsed = & $ParseOutcome $commandResult
                return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = $parsed.Status; Detail = $parsed.Detail; Blocking = $blocking; Rows = @($parsed.Rows) }
            } catch {
                return [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = $_.Exception.Message; Blocking = $blocking; Rows = @() }
            }
        }
        $outcome | Add-Member -NotePropertyName StartedAt -NotePropertyValue $iterationStartedAt -Force
        $outcome | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date) -Force
        $outcome
    }

    return New-VcfCheckPerDomainResults -Context $Context -PerVCenterOutcome $outcomes -CheckId $CheckId -Area vCenter `
        -ValidationCriteria $validationCriteria -Remediation $remediation -StartedAt $startedAt -DisplayName $displayName
}
function ConvertFrom-VcfCheckDfOutput {

    <#
        .SYNOPSIS
        Parses `df -h` output into one row object per filesystem.

        .DESCRIPTION
        Shared by every check that runs `df -h` on an appliance (SDDC Manager, vCenter) so the
        report can render an actual per-filesystem table instead of dumping the raw `df -h` text
        into Detail. Skips the header line; a data row with fewer than the expected 6 whitespace-separated
        fields (Filesystem, Size, Used, Available, Use%, Mounted-on) is skipped rather than guessed at.
        A mount path containing an embedded space (rare, but not impossible) is rejoined from
        whatever fields remain after the first 5, rather than truncated.

        .PARAMETER ScriptOutput
        The raw stdout of a `df -h` guest command.

        .OUTPUTS
        [Object[]] one PSCustomObject per filesystem, each with Filesystem/Size/Used/Available/
        UsedPercent/MountedOn properties. Empty array for blank/header-only input.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$ScriptOutput = ''
    )

    $rows = [System.Collections.Generic.List[Object]]::new()
    $lines = @($ScriptOutput -split "`r?`n" | Where-Object { -not [String]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -le 1) {
        return $rows.ToArray()
    }

    foreach ($line in ($lines | Select-Object -Skip 1)) {
        $fields = $line.Trim() -split '\s+'
        if ($fields.Count -lt 6) { continue }
        $rows.Add([PSCustomObject]@{
            Filesystem  = $fields[0]
            Size        = $fields[1]
            Used        = $fields[2]
            Available   = $fields[3]
            UsedPercent = $fields[4]
            MountedOn   = ($fields[5..($fields.Count - 1)] -join ' ')
        })
    }

    return $rows.ToArray()
}
function Get-VcfCheckPsqlExecutablePath {

    <#
        .SYNOPSIS
        Resolves the correct, version-specific psql client path for an SDDC Manager appliance
        appliance guest-ops command, instead of relying on a bare `psql` PATH lookup.

        .DESCRIPTION
        SDDC Manager checks querying its internal PostgreSQL database (platform.lock,
        platform.vx_manager, platform.credentialhistory) require an absolute, version-pinned
        psql path per SDDC Manager major(.minor) version. Relying on a bare `psql` PATH lookup
        can fail with `fe_sendauth: error sending password authentication` if PATH resolves to a
        version not trusted by the local pg_hba.conf for passwordless loopback access.

        Resolves absolute paths based on VCF version (e.g., '/usr/pgsql/13/bin/psql' for VCF
        4.x/5.x, '/usr/pgsql/15/bin/psql' for VCF 9.0, '/usr/pgsql/16/bin/psql' for VCF 9.1+) to
        ensure deterministic database interaction across all environment versions.

        .PARAMETER VcfVersion
        The SDDC Manager version string (e.g. from Get-VcfCheckVcfVersion, "5.2.1.0-24305054").

        .OUTPUTS
        [String] an absolute path to the version-appropriate psql client, or the bare string
        'psql' if VcfVersion doesn't parse or no mapping matches (falls back to standard PATH lookup).
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [AllowNull()] [String]$VcfVersion
    )

    $versionMap = @{
        '4'   = '/usr/pgsql/13/bin/psql'
        '5'   = '/usr/pgsql/13/bin/psql'
        '9'   = '/usr/pgsql/15/bin/psql'
        '9.1' = '/usr/pgsql/16/bin/psql'
    }

    if ([String]::IsNullOrWhiteSpace($VcfVersion)) {
        return 'psql'
    }

    $match = [Regex]::Match($VcfVersion, '^(\d+)(?:\.(\d+))?')
    if (-not $match.Success) {
        return 'psql'
    }

    $major = $match.Groups[1].Value
    $majorMinor = if ($match.Groups[2].Success) { "$major.$($match.Groups[2].Value)" } else { $major }

    if ($versionMap.ContainsKey($majorMinor)) {
        return $versionMap[$majorMinor]
    }
    if ($versionMap.ContainsKey($major)) {
        return $versionMap[$major]
    }
    return 'psql'
}

#endregion ApplianceCommand
