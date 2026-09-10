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
#region VrslcmHelpers
#
# Aria Suite Lifecycle Manager (VRSLCM) has no PowerCLI/OpenAPI SDK coverage. VRSLCM is a
# distinct product with its own /lcm/... REST API, not reachable through VMware.Sdk.Vcf.Ops
# (Aria Operations) or VMware.Sdk.Vr (vSphere Replication). REST helper calls are required.
#
# VRSLCM has no per-domain FQDN lookup - Invoke-VcfGetCredentials -ResourceType VRSLCM is the
# only source for both its FQDN and credential. Credential filtering on CredentialType -eq 'API'
# is done client-side because Invoke-VcfGetCredentials lacks a -CredentialType parameter
# (only -AccountType is available).

function Get-VcfCheckVrslcmConnection {
    <#
        .SYNOPSIS
        Resolves and caches Aria Suite Lifecycle Manager's FQDN and API credential.

        .DESCRIPTION
        Calls Invoke-VcfGetCredentials -ResourceType VRSLCM once per run and caches the result on
        $Context. Returns $null (not an exception) when no matching credential entry comes back -
        this is the expected, normal shape of "VRSLCM is not deployed in this environment", which
        every VRSLCM-area check must treat as Skipped rather than Error.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .OUTPUTS
        [PSCustomObject] with Fqdn/Credential properties, or $null if VRSLCM is not deployed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ($Context.VrslcmConnection) {
        return $Context.VrslcmConnection
    }

    Write-LogMessage -Type DEBUG -Message 'Resolving Aria Suite Lifecycle Manager (VRSLCM) FQDN and credential from SDDC Manager.'
    try {
        $response = Invoke-VcfGetCredentials -ResourceType VRSLCM -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("Failed to query SDDC Manager for VRSLCM credentials: $($_.Exception.Message)")
    }

    $match = @($response.Elements) | Where-Object { $_.CredentialType -eq 'API' } | Select-Object -First 1
    if (-not $match) {
        Write-LogMessage -Type DEBUG -Message 'No VRSLCM credential entry returned by SDDC Manager - Aria Suite Lifecycle Manager is not part of this environment.'
        return $null
    }

    $secure = ConvertTo-SecureStringForCredential -PlainText $match.Password
    $credential = [PSCredential]::new($match.Username, $secure)
    $connection = [PSCustomObject]@{
        PSTypeName       = 'VcfCheck.VrslcmConnection'
        Fqdn             = $match.Resource.ResourceName
        Credential       = $credential
        AllowInsecureTls = [Bool]$Context.AllowInsecureTls
    }
    Remove-Variable -Name match, response -ErrorAction SilentlyContinue

    $Context.VrslcmConnection = $connection
    return $connection
}
function Get-VcfCheckVrslcmRootCredential {
    <#
        .SYNOPSIS
        Resolves the Aria Suite Lifecycle Manager appliance's root/OS credential.

        .DESCRIPTION
        VRSLCM's locker password-decrypt API ('/lcm/locker/api/passwords/view/{vmid}') requires the
        appliance's own root password as its "rootPassword" request body field - not the admin@local
        API credential used by Invoke-VcfCheckVrslcmApi. Filters the same
        Invoke-VcfGetCredentials -ResourceType VRSLCM response on CredentialType -eq 'SSH' instead of
        'API' (see Get-VcfCheckVrslcmConnection). Returns $null (not an exception) when no matching
        entry comes back, matching the "VRSLCM not deployed" Skipped convention used elsewhere in this
        file.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .OUTPUTS
        [PSCredential], or $null if VRSLCM is not deployed or has no SSH credential entry.
    #>
    [CmdletBinding()]
    [OutputType([PSCredential])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ($Context.VrslcmRootCredential) {
        return $Context.VrslcmRootCredential
    }

    Write-LogMessage -Type DEBUG -Message 'Resolving Aria Suite Lifecycle Manager (VRSLCM) root credential from SDDC Manager.'
    try {
        $response = Invoke-VcfGetCredentials -ResourceType VRSLCM -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("Failed to query SDDC Manager for VRSLCM credentials: $($_.Exception.Message)")
    }

    $match = @($response.Elements) | Where-Object { $_.CredentialType -eq 'SSH' } | Select-Object -First 1
    if (-not $match) {
        Write-LogMessage -Type DEBUG -Message 'No VRSLCM root (SSH) credential entry returned by SDDC Manager.'
        return $null
    }

    $secure = ConvertTo-SecureStringForCredential -PlainText $match.Password
    $credential = [PSCredential]::new($match.Username, $secure)
    Remove-Variable -Name match, response -ErrorAction SilentlyContinue

    $Context.VrslcmRootCredential = $credential
    return $credential
}
function Invoke-VcfCheckVrslcmApi {
    <#
        .SYNOPSIS
        Calls Aria Suite Lifecycle Manager's REST API with HTTP Basic Auth.

        .DESCRIPTION
        Thin Invoke-RestMethod wrapper - no PowerCLI/OpenAPI SDK covers VRSLCM (see file header).
        -SkipCertificateCheck is only passed when Connection.AllowInsecureTls is $true (the run's
        resolved AllowInsecureTls value, derived from PowerCLI's InvalidCertificateAction setting -
        see Invoke-VcfCheck in Orchestrator.ps1 and Get-VcfCheckVrslcmConnection) rather than being
        unconditional; an untrusted certificate
        encountered while that is $false is translated into a clear, actionable error by
        ConvertTo-VcfCheckFriendlyVrslcmError instead of being silently accepted.

        Retries up to 3 times with a 10-second delay on transient network failures (timeouts,
        connection resets) to prevent transient vRSLCM API blips from causing terminal failures.

        .PARAMETER Connection
        The object returned by Get-VcfCheckVrslcmConnection.

        .PARAMETER Method
        HTTP method. Defaults to GET.

        .PARAMETER Path
        The VRSLCM API path, e.g. '/lcm/lcops/api/v2/environments'.

        .PARAMETER Body
        Optional request body, sent as JSON. Only used for non-GET methods.

        .OUTPUTS
        The parsed JSON response.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Connection,
        [Parameter(Mandatory = $false)] [ValidateSet('GET', 'POST')] [String]$Method = 'GET',
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path,
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$Body = $null
    )

    $uri = "https://$($Connection.Fqdn)$Path"
    $parameters = @{
        Uri                  = $uri
        Method               = $Method
        Credential           = $Connection.Credential
        Authentication       = 'Basic'
        ContentType          = 'application/json'
        SkipCertificateCheck = $Connection.AllowInsecureTls
        ErrorAction          = 'Stop'
    }
    if ($Body) {
        $bodyJson = $null
        foreach ($depth in @(5, 3, 2)) {
            try {
                $bodyJson = $Body | ConvertTo-Json -Depth $depth -ErrorAction Stop
                break
            }
            catch {
                if ($depth -eq 2) {
                    throw $_
                }
            }
        }
        $parameters['Body'] = $bodyJson
    }

    $maxAttempts = 3
    $retryDelaySeconds = 10
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @parameters
        } catch {
            $isTransient = $_.Exception.Message -match '(?i)timed out|timeout|actively refused|connection refused|reset by peer|handshake'
            if (-not $isTransient -or $attempt -eq $maxAttempts) {
                throw
            }
            Write-LogMessage -Type DEBUG -Message "Transient error calling Aria Suite Lifecycle Manager API '$Path' (attempt $attempt of $maxAttempts): $($_.Exception.Message). Retrying in $retryDelaySeconds seconds."
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }
}
function ConvertTo-VcfCheckFriendlyVrslcmError {
    <#
        .SYNOPSIS
        Translates a raw VRSLCM API connection exception into a user-facing message.

        .DESCRIPTION
        Invoke-VcfCheckVrslcmApi surfaces raw .NET/PowerShell exception text (e.g. "The SSL
        connection could not be established, see inner exception.") verbatim - confusing to a
        user who has no reason to know VRSLCM's checks talk to it over HTTPS internally. Checks
        Get-VcfCheckTlsTrustErrorMessage first, so a certificate-trust failure (only reachable
        when AllowInsecureTls is $false - see Invoke-VcfCheckVrslcmApi) gets its specific,
        actionable message rather than the generic SSL-handshake wording below. Recognizes the
        remaining common network-failure shapes (connection refused, DNS/name resolution, timeout)
        and rewords them; any other exception message is passed through unchanged since it likely
        already describes an API-level (not network) problem more usefully than a generic
        rewording would.

        .PARAMETER Fqdn
        The VRSLCM FQDN the failed request was made to.

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
    $tlsMessage = Get-VcfCheckTlsTrustErrorMessage -ComponentName 'Aria Suite Lifecycle Manager' -Fqdn $Fqdn -ErrorMessage $ErrorMessage
    if ($tlsMessage) {
        return $tlsMessage
    }
    if ($ErrorMessage -match '(?i)SSL connection could not be established|handshake') {
        return "Could not establish an SSL connection to Aria Suite Lifecycle Manager `"$Fqdn`". Verify the appliance is powered on, reachable on port 443, and that VPN/firewall rules allow the connection."
    }
    if ($ErrorMessage -match '(?i)actively refused|connection refused') {
        return "Aria Suite Lifecycle Manager `"$Fqdn`" refused the connection on port 443. Verify the appliance is powered on and its service is running."
    }
    if ($ErrorMessage -match '(?i)No such host is known|could not be resolved|name or service not known') {
        return "Could not resolve Aria Suite Lifecycle Manager's FQDN `"$Fqdn`". Verify DNS resolution."
    }
    if ($ErrorMessage -match '(?i)timed out|timeout') {
        return "Connection to Aria Suite Lifecycle Manager `"$Fqdn`" timed out. Verify network connectivity, VPN, and firewall rules."
    }
    return $ErrorMessage
}

#endregion VrslcmHelpers
