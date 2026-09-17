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
#region AriaAutomationHelpers
#
# Aria Automation has no PowerCLI/OpenAPI SDK coverage at all (unlike Aria Operations'
# VMware.Sdk.Vcf.Ops) - every call in this file is hand-written REST via Invoke-RestMethod.
#
# Aria Automation is deployed and lifecycle-managed by Aria Suite Lifecycle (VRSLCM), but VRSLCM
# does not hold the Aria Automation credential either - Aria Automation manages its own
# credentials via its own API. SDDC Manager's own credential vault never holds an Aria Automation
# credential, so this file has no SDDC-Manager-based resolution path at all.
# Get-VcfCheckEnvironmentAriaAutomationEndpoints resolves the user-declared Integrations list on
# an environment (Private/Environments.ps1) as
# the only source of Aria Automation FQDN/credential. Connect-VcfCheckAriaAutomationEndpoint
# connects to one of those directly by FQDN + credential.
#
# Authentication is a two-step exchange, confirmed against a live 8.18 appliance:
#   1. POST '/csp/gateway/am/api/login?access_token' (the '?access_token' query flag is
#      required - without it the same endpoint instead returns an unrelated short-lived
#      'cspAuthToken' session token that '/iaas/api/login' rejects with "'refreshToken' is
#      invalid") with {username, password, domain} -> {refresh_token}.
#   2. POST '/iaas/api/login' (documented in the public IaaS API spec) with {refreshToken} ->
#      {token, tokenType: "Bearer"}. This bearer token is short-lived and is presented on every
#      later call as 'Authorization: Bearer <token>'.
# Local/System Domain accounts do not use a consistent domain value across vIDM builds - this
# file tries 'System Domain' first, then '' (both were observed to succeed against different
# appliances), before falling back to the credential's own domain segment for directory-backed
# accounts ('DOMAIN\user' / 'user@domain'), matching the parsing Get-VcfCheckAriaOpsApiToken
# already uses for Aria Operations.

