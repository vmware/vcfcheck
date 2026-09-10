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
#region NsxManagerApiHelpers
#
# The NSX Manager node/fabric/cluster REST API (Manager API, "/api/v1/...") is a distinct
# surface from the Policy API ("/policy/api/v1/...") that VMware.Sdk.Nsx.Policy covers.
# No SDK cmdlets exist for API rate-limiting, password expiration, compute-manager status, node
# disk space, or node install/upgrade. A hand-written REST helper is required, same as for
# Aria Suite Lifecycle Manager (see VrslcmHelpers.ps1).

function Invoke-VcfCheckNsxManagerApi {
    <#
        .SYNOPSIS
        Calls NSX Manager's node/fabric/cluster REST API (Manager API) with HTTP Basic Auth.

        .DESCRIPTION
        Thin Invoke-RestMethod wrapper - no PowerCLI/OpenAPI SDK covers the NSX Manager API
        namespace used by these checks (see file header). -SkipCertificateCheck is only passed
        when Context.AllowInsecureTls is $true (the run's resolved AllowInsecureTls value,
        derived from PowerCLI's InvalidCertificateAction setting - see Invoke-VcfCheck in
        Orchestrator.ps1) rather than being unconditional; an untrusted certificate encountered
        while that is $false surfaces as a
        clear, actionable error via Get-VcfCheckTlsTrustErrorMessage instead of being silently
        accepted.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER Fqdn
        The NSX Manager (cluster VIP) FQDN.

        .PARAMETER Path
        The NSX Manager API path, e.g. '/api/v1/cluster/api-service'.

        .OUTPUTS
        The parsed JSON response.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    $credential = Get-VcfCheckComponentCredential -Context $Context -ResourceType NSXT_MANAGER -AccountType SYSTEM -Fqdn $Fqdn -Username 'admin'

    try {
        return Invoke-RestMethod -Uri "https://$Fqdn$Path" -Method Get -Credential $credential -Authentication Basic `
            -ContentType 'application/json' -SkipCertificateCheck:$Context.AllowInsecureTls -ErrorAction Stop
    } catch {
        $message = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'NSX Manager' -Fqdn $Fqdn -ErrorMessage $_.Exception.Message
        if (-not $message) {
            throw
        }
        throw [System.InvalidOperationException]::new($message)
    }
}
function Get-VcfCheckNsxAlarm {
    <#
        .SYNOPSIS
        Retrieves every OPEN alarm from NSX Manager's Alarm/Event Framework (Manager API).

        .DESCRIPTION
        GET /api/v1/alarms?status=OPEN via Invoke-VcfCheckNsxManagerApi - the general alarm
        framework (manager health, remote logging, certificate expiry, cluster health, etc, per
        the NSX Manager API spec's Alarm definition). This is a distinct subsystem from the
        Policy API's /infra/realized-state/alarms (Invoke-ListAlarms, VMware.Sdk.Nsx.Policy),
        which only covers policy-intent-vs-realized-state drift and never reports alarms like
        "Remote logging not configured" - confirmed against nsx_policy_api.yaml/nsx_api.yaml in
        the VCF API specs.

        Follows the response's cursor to collect every page, since the default page_size (1000)
        could otherwise silently truncate a busy manager.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER Server
        The NSX Manager (cluster VIP) FQDN.

        .OUTPUTS
        [Object[]] the raw Alarm objects (id/status/severity/summary/recommended_action/
        node_display_name/...) across every page.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [String]$Server
    )

    $alarms = [System.Collections.Generic.List[Object]]::new()
    $path = '/api/v1/alarms?status=OPEN'
    do {
        $response = Invoke-VcfCheckNsxManagerApi -Context $Context -Fqdn $Server -Path $path -ErrorAction Stop
        foreach ($alarm in @($response.results)) { $alarms.Add($alarm) }
        $cursor = $response.cursor
        $path = if ([String]::IsNullOrEmpty($cursor)) { $null } else { "/api/v1/alarms?status=OPEN&cursor=$([Uri]::EscapeDataString($cursor))" }
    } while ($path)

    return $alarms.ToArray()
}
function Get-VcfCheckNsxManagerVersion {
    <#
        .SYNOPSIS
        Returns NSX Manager's product version as a [Version].

        .DESCRIPTION
        GET /api/v1/node/version (Manager API) via Invoke-VcfCheckNsxManagerApi, reading
        product_version. NSX version strings carry more dot-separated segments than [Version]
        supports (4 max) and use inconsistent separators before the trailing build number (see
        Test-VcfCheckBomVersionMatch for a confirmed example) - only the leading
        major.minor.patch.revision segments are needed for a >=/< comparison, so those four are
        extracted and the rest (including the build number) is discarded.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER Server
        The NSX Manager (cluster VIP) FQDN.

        .OUTPUTS
        [Version] e.g. 4.2.1.2, or $null if product_version could not be parsed.
    #>
    [CmdletBinding()]
    [OutputType([Version])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [String]$Server
    )

    $response = Invoke-VcfCheckNsxManagerApi -Context $Context -Fqdn $Server -Path '/api/v1/node/version' -ErrorAction Stop
    $productVersion = [String]$response.product_version
    $match = [Regex]::Match($productVersion, '^(\d+)\.(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) {
        return $null
    }
    return [Version]::new([Int32]$match.Groups[1].Value, [Int32]$match.Groups[2].Value, [Int32]$match.Groups[3].Value, [Int32]$match.Groups[4].Value)
}
function ConvertTo-VcfCheckHumanReadableKb {
    <#
        .SYNOPSIS
        Formats a KB quantity as a df-style human-readable string (e.g. "1.2G", "512M").

        .DESCRIPTION
        The NSX Manager transport-node status API (system_status.file_systems) reports used/total
        disk space in KB. The Aria Suite Appliance Disk Space check's DiskUsage rows carry
        Size/Used/Available strings straight from `df -h`, so this mirrors that single-letter
        suffix style (K/M/G/T, one decimal place once >= 1 of the next unit) rather than
        introducing a different-looking format for the same DiskUsage column in the HTML report.

        .PARAMETER Kb
        The quantity, in KB.

        .OUTPUTS
        [String] e.g. "930M", "1.4G".
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [Double]$Kb
    )

    $units = @('K', 'M', 'G', 'T')
    $value = $Kb
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt $units.Count - 1) {
        $value = $value / 1024
        $unitIndex++
    }
    $rounded = if ($unitIndex -eq 0) { [Math]::Round($value) } else { [Math]::Round($value, 1) }
    return "$rounded$($units[$unitIndex])"
}

#endregion NsxManagerApiHelpers
