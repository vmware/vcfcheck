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
#region Models

function New-VcfCheckResult {

    <#
        .SYNOPSIS
        Builds a standardized result object for a single precheck.

        .DESCRIPTION
        Every Test-Vcf<CheckId> function returns one of these. Returns a PSCustomObject carrying
        the check metadata and result status, including a Skipped status (for scenarios not applicable
        to the environment), a Blocking flag (for upgrade-blocking conditions), and timing fields.

        .PARAMETER CheckId
        The check identifier (e.g. "sddc_lock_table"), matching entries in Data/CheckCatalog.json.

        .PARAMETER Area
        Product area: Aria Suite, ESX, NSX, SDDC Manager, vCenter, vSAN, Tanzu, or Sample.

        .PARAMETER DisplayName
        Human-readable title shown in the report.

        .PARAMETER Status
        Pass, Warning, Fail, Error, or Skipped.

        .PARAMETER Blocking
        True if a Fail status is known to hard-block a VCF upgrade.

        .PARAMETER Informational
        True if this check always reports Pass unless the check itself fails to run - it has no
        real fail criteria of its own, it just surfaces data (inventory, versions, config dumps)
        for the reader to interpret. Distinct from Blocking: a check can have real fail criteria
        (able to Warn/Fail on evaluated data) without being a hard upgrade blocker.

        .PARAMETER TargetComponent
        The FQDN/VM/host the check actually ran against.

        .PARAMETER Destination
        The external location the check's subject reports to or depends on, when applicable
        (e.g. an NSX Manager backup target as "server:port/directoryPath"). Left blank for
        checks with no such destination.

        .PARAMETER Detail
        Evidence/result text explaining the status.

        .PARAMETER SkipReasonTag
        Short bracketed reason shown on the summary line in place of Detail when Status is
        Skipped (e.g. "Not vSAN Stretched Cluster", "HCX not installed") - Detail's full sentence is
        still shown in the expanded card. Ignored for every other Status.

        .PARAMETER ValidationCriteria
        Plain-language statement of what "Pass" means for this check.

        .PARAMETER Remediation
        Guidance for resolving a Warning/Fail status.

        .PARAMETER StartedAt
        UTC timestamp when the check began.

        .PARAMETER CompletedAt
        UTC timestamp when the check finished. Used with StartedAt to compute DurationMs.

        .PARAMETER Exception
        Exception message, populated only when Status is Error. Callers must ensure this
        text never contains a plaintext secret.

        .PARAMETER Domain
        VCF domain name this result pertains to. Left blank by checks that only ever target a
        single fleet-wide/management-only component (SDDC Manager, Aria Suite) - Invoke-VcfCheck
        backfills a blank Domain to the real Management domain name after the check returns,
        unless the check set -Component instead (see below).

        .PARAMETER DomainType
        VCF domain type ("MANAGEMENT" or "VI") matching Domain. Backfilled the same way as Domain
        when left blank.

        .PARAMETER Component
        Fleet-wide component name (e.g. "Aria Operations") for a check that has no real VCF
        domain to report - it is not scoped to any domain, so backfilling a Domain onto it (as
        happens for other fleet-wide checks like SDDC Manager) would misleadingly imply one.
        Rendered as a "Component: <value>" pill in place of the Domain pill. Setting this
        suppresses Invoke-VcfCheck's Domain/DomainType backfill for this result.

        .PARAMETER Rows
        Structured per-object rows rendered as a single flat table in the JSON/HTML report. Every
        row is expected to share one schema - see Format-VcfCheckHtmlRowsTable.

        .PARAMETER HostDetails
        Structured per-host hardware/inventory data (e.g. esxi_hardware_details), rendered as one
        collapsible section per host in the HTML report instead of Rows' single flat table - see
        Format-VcfCheckHtmlHostDetailCard. Unrelated to Rows; a check uses whichever shape
        fits its data, not both.

        .PARAMETER HostDetailsLabel
        Section heading for HostDetails in the HTML report. Defaults to "Hosts"; checks whose
        HostDetails entries are not ESX hosts (e.g. NSX transport nodes) should override this so
        the report does not mislabel the entities it lists.

        .OUTPUTS
        [PSCustomObject] with PSTypeName 'VcfCheck.Result'.

        .EXAMPLE
        New-VcfCheckResult -CheckId 'sddc_lock_table' -Area 'SddcManager' `
            -DisplayName 'SDDC Manager Platform Lock Table' -Status Fail -Blocking `
            -TargetComponent 'vcf01-sddcmgr01.example.com' `
            -Detail '3 stale lock rows older than 24h found in platform.lock' `
            -ValidationCriteria 'No lock rows with acquired_at older than 24 hours' `
            -Remediation 'Contact Broadcom support before proceeding; do not manually delete lock rows.' `
            -StartedAt $started -CompletedAt (Get-Date)
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CheckId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Area = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$DisplayName = '',
        [Parameter(Mandatory = $true)] [ValidateSet('Pass', 'Warning', 'Fail', 'Error', 'Skipped')] [String]$Status,
        [Parameter(Mandatory = $false)] [Switch]$Blocking,
        [Parameter(Mandatory = $false)] [Switch]$Informational,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$TargetComponent = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Destination = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Detail = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$SkipReasonTag = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Information = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$ValidationCriteria = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Remediation = '',
        [Parameter(Mandatory = $false)] [Nullable[DateTime]]$StartedAt = $null,
        [Parameter(Mandatory = $false)] [Nullable[DateTime]]$CompletedAt = $null,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$Exception = $null,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Domain = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$DomainType = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Component = '',
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$Rows = @(),
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$HostDetails = @(),
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$HostDetailsLabel = 'Hosts'
    )

    $validAreas = @('Aria Suite', 'ESX', 'NSX', 'SDDC Manager', 'vCenter', 'vSAN', 'Tanzu', 'Sample')
    $catalogEntry = (Get-VcfCheckCatalog)[$CheckId]

    $resolvedArea = if ($PSBoundParameters.ContainsKey('Area') -and -not [String]::IsNullOrWhiteSpace($Area)) { $Area } elseif ($catalogEntry) { [String]$catalogEntry.area } else { '' }
    $resolvedDisplayName = if ($PSBoundParameters.ContainsKey('DisplayName') -and -not [String]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName } elseif ($catalogEntry) { [String]$catalogEntry.displayName } else { '' }
    $resolvedBlocking = if ($PSBoundParameters.ContainsKey('Blocking')) { [bool]$Blocking } elseif ($catalogEntry) { [bool]$catalogEntry.blocking } else { $false }
    $resolvedInformational = if ($PSBoundParameters.ContainsKey('Informational')) { [bool]$Informational } elseif ($catalogEntry) { [bool]$catalogEntry.informational } else { $false }
    $resolvedValidationCriteria = if ($PSBoundParameters.ContainsKey('ValidationCriteria')) { $ValidationCriteria } elseif ($catalogEntry -and -not [String]::IsNullOrWhiteSpace($catalogEntry.validationCriteria)) { [String]$catalogEntry.validationCriteria } else { $null }
    $resolvedRemediation = if ($PSBoundParameters.ContainsKey('Remediation')) { $Remediation } elseif ($catalogEntry -and -not [String]::IsNullOrWhiteSpace($catalogEntry.remediation)) { [String]$catalogEntry.remediation } else { $null }
    $resolvedInformation = if ($PSBoundParameters.ContainsKey('Information')) { $Information } elseif ($catalogEntry -and -not [String]::IsNullOrWhiteSpace($catalogEntry.information)) { [String]$catalogEntry.information } else { $null }

    if ([String]::IsNullOrWhiteSpace($resolvedArea) -or $resolvedArea -notin $validAreas) {
        throw [System.InvalidOperationException]::new("New-VcfCheckResult: check id `"$CheckId`" has no catalog entry to resolve Area from, and no explicit -Area was supplied. Pass -Area explicitly for a check id that is not in Data/CheckCatalog.json.")
    }
    if ([String]::IsNullOrWhiteSpace($resolvedDisplayName)) {
        throw [System.InvalidOperationException]::new("New-VcfCheckResult: check id `"$CheckId`" has no catalog entry to resolve DisplayName from, and no explicit -DisplayName was supplied. Pass -DisplayName explicitly for a check id that is not in Data/CheckCatalog.json.")
    }

    $durationMs = $null
    if ($null -ne $StartedAt -and $null -ne $CompletedAt) {
        $durationMs = ($CompletedAt - $StartedAt).TotalMilliseconds
    }

    $resolvedRows = @()
    if ($null -ne $Rows) {
        $resolvedRows = $Rows
    }

    $resolvedHostDetails = @()
    if ($null -ne $HostDetails) {
        $resolvedHostDetails = $HostDetails
    }

    return [PSCustomObject]@{
        PSTypeName         = 'VcfCheck.Result'
        CheckId            = $CheckId
        Area               = $resolvedArea
        DisplayName        = $resolvedDisplayName
        Status             = $Status
        Blocking           = $resolvedBlocking
        Informational      = $resolvedInformational
        TargetComponent    = $TargetComponent
        Destination        = $Destination
        Domain             = $Domain
        DomainType         = $DomainType
        Component          = $Component
        Detail             = Protect-VcfCheckLogMessage -Message $Detail
        SkipReasonTag      = if ($Status -eq 'Skipped') { Protect-VcfCheckLogMessage -Message $SkipReasonTag } else { $null }
        Information        = $resolvedInformation
        ValidationCriteria = $resolvedValidationCriteria
        Remediation        = $resolvedRemediation
        StartedAt          = $StartedAt
        CompletedAt        = $CompletedAt
        DurationMs         = $durationMs
        Exception          = if ($null -ne $Exception) { Protect-VcfCheckLogMessage -Message $Exception } else { $null }
        Rows               = $resolvedRows
        HostDetails        = $resolvedHostDetails
        HostDetailsLabel   = $HostDetailsLabel
    }
}
function Get-VcfCheckBlockingStatusFromCatalog {

    <#
        .SYNOPSIS
        Retrieves the blocking status for a check from the catalog.

        .DESCRIPTION
        Looks up a check ID in CheckCatalog.json and returns its blocking flag.
        This is a convenience wrapper to avoid duplicating the catalog lookup logic
        across check functions.

        .PARAMETER CheckId
        The check identifier to look up in the catalog.

        .OUTPUTS
        [Bool] True if the check is catalog-marked as blocking, false otherwise.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CheckId
    )

    $catalog = Get-VcfCheckCatalog
    if ($catalog -and $catalog[$CheckId]) {
        return [bool]$catalog[$CheckId].blocking
    }
    return $false
}
function New-VcfCheckContext {

    <#
        .SYNOPSIS
        Builds the explicit connection/credential context object passed to every check.

        .DESCRIPTION
        Creates an explicit context object that holds all shared state (connections, credentials,
        resolved FQDNs, caches) used by check functions. Every Test-Vcf<CheckId> function
        receives this context and reads/writes through it, making checks testable in isolation
        and centralizing the connect-once-reuse-everywhere behavior in one place.

        .PARAMETER Settings
        The settings object returned by Get-VcfCheckSettings.

        .OUTPUTS
        [PSCustomObject] with PSTypeName 'VcfCheck.Context'.

        .NOTES
        ComponentCredentialCache is keyed by "<ResourceType>|<AccountType>|<Fqdn>|<Username>"
        (see Get-VcfCheckComponentCredential) rather than one dictionary per resource type -
        live testing against a real SDDC Manager showed the credentials API can return several
        distinct accounts (e.g. admin/audit/root) for the same resource + account type, so the
        cache key has to disambiguate on Username too.

        SddcManagerRootCredential is separate from ComponentCredentialCache: SDDC Manager's own
        appliance root/OS account is NOT retrievable via the VCF credentials API (confirmed
        against a live lab - it never appears in Invoke-VcfGetCredentials output), so it is
        always resolved via a dedicated interactive prompt (Get-VcfCheckSddcManagerRootCredential)
        and cached here instead.

        VrslcmConnection is separate from ComponentCredentialCache for a different reason: Aria
        Suite Lifecycle Manager (VRSLCM) is a fleet-wide shared service with no per-domain FQDN
        lookup (unlike vCenter/NSX Manager, which are resolved from a known domain first) - its
        FQDN can only be discovered from the credential API response itself
        (Invoke-VcfGetCredentials -ResourceType VRSLCM -> Elements[].Resource.Fqdn), so the
        Fqdn/Credential pair is resolved and cached together by Get-VcfCheckVrslcmConnection
        rather than looked up by a caller-supplied Fqdn.

        VrslcmRootCredential is cached separately from VrslcmConnection because it is a different
        SDDC Manager credential entry (CredentialType 'SSH', not 'API') - see
        Get-VcfCheckVrslcmRootCredential.

        AriaOpsCredential/AriaOpsConnection/UnreachableAriaOps mirror the VrslcmConnection /
        UnreachableVCenters caches for Aria Operations - see Get-VcfCheckAriaOpsCredential and
        Connect-VcfCheckAriaOps in Private/AriaOpsHelpers.ps1. Aria Operations has full SDK
        coverage (VMware.Sdk.Vcf.Ops), so unlike VRSLCM there is no separate REST-API-session
        cache - Invoke-VcfOps* cmdlets take AriaOpsConnection directly via -Server.

        VCenterApiSessions caches vSphere Automation API session tokens (POST /api/session)
        keyed by vCenter FQDN, for checks that call vCenter's own REST API directly rather than
        through PowerCLI (e.g. namespace-management, appliance health/proxy endpoints) - see
        Private/VCenterApiHelpers.ps1.

        AllVCenterFqdns caches every vCenter FQDN SDDC Manager knows about (management domain and
        every workload domain), resolved by Get-VcfCheckAllVCenterFqdns. Checks that inspect
        vCenter/ESXi/vSAN inventory iterate this list rather than the single
        ManagementVCenterFqdn, so every workload domain's clusters/hosts are covered, not just
        the management domain's.

        VCenterDomainTypesByFqdn is the DomainType sibling of VCenterDomainsByFqdn (kept as a
        separate cache rather than changing that dictionary's value shape, so existing consumers
        of the name-only cache are unaffected) - see Get-VcfCheckVCenterDomainType.

        DomainsByName caches the full domain object (Name, SsoName, IsManagementSsoDomain, Type,
        VCenters, etc.) returned by Invoke-VcfGetDomains, keyed by domain name - populated
        alongside VCenterDomainsByFqdn by Get-VcfCheckAllVCenterFqdns. Needed by
        Get-VcfCheckVCenterSsoCredential to tell an isolated-SSO workload domain (its own PSC/
        SYSTEM credential) from one that joined the Management domain's shared SSO domain (must
        use the Management domain's own credential instead) - a vCenter's PSC/SYSTEM credential in
        SDDC Manager is registered against the owning SSO domain's name, not the vCenter's own
        FQDN, so looking it up by Fqdn silently returns no match for a workload domain vCenter.

        SelectedDomains carries Invoke-VcfCheck's -Domain run-scope filter (domain names,
        empty array = no filtering) so Get-VcfCheckAllVCenterFqdns can exclude out-of-scope
        domains' vCenters before any check connects to them.

        OutputPath is Invoke-VcfCheck's resolved findings directory (the same directory
        latest.json is written to), set once before the check loop starts. It lets a long-running
        check report sub-progress (e.g. "host 3/12") via Write-VcfCheckSubProgress without
        needing its own -OutputPath parameter.

        AllowInsecureTls is the resolved, effective decision for this run on whether to accept
        untrusted/self-signed TLS certificates - derived entirely from PowerCLI's own
        InvalidCertificateAction setting (see Invoke-VcfCheck in Orchestrator.ps1; there is no
        VcfCheck-specific setting). Every connector that would otherwise unconditionally bypass
        TLS certificate validation (Aria Automation/Aria Operations/VRSLCM/NSX Manager REST
        helpers) reads this instead of hard-coding the bypass, so an operator who has not opted in
        (via PowerCLI's own configuration) gets a clear connection failure instead of a silently
        accepted untrusted certificate.

        AriaAutomationCredential caches the resolved Fqdn/Credential/AllowInsecureTls object for
        Aria Automation - see Get-VcfCheckAriaAutomationCredential in
        Private/AriaAutomationHelpers.ps1. A single cache entry is sufficient because, unlike
        VRSLCM/Aria Operations, Aria Automation is looked up once per run and reused by every
        check that calls Invoke-VcfCheckAriaAutomationApi.

        UnreachableVCenters caches, per vCenter FQDN, the reason Connect-VcfCheckVCenter last
        failed to reach or authenticate to it. Confirmed live: when a vCenter drops mid-run, every
        remaining check that targets it independently re-attempts the connection and each surfaces
        its own raw PowerCLI exception text ("Server X is not connected" from Get-VIMachineCertificate,
        a different message from Get-VMHost, etc.) - a confusing, repetitive report for one real
        outage. Connect-VcfCheckVCenter checks this cache first and fails fast with the same
        message every time instead of re-running the TCP/auth attempt (and its timeout) for every
        check that targets the same dead vCenter.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$Settings = $null
    )

    return [PSCustomObject]@{
        PSTypeName                = 'VcfCheck.Context'
        Settings                  = $Settings
        SddcManagerFqdn            = $null
        SddcManagerConnection      = $null
        SddcManagerRootCredential  = $null
        ManagementVCenterFqdn      = $null
        ManagementNsxManagerFqdn   = $null
        ManagementDomainId         = $null
        ManagementDomainObject     = $null
        AllVCenterFqdns            = $null
        VcfVersion                 = $null
        VCenterDomainsByFqdn       = @{}
        VCenterDomainTypesByFqdn   = @{}
        DomainsByName              = @{}
        SelectedDomains            = @()
        AllowInsecureTls           = $false
        VrslcmConnection           = $null
        VrslcmRootCredential       = $null
        AriaOpsCredential          = $null
        AriaOpsConnection          = $null
        UnreachableAriaOps         = $null
        AriaOpsEndpointConnections = @{}
        UnreachableAriaOpsEndpoints = @{}
        AriaOpsEndpoints           = @()
        AriaOpsEndpointCredentials = @{}
        AriaAutomationCredential   = $null
        VCenterApiSessions         = @{}
        ComponentCredentialCache   = @{}
        ConnectedVCenters          = [System.Collections.Generic.List[String]]::new()
        ConnectedNsxManagers       = [System.Collections.Generic.List[String]]::new()
        UnreachableVCenters        = @{}
        LogPath                    = $null
        OutputPath                 = $null
    }
}

#endregion Models
