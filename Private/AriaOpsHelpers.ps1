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
#region AriaOpsHelpers
#
# Aria Operations has full PowerCLI/OpenAPI SDK coverage via VMware.Sdk.Vcf.Ops (nested inside
# VCF.PowerCLI) - unlike VRSLCM, no hand-written REST helper is needed. Checks call the
# Invoke-VcfOps* cmdlets directly (e.g. Invoke-VcfOpsGetAlerts), passing the connection object
# this file resolves as -Server.
#
# Aria Operations has no per-domain FQDN lookup - like VRSLCM, Invoke-VcfGetCredentials
# -ResourceType VROPS is the only source for both its FQDN and credential. Credential filtering
# on CredentialType -eq 'API' is done client-side because Invoke-VcfGetCredentials lacks a
# -CredentialType parameter (only -AccountType is available).
#
# Aria Operations can also be deployed entirely outside SDDC Manager/VRSLCM (SDDC Manager has
# zero knowledge of it) - see Get-VcfCheckEnvironmentAriaOpsEndpoints, which resolves the
# user-declared Integrations list on an environment (Private/Environments.ps1) instead of
# Invoke-VcfGetCredentials. Connect-VcfCheckAriaOpsEndpoint connects to one of those directly by
# FQDN + credential, with no SDDC Manager lookup at all.
#
# Invoke-VcfOpsGetResourcesOfAdapterInstance (VMware.Sdk.Vcf.Ops 13.5.0.25380678, the newest
# release at time of writing) sends a malformed 'adapterId' value for this specific endpoint - a
# resource-kind schema version tag (e.g. "Variant.8,Version.4") instead of the real adapter
# instance GUID - so Aria Operations rejects every call with HTTP 400. Get-VcfCheckAriaOpsAdapterResources
# below bypasses the SDK for this one call and hits '/suite-api/api/adapters/{id}/resources'
# directly via Invoke-VcfCheckAriaOpsApi, the same REST-fallback pattern VrslcmHelpers.ps1 uses -
# except unlike VRSLCM, suite-api does not accept HTTP Basic Auth on ordinary endpoints, so
# Invoke-VcfCheckAriaOpsApi first exchanges the credential for a session token via
# Get-VcfCheckAriaOpsApiToken ('/suite-api/api/auth/token/acquire') and sends it as an
# 'Authorization: vRealizeOpsToken <token>' header instead.
#
# Invoke-VcfOpsGetResource sends the same malformed schema-version-tag value as its 'id', so
# Get-VcfCheckAriaOpsResource below hits '/suite-api/api/resources/{id}' directly via
# Invoke-VcfCheckAriaOpsApi instead. Test-VcfAriaOpsCriticalAlerts guards with [Guid]::TryParse
# before calling it, since Alert.ResourceId can independently arrive non-GUID.