function Get-VcfCheckAriaAutomationRefreshToken {
    <#
        .SYNOPSIS
        Acquires (and caches) an Aria Automation vIDM refresh token.

        .DESCRIPTION
        POSTs to '/csp/gateway/am/api/login?access_token' with the credential's username/
        password. The '?access_token' query flag is required - see AriaAutomationHelpers.ps1's
        file header for why. Directory-backed accounts ('DOMAIN\user' / 'user@domain') resolve
        their domain from the username; local/System Domain accounts try 'System Domain' first,
        then '' - both have been observed to work depending on appliance/vIDM version. The
        refresh token is cached as a 'RefreshToken' member added directly onto the CredentialInfo
        object so every call within a run re-uses it instead of re-authenticating.

        .PARAMETER CredentialInfo
        The AriaAutomationCredential object returned by Connect-VcfCheckAriaAutomationEndpoint
        (Fqdn + Credential).

        .OUTPUTS
        [String] the refresh token.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo
    )

    if ($CredentialInfo.PSObject.Properties['RefreshToken'] -and $CredentialInfo.RefreshToken) {
        return $CredentialInfo.RefreshToken
    }

    $rawUsername = $CredentialInfo.Credential.UserName
    if ($rawUsername -match '^(?<domain>[^\\]+)\\(?<user>.+)$') {
        $username = $Matches.user
        $domainCandidates = @($Matches.domain)
    } elseif ($rawUsername -match '^(?<user>[^@]+)@(?<domain>.+)$') {
        $username = $Matches.user
        $domainCandidates = @($Matches.domain)
    } else {
        $username = $rawUsername
        $domainCandidates = @('System Domain', '')
    }

    $password = $CredentialInfo.Credential.GetNetworkCredential().Password
    $uri = "https://$($CredentialInfo.Fqdn)/csp/gateway/am/api/login?access_token"
    $refreshToken = $null
    $lastError = $null
    foreach ($domainCandidate in $domainCandidates) {
        $body = @{ username = $username; password = $password; domain = $domainCandidate } | ConvertTo-Json -Depth 2
        try {
            $response = Invoke-RestMethod -Uri $uri -Method POST -Body $body -ContentType 'application/json' -SkipCertificateCheck:$CredentialInfo.AllowInsecureTls -ErrorAction Stop
            if ($response.refresh_token) {
                $refreshToken = $response.refresh_token
                break
            }
        } catch {
            $lastError = $_
        }
    }

    if (-not $refreshToken) {
        if ($lastError) {
            $rawMessage = $lastError.Exception.Message
            if ($lastError.ErrorDetails.Message) {
                $rawMessage = "$rawMessage $($lastError.ErrorDetails.Message)"
            }
        } else {
            $rawMessage = 'no refresh_token field was returned'
        }
        $message = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'Aria Automation' -Fqdn $CredentialInfo.Fqdn -ErrorMessage $rawMessage
        if (-not $message) {
            $message = "Failed to acquire an Aria Automation refresh token for `"$($CredentialInfo.Fqdn)`": $rawMessage"
        }
        throw [System.InvalidOperationException]::new($message)
    }

    if ($CredentialInfo.PSObject.Properties['RefreshToken']) {
        $CredentialInfo.RefreshToken = $refreshToken
    } else {
        $CredentialInfo | Add-Member -NotePropertyName 'RefreshToken' -NotePropertyValue $refreshToken
    }
    return $refreshToken
}
function Get-VcfCheckAriaAutomationBearerToken {
    <#
        .SYNOPSIS
        Exchanges a cached refresh token for an Aria Automation IaaS API bearer token.

        .DESCRIPTION
        POSTs to '/iaas/api/login' with the refresh token from Get-VcfCheckAriaAutomationRefreshToken.
        The bearer token is cached as a 'BearerToken' member added directly onto the
        CredentialInfo object. Callers needing a fresh token after a 401 must call
        Clear-VcfCheckAriaAutomationBearerToken first, then call this function again.

        .PARAMETER CredentialInfo
        The AriaAutomationCredential object returned by Connect-VcfCheckAriaAutomationEndpoint
        (Fqdn + Credential).

        .OUTPUTS
        [String] the bearer token.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo
    )

    if ($CredentialInfo.PSObject.Properties['BearerToken'] -and $CredentialInfo.BearerToken) {
        return $CredentialInfo.BearerToken
    }

    $refreshToken = Get-VcfCheckAriaAutomationRefreshToken -CredentialInfo $CredentialInfo
    $body = @{ refreshToken = $refreshToken } | ConvertTo-Json
    try {
        $response = Invoke-RestMethod -Uri "https://$($CredentialInfo.Fqdn)/iaas/api/login" -Method POST -Body $body -ContentType 'application/json' -SkipCertificateCheck:$CredentialInfo.AllowInsecureTls -ErrorAction Stop
    } catch {
        $rawMessage = $_.Exception.Message
        if ($_.ErrorDetails.Message) {
            $rawMessage = "$rawMessage $($_.ErrorDetails.Message)"
        }
        $message = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'Aria Automation' -Fqdn $CredentialInfo.Fqdn -ErrorMessage $rawMessage
        if (-not $message) {
            $message = "Failed to exchange the Aria Automation refresh token for a bearer token on `"$($CredentialInfo.Fqdn)`": $rawMessage"
        }
        throw [System.InvalidOperationException]::new($message)
    }

    if ($CredentialInfo.PSObject.Properties['BearerToken']) {
        $CredentialInfo.BearerToken = $response.token
    } else {
        $CredentialInfo | Add-Member -NotePropertyName 'BearerToken' -NotePropertyValue $response.token
    }
    return $response.token
}
function Clear-VcfCheckAriaAutomationBearerToken {
    <#
        .SYNOPSIS
        Clears a cached, expired/rejected Aria Automation bearer token so the next call
        re-acquires one.

        .PARAMETER CredentialInfo
        The AriaAutomationCredential object carrying the cached BearerToken member.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo
    )

    if ($CredentialInfo.PSObject.Properties['BearerToken']) {
        $CredentialInfo.BearerToken = $null
    }
}
function Invoke-VcfCheckAriaAutomationApi {
    <#
        .SYNOPSIS
        Calls Aria Automation's REST API directly with a bearer token acquired via
        Get-VcfCheckAriaAutomationBearerToken.

        .DESCRIPTION
        Thin Invoke-RestMethod wrapper - Aria Automation has no SDK, so every check goes through
        this function. -SkipCertificateCheck is only passed when CredentialInfo.AllowInsecureTls
        is $true (the run's resolved AllowInsecureTls value, derived from PowerCLI's
        InvalidCertificateAction setting - see Invoke-VcfCheck in Orchestrator.ps1) rather than
        being unconditional; an untrusted
        certificate encountered while that is $false surfaces as a clear, actionable error via
        Get-VcfCheckTlsTrustErrorMessage instead of being silently accepted. Retries up to 3 times with a 10-second delay on transient network failures
        (timeouts, connection resets). On an HTTP 401 (expired bearer token), clears the cached
        token and re-authenticates once before retrying the call - this connector has no SDK
        managing token lifetime for it, unlike Aria Operations.

        .PARAMETER CredentialInfo
        The AriaAutomationCredential object returned by Connect-VcfCheckAriaAutomationEndpoint
        (Fqdn + Credential).

        .PARAMETER Method
        HTTP method. Defaults to GET.

        .PARAMETER Path
        The IaaS/CSP API path, e.g. '/iaas/api/about'.

        .PARAMETER Body
        Optional request body, already a Hashtable/PSCustomObject (will be converted to JSON).

        .OUTPUTS
        The parsed JSON response.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo,
        [Parameter(Mandatory = $false)] [ValidateSet('GET', 'POST')] [String]$Method = 'GET',
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path,
        [Parameter(Mandatory = $false)] [Object]$Body
    )

    $uri = "https://$($CredentialInfo.Fqdn)$Path"
    $maxAttempts = 3
    $retryDelaySeconds = 10
    $reauthenticated = $false

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $token = Get-VcfCheckAriaAutomationBearerToken -CredentialInfo $CredentialInfo
        $parameters = @{
            Uri                  = $uri
            Method               = $Method
            Headers              = @{ Accept = 'application/json'; Authorization = "Bearer $token" }
            SkipCertificateCheck = $CredentialInfo.AllowInsecureTls
            ErrorAction          = 'Stop'
        }
        if ($Body) {
            $parameters.Body = ($Body | ConvertTo-Json -Depth 10)
            $parameters.ContentType = 'application/json'
        }

        try {
            return Invoke-RestMethod @parameters
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 401 -and -not $reauthenticated) {
                Write-LogMessage -Type DEBUG -Message "Aria Automation bearer token for `"$($CredentialInfo.Fqdn)`" was rejected (HTTP 401) - re-authenticating."
                Clear-VcfCheckAriaAutomationBearerToken -CredentialInfo $CredentialInfo
                $reauthenticated = $true
                continue
            }
            $tlsMessage = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'Aria Automation' -Fqdn $CredentialInfo.Fqdn -ErrorMessage $_.Exception.Message
            if ($tlsMessage) {
                throw [System.InvalidOperationException]::new($tlsMessage)
            }
            $isTransient = $_.Exception.Message -match '(?i)timed out|timeout|actively refused|connection refused|reset by peer|handshake'
            if (-not $isTransient -or $attempt -eq $maxAttempts) {
                throw
            }
            Write-LogMessage -Type DEBUG -Message "Transient error calling Aria Automation API '$Path' (attempt $attempt of $maxAttempts): $($_.Exception.Message). Retrying in $retryDelaySeconds seconds."
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }
}
function Get-VcfCheckAriaAutomationConnectionFailureCategory {
    <#
        .SYNOPSIS
        Classifies a Connect-VcfCheckAriaAutomationEndpoint failure message so the caller can
        show an accurate, specific remediation instead of one generic "check your network"
        message for every failure.

        .DESCRIPTION
        A rejected credential (bad password) surfaces from the login exchange
        (Get-VcfCheckAriaAutomationRefreshToken / Get-VcfCheckAriaAutomationBearerToken) as an
        ordinary caught exception, indistinguishable at a glance from a real network/TLS problem.
        Left unclassified, it was being reported as an "Error" result telling the user to verify
        network connectivity - misleading when the endpoint is reachable and the only problem is
        the entered credential. This inspects the exception message for a recognized credential/
        authorization rejection signature and returns 'AuthenticationFailed', else 'Unknown'.

        .PARAMETER ErrorMessage
        The exception message from a failed Connect-VcfCheckAriaAutomationEndpoint call.

        .OUTPUTS
        [String] one of 'AuthenticationFailed', 'Unknown'.

        .EXAMPLE
        Get-VcfCheckAriaAutomationConnectionFailureCategory -ErrorMessage $_.Exception.Message
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage
    )

    if ($ErrorMessage -match '(?i)UNAUTHORIZED|not authorized|invalid credentials|invalid_grant|invalid user ?name or password|incorrect user ?name or password|authentication failed|401\b') {
        return 'AuthenticationFailed'
    }
    return 'Unknown'
}
function Get-VcfCheckEnvironmentAriaAutomationEndpoints {
    <#
        .SYNOPSIS
        Resolves the user-declared, standalone Aria Automation endpoints attached to an
        environment (Private/Environments.ps1's Integrations field) - components SDDC Manager
        has zero knowledge of.

        .DESCRIPTION
        Filters $Environment.Integrations to entries with Type -eq 'AriaAutomation' and flattens
        their Endpoints into one object per endpoint, applying each integration's
        SharedCredentials setting to resolve which Username applies (the integration-level one
        when shared, else the endpoint's own). Never resolves a password - see
        Connect-VcfCheckAriaAutomationEndpoint.

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
        Empty array if the environment has no AriaAutomation integration.

        .EXAMPLE
        Get-VcfCheckEnvironmentAriaAutomationEndpoints -Environment $environment
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Environment
    )

    $results = [System.Collections.Generic.List[PSObject]]::new()
    $ariaIntegrations = @($Environment.Integrations) | Where-Object { $_ -and $_.Type -eq 'AriaAutomation' }

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
                        Write-LogMessage -Type WARNING -Message "GuestOS checks are enabled for Aria Automation endpoint '$($endpoint.Name)' but no VCenterFqdn is configured; skipping guestOS checks for this endpoint."
                    }
                }
            }
            $results.Add([PSCustomObject]@{
                PSTypeName      = 'VcfCheck.AriaAutomationEndpoint'
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
function Connect-VcfCheckAriaAutomationEndpoint {
    <#
        .SYNOPSIS
        Validates connectivity and authentication against a user-declared Aria Automation
        endpoint by FQDN and credential - no SDDC Manager lookup.

        .DESCRIPTION
        Connects to an Aria Automation instance declared on the environment (see
        Get-VcfCheckEnvironmentAriaAutomationEndpoints) - the only source of Aria Automation
        FQDN/credential, since SDDC Manager never holds one. Runs a TCP reachability pre-flight
        and login exchange, caching the resulting CredentialInfo on
        $Context.AriaAutomationEndpointConnections (keyed by Fqdn, since there can be more than
        one) so repeat checks against the same endpoint reuse it. Unreachable/failed endpoints
        are cached on $Context.UnreachableAriaAutomationEndpoints (also keyed by Fqdn).

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
        The AriaAutomationCredential object (now carrying a cached bearer token).

        .EXAMPLE
        Connect-VcfCheckAriaAutomationEndpoint -Context $Context -Fqdn 'vra-standalone.example.com' -Credential $credential
    #>
    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $true)] [PSCredential]$Credential,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 15
    )

    if (-not $Context.AriaAutomationEndpointConnections) {
        $Context.AriaAutomationEndpointConnections = @{}
    }
    if (-not $Context.UnreachableAriaAutomationEndpoints) {
        $Context.UnreachableAriaAutomationEndpoints = @{}
    }

    if ($Context.UnreachableAriaAutomationEndpoints.ContainsKey($Fqdn)) {
        throw [System.InvalidOperationException]::new($Context.UnreachableAriaAutomationEndpoints[$Fqdn])
    }
    if ($Context.AriaAutomationEndpointConnections.ContainsKey($Fqdn)) {
        return $Context.AriaAutomationEndpointConnections[$Fqdn]
    }

    if (-not (Test-VcfCheckTcpConnectivity -ComputerName $Fqdn -Port 443 -TimeoutSeconds $ConnectivityTimeoutSeconds)) {
        $reason = "Could not reach Aria Automation `"$Fqdn`" on port 443 within $ConnectivityTimeoutSeconds second(s). Check VPN/network connectivity to the environment, firewall rules, and that the FQDN resolves to the correct address, then retry."
        $Context.UnreachableAriaAutomationEndpoints[$Fqdn] = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    $credentialInfo = [PSCustomObject]@{ PSTypeName = 'VcfCheck.AriaAutomationCredential'; Fqdn = $Fqdn; Credential = $Credential; AllowInsecureTls = [Bool]$Context.AllowInsecureTls }
    Write-LogMessage -Type INFO -Message "Connecting to Aria Automation `"$Fqdn`"..." -NoNewline
    try {
        [void](Get-VcfCheckAriaAutomationBearerToken -CredentialInfo $credentialInfo)
        # Write-Host: completes the -NoNewline INFO line above on the same console row; Write-LogMessage
        # always appends a newline, which would split the status suffix onto its own line.
        Write-Host " Connected" -ForegroundColor White
    } catch {
        # Write-Host: see comment above - completes the same -NoNewline console row.
        Write-Host " Failed" -ForegroundColor Red
        $category = Get-VcfCheckAriaAutomationConnectionFailureCategory -ErrorMessage $_.Exception.Message
        $reason = switch ($category) {
            'AuthenticationFailed' { "Authentication failed for Aria Automation `"$Fqdn`". Verify the username and password entered for this endpoint are correct." }
            default { "Failed to authenticate to Aria Automation `"$Fqdn`". Verify network connectivity and the credential entered for this endpoint." }
        }
        $reason = "$reason $($_.Exception.Message)"
        $Context.UnreachableAriaAutomationEndpoints[$Fqdn] = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    $Context.AriaAutomationEndpointConnections[$Fqdn] = $credentialInfo
    return $credentialInfo
}
function Resolve-VcfCheckAriaAutomationEndpointCredentials {
    <#
        .SYNOPSIS
        Resolves and caches a [PSCredential] per standalone Aria Automation endpoint's Username.

        .DESCRIPTION
        For each endpoint returned by Get-VcfCheckEnvironmentAriaAutomationEndpoints, uses a
        matching entry (by Fqdn) in PreSuppliedCredentials (the launcher/browser session-only
        password path) when present, otherwise prompts once via Read-Host -AsSecureString.
        Results are cached on $Context.AriaAutomationEndpointCredentials, keyed by Fqdn, so a
        second run within the same $Context never re-prompts.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER Endpoints
        Endpoint objects as returned by Get-VcfCheckEnvironmentAriaAutomationEndpoints
        (Name/Fqdn/Username).

        .PARAMETER PreSuppliedCredentials
        Optional array of PSCustomObject/Hashtable with Fqdn/Username/Password (SecureString),
        e.g. resolved from the browser's per-endpoint session-only password field. Endpoints not
        matched here fall back to an interactive prompt.

        .EXAMPLE
        Resolve-VcfCheckAriaAutomationEndpointCredentials -Context $Context -Endpoints $endpoints -PreSuppliedCredentials $AriaAutomationEndpointCredentials
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'PreSuppliedCredentials', Justification = 'Object[] of Fqdn/Username/Password triplets, not a password itself - each element''s Password field is already a SecureString.')]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [Object[]]$Endpoints,
        [Parameter(Mandatory = $false)] [Object[]]$PreSuppliedCredentials = @()
    )

    if (-not $Context.AriaAutomationEndpointCredentials) {
        $Context.AriaAutomationEndpointCredentials = @{}
    }

    foreach ($endpoint in @($Endpoints)) {
        if (-not $endpoint -or $Context.AriaAutomationEndpointCredentials.ContainsKey($endpoint.Fqdn)) {
            continue
        }

        $preSupplied = @($PreSuppliedCredentials) | Where-Object { $_ -and $_.Fqdn -eq $endpoint.Fqdn } | Select-Object -First 1
        if ($preSupplied) {
            $Context.AriaAutomationEndpointCredentials[$endpoint.Fqdn] = [PSCredential]::new($endpoint.Username, $preSupplied.Password)
            continue
        }

        $securePassword = Read-Host -Prompt "Enter the password for $($endpoint.Username)@$($endpoint.Fqdn) (Aria Automation - $($endpoint.Name))" -AsSecureString
        if ($securePassword.Length -eq 0) {
            throw [System.InvalidOperationException]::new("Password for Aria Automation endpoint `"$($endpoint.Fqdn)`" must not be empty.")
        }
        $Context.AriaAutomationEndpointCredentials[$endpoint.Fqdn] = [PSCredential]::new($endpoint.Username, $securePassword)
    }
}
function Get-VcfCheckAriaAutomationTargets {
    <#
        .SYNOPSIS
        Resolves every Aria Automation instance a check should evaluate - every standalone
        endpoint declared on the current environment - and authenticates to each.

        .DESCRIPTION
        Every Test-VcfAriaAutomation* check calls this once instead of
        Connect-VcfCheckAriaAutomationEndpoint directly, so a single check fans out across every
        declared Aria Automation instance. SDDC Manager never holds an Aria Automation credential
        (it is deployed and lifecycle-managed by Aria Suite Lifecycle, but Aria Automation
        manages its own credentials via its own API), so the environment's
        declared Integrations endpoints are the only source of targets. An authentication failure
        for one target (unreachable, bad credential) never blocks evaluation of the others - it
        is surfaced on that target's ConnectError instead of throwing, so the caller can emit one
        Error result per failed target and keep evaluating the rest.

        .PARAMETER Context
        The VcfCheck.Context object. $Context.AriaAutomationEndpoints and
        $Context.AriaAutomationEndpointCredentials must already be populated by Invoke-VcfCheck
        (via Resolve-VcfCheckAriaAutomationEndpointCredentials) for endpoints to be included.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for each target's TCP reachability pre-flight check. Defaults to 15
        seconds.

        .OUTPUTS
        [Object[]] of PSCustomObject with Name, Fqdn, CredentialInfo, ConnectError.
        CredentialInfo (Fqdn/Credential, plus a cached bearer token) is the same shape
        Connect-VcfCheckAriaAutomationEndpoint returns - pass it to Invoke-VcfCheckAriaAutomationApi.
        Empty array if the environment has no Aria Automation Integration declared - callers must
        treat that as Skipped.

        .EXAMPLE
        Get-VcfCheckAriaAutomationTargets -Context $Context
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 15
    )

    $targets = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($endpoint in @($Context.AriaAutomationEndpoints) | Where-Object { $_ }) {
        $credential = $Context.AriaAutomationEndpointCredentials[$endpoint.Fqdn]
        if (-not $credential) {
            $targets.Add([PSCustomObject]@{ Name = $endpoint.Name; Fqdn = $endpoint.Fqdn; CredentialInfo = $null; ConnectError = "No password was supplied for Aria Automation endpoint `"$($endpoint.Fqdn)`"." })
            continue
        }
        try {
            $credentialInfo = Connect-VcfCheckAriaAutomationEndpoint -Context $Context -Fqdn $endpoint.Fqdn -Credential $credential -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
            $targets.Add([PSCustomObject]@{ Name = $endpoint.Name; Fqdn = $endpoint.Fqdn; CredentialInfo = $credentialInfo; ConnectError = $null })
        } catch {
            $targets.Add([PSCustomObject]@{ Name = $endpoint.Name; Fqdn = $endpoint.Fqdn; CredentialInfo = $null; ConnectError = $_.Exception.Message })
        }
    }

    return $targets.ToArray()
}
function Get-VcfCheckAriaAutomationVersion {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around GET /vco/api/about, returning Aria Automation's own
        reported marketing version with the build number stripped out.

        .DESCRIPTION
        Aria Automation ships the embedded vRealize Orchestrator's own version 1:1 with the
        product release, exposed on '/vco/api/about' as e.g. "8.18.0.24015865" - the trailing
        segment is vRO's internal build number, not part of the marketing version the shipped
        Interop Matrix snapshot (Data/Interoperability/Vra.json) compares against. This keeps
        only the leading major.minor.patch group.

        .PARAMETER CredentialInfo
        The AriaAutomationCredential object returned by Connect-VcfCheckAriaAutomationEndpoint
        (Fqdn + Credential).

        .OUTPUTS
        [String] the dotted marketing version string, or $null if it could not be determined.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$CredentialInfo
    )

    $about = Invoke-VcfCheckAriaAutomationApi -CredentialInfo $CredentialInfo -Path '/vco/api/about' -ErrorAction Stop
    if ($null -eq $about -or [String]::IsNullOrWhiteSpace($about.version)) {
        return $null
    }

    $match = [Regex]::Match($about.version, '^\d+\.\d+\.\d+')
    if (-not $match.Success) {
        return $null
    }

    return $match.Value
}
