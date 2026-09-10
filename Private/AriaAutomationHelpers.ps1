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
# Aria Automation has no per-domain FQDN lookup - like VROPS/VRSLCM, Invoke-VcfGetCredentials
# -ResourceType VRA is the only source for both its FQDN and credential. Credential filtering
# on CredentialType -eq 'API' is done client-side because Invoke-VcfGetCredentials lacks a
# -CredentialType parameter (only -AccountType is available).
#
# Aria Automation can also be deployed entirely outside SDDC Manager's knowledge - see
# Get-VcfCheckEnvironmentAriaAutomationEndpoints, which resolves the user-declared Integrations
# list on an environment (Private/Environments.ps1) instead of Invoke-VcfGetCredentials.
# Connect-VcfCheckAriaAutomationEndpoint connects to one of those directly by FQDN + credential,
# with no SDDC Manager lookup at all.
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

function Get-VcfCheckAriaAutomationCredential {
    <#
        .SYNOPSIS
        Resolves and caches Aria Automation's FQDN and API credential from SDDC Manager.

        .DESCRIPTION
        Calls Invoke-VcfGetCredentials -ResourceType VRA once per run and caches the result on
        $Context. Returns $null (not an exception) when no matching credential entry comes back -
        this is the expected, normal shape of "Aria Automation is not deployed in this
        environment", which every Aria Automation check must treat as Skipped rather than Error.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .OUTPUTS
        [PSCustomObject] with Fqdn/Credential properties, or $null if Aria Automation is not
        deployed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ($Context.AriaAutomationCredential) {
        return $Context.AriaAutomationCredential
    }

    Write-LogMessage -Type DEBUG -Message 'Resolving Aria Automation FQDN and credential from SDDC Manager.'
    try {
        $response = Invoke-VcfGetCredentials -ResourceType VRA -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("Failed to query SDDC Manager for Aria Automation credentials: $($_.Exception.Message)")
    }

    $match = @($response.Elements) | Where-Object { $_.CredentialType -eq 'API' } | Select-Object -First 1
    if (-not $match) {
        Write-LogMessage -Type DEBUG -Message 'No Aria Automation credential entry returned by SDDC Manager - Aria Automation is not part of this environment.'
        return $null
    }

    $secure = ConvertTo-SecureStringForCredential -PlainText $match.Password
    $credential = [PSCredential]::new($match.Username, $secure)
    $resolved = [PSCustomObject]@{
        PSTypeName       = 'VcfCheck.AriaAutomationCredential'
        Fqdn             = $match.Resource.ResourceName
        Credential       = $credential
        AllowInsecureTls = [Bool]$Context.AllowInsecureTls
    }
    Remove-Variable -Name match, response -ErrorAction SilentlyContinue

    $Context.AriaAutomationCredential = $resolved
    return $resolved
}
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
        The AriaAutomationCredential object returned by Get-VcfCheckAriaAutomationCredential
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
        $rawMessage = if ($lastError) { $lastError.Exception.Message } else { 'no refresh_token field was returned' }
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
        The AriaAutomationCredential object returned by Get-VcfCheckAriaAutomationCredential
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
        $message = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'Aria Automation' -Fqdn $CredentialInfo.Fqdn -ErrorMessage $_.Exception.Message
        if (-not $message) {
            $message = "Failed to exchange the Aria Automation refresh token for a bearer token on `"$($CredentialInfo.Fqdn)`": $($_.Exception.Message)"
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
        InvalidCertificateAction setting - see Invoke-VcfCheck in Orchestrator.ps1 and
        Get-VcfCheckAriaAutomationCredential) rather than being unconditional; an untrusted
        certificate encountered while that is $false surfaces as a clear, actionable error via
        Get-VcfCheckTlsTrustErrorMessage instead of being silently accepted. Retries up to 3 times with a 10-second delay on transient network failures
        (timeouts, connection resets). On an HTTP 401 (expired bearer token), clears the cached
        token and re-authenticates once before retrying the call - this connector has no SDK
        managing token lifetime for it, unlike Aria Operations.

        .PARAMETER CredentialInfo
        The AriaAutomationCredential object returned by Get-VcfCheckAriaAutomationCredential
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
function Connect-VcfCheckAriaAutomation {
    <#
        .SYNOPSIS
        Validates connectivity and authentication against Aria Automation, using the credential
        SDDC Manager has on file.

        .DESCRIPTION
        Resolves the FQDN/credential via Get-VcfCheckAriaAutomationCredential, runs a TCP
        reachability pre-flight check (Test-VcfCheckTcpConnectivity) against <Fqdn>:443, then
        performs the full login exchange (Get-VcfCheckAriaAutomationBearerToken) to fail fast on
        a bad credential. Unlike Aria Operations there is no separate SDK connection object -
        the returned CredentialInfo object itself carries the cached bearer token and is passed
        directly to Invoke-VcfCheckAriaAutomationApi. The result (success or failure reason) is
        cached on $Context so every later check reuses it instead of reconnecting.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for the TCP reachability pre-flight check. Defaults to 15 seconds.

        .OUTPUTS
        The AriaAutomationCredential object (now carrying a cached bearer token), or $null if
        Aria Automation is not deployed in this environment.

        .EXAMPLE
        Connect-VcfCheckAriaAutomation -Context $Context
    #>
    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 15
    )

    if ($Context.UnreachableAriaAutomation) {
        throw [System.InvalidOperationException]::new($Context.UnreachableAriaAutomation)
    }

    if ($Context.AriaAutomationConnection) {
        return $Context.AriaAutomationConnection
    }

    $resolved = Get-VcfCheckAriaAutomationCredential -Context $Context
    if (-not $resolved) {
        return $null
    }

    if (-not (Test-VcfCheckTcpConnectivity -ComputerName $resolved.Fqdn -Port 443 -TimeoutSeconds $ConnectivityTimeoutSeconds)) {
        $reason = "Could not reach Aria Automation `"$($resolved.Fqdn)`" on port 443 within $ConnectivityTimeoutSeconds second(s). Check VPN/network connectivity to the environment, firewall rules, and that the FQDN resolves to the correct address, then retry."
        $Context.UnreachableAriaAutomation = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    Write-LogMessage -Type INFO -Message "Connecting to Aria Automation `"$($resolved.Fqdn)`"..." -NoNewline
    try {
        [void](Get-VcfCheckAriaAutomationBearerToken -CredentialInfo $resolved)
        # Write-Host: completes the -NoNewline INFO line above on the same console row; Write-LogMessage
        # always appends a newline, which would split the status suffix onto its own line.
        Write-Host " Connected" -ForegroundColor White
    } catch {
        # Write-Host: see comment above - completes the same -NoNewline console row.
        Write-Host " Failed" -ForegroundColor Red
        $reason = "Failed to authenticate to Aria Automation `"$($resolved.Fqdn)`". Verify network connectivity, that the credential SDDC Manager has on file is still valid, and that Aria Automation is reachable."
        $Context.UnreachableAriaAutomation = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    $Context.AriaAutomationConnection = $resolved
    return $resolved
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

        .PARAMETER Environment
        An environment object as returned by Get-VcfCheckEnvironments.

        .OUTPUTS
        [Object[]] of PSCustomObject with Name, Fqdn, Username. Empty array if the environment
        has no AriaAutomation integration.

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
            $results.Add([PSCustomObject]@{
                PSTypeName = 'VcfCheck.AriaAutomationEndpoint'
                Name       = $endpoint.Name
                Fqdn       = $endpoint.Fqdn
                Username   = $username
            })
        }
    }

    return $results.ToArray()
}
function Connect-VcfCheckAriaAutomationEndpoint {
    <#
        .SYNOPSIS
        Validates connectivity and authentication against a user-declared, standalone Aria
        Automation endpoint by FQDN and credential - no SDDC Manager lookup.

        .DESCRIPTION
        Companion to Connect-VcfCheckAriaAutomation for Aria Automation instances SDDC Manager
        has zero knowledge of (see Get-VcfCheckEnvironmentAriaAutomationEndpoints). Runs the same
        TCP reachability pre-flight and login exchange, caching the resulting CredentialInfo on
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

    $credentialInfo = [PSCustomObject]@{ PSTypeName = 'VcfCheck.AriaAutomationCredential'; Fqdn = $Fqdn; Credential = $Credential }
    Write-LogMessage -Type INFO -Message "Connecting to Aria Automation `"$Fqdn`"..." -NoNewline
    try {
        [void](Get-VcfCheckAriaAutomationBearerToken -CredentialInfo $credentialInfo)
        # Write-Host: completes the -NoNewline INFO line above on the same console row; Write-LogMessage
        # always appends a newline, which would split the status suffix onto its own line.
        Write-Host " Connected" -ForegroundColor White
    } catch {
        # Write-Host: see comment above - completes the same -NoNewline console row.
        Write-Host " Failed" -ForegroundColor Red
        $reason = "Failed to authenticate to Aria Automation `"$Fqdn`". Verify network connectivity and the credential entered for this endpoint."
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
        Resolves every Aria Automation instance a check should evaluate - the SDDC-Manager-known
        instance (if deployed) plus every standalone endpoint declared on the current
        environment - and authenticates to each.

        .DESCRIPTION
        Every Test-VcfAriaAutomation* check calls this once instead of
        Connect-VcfCheckAriaAutomation directly, so a single check fans out across every known
        Aria Automation instance rather than only the SDDC-Manager-known one. An authentication
        failure for one target (unreachable, bad credential, not deployed) never blocks
        evaluation of the others - it is surfaced on that target's ConnectError instead of
        throwing, so the caller can emit one Error result per failed target and keep evaluating
        the rest.

        A standalone endpoint whose FQDN matches the SDDC-Manager-known instance's FQDN is
        skipped, since that is the same physical appliance registered twice and would otherwise
        double every check result.

        .PARAMETER Context
        The VcfCheck.Context object. $Context.AriaAutomationEndpoints and
        $Context.AriaAutomationEndpointCredentials must already be populated by Invoke-VcfCheck
        (via Resolve-VcfCheckAriaAutomationEndpointCredentials) for standalone endpoints to be
        included.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for each target's TCP reachability pre-flight check. Defaults to 15
        seconds.

        .OUTPUTS
        [Object[]] of PSCustomObject with Name, Fqdn, CredentialInfo, ConnectError.
        CredentialInfo (Fqdn/Credential, plus a cached bearer token) is the same shape
        Get-VcfCheckAriaAutomationCredential returns - pass it to Invoke-VcfCheckAriaAutomationApi.
        Empty array if Aria Automation is not deployed via SDDC Manager and the environment has
        no standalone endpoints declared - callers must treat that as Skipped.

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

    try {
        $credentialInfo = Connect-VcfCheckAriaAutomation -Context $Context -ConnectivityTimeoutSeconds $ConnectivityTimeoutSeconds
        if ($credentialInfo) {
            $targets.Add([PSCustomObject]@{ Name = 'SDDC Manager'; Fqdn = $credentialInfo.Fqdn; CredentialInfo = $credentialInfo; ConnectError = $null })
        }
    } catch {
        $targets.Add([PSCustomObject]@{ Name = 'SDDC Manager'; Fqdn = $Context.AriaAutomationCredential.Fqdn; CredentialInfo = $null; ConnectError = $_.Exception.Message })
    }

    $knownFqdns = @($targets | Where-Object { $_.Fqdn } | ForEach-Object { $_.Fqdn })
    foreach ($endpoint in @($Context.AriaAutomationEndpoints) | Where-Object { $_ }) {
        if ($endpoint.Fqdn -and ($knownFqdns -icontains $endpoint.Fqdn)) {
            continue
        }
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
