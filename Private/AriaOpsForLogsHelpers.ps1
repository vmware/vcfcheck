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
#region AriaOpsForLogsHelpers
#
# Aria Operations for Logs (formerly Log Insight) has no PowerCLI/OpenAPI SDK coverage - it is a
# distinct product from Aria Operations (VMware.Sdk.Vcf.Ops) with its own /api/v2/... REST API.
# Unlike VRSLCM/NSX Manager, which authenticate with HTTP Basic Auth on every call, this API uses
# a session-token model: POST /api/v2/sessions with a username/password/provider body returns a
# short-lived (default 1800s) opaque sessionId, sent back as a Bearer token on every subsequent
# call. The token, not just the credential, must be cached and refreshed on expiry.
#
# Aria Operations for Logs is deployed and lifecycle-managed by Aria Suite Lifecycle (VRSLCM),
# but VRSLCM does not hold the Aria Operations for Logs credential either - Aria Operations for
# Logs manages its own credentials via its own API. SDDC Manager's own credential vault never
# holds an Aria Operations for Logs credential, so this file has no SDDC-Manager-based resolution
# path at all.
# Get-VcfCheckEnvironmentAriaOpsForLogsEndpoints resolves the user-declared Integrations list on
# an environment (Private/Environments.ps1) as the only source of Aria Operations for Logs
# FQDN/credential. Connect-VcfCheckAriaOpsForLogsEndpoint acquires a session token for one of
# those directly by FQDN + credential.

