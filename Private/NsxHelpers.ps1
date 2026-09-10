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
#region NsxHelpers
#
# Thin, mockable wrappers around VMware.Sdk.Nsx.Policy cmdlets. Confirmed via reflection that
# these carry a ServerByNameTransformationAttribute on -Server (the NSX Policy SDK's equivalent
# of the ObnArgumentTransformationAttribute found on classic PowerCLI cmdlets in
# InventoryHelpers.ps1 - same underlying problem, different attribute class name, which is why an
# initial grep for "ArgumentTransformation" alone missed it) that resolves a bare string to a live
# connection *before* a Pester mock's body ever runs. Each wrapper here has plain string
# parameters and no such attribute, so the check functions that call them can be fully
# unit-tested against mocks.
#
# Default site/enforcement-point IDs: NSX-T's non-federated default site and enforcement point
# are both literally named "default".

function Invoke-VcfCheckNsxtCheck {

    <#
        .SYNOPSIS
        Connects to the management NSX Manager and turns a scriptblock's outcome into a single
        VcfCheck.Result.

        .DESCRIPTION
        Centralizes the "resolve catalog/displayName -> resolve+connect to the management NSX
        Manager (Error result on failure) -> invoke -Body (Error result if it throws) -> build
        the final Result" skeleton duplicated near-verbatim across every check under
        Private/Checks/Nsxt - every one of those checks targets the single management NSX
        Manager, not a per-domain list like the vCenter checks (see
        Invoke-VcfCheckPerVCenterCheck for that shape).

        -Body is invoked once, after Connect-VcfCheckNsxManager has already connected, as
        `& $Body $Context $NsxFqdn`. It must return a PSCustomObject with Status and Detail;
        Rows, Blocking, Destination, Remediation and SkipReasonTag are optional and passed
        through when present - Remediation lets a check override the catalog's static remediation
        text with one tailored to the specific failure it hit, and SkipReasonTag (only meaningful
        when Status is Skipped) is a short reason shown next to the badge instead of the full
        Detail sentence.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER CheckId
        The check's catalog ID (Data/CheckCatalog.json), used to resolve DisplayName and passed
        through to the result object.

        .PARAMETER DisplayName
        Overrides the catalog's own displayName when supplied.

        .PARAMETER Body
        ScriptBlock invoked as `param($Context, $NsxFqdn) ...`, returning an outcome
        PSCustomObject with at least Status and Detail.

        .OUTPUTS
        [PSObject] a single VcfCheck.Result.

        .EXAMPLE
        Invoke-VcfCheckNsxtCheck -Context $Context -CheckId 'nsxt_sites' -DisplayName $DisplayName -Body {
            param($Context, $NsxFqdn)
            $sites = @(Get-VcfCheckNsxSite -Server $NsxFqdn)
            [PSCustomObject]@{ Status = 'Pass'; Detail = "Checked $($sites.Count) site(s)." }
        }
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CheckId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$DisplayName = '',
        [Parameter(Mandatory = $true)] [ScriptBlock]$Body
    )

    $startedAt = Get-Date
    $catalogEntry = (Get-VcfCheckCatalog)[$CheckId]
    $resolvedDisplayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }

    try {
        $nsxFqdn = Get-VcfCheckManagementNsxManagerFqdn -Context $Context
        Connect-VcfCheckNsxManager -Context $Context -Fqdn $nsxFqdn
    } catch {
        return New-VcfCheckResult -CheckId $CheckId -Status Error `
            -TargetComponent $nsxFqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resolvedDisplayName
    }

    try {
        $outcome = & $Body $Context $nsxFqdn
    } catch {
        return New-VcfCheckResult -CheckId $CheckId -Status Error `
            -TargetComponent $nsxFqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resolvedDisplayName
    }

    $resultParams = @{
        CheckId         = $CheckId
        Status          = $outcome.Status
        TargetComponent = $nsxFqdn
        Detail          = $outcome.Detail
        StartedAt       = $startedAt
        CompletedAt     = Get-Date
        DisplayName     = $resolvedDisplayName
    }
    if ($outcome.PSObject.Properties['Destination']) { $resultParams['Destination'] = $outcome.Destination }
    if ($outcome.PSObject.Properties['Rows']) { $resultParams['Rows'] = $outcome.Rows }
    if ($outcome.PSObject.Properties['Remediation']) { $resultParams['Remediation'] = $outcome.Remediation }
    if ($outcome.PSObject.Properties['Blocking'] -and $outcome.Blocking) { $resultParams['Blocking'] = $true }
    if ($outcome.Status -eq 'Skipped' -and $outcome.PSObject.Properties['SkipReasonTag']) { $resultParams['SkipReasonTag'] = $outcome.SkipReasonTag }
    return New-VcfCheckResult @resultParams
}
function Get-VcfCheckNsxBackupHistory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-GetBackupHistory (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected NSX Manager FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-GetBackupHistory -Server $Server -ErrorAction Stop
}
function Get-VcfCheckNsxBackupConfig {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-GetBackupConfig (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected NSX Manager FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-GetBackupConfig -Server $Server -ErrorAction Stop
}
function Get-VcfCheckNsxNappRegistration {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ListNappRegistrations (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected NSX Manager FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return (Invoke-ListNappRegistrations -Server $Server -ErrorAction Stop).NappRegistrationResults
}
function Get-VcfCheckNsxLatencyProfile {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ListPolicyLatencyProfiles (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected NSX Manager FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return (Invoke-ListPolicyLatencyProfiles -Server $Server -ErrorAction Stop).Results
}
function Get-VcfCheckNsxEdgeCluster {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ListEdgeClustersForEnforcementPoint (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected NSX Manager FQDN.

        .PARAMETER SiteId
        NSX site ID. Defaults to 'default' (the only site in a non-federated deployment).

        .PARAMETER EnforcementPointId
        NSX enforcement point ID. Defaults to 'default'.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $false)] [String]$SiteId = 'default',
        [Parameter(Mandatory = $false)] [String]$EnforcementPointId = 'default'
    )
    return (Invoke-ListEdgeClustersForEnforcementPoint -Server $Server -SiteId $SiteId -EnforcementpointId $EnforcementPointId -ErrorAction Stop).Results
}
function Get-VcfCheckNsxFederationConfig {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ReadFederationConfig (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected NSX Manager FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-ReadFederationConfig -Server $Server -ErrorAction Stop
}
function Get-VcfCheckNsxSite {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ListSites (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected NSX Manager FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return (Invoke-ListSites -Server $Server -ErrorAction Stop).Results
}
function Get-VcfCheckNsxEnforcementPoint {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ListEnforcementPointForSite (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected NSX Manager FQDN.

        .PARAMETER SiteId
        NSX site ID.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [String]$SiteId
    )
    return (Invoke-ListEnforcementPointForSite -Server $Server -SiteId $SiteId -ErrorAction Stop).Results
}
function Get-VcfCheckNsxTransportZone {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ListTransportZonesForEnforcementPoint (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected NSX Manager FQDN.

        .PARAMETER SiteId
        NSX site ID.

        .PARAMETER EnforcementPointId
        NSX enforcement point ID.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [String]$SiteId,
        [Parameter(Mandatory = $true)] [String]$EnforcementPointId
    )
    return (Invoke-ListTransportZonesForEnforcementPoint -Server $Server -SiteId $SiteId -EnforcementpointId $EnforcementPointId -ErrorAction Stop).Results
}
function Get-VcfCheckNsxApiServiceConfig {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-GetApiServiceConfig (see file header for why this wrapper exists).

        .DESCRIPTION
        Confirmed via Get-NsxOperation -Path '/cluster/api-service' (VMware.Sdk.Nsx.Policy) that
        NSX Manager's API rate-limiting config is covered by the Policy API despite living outside
        the /infra hierarchy most Policy API objects use. The returned ApiServiceConfig object
        includes fields for ClientApiRateLimit, ClientApiConcurrencyLimit, GlobalApiConcurrencyLimit,
        ConnectionTimeout, and RedirectHost.

        .PARAMETER Server
        The connected NSX Manager FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-GetApiServiceConfig -Server $Server -ErrorAction Stop
}

#endregion NsxHelpers