function Get-VcfCheckAriaOpsCredential {
    <#
        .SYNOPSIS
        Resolves and caches Aria Operations' FQDN and API credential from SDDC Manager.

        .DESCRIPTION
        Calls Invoke-VcfGetCredentials -ResourceType VROPS once per run and caches the result on
        $Context. Returns $null (not an exception) when no matching credential entry comes back -
        this is the expected, normal shape of "Aria Operations is not deployed in this
        environment", which every Aria Operations check must treat as Skipped rather than Error.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .OUTPUTS
        [PSCustomObject] with Fqdn/Credential properties, or $null if Aria Operations is not
        deployed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ($Context.AriaOpsCredential) {
        return $Context.AriaOpsCredential
    }

    Write-LogMessage -Type DEBUG -Message 'Resolving Aria Operations FQDN and credential from SDDC Manager.'
    try {
        $response = Invoke-VcfGetCredentials -ResourceType VROPS -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("Failed to query SDDC Manager for Aria Operations credentials: $($_.Exception.Message)")
    }

    $match = @($response.Elements) | Where-Object { $_.CredentialType -eq 'API' } | Select-Object -First 1
    if (-not $match) {
        Write-LogMessage -Type DEBUG -Message 'No Aria Operations credential entry returned by SDDC Manager - Aria Operations is not part of this environment.'
        return $null
    }

    $secure = ConvertTo-SecureStringForCredential -PlainText $match.Password
    $credential = [PSCredential]::new($match.Username, $secure)
    $resolved = [PSCustomObject]@{
        PSTypeName       = 'VcfCheck.AriaOpsCredential'
        Fqdn             = $match.Resource.ResourceName
        Credential       = $credential
        AllowInsecureTls = [Bool]$Context.AllowInsecureTls
    }
    Remove-Variable -Name match, response -ErrorAction SilentlyContinue

    $Context.AriaOpsCredential = $resolved
    return $resolved
}
function Connect-VcfCheckAriaOps {
    <#
        .SYNOPSIS
        Connects to Aria Operations via the VMware.Sdk.Vcf.Ops SDK, using the credential SDDC
        Manager has on file.

        .DESCRIPTION
        Resolves the FQDN/credential via Get-VcfCheckAriaOpsCredential, runs a TCP reachability
        pre-flight check (Test-VcfCheckTcpConnectivity) against <Fqdn>:443, then calls
        Connect-VcfOpsServer. The resulting connection is cached on $Context.AriaOpsConnection so
        every later check reuses it instead of reconnecting. On any failure - not deployed,
        unreachable, or auth failure - the reason is cached on $Context.UnreachableAriaOps so
        every later Aria Operations check fails fast with the same message.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for the TCP reachability pre-flight check. Defaults to 15 seconds.

        .OUTPUTS
        The Aria Operations connection object returned by Connect-VcfOpsServer, or $null if Aria
        Operations is not deployed in this environment.

        .EXAMPLE
        Connect-VcfCheckAriaOps -Context $Context
    #>
    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 15
    )

    if ($Context.UnreachableAriaOps) {
        throw [System.InvalidOperationException]::new($Context.UnreachableAriaOps)
    }

    if ($Context.AriaOpsConnection) {
        return $Context.AriaOpsConnection
    }

    $resolved = Get-VcfCheckAriaOpsCredential -Context $Context
    if (-not $resolved) {
        return $null
    }

    if (-not (Test-VcfCheckTcpConnectivity -ComputerName $resolved.Fqdn -Port 443 -TimeoutSeconds $ConnectivityTimeoutSeconds)) {
        $reason = "Could not reach Aria Operations `"$($resolved.Fqdn)`" on port 443 within $ConnectivityTimeoutSeconds second(s). Check VPN/network connectivity to the environment, firewall rules, and that the FQDN resolves to the correct address, then retry."
        $Context.UnreachableAriaOps = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    Write-LogMessage -Type INFO -Message "Connecting to Aria Operations `"$($resolved.Fqdn)`"..." -NoNewline
    try {
        $connection = Connect-VcfOpsServer -Server $resolved.Fqdn -Credential $resolved.Credential -NotDefault -IgnoreInvalidCertificate:$resolved.AllowInsecureTls -ErrorAction Stop
        Write-Host " Connected" -ForegroundColor White
    } catch {
        Write-Host " Failed" -ForegroundColor Red
        $reason = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'Aria Operations' -Fqdn $resolved.Fqdn -ErrorMessage $_.Exception.Message
        if (-not $reason) {
            $reason = "Failed to connect to Aria Operations `"$($resolved.Fqdn)`". Verify network connectivity, that the credential SDDC Manager has on file is still valid, and that Aria Operations is reachable."
        }
        $Context.UnreachableAriaOps = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    $Context.AriaOpsConnection = $connection
    return $connection
}
function Get-VcfCheckEnvironmentAriaOpsEndpoints {
    <#
        .SYNOPSIS
        Resolves the user-declared, standalone Aria Operations endpoints attached to an
        environment (Private/Environments.ps1's Integrations field) - components SDDC Manager and
        VRSLCM have zero knowledge of.

        .DESCRIPTION
        Filters $Environment.Integrations to entries with Type -eq 'AriaOperations' and flattens
        their Endpoints into one object per endpoint, applying each integration's
        SharedCredentials setting to resolve which Username applies (the integration-level one
        when shared, else the endpoint's own). Never resolves a password - see
        Connect-VcfCheckAriaOpsEndpoint.

        .PARAMETER Environment
        An environment object as returned by Get-VcfCheckEnvironments.

        .OUTPUTS
        [Object[]] of PSCustomObject with Name, Fqdn, Username. Empty array if the environment has
        no AriaOperations integration.

        .EXAMPLE
        Get-VcfCheckEnvironmentAriaOpsEndpoints -Environment $environment
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Environment
    )

    $results = [System.Collections.Generic.List[PSObject]]::new()
    $ariaIntegrations = @($Environment.Integrations) | Where-Object { $_ -and $_.Type -eq 'AriaOperations' }

    foreach ($integration in $ariaIntegrations) {
        foreach ($endpoint in @($integration.Endpoints)) {
            if (-not $endpoint) {
                continue
            }
            $username = if ($integration.SharedCredentials) { $integration.Username } else { $endpoint.Username }
            $results.Add([PSCustomObject]@{
                PSTypeName = 'VcfCheck.AriaOpsEndpoint'
                Name       = $endpoint.Name
                Fqdn       = $endpoint.Fqdn
                Username   = $username
            })
        }
    }

    return $results.ToArray()
}
function Connect-VcfCheckAriaOpsEndpoint {
    <#
        .SYNOPSIS
        Connects directly to a user-declared, standalone Aria Operations endpoint by FQDN and
        credential - no SDDC Manager lookup.

        .DESCRIPTION
        Companion to Connect-VcfCheckAriaOps for Aria Operations instances SDDC Manager has zero
        knowledge of (see Get-VcfCheckEnvironmentAriaOpsEndpoints). Runs the same TCP reachability
        pre-flight and caches the resulting connection on $Context.AriaOpsEndpointConnections
        (keyed by Fqdn, since there can be more than one) so repeat checks against the same
        endpoint reuse it. Unreachable/failed endpoints are cached on
        $Context.UnreachableAriaOpsEndpoints (also keyed by Fqdn) for the same fail-fast reason
        Connect-VcfCheckVCenter caches per-vCenter failures.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER Fqdn
        The endpoint's FQDN, as entered by the user.

        .PARAMETER Credential
        The credential to connect with. The caller is responsible for resolving the password
        (session-only prompt or launcher parameter) - this function never persists or looks one
        up itself.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for the TCP reachability pre-flight check. Defaults to 15 seconds.

        .OUTPUTS
        The Aria Operations connection object returned by Connect-VcfOpsServer.

        .EXAMPLE
        Connect-VcfCheckAriaOpsEndpoint -Context $Context -Fqdn 'vrops-standalone.example.com' -Credential $credential
    #>
    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $true)] [PSCredential]$Credential,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 15
    )

    if (-not $Context.AriaOpsEndpointConnections) {
        $Context.AriaOpsEndpointConnections = @{}
    }
    if (-not $Context.UnreachableAriaOpsEndpoints) {
        $Context.UnreachableAriaOpsEndpoints = @{}
    }

    if ($Context.UnreachableAriaOpsEndpoints.ContainsKey($Fqdn)) {
        throw [System.InvalidOperationException]::new($Context.UnreachableAriaOpsEndpoints[$Fqdn])
    }
    if ($Context.AriaOpsEndpointConnections.ContainsKey($Fqdn)) {
        return $Context.AriaOpsEndpointConnections[$Fqdn]
    }

    if (-not (Test-VcfCheckTcpConnectivity -ComputerName $Fqdn -Port 443 -TimeoutSeconds $ConnectivityTimeoutSeconds)) {
        $reason = "Could not reach Aria Operations `"$Fqdn`" on port 443 within $ConnectivityTimeoutSeconds second(s). Check VPN/network connectivity to the environment, firewall rules, and that the FQDN resolves to the correct address, then retry."
        $Context.UnreachableAriaOpsEndpoints[$Fqdn] = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    Write-LogMessage -Type INFO -Message "Connecting to Aria Operations `"$Fqdn`"..." -NoNewline
    try {
        $connection = Connect-VcfOpsServer -Server $Fqdn -Credential $Credential -NotDefault -IgnoreInvalidCertificate:$Context.AllowInsecureTls -ErrorAction Stop
        Write-Host " Connected" -ForegroundColor White
    } catch {
        Write-Host " Failed" -ForegroundColor Red
        $reason = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'Aria Operations' -Fqdn $Fqdn -ErrorMessage $_.Exception.Message
        if (-not $reason) {
            $reason = "Failed to connect to Aria Operations `"$Fqdn`". Verify network connectivity and the credential entered for this endpoint."
        }
        $Context.UnreachableAriaOpsEndpoints[$Fqdn] = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    $Context.AriaOpsEndpointConnections[$Fqdn] = $connection
    return $connection
}
function Resolve-VcfCheckAriaOpsEndpointCredentials {
    <#
        .SYNOPSIS
        Resolves and caches a [PSCredential] per standalone Aria Operations endpoint's Username.

        .DESCRIPTION
        For each endpoint returned by Get-VcfCheckEnvironmentAriaOpsEndpoints, uses a matching
        entry (by Fqdn) in PreSuppliedCredentials (the launcher/browser session-only password
        path - see Tools/Invoke-VcfCheckLauncher.ps1) when present, otherwise prompts once via
        Read-Host -AsSecureString (the CLI path, matching Get-VcfCheckSddcManagerRootCredential's
        prompt style). Results are cached on $Context.AriaOpsEndpointCredentials, keyed by Fqdn,
        so a second run within the same $Context (e.g. re-invoking with a different -CheckId
        filter) never re-prompts.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER Endpoints
        Endpoint objects as returned by Get-VcfCheckEnvironmentAriaOpsEndpoints (Name/Fqdn/Username).

        .PARAMETER PreSuppliedCredentials
        Optional array of PSCustomObject/Hashtable with Fqdn/Username/Password (SecureString),
        e.g. resolved from the browser's per-endpoint session-only password field. Endpoints not
        matched here fall back to an interactive prompt.

        .EXAMPLE
        Resolve-VcfCheckAriaOpsEndpointCredentials -Context $Context -Endpoints $endpoints -PreSuppliedCredentials $AriaOpsEndpointCredentials
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'PreSuppliedCredentials', Justification = 'Object[] of Fqdn/Username/Password triplets, not a password itself - each element''s Password field is already a SecureString.')]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [Object[]]$Endpoints,
        [Parameter(Mandatory = $false)] [Object[]]$PreSuppliedCredentials = @()
    )

    foreach ($endpoint in @($Endpoints)) {
        if (-not $endpoint -or $Context.AriaOpsEndpointCredentials.ContainsKey($endpoint.Fqdn)) {
            continue
        }

        $preSupplied = @($PreSuppliedCredentials) | Where-Object { $_ -and $_.Fqdn -eq $endpoint.Fqdn } | Select-Object -First 1
        if ($preSupplied) {
            $Context.AriaOpsEndpointCredentials[$endpoint.Fqdn] = [PSCredential]::new($endpoint.Username, $preSupplied.Password)
            continue
        }

        $securePassword = Read-Host -Prompt "Enter the password for $($endpoint.Username)@$($endpoint.Fqdn) (Aria Operations - $($endpoint.Name))" -AsSecureString
        if ($securePassword.Length -eq 0) {
            throw [System.InvalidOperationException]::new("Password for Aria Operations endpoint `"$($endpoint.Fqdn)`" must not be empty.")
        }
        $Context.AriaOpsEndpointCredentials[$endpoint.Fqdn] = [PSCredential]::new($endpoint.Username, $securePassword)
    }
}
function Get-VcfCheckAriaOpsTargets {
    <#
        .SYNOPSIS
        Resolves every Aria Operations instance a check should evaluate - the SDDC-Manager-known
        instance (if deployed) plus every standalone endpoint declared on the current
        environment - and connects to each.

        .DESCRIPTION
        Every Test-VcfAriaOps* check calls this once instead of Connect-VcfCheckAriaOps directly,
        so a single check fans out across every known Aria Operations instance rather than only
        the SDDC-Manager-known one. A connection failure for one target (unreachable, bad
        credential, not deployed) never blocks evaluation of the others - it is surfaced on that
        target's ConnectError instead of throwing, so the caller can emit one Error result per
        failed target and keep evaluating the rest.

        A standalone endpoint whose FQDN matches the SDDC-Manager-known instance's FQDN is
        skipped, since that is the same physical appliance registered twice - once via SDDC
        Manager and once as a manually declared endpoint - and would otherwise double every
        check result.

        .PARAMETER Context
        The VcfCheck.Context object. $Context.AriaOpsEndpoints and
        $Context.AriaOpsEndpointCredentials must already be populated by Invoke-VcfCheck (via
        Resolve-VcfCheckAriaOpsEndpointCredentials) for standalone endpoints to be included.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for each target's TCP reachability pre-flight check. Defaults to 15
        seconds.

        .OUTPUTS
        [Object[]] of PSCustomObject with Name, Fqdn, Connection, CredentialInfo, ConnectError.
        CredentialInfo (Fqdn/Credential) is the same shape Get-VcfCheckAriaOpsCredential returns -
        pass it to the REST-fallback helpers (Get-VcfCheckAriaOpsResource,
        Get-VcfCheckAriaOpsAdapterResources) instead of $Context.AriaOpsCredential so those calls
        target the right instance for a standalone endpoint too. Empty array if Aria Operations
        is not deployed via SDDC Manager and the environment has no standalone endpoints
        declared - callers must treat that as Skipped.

        .EXAMPLE
        Get-VcfCheckAriaOpsTargets -Context $Context
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 15
    )

    $targets = [System.Collections.Generic.List[PSObject]]::new()

    try {
        $connection = Connect-VcfCheckAriaOps -Context $Context -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
        if ($connection) {
            $targets.Add([PSCustomObject]@{ Name = 'SDDC Manager'; Fqdn = $Context.AriaOpsCredential.Fqdn; Connection = $connection; CredentialInfo = $Context.AriaOpsCredential; ConnectError = $null })
        }
    } catch {
        $targets.Add([PSCustomObject]@{ Name = 'SDDC Manager'; Fqdn = $Context.AriaOpsCredential.Fqdn; Connection = $null; CredentialInfo = $null; ConnectError = $_.Exception.Message })
    }

    $knownFqdns = @($targets | Where-Object { $_.Fqdn } | ForEach-Object { $_.Fqdn })
    foreach ($endpoint in @($Context.AriaOpsEndpoints) | Where-Object { $_ }) {
        if ($endpoint.Fqdn -and ($knownFqdns -icontains $endpoint.Fqdn)) {
            continue
        }
        $credential = $Context.AriaOpsEndpointCredentials[$endpoint.Fqdn]
        if (-not $credential) {
            $targets.Add([PSCustomObject]@{ Name = $endpoint.Name; Fqdn = $endpoint.Fqdn; Connection = $null; CredentialInfo = $null; ConnectError = "No password was supplied for Aria Operations endpoint `"$($endpoint.Fqdn)`"." })
            continue
        }
        $credentialInfo = [PSCustomObject]@{ PSTypeName = 'VcfCheck.AriaOpsCredential'; Fqdn = $endpoint.Fqdn; Credential = $credential }
        try {
            $connection = Connect-VcfCheckAriaOpsEndpoint -Context $Context -Fqdn $endpoint.Fqdn -Credential $credential -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
            $targets.Add([PSCustomObject]@{ Name = $endpoint.Name; Fqdn = $endpoint.Fqdn; Connection = $connection; CredentialInfo = $credentialInfo; ConnectError = $null })
        } catch {
            $targets.Add([PSCustomObject]@{ Name = $endpoint.Name; Fqdn = $endpoint.Fqdn; Connection = $null; CredentialInfo = $credentialInfo; ConnectError = $_.Exception.Message })
        }
    }

    return $targets.ToArray()
}
function Get-VcfCheckAriaOpsCollectors {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-VcfOpsGetCollectors (see AriaOpsHelpers.ps1's file
        header for why this wrapper exists).

        .PARAMETER Connection
        The Aria Operations connection object returned by Connect-VcfCheckAriaOps or
        Connect-VcfCheckAriaOpsEndpoint.

        .OUTPUTS
        The Collectors response object returned by Invoke-VcfOpsGetCollectors.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Connection
    )

    return Invoke-VcfOpsGetCollectors -Server $Connection -ErrorAction Stop
}
function Get-VcfCheckAriaOpsCriticalAlerts {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-VcfOpsQueryAlert (see AriaOpsHelpers.ps1's file
        header for why this wrapper exists), pre-built for active Critical/Immediate alerts.

        .DESCRIPTION
        Builds an AlertQuery via Initialize-VcfOpsAlertQuery filtered to ActiveOnly with
        AlertCriticality 'CRITICAL'/'IMMEDIATE', then calls Invoke-VcfOpsQueryAlert. The response
        object's alert collection is exposed as its '_Alerts' property - a naming quirk of the
        generated SDK model, not a typo.

        .PARAMETER Connection
        The Aria Operations connection object returned by Connect-VcfCheckAriaOps or
        Connect-VcfCheckAriaOpsEndpoint.

        .OUTPUTS
        The Alerts response object returned by Invoke-VcfOpsQueryAlert.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Connection
    )

    $alertQuery = Initialize-VcfOpsAlertQuery -ActiveOnly $true -AlertCriticality @('CRITICAL', 'IMMEDIATE')
    return Invoke-VcfOpsQueryAlert -Server $Connection -AlertQuery $alertQuery -ErrorAction Stop
}
function Get-VcfCheckAriaOpsResource {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Aria Operations' '/suite-api/api/resources/{id}' REST
        endpoint - see AriaOpsHelpers.ps1's file header for why this bypasses the SDK.

        .DESCRIPTION
        Resolves a resource id (as returned on an Alert's ResourceId property) to its Resource
        object, whose ResourceKey carries the human-readable Name and AdapterKindKey/
        ResourceKindKey - fields the Alert model itself does not expose. Invoke-VcfOpsGetResource
        (the SDK equivalent) hits the same "Variant,<n>,Version,4" schema-tag defect as
        Invoke-VcfOpsGetResourcesOfAdapterInstance - it malforms its own request path regardless
        of the id passed in - so this call goes straight to suite-api instead, the same
        REST-fallback pattern Get-VcfCheckAriaOpsAdapterResources uses.

        .PARAMETER CredentialInfo
        The AriaOpsCredential object returned by Get-VcfCheckAriaOpsCredential (Fqdn + Credential).

        .PARAMETER ResourceId
        The resource id to resolve.

        .OUTPUTS
        The Resource object returned by the suite-api.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo,
        [Parameter(Mandatory = $true)] [Guid]$ResourceId
    )

    return Invoke-VcfCheckAriaOpsApi -CredentialInfo $CredentialInfo -Path "/suite-api/api/resources/$($ResourceId.ToString())" -ErrorAction Stop
}
function Test-VcfCheckAriaOpsValueLooksLikeFqdn {
    <#
        .SYNOPSIS
        Returns whether a string value is shaped like an FQDN rather than a bare IP address.

        .PARAMETER Value
        The candidate string.

        .OUTPUTS
        [Bool]
    #>
    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [String]$Value
    )

    if ([String]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $parsedIp = $null
    if ([System.Net.IPAddress]::TryParse($Value, [ref]$parsedIp)) {
        return $false
    }

    return $Value -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$'
}
function Resolve-VcfCheckAriaOpsCollectorFqdn {
    <#
        .SYNOPSIS
        Best-effort resolution of an Aria Operations collector's FQDN from its node resource.

        .DESCRIPTION
        A Collector's HostName property is documented by Aria Operations as "host name or IP
        address" and in practice is usually an IP address - the Collector object itself has no
        FQDN field. This resolves the collector's NodeIdentifier to its Resource object via
        Get-VcfCheckAriaOpsResource and scans ResourceKey.ResourceIdentifiers for a
        network-address-type identifier whose value is shaped like an FQDN (see
        Test-VcfCheckAriaOpsValueLooksLikeFqdn). Falls back to the collector's own HostName -
        logged via Write-LogMessage - when the resource lookup fails, the NodeIdentifier is not a
        GUID, or no FQDN-shaped identifier is found. This is best-effort enrichment only; it never
        throws.

        .PARAMETER CredentialInfo
        The AriaOpsCredential object returned by Get-VcfCheckAriaOpsCredential (Fqdn + Credential).

        .PARAMETER Collector
        A Collector object as returned by Get-VcfCheckAriaOpsCollectors.

        .OUTPUTS
        [String] The resolved FQDN, or the collector's HostName if none could be resolved.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo,
        [Parameter(Mandatory = $true)] [PSObject]$Collector
    )

    $nodeIdentifier = [Guid]::Empty
    if (-not [Guid]::TryParse($Collector.NodeIdentifier, [ref]$nodeIdentifier)) {
        return $Collector.HostName
    }

    try {
        $resource = Get-VcfCheckAriaOpsResource -CredentialInfo $CredentialInfo -ResourceId $nodeIdentifier
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not resolve FQDN for Aria Operations collector `"$($Collector.Name)`" - falling back to its reported HostName `"$($Collector.HostName)`": $($_.Exception.Message)"
        return $Collector.HostName
    }

    $identifiers = @($resource.ResourceKey.ResourceIdentifiers | Where-Object { $_.IdentifierType.Name -match '(?i)network|address|dns|host' })
    $fqdn = $identifiers | ForEach-Object { $_.Value } | Where-Object { Test-VcfCheckAriaOpsValueLooksLikeFqdn -Value $_ } | Select-Object -First 1

    if (-not $fqdn) {
        Write-LogMessage -Type DEBUG -Message "No FQDN-shaped network identifier found for Aria Operations collector `"$($Collector.Name)`" - falling back to its reported HostName `"$($Collector.HostName)`"."
        return $Collector.HostName
    }

    return $fqdn
}
function Get-VcfCheckAriaOpsCertificates {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-VcfOpsGetAllCertificates (see AriaOpsHelpers.ps1's
        file header for why this wrapper exists).

        .DESCRIPTION
        The response object's certificate collection is exposed as its '_Certificates' property -
        a naming quirk of the generated SDK model, not a typo.

        .PARAMETER Connection
        The Aria Operations connection object returned by Connect-VcfCheckAriaOps or
        Connect-VcfCheckAriaOpsEndpoint.

        .OUTPUTS
        The Certificates response object returned by Invoke-VcfOpsGetAllCertificates.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Connection
    )

    return Invoke-VcfOpsGetAllCertificates -Server $Connection -ErrorAction Stop
}
function Get-VcfCheckAriaOpsApiToken {
    <#
        .SYNOPSIS
        Acquires (and caches) an Aria Operations suite-api session token.

        .DESCRIPTION
        Aria Operations' suite-api does not accept HTTP Basic Auth on ordinary endpoints (unlike
        VRSLCM) - it requires a short-lived token acquired via POST '/suite-api/api/auth/token/acquire'
        with the username/password/authSource, then presented on every later call as
        'Authorization: vRealizeOpsToken <token>'. The token is cached as an 'ApiToken' member added
        directly onto the CredentialInfo object (the same object callers already cache on
        $Context.AriaOpsCredential), so every call within a run re-uses it instead of
        re-authenticating.

        Aria Operations accounts are not always local - the credential's username determines the
        authSource to authenticate against: 'DOMAIN\user' or 'user@domain' is treated as a
        directory-backed account (authSource 'domain', username 'user' with the domain stripped,
        matching how Aria Operations' own login screen splits the same formats); a bare username
        with neither separator is treated as a local account (authSource 'LOCAL').

        .PARAMETER CredentialInfo
        The AriaOpsCredential object returned by Get-VcfCheckAriaOpsCredential (Fqdn + Credential).

        .OUTPUTS
        [String] the session token.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo
    )

    if ($CredentialInfo.PSObject.Properties['ApiToken'] -and $CredentialInfo.ApiToken) {
        return $CredentialInfo.ApiToken
    }

    $rawUsername = $CredentialInfo.Credential.UserName
    if ($rawUsername -match '^(?<domain>[^\\]+)\\(?<user>.+)$') {
        $username = $Matches.user
        $authSource = $Matches.domain
    } elseif ($rawUsername -match '^(?<user>[^@]+)@(?<domain>.+)$') {
        $username = $Matches.user
        $authSource = $Matches.domain
    } else {
        $username = $rawUsername
        $authSource = 'LOCAL'
    }

    $body = @{
        username   = $username
        password   = $CredentialInfo.Credential.GetNetworkCredential().Password
        authSource = $authSource
    } | ConvertTo-Json -Depth 2

    try {
        $response = Invoke-RestMethod -Uri "https://$($CredentialInfo.Fqdn)/suite-api/api/auth/token/acquire" `
            -Method POST -Body $body -ContentType 'application/json' -Headers @{ Accept = 'application/json' } `
            -SkipCertificateCheck:$CredentialInfo.AllowInsecureTls -ErrorAction Stop
    } catch {
        $message = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'Aria Operations' -Fqdn $CredentialInfo.Fqdn -ErrorMessage $_.Exception.Message
        if (-not $message) {
            throw
        }
        throw [System.InvalidOperationException]::new($message)
    }

    if ($CredentialInfo.PSObject.Properties['ApiToken']) {
        $CredentialInfo.ApiToken = $response.token
    } else {
        $CredentialInfo | Add-Member -NotePropertyName 'ApiToken' -NotePropertyValue $response.token
    }

    return $response.token
}
function Invoke-VcfCheckAriaOpsApi {
    <#
        .SYNOPSIS
        Calls Aria Operations' suite-api REST API directly with a token acquired via
        Get-VcfCheckAriaOpsApiToken, bypassing the VMware.Sdk.Vcf.Ops SDK.

        .DESCRIPTION
        Thin Invoke-RestMethod wrapper for the handful of suite-api endpoints where the
        VMware.Sdk.Vcf.Ops SDK cannot be used - see AriaOpsHelpers.ps1's file header.
        -SkipCertificateCheck is only passed when CredentialInfo.AllowInsecureTls is $true (the
        run's resolved AllowInsecureTls value, derived from PowerCLI's InvalidCertificateAction
        setting (see Invoke-VcfCheck in Orchestrator.ps1 and Get-VcfCheckAriaOpsCredential) rather
        than being unconditional; an untrusted
        certificate encountered while that is $false surfaces as a clear, actionable error via
        Get-VcfCheckTlsTrustErrorMessage instead of being silently accepted. Retries up to 3 times
        with a 10-second delay on transient network failures (timeouts, connection resets).

        .PARAMETER CredentialInfo
        The AriaOpsCredential object returned by Get-VcfCheckAriaOpsCredential (Fqdn + Credential).

        .PARAMETER Method
        HTTP method. Defaults to GET.

        .PARAMETER Path
        The suite-api path, e.g. '/suite-api/api/adapters/<guid>/resources'.

        .OUTPUTS
        The parsed JSON response.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo,
        [Parameter(Mandatory = $false)] [ValidateSet('GET', 'POST')] [String]$Method = 'GET',
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    $token = Get-VcfCheckAriaOpsApiToken -CredentialInfo $CredentialInfo
    $uri = "https://$($CredentialInfo.Fqdn)$Path"
    $parameters = @{
        Uri                  = $uri
        Method               = $Method
        Headers              = @{ Accept = 'application/json'; Authorization = "vRealizeOpsToken $token" }
        SkipCertificateCheck = $CredentialInfo.AllowInsecureTls
        ErrorAction          = 'Stop'
    }

    $maxAttempts = 3
    $retryDelaySeconds = 10
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @parameters
        } catch {
            $tlsMessage = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'Aria Operations' -Fqdn $CredentialInfo.Fqdn -ErrorMessage $_.Exception.Message
            if ($tlsMessage) {
                throw [System.InvalidOperationException]::new($tlsMessage)
            }
            $isTransient = $_.Exception.Message -match '(?i)timed out|timeout|actively refused|connection refused|reset by peer|handshake'
            if (-not $isTransient -or $attempt -eq $maxAttempts) {
                throw
            }
            Write-LogMessage -Type DEBUG -Message "Transient error calling Aria Operations suite-api '$Path' (attempt $attempt of $maxAttempts): $($_.Exception.Message). Retrying in $retryDelaySeconds seconds."
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }
}
function Get-VcfCheckAriaOpsAdapterInstances {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-VcfOpsEnumerateAdapterInstances (see
        AriaOpsHelpers.ps1's file header for why this wrapper exists).

        .DESCRIPTION
        The response object's adapter instance collection is exposed as its
        'AdapterInstancesInfoDto' property, per the generated SDK model.

        .PARAMETER Connection
        The Aria Operations connection object returned by Connect-VcfCheckAriaOps or
        Connect-VcfCheckAriaOpsEndpoint.

        .OUTPUTS
        The AdapterInstances response object returned by Invoke-VcfOpsEnumerateAdapterInstances.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Connection
    )

    return Invoke-VcfOpsEnumerateAdapterInstances -Server $Connection -ErrorAction Stop
}
function Get-VcfCheckAriaOpsAdapterResources {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Aria Operations' '/suite-api/api/adapters/{id}/resources'
        REST endpoint - see AriaOpsHelpers.ps1's file header for why this bypasses the SDK.

        .DESCRIPTION
        The response object's resource collection is exposed as its 'ResourceList' property
        (PowerShell's property access on a JSON-deserialized PSCustomObject is case-insensitive,
        so this matches the suite-api response's camelCase 'resourceList' as well as the
        generated SDK model's PascalCase naming callers were already written against). Each
        resource's ResourceStatusStates carries the collection status (e.g. DATA_RECEIVING,
        COLLECTOR_DOWN) per adapter instance monitoring it.

        .PARAMETER CredentialInfo
        The AriaOpsCredential object returned by Get-VcfCheckAriaOpsCredential (Fqdn + Credential).

        .PARAMETER AdapterId
        The identifier of the adapter instance to enumerate resources for.

        .OUTPUTS
        The Resources response object returned by the suite-api.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo,
        [Parameter(Mandatory = $true)] [Guid]$AdapterId
    )

    return Invoke-VcfCheckAriaOpsApi -CredentialInfo $CredentialInfo -Path "/suite-api/api/adapters/$($AdapterId.ToString())/resources" -ErrorAction Stop
}
function Get-VcfCheckAriaOpsLicenseEntitlement {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Aria Operations' '/suite-api/api/product/licensing/entitlement'
        REST endpoint - see AriaOpsHelpers.ps1's file header for why this bypasses the SDK.

        .DESCRIPTION
        No VMware.Sdk.Vcf.Ops cmdlet covers this endpoint (only Invoke-VcfOpsGetLicenseInfo exists,
        and it 404s on every real instance tested - see Docs/CheckConfidence.md's
        aria_ops_license entry), so this goes straight through Invoke-VcfCheckAriaOpsApi. The
        response object's license collection is exposed as its 'solutionLicenses' property, each
        entry carrying id/licenseKey/expirationDate (epoch milliseconds)/capacity/usage/edition/
        licenseType/statuses per the 8.18 swagger spec's 'solution-licenses' schema.

        .PARAMETER CredentialInfo
        The AriaOpsCredential object returned by Get-VcfCheckAriaOpsCredential (Fqdn + Credential).

        .OUTPUTS
        The solution-licenses response object returned by the suite-api.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo
    )

    return Invoke-VcfCheckAriaOpsApi -CredentialInfo $CredentialInfo -Path '/suite-api/api/product/licensing/entitlement' -ErrorAction Stop
}
function Get-VcfCheckAriaOpsVersion {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-VcfOpsGetCurrentVersionOfServer, returning Aria
        Operations' own reported marketing version as a dotted string.

        .DESCRIPTION
        The SDK's Version model (VMware.Bindings.Vcf.Ops.Model.Version) exposes Major/Minor/
        MinorMinor/Patch as separate integers, but those are the internal build-numbering
        scheme (e.g. 1.70.0), not the marketing product version (e.g. 8.18.0) that the shipped
        Interop Matrix snapshot (Data/Interoperability/Vrops.json) uses. The marketing version
        is embedded as free text in the model's ReleaseName property (e.g. 'VMware Aria
        Operations 8.18.0'), so this extracts the trailing dotted-number group from it.

        .PARAMETER Connection
        The Aria Operations connection object returned by Connect-VcfCheckAriaOps or
        Connect-VcfCheckAriaOpsEndpoint.

        .OUTPUTS
        [String] the dotted marketing version string, or $null if it could not be determined.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Connection
    )

    $version = Invoke-VcfOpsGetCurrentVersionOfServer -Server $Connection -ErrorAction Stop
    if ($null -eq $version -or [String]::IsNullOrWhiteSpace($version.ReleaseName)) {
        return $null
    }

    $match = [Regex]::Match($version.ReleaseName, '\d+(?:\.\d+){1,3}$')
    if (-not $match.Success) {
        return $null
    }

    return $match.Value
}
function Get-VcfCheckAriaOpsSelfMonitoringResources {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-VcfOpsGetResourcesWithAdapterKind (see
        AriaOpsHelpers.ps1's file header for why this wrapper exists), pre-built for Aria
        Operations' own self-monitoring resources (its cluster and node(s)).

        .DESCRIPTION
        Aria Operations monitors itself under a built-in adapter kind - the same resources the
        product's own "vRealize Operations Manager Cluster" dashboards chart. The exact adapter
        kind key varies in shape by version and is resolved by the caller (see
        Get-VcfCheckAriaOpsSelfMonitoringAdapterKind) rather than hardcoded here, since a
        hardcoded guess ('VCOPS_VCOPS_ADAPTER') was confirmed live to return zero resources
        against a real instance - see ARIA_OPS_CONNECTOR_PLAN.md. The response object's resource
        collection is exposed as its 'ResourceList' property, per the generated SDK model.

        .PARAMETER Connection
        The Aria Operations connection object returned by Connect-VcfCheckAriaOps or
        Connect-VcfCheckAriaOpsEndpoint.

        .PARAMETER AdapterKindKey
        The adapter kind key to query, as resolved by Get-VcfCheckAriaOpsSelfMonitoringAdapterKind.

        .OUTPUTS
        The Resources response object returned by Invoke-VcfOpsGetResourcesWithAdapterKind.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Connection,
        [Parameter(Mandatory = $true)] [String]$AdapterKindKey
    )

    return Invoke-VcfOpsGetResourcesWithAdapterKind -Server $Connection -AdapterKindKey $AdapterKindKey -ErrorAction Stop
}
function Get-VcfCheckAriaOpsSelfMonitoringAdapterKind {
    <#
        .SYNOPSIS
        Resolves the adapter kind key of Aria Operations' own self-monitoring adapter instance by
        matching on name/kind rather than a hardcoded key.

        .DESCRIPTION
        Calls Get-VcfCheckAriaOpsAdapterInstances and returns the AdapterKindKey of the first
        configured adapter instance whose AdapterKindKey or resource name matches the
        self-monitoring adapter's known naming pattern ('VCOPS', 'vRealize Operations Manager', or
        'vRealize Operations Adapter' - a real instance's self-monitoring adapters are named
        'vRealize Operations Adapter - <node>', one per node, confirmed live against
        xint-ops01.rainpole.io). A hardcoded key ('VCOPS_VCOPS_ADAPTER') was tried previously and
        confirmed live to return zero resources - see ARIA_OPS_CONNECTOR_PLAN.md - so this
        discovers the key from the instance's own adapter inventory instead of guessing.

        .PARAMETER Connection
        The Aria Operations connection object returned by Connect-VcfCheckAriaOps or
        Connect-VcfCheckAriaOpsEndpoint.

        .OUTPUTS
        [String] The discovered adapter kind key, or $null if no self-monitoring adapter instance
        is configured.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Connection
    )

    $response = Get-VcfCheckAriaOpsAdapterInstances -Connection $Connection
    $adapters = @($response.AdapterInstancesInfoDto) | Where-Object { $_ -and $_.ResourceKey }
    $selfMonitoring = $adapters | Where-Object {
        $_.ResourceKey.AdapterKindKey -match '(?i)vcops' -or $_.ResourceKey.Name -match '(?i)vRealize Operations Manager|vRealize Operations Adapter|Aria Operations'
    } | Select-Object -First 1

    if (-not $selfMonitoring) {
        return $null
    }

    return $selfMonitoring.ResourceKey.AdapterKindKey
}
function Get-VcfCheckAriaOpsResourceStats {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-VcfOpsGetLatestStatsOfResources (see
        AriaOpsHelpers.ps1's file header for why this wrapper exists).

        .DESCRIPTION
        Returns every stat Aria Operations currently reports for the given resource id(s) - no
        -StatKey filter is passed, since the exact stat key names for CPU/memory/disk/network/
        object-count self-monitoring metrics have not been confirmed live against a real
        instance (see ARIA_OPS_CONNECTOR_PLAN.md). Callers filter the returned stats by name
        pattern instead of relying on hardcoded key strings. The response object's per-resource
        stat collection is exposed as its 'Values' property, each entry's 'StatList' property
        being a wrapper object (not itself enumerable) whose 'Stat' property holds one Stats
        object per reported metric (StatKey.Key/Data/Timestamps), per the generated SDK model.

        .PARAMETER Connection
        The Aria Operations connection object returned by Connect-VcfCheckAriaOps or
        Connect-VcfCheckAriaOpsEndpoint.

        .PARAMETER ResourceId
        Array of resource ids to fetch the latest stats for.

        .OUTPUTS
        The StatsOfResources response object returned by Invoke-VcfOpsGetLatestStatsOfResources.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Connection,
        [Parameter(Mandatory = $true)] [Guid[]]$ResourceId
    )

    return Invoke-VcfOpsGetLatestStatsOfResources -Server $Connection -ResourceId $ResourceId -CurrentOnly $true -ErrorAction Stop
}