function Invoke-VcfCheckAriaOpsForLogsApi {
    <#
        .SYNOPSIS
        Calls Aria Operations for Logs' REST API with a bearer session token.

        .DESCRIPTION
        Thin Invoke-RestMethod wrapper - no PowerCLI/OpenAPI SDK covers Aria Operations for Logs
        (see file header). -SkipCertificateCheck is only passed when Session.AllowInsecureTls is
        $true, matching every other hand-rolled-REST connector in this repo, rather than being
        unconditional.

        .PARAMETER Session
        The object returned by Connect-VcfCheckAriaOpsForLogsEndpoint.

        .PARAMETER Method
        HTTP method. Defaults to GET.

        .PARAMETER Path
        The Aria Operations for Logs API path, e.g. '/api/v2/version'.

        .OUTPUTS
        The parsed JSON response.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Session,
        [Parameter(Mandatory = $false)] [ValidateSet('GET', 'POST')] [String]$Method = 'GET',
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    $uri = "https://$($Session.Fqdn):$($Session.Port)$Path"
    $parameters = @{
        Uri                  = $uri
        Method               = $Method
        Headers              = @{ Authorization = "Bearer $($Session.SessionId)" }
        ContentType          = 'application/json'
        SkipCertificateCheck = $Session.AllowInsecureTls
        ErrorAction          = 'Stop'
    }

    try {
        return Invoke-RestMethod @parameters
    } catch {
        $friendly = ConvertTo-VcfCheckFriendlyAriaOpsForLogsError -Fqdn $Session.Fqdn -ErrorMessage $_.Exception.Message
        throw [System.InvalidOperationException]::new($friendly)
    }
}
function Get-VcfCheckEnvironmentAriaOpsForLogsEndpoints {
    <#
        .SYNOPSIS
        Resolves the user-declared, standalone Aria Operations for Logs endpoints attached to an
        environment (Private/Environments.ps1's Integrations field) - instances SDDC Manager has
        zero knowledge of.

        .DESCRIPTION
        Filters $Environment.Integrations to entries with Type -eq 'AriaOpsForLogs' and flattens
        their Endpoints into one object per endpoint, applying each integration's
        SharedCredentials setting to resolve which Username applies (the integration-level one
        when shared, else the endpoint's own). Never resolves a password - see
        Connect-VcfCheckAriaOpsForLogsEndpoint.

        When the integration has EnableGuestOsChecks set, also resolves VCenterFqdn/
        VCenterUsername for the vCenter that hosts this endpoint - the integration-level
        AriaVCenterFqdn/AriaVCenterUsername when AriaVCenterSharedAcrossEndpoints is set, else the
        endpoint's own VCenterFqdn/VCenterUsername. Both are left $null when guestOS checks are
        not enabled, so Get-VcfCheckAllVCenterFqdns' dedup loop skips the endpoint. When guestOS
        checks are enabled, not shared, and the endpoint has no VCenterFqdn of its own, both are
        left $null and a warning is logged.

        .PARAMETER Environment
        An environment object as returned by Get-VcfCheckEnvironments.

        .OUTPUTS
        [Object[]] of PSCustomObject with Name, Fqdn, Username, VCenterFqdn, VCenterUsername,
        VmNames. VmNames is the user-declared, comma-delimited list of guestOS VM names for this
        endpoint - a single Aria appliance is not always one VM, and its VM name(s) cannot be
        assumed to match the FQDN shortname, so it is entered explicitly rather than derived.
        Empty array if the environment has no AriaOpsForLogs integration.

        .EXAMPLE
        Get-VcfCheckEnvironmentAriaOpsForLogsEndpoints -Environment $environment
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Environment
    )

    $results = [System.Collections.Generic.List[PSObject]]::new()
    $ariaIntegrations = @($Environment.Integrations) | Where-Object { $_ -and $_.Type -eq 'AriaOpsForLogs' }

    foreach ($integration in $ariaIntegrations) {
        foreach ($endpoint in @($integration.Endpoints)) {
            if (-not $endpoint) {
                continue
            }
            $username = if ($integration.SharedCredentials) { $integration.Username } else { $endpoint.Username }
            $vCenterFqdn = $null
            $vCenterUsername = $null
            if ($integration.EnableGuestOsChecks) {
                if ($integration.AriaVCenterSharedAcrossEndpoints) {
                    $vCenterFqdn = $integration.AriaVCenterFqdn
                    $vCenterUsername = $integration.AriaVCenterUsername
                } else {
                    $vCenterFqdn = $endpoint.VCenterFqdn
                    $vCenterUsername = $endpoint.VCenterUsername
                    if ([String]::IsNullOrWhiteSpace($vCenterFqdn)) {
                        Write-LogMessage -Type WARNING -Message "GuestOS checks are enabled for Aria Operations for Logs endpoint '$($endpoint.Name)' but no VCenterFqdn is configured; skipping guestOS checks for this endpoint."
                    }
                }
            }
            $results.Add([PSCustomObject]@{
                PSTypeName      = 'VcfCheck.AriaOpsForLogsEndpoint'
                Name            = $endpoint.Name
                Fqdn            = $endpoint.Fqdn
                Username        = $username
                VCenterFqdn     = $vCenterFqdn
                VCenterUsername = $vCenterUsername
                VmNames         = @(if ($endpoint.VmNames) { $endpoint.VmNames } else { @() })
            })
        }
    }

    return $results.ToArray()
}
function Connect-VcfCheckAriaOpsForLogsEndpoint {
    <#
        .SYNOPSIS
        Acquires a session token for a user-declared, standalone Aria Operations for Logs
        endpoint by FQDN and credential - no SDDC Manager lookup.

        .DESCRIPTION
        Connects to an Aria Operations for Logs instance declared on the environment (see
        Get-VcfCheckEnvironmentAriaOpsForLogsEndpoints) - the only source of Aria Operations for
        Logs FQDN/credential, since SDDC Manager never holds one. Runs a TCP reachability
        pre-flight against <Fqdn>:<Port> before POSTing '/api/v2/sessions', and caches the
        resulting session on $Context.AriaOpsForLogsEndpointConnections (keyed by Fqdn, since
        there can be more than one) so repeat checks against the same endpoint reuse it as long
        as more than 60 seconds of its ttl remain. Unreachable/failed endpoints are cached on
        $Context.UnreachableAriaOpsForLogsEndpoints (also keyed by Fqdn) for the same fail-fast
        reason Connect-VcfCheckAriaOpsEndpoint caches per-endpoint failures.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER Fqdn
        The endpoint's FQDN, as entered by the user.

        .PARAMETER Credential
        The credential to connect with. The caller is responsible for resolving the password
        (session-only prompt or launcher parameter) - this function never persists or looks one
        up itself.

        .PARAMETER Port
        The API port. Defaults to 9543, matching the product's documented API port - not 443.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for the TCP reachability pre-flight check. Defaults to 15 seconds.

        .OUTPUTS
        [PSCustomObject] with Fqdn/Port/SessionId/AllowInsecureTls/ExpiresAt properties.

        .EXAMPLE
        Connect-VcfCheckAriaOpsForLogsEndpoint -Context $Context -Fqdn 'vrli-standalone.example.com' -Credential $credential
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $true)] [PSCredential]$Credential,
        [Parameter(Mandatory = $false)] [Int]$Port = 9543,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 15
    )

    if (-not $Context.AriaOpsForLogsEndpointConnections) {
        $Context.AriaOpsForLogsEndpointConnections = @{}
    }
    if (-not $Context.UnreachableAriaOpsForLogsEndpoints) {
        $Context.UnreachableAriaOpsForLogsEndpoints = @{}
    }

    if ($Context.UnreachableAriaOpsForLogsEndpoints.ContainsKey($Fqdn)) {
        throw [System.InvalidOperationException]::new($Context.UnreachableAriaOpsForLogsEndpoints[$Fqdn])
    }
    $cached = $Context.AriaOpsForLogsEndpointConnections[$Fqdn]
    if ($cached -and $cached.ExpiresAt -gt (Get-Date).AddSeconds(60)) {
        return $cached
    }

    if (-not (Test-VcfCheckTcpConnectivity -ComputerName $Fqdn -Port $Port -TimeoutSeconds $ConnectivityTimeoutSeconds)) {
        $reason = "Could not reach Aria Operations for Logs `"$Fqdn`" on port $Port within $ConnectivityTimeoutSeconds second(s). Check VPN/network connectivity to the environment, firewall rules, and that the FQDN resolves to the correct address, then retry."
        $Context.UnreachableAriaOpsForLogsEndpoints[$Fqdn] = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    $uri = "https://${Fqdn}:${Port}/api/v2/sessions"
    $body = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
        provider = 'Local'
    } | ConvertTo-Json
    $parameters = @{
        Uri                  = $uri
        Method               = 'POST'
        Body                 = $body
        ContentType          = 'application/json'
        SkipCertificateCheck = [Bool]$Context.AllowInsecureTls
        ErrorAction          = 'Stop'
    }

    Write-LogMessage -Type INFO -Message "Connecting to Aria Operations for Logs `"$Fqdn`"..." -NoNewline
    try {
        $response = Invoke-RestMethod @parameters
        Write-Host " Connected" -ForegroundColor White
    } catch {
        Write-Host " Failed" -ForegroundColor Red
        $reason = ConvertTo-VcfCheckFriendlyAriaOpsForLogsError -Fqdn $Fqdn -ErrorMessage $_.Exception.Message
        $Context.UnreachableAriaOpsForLogsEndpoints[$Fqdn] = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    $session = [PSCustomObject]@{
        PSTypeName       = 'VcfCheck.AriaOpsForLogsSession'
        Fqdn             = $Fqdn
        Port             = $Port
        SessionId        = $response.sessionId
        AllowInsecureTls = [Bool]$Context.AllowInsecureTls
        ExpiresAt        = (Get-Date).AddSeconds([Int]$response.ttl)
    }
    $Context.AriaOpsForLogsEndpointConnections[$Fqdn] = $session
    return $session
}
function ConvertTo-VcfCheckFriendlyAriaOpsForLogsError {
    <#
        .SYNOPSIS
        Translates a raw Aria Operations for Logs API connection exception into a user-facing
        message.

        .DESCRIPTION
        Mirrors ConvertTo-VcfCheckFriendlyVrslcmError's translation table (TLS trust, SSL
        handshake, connection refused, DNS resolution, timeout) so both hand-rolled-REST
        connectors give consistent, actionable messages instead of raw .NET exception text.

        .PARAMETER Fqdn
        The Aria Operations for Logs FQDN the failed request was made to.

        .PARAMETER ErrorMessage
        The raw exception message to translate.

        .OUTPUTS
        [String] a user-facing error message.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage
    )
    $tlsMessage = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'Aria Operations for Logs' -Fqdn $Fqdn -ErrorMessage $ErrorMessage
    if ($tlsMessage) {
        return $tlsMessage
    }
    if ($ErrorMessage -match '(?i)SSL connection could not be established|handshake') {
        return "Could not establish an SSL connection to Aria Operations for Logs `"$Fqdn`". Verify the appliance is powered on, reachable on its API port, and that VPN/firewall rules allow the connection."
    }
    if ($ErrorMessage -match '(?i)actively refused|connection refused') {
        return "Aria Operations for Logs `"$Fqdn`" refused the connection. Verify the appliance is powered on and its service is running."
    }
    if ($ErrorMessage -match '(?i)No such host is known|could not be resolved|name or service not known') {
        return "Could not resolve Aria Operations for Logs' FQDN `"$Fqdn`". Verify DNS resolution."
    }
    if ($ErrorMessage -match '(?i)timed out|timeout') {
        return "Connection to Aria Operations for Logs `"$Fqdn`" timed out. Verify network connectivity, VPN, and firewall rules."
    }
    if ($ErrorMessage -match '(?i)Unauthorized|401') {
        return "Aria Operations for Logs `"$Fqdn`" rejected the supplied credentials."
    }
    return $ErrorMessage
}
function Resolve-VcfCheckAriaOpsForLogsEndpointCredentials {
    <#
        .SYNOPSIS
        Resolves and caches a [PSCredential] per standalone Aria Operations for Logs endpoint's
        Username.

        .DESCRIPTION
        For each endpoint returned by Get-VcfCheckEnvironmentAriaOpsForLogsEndpoints, uses a
        matching entry (by Fqdn) in PreSuppliedCredentials (the launcher/browser session-only
        password path) when present, otherwise prompts once via Read-Host -AsSecureString.
        Results are cached on $Context.AriaOpsForLogsEndpointCredentials, keyed by Fqdn, so a
        second run within the same $Context never re-prompts. Mirrors
        Resolve-VcfCheckAriaOpsEndpointCredentials.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER Endpoints
        Endpoint objects as returned by Get-VcfCheckEnvironmentAriaOpsForLogsEndpoints
        (Name/Fqdn/Username).

        .PARAMETER PreSuppliedCredentials
        Optional array of PSCustomObject/Hashtable with Fqdn/Username/Password (SecureString).
        Endpoints not matched here fall back to an interactive prompt.

        .EXAMPLE
        Resolve-VcfCheckAriaOpsForLogsEndpointCredentials -Context $Context -Endpoints $endpoints -PreSuppliedCredentials $AriaOpsForLogsEndpointCredentials
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'PreSuppliedCredentials', Justification = 'Object[] of Fqdn/Username/Password triplets, not a password itself - each element''s Password field is already a SecureString.')]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [Object[]]$Endpoints,
        [Parameter(Mandatory = $false)] [Object[]]$PreSuppliedCredentials = @()
    )

    foreach ($endpoint in @($Endpoints)) {
        if (-not $endpoint -or $Context.AriaOpsForLogsEndpointCredentials.ContainsKey($endpoint.Fqdn)) {
            continue
        }

        $preSupplied = @($PreSuppliedCredentials) | Where-Object { $_ -and $_.Fqdn -eq $endpoint.Fqdn } | Select-Object -First 1
        if ($preSupplied) {
            $Context.AriaOpsForLogsEndpointCredentials[$endpoint.Fqdn] = [PSCredential]::new($endpoint.Username, $preSupplied.Password)
            continue
        }

        $securePassword = Read-Host -Prompt "Enter the password for $($endpoint.Username)@$($endpoint.Fqdn) (Aria Operations for Logs - $($endpoint.Name))" -AsSecureString
        if ($securePassword.Length -eq 0) {
            throw [System.InvalidOperationException]::new("Password for Aria Operations for Logs endpoint `"$($endpoint.Fqdn)`" must not be empty.")
        }
        $Context.AriaOpsForLogsEndpointCredentials[$endpoint.Fqdn] = [PSCredential]::new($endpoint.Username, $securePassword)
    }
}
function Get-VcfCheckAriaOpsForLogsTargets {
    <#
        .SYNOPSIS
        Resolves every Aria Operations for Logs instance a check should evaluate - every
        standalone endpoint declared on the current environment - and connects to each.

        .DESCRIPTION
        Every Test-VcfAriaOpsForLogs* check calls this once instead of
        Connect-VcfCheckAriaOpsForLogsEndpoint directly, so a single check fans out across every
        declared instance. SDDC Manager never holds an Aria Operations for Logs credential (it
        is deployed and lifecycle-managed by Aria Suite Lifecycle, but Aria Operations for Logs
        manages its own credentials via its own API), so the environment's
        declared Integrations endpoints are the only source of targets. A connection failure for
        one target never blocks evaluation of the others - it is surfaced on that target's
        ConnectError instead of throwing. Mirrors Get-VcfCheckAriaOpsTargets.

        .PARAMETER Context
        The VcfCheck.Context object. $Context.AriaOpsForLogsEndpoints and
        $Context.AriaOpsForLogsEndpointCredentials must already be populated (via
        Resolve-VcfCheckAriaOpsForLogsEndpointCredentials) for standalone endpoints to be
        included.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for each target's TCP reachability pre-flight check. Defaults to 15
        seconds.

        .OUTPUTS
        [Object[]] of PSCustomObject with Name, Fqdn, Session, ConnectError. Session is the
        object returned by Connect-VcfCheckAriaOpsForLogsEndpoint - pass it to
        Invoke-VcfCheckAriaOpsForLogsApi. Empty array if the environment has no Aria Operations
        for Logs Integration declared - callers must treat that as Skipped.

        .EXAMPLE
        Get-VcfCheckAriaOpsForLogsTargets -Context $Context
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 15
    )

    $targets = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($endpoint in @($Context.AriaOpsForLogsEndpoints) | Where-Object { $_ }) {
        $credential = $Context.AriaOpsForLogsEndpointCredentials[$endpoint.Fqdn]
        if (-not $credential) {
            $targets.Add([PSCustomObject]@{ Name = $endpoint.Name; Fqdn = $endpoint.Fqdn; Session = $null; ConnectError = "No password was supplied for Aria Operations for Logs endpoint `"$($endpoint.Fqdn)`"." })
            continue
        }
        try {
            $session = Connect-VcfCheckAriaOpsForLogsEndpoint -Context $Context -Fqdn $endpoint.Fqdn -Credential $credential -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
            $targets.Add([PSCustomObject]@{ Name = $endpoint.Name; Fqdn = $endpoint.Fqdn; Session = $session; ConnectError = $null })
        } catch {
            $targets.Add([PSCustomObject]@{ Name = $endpoint.Name; Fqdn = $endpoint.Fqdn; Session = $null; ConnectError = $_.Exception.Message })
        }
    }

    return $targets.ToArray()
}
function Get-VcfCheckAriaOpsForLogsVersion {
    <#
        .SYNOPSIS
        Queries Aria Operations for Logs' own '/api/v2/version' endpoint for its installed
        version.

        .DESCRIPTION
        Live-verified 2026-09-14 against sfo-logs01.sfo.rainpole.io:9543: the response is
        {"releaseName": "GA", "version": "8.18.0-24021974"} - a dotted version string with a
        trailing build-number suffix, same shape as other components' Interop Matrix comparisons
        expect once the build suffix is stripped.

        .PARAMETER Session
        The object returned by Connect-VcfCheckAriaOpsForLogsEndpoint.

        .OUTPUTS
        [String] the installed version, e.g. '8.18.0-24021974'.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Session
    )

    $response = Invoke-VcfCheckAriaOpsForLogsApi -Session $Session -Path '/api/v2/version'
    return $response.version
}
function Get-VcfCheckAriaOpsForLogsCertificate {
    <#
        .SYNOPSIS
        Queries Aria Operations for Logs' own '/api/v2/certificate' endpoint for its appliance
        certificate.

        .DESCRIPTION
        Returns the certificate currently presented by the appliance itself - owner/issuer
        distinguished-name fields and a validityPeriod.from/until pair - not the deprecated
        '/api/v2/certificates' trusted-certificate list, which reports certificates the appliance
        trusts from other systems, not its own. The spec's documented example wraps a single
        object in a JSON array even though the schema describes one object; both shapes are
        handled here.

        .PARAMETER Session
        The object returned by Connect-VcfCheckAriaOpsForLogsEndpoint.

        .OUTPUTS
        [PSCustomObject] the certificate object (owner/issuer/serialNum/validityPeriod).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Session
    )

    $response = Invoke-VcfCheckAriaOpsForLogsApi -Session $Session -Path '/api/v2/certificate'
    if ($response -is [Array]) {
        return $response[0]
    }
    return $response
}
function Get-VcfCheckAriaOpsForLogsVsphereIntegrations {
    <#
        .SYNOPSIS
        Queries Aria Operations for Logs' own '/api/v2/vsphere' endpoint for its configured
        vCenter Server integrations.

        .DESCRIPTION
        Returns the 'vSenterServers' array (the API's own property name, not a typo introduced
        here) - one entry per configured vCenter Server, each carrying the appliance's live
        collectionStatus/collectionStatusDetails for that integration, not just whether it is
        configured.

        .PARAMETER Session
        The object returned by Connect-VcfCheckAriaOpsForLogsEndpoint.

        .OUTPUTS
        [Object[]] of PSCustomObject, one per configured vCenter Server integration. Empty array
        if none are configured.
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Session
    )

    $response = Invoke-VcfCheckAriaOpsForLogsApi -Session $Session -Path '/api/v2/vsphere'
    return @($response.vSenterServers)
}
function Get-VcfCheckAriaOpsForLogsLogForwarders {
    <#
        .SYNOPSIS
        Queries Aria Operations for Logs' own '/api/v2/log-forwarder' endpoint for its configured
        log forwarders.

        .DESCRIPTION
        Returns the flat array the endpoint returns directly (no wrapper property, unlike
        '/api/v2/vsphere''s 'vSenterServers') - one entry per configured forwarder, each carrying
        the appliance's live forwarderStats.state (ACTIVE/PENDING/IDLE) for that forwarder, not
        just whether it is configured.

        .PARAMETER Session
        The object returned by Connect-VcfCheckAriaOpsForLogsEndpoint.

        .OUTPUTS
        [Object[]] of PSCustomObject, one per configured log forwarder. Empty array if none are
        configured.
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Session
    )

    $response = Invoke-VcfCheckAriaOpsForLogsApi -Session $Session -Path '/api/v2/log-forwarder'
    return @($response)
}
function Get-VcfCheckAriaOpsForLogsVidmStatus {
    <#
        .SYNOPSIS
        Queries Aria Operations for Logs' own '/api/v2/vidm/status' endpoint for its vIDM auth-source
        connection state.

        .DESCRIPTION
        Returns the 'state' field directly - CONNECTED/DISCONNECTED/UNCONFIGURED per the OpenAPI
        spec's enum - the appliance's own live assessment of its vIDM connection, not just whether
        vIDM is configured. Unlike '/api/v2/vsphere'/'/api/v2/log-forwarder', this endpoint has no
        details/reason field alongside the state.

        .PARAMETER Session
        The object returned by Connect-VcfCheckAriaOpsForLogsEndpoint.

        .OUTPUTS
        [String] the vIDM connection state, e.g. 'CONNECTED'.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Session
    )

    $response = Invoke-VcfCheckAriaOpsForLogsApi -Session $Session -Path '/api/v2/vidm/status'
    return $response.state
}

#endregion AriaOpsForLogsHelpers
