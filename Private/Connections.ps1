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
#region Connections
#
# Connection/credential state lives on the explicit $Context object (New-VcfCheckContext),
# never in $Global:/$Script: scope. This enables multiple independent contexts (e.g., testing
# different SDDC Managers) in the same session. Plaintext passwords are only ever held in a local
# variable for the duration of a single statement; see Private/SecureStringHelpers.ps1.
#
# Resource/account type mapping was confirmed against a live SDDC Manager (VCF 9.x), NOT
# assumed from documentation: the credentials API returns "PSC" (AccountType SYSTEM,
# administrator@vsphere.local) for vCenter's SSO login, and a *separate* "VCENTER" resource
# type (AccountType USER/SERVICE, e.g. root) for the vCenter appliance's own guest OS account.
# A single resource can have multiple accounts of the same AccountType (e.g. NSX Manager's
# SYSTEM account type covers admin/audit/root) - Username must disambiguate.

function Test-VcfCheckTcpConnectivity {

    <#
        .SYNOPSIS
        Checks TCP reachability to a host:port within a short, fixed timeout.

        .DESCRIPTION
        A cross-platform (no Test-NetConnection - Windows-only, unavailable on macOS/Linux
        PowerShell 7) fast-fail reachability check via System.Net.Sockets.TcpClient. Exists so a
        genuine network-path problem (VPN down, firewall block, wrong FQDN) fails in
        -TimeoutSeconds instead of whatever long default timeout the underlying PowerCLI connect
        cmdlet uses (confirmed against a live attempt: over 60 seconds with zero console feedback
        before finally surfacing "Operation timed out").

        .PARAMETER ComputerName
        Hostname or IP address to test.

        .PARAMETER Port
        TCP port to test.

        .PARAMETER TimeoutSeconds
        Maximum time to wait for the connection to complete.

        .OUTPUTS
        [Boolean] $true if a TCP connection was established within the timeout, else $false.
    #>

    [CmdletBinding()]
    [OutputType([Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ComputerName,
        [Parameter(Mandatory = $true)] [Int]$Port,
        [Parameter(Mandatory = $false)] [Int]$TimeoutSeconds = 30
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync($ComputerName, $Port)
        $completedInTime = $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))
        return ($completedInTime -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Close()
        $client.Dispose()
    }
}
function Invoke-VcfCheckWithTimeout {

    <#
        .SYNOPSIS
        Runs a scriptblock on a background thread and enforces a hard wall-clock timeout.

        .DESCRIPTION
        Some PowerCLI/esxcli round trips (e.g. Get-EsxCli -V2 ... .Invoke()) have no cancellable
        timeout of their own: a single unresponsive host's hostd can block the call indefinitely
        and stall an entire check run (confirmed live: "ESX Image Profile" stuck at 0/27 for
        several minutes against a wedged host). This wraps such a call the same way
        Test-VcfCheckTcpConnectivity bounds TcpClient.ConnectAsync - via Task.Wait(timeout) -
        so a caller gets control back within -TimeoutSeconds regardless of whether the underlying
        call ever completes. On timeout, the runspace is left to finish or die on its own; its
        result is discarded.

        .PARAMETER ScriptBlock
        The work to run. It executes in a separate runspace, so it cannot close over caller
        variables directly - pass them via -ArgumentList and a param() block instead (they remain
        the same object references; only session state, not object identity, is isolated per
        runspace).

        .PARAMETER ArgumentList
        Positional arguments passed to -ScriptBlock's param() block.

        .PARAMETER TimeoutSeconds
        Maximum time to wait for the scriptblock to complete.

        .OUTPUTS
        [PSObject] The scriptblock's output. Throws a [System.TimeoutException] if -TimeoutSeconds
        elapses first.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ScriptBlock]$ScriptBlock,
        [Parameter(Mandatory = $false)] [Object[]]$ArgumentList = @(),
        [Parameter(Mandatory = $false)] [Int]$TimeoutSeconds = 30
    )

    $powershell = [PowerShell]::Create()
    try {
        [void]$powershell.AddScript($ScriptBlock)
        foreach ($argument in $ArgumentList) {
            [void]$powershell.AddArgument($argument)
        }
        $asyncResult = $powershell.BeginInvoke()
        if (-not $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw [System.TimeoutException]::new("Operation did not complete within $TimeoutSeconds second(s).")
        }
        try {
            return $powershell.EndInvoke($asyncResult)
        } catch [System.Management.Automation.MethodInvocationException] {
            throw $_.Exception.GetBaseException()
        }
    } finally {
        if ($powershell.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Running) {
            [void]$powershell.BeginStop($null, $null)
        } else {
            $powershell.Dispose()
        }
    }
}
function Connect-VcfCheckSddcManager {

    <#
        .SYNOPSIS
        Connects to SDDC Manager via VCF.PowerCLI and stores the connection on the context.

        .DESCRIPTION
        Wraps Connect-VcfSddcManagerServer. Never logs the password. On success, stores the
        connection object and FQDN on $Context so downstream checks/credential lookups can
        reuse it without re-authenticating.

        Runs a TCP reachability pre-flight check (Test-VcfCheckTcpConnectivity) against
        <Fqdn>:443 first, with a short timeout - a genuine network-path problem then fails fast
        with a specific, actionable message instead of waiting out whatever long default timeout
        Connect-VcfSddcManagerServer itself uses (confirmed over 60 seconds with zero console
        feedback in that case).

        After a successful connection, verifies the SDDC Manager's VCF version is at least 5.2
        (VCF Check's minimum supported version) via Get-VcfCheckVcfVersion. On an unsupported
        version, disconnects immediately and throws rather than letting downstream checks run
        against an environment VCF Check was never validated on.

        .PARAMETER Context
        The VcfCheck.Context object from New-VcfCheckContext.

        .PARAMETER Fqdn
        SDDC Manager FQDN.

        .PARAMETER User
        SDDC Manager username.

        .PARAMETER Password
        SDDC Manager password as a SecureString.

        .PARAMETER IgnoreInvalidCertificate
        Trust a self-signed/untrusted SDDC Manager certificate. Off by default; intended for
        lab environments. Production use should install a trusted certificate instead.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for the TCP reachability pre-flight check. Defaults to 30 seconds.

        .OUTPUTS
        None. Mutates $Context.SddcManagerConnection and $Context.SddcManagerFqdn.

        .EXAMPLE
        Connect-VcfCheckSddcManager -Context $Context -Fqdn $cred.Fqdn -User $cred.User -Password $cred.Password
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$User,
        [Parameter(Mandatory = $true)] [SecureString]$Password,
        [Parameter(Mandatory = $false)] [Switch]$IgnoreInvalidCertificate,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 30
    )

    Write-LogMessage -Type INFO -Message "Checking network reachability to `"$Fqdn`":443 (up to $ConnectivityTimeoutSeconds second(s))..."
    if (-not (Test-VcfCheckTcpConnectivity -ComputerName $Fqdn -Port 443 -TimeoutSeconds $ConnectivityTimeoutSeconds)) {
        throw [System.InvalidOperationException]::new("Could not reach `"$Fqdn`" on port 443 within $ConnectivityTimeoutSeconds second(s). Check VPN/network connectivity to the environment, firewall rules, and that the FQDN resolves to the correct address, then retry.")
    }

    Write-LogMessage -Type INFO -Message "Connecting to SDDC Manager `"$Fqdn`" as `"$User`"..." -NoNewline
    try {
        $connection = Connect-VcfSddcManagerServer -Server $Fqdn -User $User -Password $Password -IgnoreInvalidCertificate:$IgnoreInvalidCertificate.IsPresent -ErrorAction Stop
        Write-Host " Connected" -ForegroundColor White
    } catch {
        Write-Host " Failed" -ForegroundColor Red
        $category = Get-VcfCheckSddcManagerConnectionFailureCategory -ErrorMessage $_.Exception.Message
        $cleanMessage = switch ($category) {
            'NetworkUnreachable' { "Could not reach SDDC Manager `"$Fqdn`" on port 443. Check VPN/network connectivity, firewall rules, and that the FQDN resolves correctly." }
            'AuthenticationFailed' { "Authentication failed for `"$Fqdn`". Verify the username and password are correct." }
            default { "Failed to connect to SDDC Manager `"$Fqdn`". Check your network connectivity and credentials." }
        }
        throw [System.InvalidOperationException]::new($cleanMessage)
    }

    $Context.SddcManagerConnection = $connection
    $Context.SddcManagerFqdn = $Fqdn

    $vcfVersion = Get-VcfCheckVcfVersion -Context $Context
    $minimumSupportedVersion = [Version]'5.2'
    $parsedVersion = [Version](($vcfVersion -split '-')[0])
    if ($parsedVersion -lt $minimumSupportedVersion) {
        try {
            Disconnect-VcfSddcManagerServer -Server $Fqdn -Force -ErrorAction Stop
        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to disconnect from SDDC Manager `"$Fqdn`" after rejecting an unsupported VCF version: $($_.Exception.Message)"
        }
        $Context.SddcManagerConnection = $null
        $Context.SddcManagerFqdn = $null
        throw [System.InvalidOperationException]::new("SDDC Manager `"$Fqdn`" is running VCF $vcfVersion, which is earlier than the minimum version VCF Check supports ($minimumSupportedVersion). Upgrade to VCF 5.2 or later, or point VCF Check at a supported environment.")
    }
}
function Get-VcfCheckSddcManagerConnectionFailureCategory {

    <#
        .SYNOPSIS
        Classifies a Connect-VcfCheckSddcManager failure message so the caller can show an
        accurate, specific remediation instead of one generic message for every failure.

        .DESCRIPTION
        Confirmed live: a real authentication failure (VCF API's own
        IDENTITY_UNAUTHORIZED_ENTITY/"User is not authorized" response) was being shown to the
        user with remediation text that led with "Verify network/VPN connectivity and DNS
        resolution" - actively misleading for a failure that has nothing to do with the network
        (the TCP reachability pre-flight in Connect-VcfCheckSddcManager had already succeeded
        by the time this kind of error is even possible). This classifies the exception message
        into NetworkUnreachable (matches the pre-flight's own message signature exactly, since
        that one IS a real network/DNS/firewall problem), AuthenticationFailed (a recognized
        credential/authorization rejection signature), or Unknown (anything else - e.g. a TLS
        trust problem or an unexpected API error) so the remediation text can match the actual
        cause instead of guessing at network issues by default.

        .PARAMETER ErrorMessage
        The exception message from a failed Connect-VcfCheckSddcManager call.

        .OUTPUTS
        [String] one of 'NetworkUnreachable', 'AuthenticationFailed', 'Unknown'.

        .EXAMPLE
        Get-VcfCheckSddcManagerConnectionFailureCategory -ErrorMessage $_.Exception.Message
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage
    )

    if ($ErrorMessage -match 'Could not reach ".*" on port \d+ within \d+ second') {
        return 'NetworkUnreachable'
    }
    if ($ErrorMessage -match '(?i)UNAUTHORIZED|not authorized|invalid credentials|incorrect user ?name or password|authentication failed|401\b') {
        return 'AuthenticationFailed'
    }
    return 'Unknown'
}
function Get-VcfCheckTlsTrustErrorMessage {

    <#
        .SYNOPSIS
        Recognizes a TLS certificate-trust failure and returns an actionable, user-facing message
        for it, or $null if the given error is not TLS-related.

        .DESCRIPTION
        Every hand-written REST helper in this module (Aria Automation, Aria Operations, Aria
        Suite Lifecycle Manager, NSX Manager) now passes -SkipCertificateCheck only when the
        run's resolved AllowInsecureTls value (see New-VcfCheckContext) is $true, instead of
        unconditionally bypassing certificate validation. When it is $false and the target
        presents an untrusted/self-signed certificate, .NET's raw exception text ("The SSL
        connection could not be established... RemoteCertificateChainErrors") is confusing and
        gives no indication of how to resolve it. Callers pass that raw message here; a non-$null
        result replaces it before the exception is thrown or logged.

        .PARAMETER ComponentName
        Human-readable name of the component being connected to, e.g. 'Aria Automation'.

        .PARAMETER Fqdn
        The FQDN the failed request was made to.

        .PARAMETER ErrorMessage
        The raw exception message to inspect.

        .OUTPUTS
        [String] an actionable message, or $null if ErrorMessage does not look TLS-related.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ComponentName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage
    )

    if ($ErrorMessage -notmatch '(?i)certificate|SSL/TLS|remote certificate|trust relationship|RemoteCertificateChainErrors|RemoteCertificateNameMismatch|PKIX|SslPolicyErrors') {
        return $null
    }

    return "$ComponentName `"$Fqdn`" presented a certificate that is not trusted: $ErrorMessage. Run `"Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore`" if this is a self-signed lab certificate (check the current setting with `"Get-PowerCLIConfiguration`"), or install a certificate trusted by this machine."
}
function Get-VcfCheckComponentCredential {

    <#
        .SYNOPSIS
        Retrieves and caches a component credential via the SDDC Manager credential API.

        .DESCRIPTION
        Wraps Invoke-VcfGetCredentials, filtering server-side by ResourceName/ResourceType/
        AccountType. Caches the resulting PSCredential on $Context so repeated checks against
        the same target/account don't re-hit the credentials API. The plaintext password from
        the API response is wrapped via ConvertTo-SecureStringForCredential and the source
        response object is immediately discarded with Remove-Variable so it never lingers on
        the call stack.

        A single resource can return more than one account under the same AccountType (e.g. NSX
        Manager's SYSTEM accounts include admin/audit/root) - pass -Username to disambiguate;
        without it, the first match is used, which is only safe when exactly one account of
        that AccountType is expected.

        Does NOT support PSC - a vCenter's PSC/SYSTEM (SSO) credential is registered in SDDC
        Manager against its owning SSO domain's name, not the vCenter's own FQDN, so filtering
        this function's -ResourceName by Fqdn silently returns no match for a workload domain
        vCenter. Use Get-VcfCheckVCenterSsoCredential instead, which resolves the credential
        by domain.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER ResourceType
        VCENTER (vCenter appliance guest OS), NSXT_MANAGER, or ESX.

        .PARAMETER AccountType
        SYSTEM, USER, or SERVICE - confirmed against a live lab to materially change which
        account comes back even for the same ResourceType/Fqdn.

        .PARAMETER Fqdn
        FQDN of the target component.

        .PARAMETER Username
        Optional disambiguator when a resource has multiple accounts of the same AccountType.

        .OUTPUTS
        [PSCredential]

        .EXAMPLE
        $rootCred = Get-VcfCheckComponentCredential -Context $Context -ResourceType VCENTER -AccountType USER -Fqdn 'm01-vc01.example.com' -Username root
    #>

    [CmdletBinding()]
    [OutputType([PSCredential])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateSet('VCENTER', 'NSXT_MANAGER', 'ESX')] [String]$ResourceType,
        [Parameter(Mandatory = $true)] [ValidateSet('SYSTEM', 'USER', 'SERVICE')] [String]$AccountType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Username = ''
    )

    $cacheKey = "$ResourceType|$AccountType|$Fqdn|$Username"
    if ($Context.ComponentCredentialCache.ContainsKey($cacheKey)) {
        return $Context.ComponentCredentialCache[$cacheKey]
    }

    Write-LogMessage -Type DEBUG -Message "Retrieving $ResourceType/$AccountType credential for `"$Fqdn`" from SDDC Manager."
    try {
        $response = Invoke-VcfGetCredentials -ResourceName $Fqdn -ResourceType $ResourceType -AccountType $AccountType -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("Failed to retrieve credentials for `"$Fqdn`" from SDDC Manager. Verify the SDDC Manager connection and that the component is properly registered.")
    }

    $candidates = @($response.Elements)
    if (-not [String]::IsNullOrWhiteSpace($Username)) {
        $candidates = @($candidates | Where-Object { $_.Username -eq $Username })
    }
    $match = $candidates | Select-Object -First 1

    if (-not $match) {
        $usernameNote = if ($Username) { " username `"$Username`"" } else { '' }
        throw [System.InvalidOperationException]::new("SDDC Manager returned no $ResourceType/$AccountType credential for `"$Fqdn`"$usernameNote.")
    }

    $secure = ConvertTo-SecureStringForCredential -PlainText $match.Password
    $credential = [PSCredential]::new($match.Username, $secure)
    Remove-Variable -Name match, candidates, response -ErrorAction SilentlyContinue

    $Context.ComponentCredentialCache[$cacheKey] = $credential
    return $credential
}
function Get-VcfCheckSddcManagerRootCredential {

    <#
        .SYNOPSIS
        Resolves the SDDC Manager appliance's own root/OS credential via an interactive prompt.

        .DESCRIPTION
        Confirmed against a live lab: SDDC Manager's own appliance root account is NOT
        retrievable via Invoke-VcfGetCredentials (it manages credentials for the components it
        deploys, not its own OS account) - so this is deliberately NOT an API call. Prompts once
        via Read-Host -AsSecureString and caches the result on $Context for the life of the run;
        the password is never read from or written to settings.json.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager (so
        $Context.SddcManagerFqdn is available for the prompt text).

        .PARAMETER Username
        Guest OS username to pair with the prompted password. Defaults to 'root'.

        .OUTPUTS
        [PSCredential]

        .EXAMPLE
        $rootCred = Get-VcfCheckSddcManagerRootCredential -Context $Context
    #>

    [CmdletBinding()]
    [OutputType([PSCredential])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Username = 'root'
    )

    if ($Context.SddcManagerRootCredential) {
        return $Context.SddcManagerRootCredential
    }

    $securePassword = Read-Host -Prompt "Enter the $Username password for the SDDC Manager appliance ($($Context.SddcManagerFqdn)) - not available via the VCF credentials API" -AsSecureString
    if ($securePassword.Length -eq 0) {
        throw [System.InvalidOperationException]::new('SDDC Manager appliance root password must not be empty.')
    }

    $credential = [PSCredential]::new($Username, $securePassword)
    $Context.SddcManagerRootCredential = $credential
    return $credential
}
function Get-VcfCheckDomains {

    <#
        .SYNOPSIS
        Calls Invoke-VcfGetDomains and returns its Elements, with actionable error handling.

        .DESCRIPTION
        Every domain lookup in this file (management vCenter FQDN, all vCenter FQDNs, the
        management domain object, the management domain ID, the management NSX Manager FQDN)
        wrapped its own try/catch around Invoke-VcfGetDomains with an identical generic failure
        message. That message was misleading for a specific failure mode confirmed live: a
        VCF.PowerCLI/VMware.Sdk.Vcf.SddcManager module version mismatch (e.g. a stray newer
        VMware.Sdk.Vcf.SddcManager copy under WindowsPowerShell\Modules shadowing the version
        paired with the installed VCF.PowerCLI) throws a .NET MissingMethodException -
        "Method not found: ...DomainsApi.GetDomains(...)" - which is a broken module
        installation, not a dropped SDDC Manager connection. That distinction was only visible
        in the DEBUG log, never in the message shown to the user. This centralizes the call so
        the distinction is made once and surfaced to every caller.

        .PARAMETER Type
        Optional -Type filter to pass through to Invoke-VcfGetDomains (e.g. 'MANAGEMENT').
        Omit to return every domain.

        .OUTPUTS
        [PSObject[]] the domains API response's Elements.

        .EXAMPLE
        $domains = Get-VcfCheckDomains -Type 'MANAGEMENT'
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $false)] [String]$Type
    )

    try {
        if ($Type) {
            return @((Invoke-VcfGetDomains -Type $Type -ErrorAction Stop).Elements)
        }
        return @((Invoke-VcfGetDomains -ErrorAction Stop).Elements)
    } catch {
        Write-LogMessage -Type DEBUG -Message "Invoke-VcfGetDomains failed: $($_.Exception.Message)"
        if ($_.Exception.Message -match '(?i)Method not found|Could not load (type|file or assembly)|TypeLoadException|FileLoadException|BadImageFormatException') {
            throw [System.InvalidOperationException]::new("Failed to call the SDDC Manager domains API due to a VCF.PowerCLI module version mismatch, not a connection problem. Run 'Get-Module -ListAvailable VCF.PowerCLI, VMware.Sdk.Vcf.SddcManager -All' and confirm only one matched, paired version set resolves (check both the PowerShell and WindowsPowerShell module directories) - a stray duplicate module version is the most common cause.")
        }
        throw [System.InvalidOperationException]::new('Failed to retrieve domains from SDDC Manager. Verify the SDDC Manager connection is still active.')
    }
}
function Get-VcfCheckManagementVCenterFqdn {

    <#
        .SYNOPSIS
        Resolves and caches the management domain's vCenter FQDN.

        .DESCRIPTION
        Wraps Invoke-VcfGetDomains -Type 'MANAGEMENT'. Needed because appliance-command checks
        that target the SDDC Manager VM itself (e.g. sddc_lock_table) must call Invoke-VMScript
        against the vCenter that manages that VM, and the SDDC Manager appliance always lives in
        the management domain - confirmed against a live lab (VCenters.Fqdn on the management
        domain element).

        Filters on -Type 'MANAGEMENT', not -IsManagementSsoDomain $true: despite its name, the API's
        isManagementSsoDomain flag means "is this domain joined to the Management domain's SSO," not
        "is this the management domain." Confirmed live: in a topology where a VI workload domain
        joins the same SSO domain as the management domain (a common configuration), the SSO filter
        returned both domains, and Select-Object -First 1 picked whichever the API happened to list
        first - a workload domain's vCenter in the confirmed case, not the actual management domain.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .OUTPUTS
        [String] the management domain's vCenter FQDN.

        .EXAMPLE
        $mgmtVcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ($Context.ManagementVCenterFqdn) {
        return $Context.ManagementVCenterFqdn
    }

    $domains = Get-VcfCheckDomains -Type 'MANAGEMENT'
    $managementDomain = $domains | Select-Object -First 1
    if (-not $managementDomain) {
        throw [System.InvalidOperationException]::new('SDDC Manager did not return a management domain.')
    }

    $fqdn = $managementDomain.VCenters.Fqdn | Select-Object -First 1
    if ([String]::IsNullOrWhiteSpace($fqdn)) {
        throw [System.InvalidOperationException]::new('The management domain has no vCenter FQDN.')
    }

    $Context.ManagementVCenterFqdn = $fqdn
    return $fqdn
}
function Get-VcfCheckAllVCenterFqdns {

    <#
        .SYNOPSIS
        Resolves and caches every vCenter FQDN attached to SDDC Manager.

        .DESCRIPTION
        Wraps Invoke-VcfGetDomains with no filter, returning every domain SDDC Manager manages
        (the management domain and every workload domain) and reading each domain's own VCenters
        collection - the same domain-owns-its-vcenters field Get-VcfCheckManagementVCenterFqdn
        already trusts for the management domain - rather than Invoke-VcfGetVcenters's per-vCenter
        Domain sub-object, which does not reliably carry the owning domain's Name/Type for a
        workload domain vCenter (confirmed live: a workload domain's vCenter came back with a
        blank Domain, while every domain's own VCenters.Fqdn field is always populated). Checks
        that inspect vCenter/ESXi/vSAN inventory (clusters, hosts, datastores, the vCenter
        appliance itself) must iterate this list to cover every workload domain, not just the
        management vCenter.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        Deliberately does NOT filter by $Context.SelectedDomains (Invoke-VcfCheck's -Domain
        parameter) - every one of the ~40 checks that iterate this list assumes a non-empty
        result whenever this function doesn't throw, and several pass the per-vCenter outcome
        array straight into New-VcfCheckPerDomainResults's [ValidateNotNullOrEmpty()]
        PerVCenterOutcome parameter with no guard for zero elements. Domain scoping is applied
        afterwards, uniformly, to every check's finished Result objects in Invoke-VcfCheck's
        dispatch loop instead - see Private/Orchestrator.ps1.

        .OUTPUTS
        [String[]] every distinct vCenter FQDN known to SDDC Manager.

        .EXAMPLE
        $vcenterFqdns = Get-VcfCheckAllVCenterFqdns -Context $Context
    #>

    [CmdletBinding()]
    [OutputType([String[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ($Context.AllVCenterFqdns) {
        return $Context.AllVCenterFqdns
    }

    $domains = Get-VcfCheckDomains
    if ($domains.Count -eq 0) {
        throw [System.InvalidOperationException]::new('SDDC Manager returned no domains.')
    }

    $fqdns = [System.Collections.Generic.List[String]]::new()
    foreach ($domain in $domains) {
        if (-not [String]::IsNullOrWhiteSpace($domain.Name)) {
            $Context.DomainsByName[$domain.Name] = $domain
        }
        foreach ($vcenterRef in @($domain.VCenters)) {
            if ([String]::IsNullOrWhiteSpace($vcenterRef.Fqdn)) {
                continue
            }
            $fqdns.Add($vcenterRef.Fqdn)
            $Context.VCenterDomainsByFqdn[$vcenterRef.Fqdn] = $domain.Name
            $Context.VCenterDomainTypesByFqdn[$vcenterRef.Fqdn] = $domain.Type
        }
    }

    $fqdns = @($fqdns | Select-Object -Unique)
    if ($fqdns.Count -eq 0) {
        throw [System.InvalidOperationException]::new('SDDC Manager returned no vCenters.')
    }

    $Context.AllVCenterFqdns = $fqdns
    return $fqdns
}
function Get-VcfCheckVCenterDomainName {

    <#
        .SYNOPSIS
        Resolves a vCenter FQDN to its workload domain name.

        .DESCRIPTION
        Given a vCenter FQDN, returns the name of the workload domain it belongs to by looking it
        up in the cache populated by Get-VcfCheckAllVCenterFqdns. If the cache is not populated
        yet, calls Get-VcfCheckAllVCenterFqdns to populate it rather than re-implementing the
        same domain scan here - a single source of truth for the FQDN-to-domain mapping. Returns
        an empty string if the FQDN is not found in any domain.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER Fqdn
        The vCenter FQDN to look up.

        .OUTPUTS
        [String] the workload domain name, or empty string if not found.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn
    )

    if ($Context.VCenterDomainsByFqdn[$Fqdn]) {
        return $Context.VCenterDomainsByFqdn[$Fqdn]
    }

    $null = Get-VcfCheckAllVCenterFqdns -Context $Context

    if ($Context.VCenterDomainsByFqdn[$Fqdn]) {
        return $Context.VCenterDomainsByFqdn[$Fqdn]
    }

    Write-LogMessage -Type DEBUG -Message "No domain found for vCenter FQDN: $Fqdn"
    return ''
}
function Get-VcfCheckVCenterDomainType {

    <#
        .SYNOPSIS
        Resolves a vCenter FQDN to its VCF domain type (MANAGEMENT or VI).

        .DESCRIPTION
        Given a vCenter FQDN, returns the type of the VCF domain it belongs to by looking it up
        in the cache populated by Get-VcfCheckAllVCenterFqdns. If the cache is not populated
        yet, calls Get-VcfCheckAllVCenterFqdns to populate it rather than re-implementing the
        same domain scan here - a single source of truth for the FQDN-to-domain mapping. Kept as a
        sibling to Get-VcfCheckVCenterDomainName (rather than changing that function's
        [String] return contract) so existing callers of the domain-name cache are unaffected.
        Returns an empty string if the FQDN is not found.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER Fqdn
        The vCenter FQDN to look up.

        .OUTPUTS
        [String] the VCF domain type ("MANAGEMENT" or "VI"), or empty string if not found.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn
    )

    if ($Context.VCenterDomainTypesByFqdn[$Fqdn]) {
        return $Context.VCenterDomainTypesByFqdn[$Fqdn]
    }

    $null = Get-VcfCheckAllVCenterFqdns -Context $Context

    if ($Context.VCenterDomainTypesByFqdn[$Fqdn]) {
        return $Context.VCenterDomainTypesByFqdn[$Fqdn]
    }

    return ''
}
function New-VcfCheckPerDomainResults {

    <#
        .SYNOPSIS
        Turns one outcome per vCenter into one VcfCheck.Result per workload domain.

        .DESCRIPTION
        Shared by every check that iterates Get-VcfCheckAllVCenterFqdns instead of a single
        management-vCenter FQDN, so a check that must run against every vCenter attached to SDDC
        Manager reports its own pass/fail per domain - extracted here rather than duplicated per
        check, mirroring how New-VcfCheckApplianceCommandFailureResult centralizes a different
        shared per-check outcome shape (Private/ApplianceCommand.ps1).

        Each vCenter's domain name is resolved via Get-VcfCheckVCenterDomainName and stamped
        onto its own result - deliberately not merged into a single rolled-up row (an earlier
        design did that, prefixing Detail lines with the vCenter FQDN instead), so a report reader
        sees each domain's own status rather than a single worst-of-all-domains verdict that hides
        which domain actually failed.

        If domain resolution throws or comes back blank for a given vCenter, that vCenter's own
        FQDN is stamped on as Domain instead of leaving it blank. Orchestrator.ps1's dispatch loop
        backfills any still-blank Domain to the Management domain, on the assumption that only a
        genuinely single-target check (SDDC Manager, Aria Suite) ever leaves Domain unset - a blank
        Domain here would otherwise get silently mislabeled as belonging to the Management domain
        instead of whichever vCenter this outcome actually came from.

        .PARAMETER Context
        The VcfCheck.Context object, used to resolve each vCenter's domain name.

        .PARAMETER PerVCenterOutcome
        One object per vCenter checked, each with VCenterFqdn, Status (Pass/Warning/Fail/Error/
        Skipped), Detail, and Blocking (bool) properties. May also carry a Rows property (an
        array of structured per-object rows) and/or a HostDetails property (an array of per-host
        structured data), both passed straight through to the resulting Result when present. A
        HostDetailsLabel property, when present, is likewise passed straight through (falls back
        to New-VcfCheckResult's own "Hosts" default otherwise). A SkipReasonTag property, when
        present on a Skipped outcome, is passed straight through to New-VcfCheckResult so the
        report can show a short reason next to the badge instead of the full Detail sentence. A
        StartedAt/CompletedAt pair, stamped by the calling check around that vCenter's own work,
        is used for that domain's DurationMs when present - each vCenter can otherwise take a
        very different amount of time to check, so falling back to -StartedAt/"now" for every
        outcome would report the same total run duration against every domain instead of its own.

        .PARAMETER CheckId
        .PARAMETER Area
        .PARAMETER DisplayName
        .PARAMETER ValidationCriteria
        .PARAMETER Remediation
        Passed straight through to New-VcfCheckResult when supplied; omitted parameters let
        New-VcfCheckResult resolve them from Data/CheckCatalog.json by -CheckId instead - the
        expected path for every real check, so its own catalog entry stays the single source of
        truth instead of a second copy living in the check's own file.

        .PARAMETER StartedAt
        UTC timestamp when the check began.

        .OUTPUTS
        [PSObject[]] one VcfCheck.Result per domain checked.

        .EXAMPLE
        New-VcfCheckPerDomainResults -Context $Context -PerVCenterOutcome $outcomes -CheckId 'vcenter_check_hosts' -StartedAt $startedAt
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$PerVCenterOutcome,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CheckId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Area = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$ValidationCriteria = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Remediation = '',
        [Parameter(Mandatory = $true)] [DateTime]$StartedAt
    )

    $results = [System.Collections.Generic.List[Object]]::new()

    foreach ($outcome in $PerVCenterOutcome) {
        $outcomeStartedAt = if ($outcome.StartedAt) { $outcome.StartedAt } else { $StartedAt }
        $outcomeCompletedAt = if ($outcome.CompletedAt) { $outcome.CompletedAt } else { Get-Date }
        try {
            $domain = Get-VcfCheckVCenterDomainName -Context $Context -Fqdn $outcome.VCenterFqdn
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not resolve the workload domain name for vCenter `"$($outcome.VCenterFqdn)`": $($_.Exception.Message)"
            $domain = ''
        }
        try {
            $domainType = Get-VcfCheckVCenterDomainType -Context $Context -Fqdn $outcome.VCenterFqdn
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not resolve the workload domain type for vCenter `"$($outcome.VCenterFqdn)`": $($_.Exception.Message)"
            $domainType = ''
        }
        if ([String]::IsNullOrWhiteSpace($domain)) {
            $domain = $outcome.VCenterFqdn
        }
        $resultParams = @{
            CheckId         = $CheckId
            Status          = $outcome.Status
            Domain          = $domain
            DomainType      = $domainType
            TargetComponent = $outcome.VCenterFqdn
            Detail          = $outcome.Detail
            Rows            = $outcome.Rows
            HostDetails     = $outcome.HostDetails
            StartedAt       = $outcomeStartedAt
            CompletedAt     = $outcomeCompletedAt
        }
        if ($outcome.HostDetailsLabel) { $resultParams['HostDetailsLabel'] = $outcome.HostDetailsLabel }
        if ($outcome.Status -eq 'Skipped' -and $outcome.SkipReasonTag) { $resultParams['SkipReasonTag'] = $outcome.SkipReasonTag }
        if ($outcome.Blocking) { $resultParams['Blocking'] = $true }
        if ($outcome.Exception) { $resultParams['Exception'] = $outcome.Exception }
        if ($PSBoundParameters.ContainsKey('Area')) { $resultParams['Area'] = $Area }
        if ($PSBoundParameters.ContainsKey('DisplayName')) { $resultParams['DisplayName'] = $DisplayName }
        if ($PSBoundParameters.ContainsKey('ValidationCriteria')) { $resultParams['ValidationCriteria'] = $ValidationCriteria }
        if ($outcome.Status -in @('Fail', 'Warning', 'Error') -and $PSBoundParameters.ContainsKey('Remediation')) {
            $resultParams['Remediation'] = $Remediation
        }
        $results.Add((New-VcfCheckResult @resultParams))
    }

    return $results.ToArray()
}
function Invoke-VcfCheckPerVCenterCheck {

    <#
        .SYNOPSIS
        Runs a scriptblock against every vCenter attached to SDDC Manager and turns the outcomes
        into one VcfCheck.Result per workload domain.

        .DESCRIPTION
        Centralizes the "resolve catalog/displayName/blocking -> enumerate every vCenter FQDN
        (Error result on enumeration failure) -> foreach FQDN { connect, invoke -Body, stamp
        StartedAt/CompletedAt, catch to an Error outcome } -> New-VcfCheckPerDomainResults"
        skeleton that was duplicated near-verbatim across every vCenter/vSAN check under
        Private/Checks/VCenter and Private/Checks/Vsan - the PowerCLI/API-based counterpart to
        Invoke-VcfCheckVCenterApplianceCliCheck, which already centralizes the equivalent
        shape for appliance-CLI (guest-command) checks.

        -Body is invoked once per vCenter FQDN, after Connect-VcfCheckVCenter has already
        connected to it, as `& $Body $Context $vcenterFqdn`. It must return a PSCustomObject
        with Status and Detail (Rows, HostDetails, and SkipReasonTag are optional and passed
        through untouched - SkipReasonTag only matters when Status is Skipped). VCenterFqdn and
        Blocking are stamped onto the returned outcome by this function so -Body does not need to
        reference either.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER CheckId
        The check's catalog ID (Data/CheckCatalog.json), used to resolve DisplayName/
        ValidationCriteria/Remediation/Blocking and passed through to the result objects.

        .PARAMETER Area
        Passed straight through to New-VcfCheckResult (e.g. 'vCenter', 'vSAN').

        .PARAMETER DisplayName
        Overrides the catalog's own displayName when supplied.

        .PARAMETER Body
        ScriptBlock invoked per vCenter as `param($Context, $VCenterFqdn) ...`, returning an
        outcome PSCustomObject with at least Status and Detail.

        .OUTPUTS
        [PSObject[]] one VcfCheck.Result per domain checked.

        .EXAMPLE
        Invoke-VcfCheckPerVCenterCheck -Context $Context -CheckId 'vcenter_check_hosts' -Area vCenter -DisplayName $DisplayName -Body {
            param($Context, $VCenterFqdn)
            $hosts = @(Get-VcfCheckVMHostInventory -Server $VCenterFqdn)
            [PSCustomObject]@{ Status = 'Pass'; Detail = "Checked $($hosts.Count) host(s)." }
        }
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CheckId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Area,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$DisplayName = '',
        [Parameter(Mandatory = $true)] [ScriptBlock]$Body
    )

    $startedAt = Get-Date
    $catalogEntry = (Get-VcfCheckCatalog)[$CheckId]
    $resolvedDisplayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }
    $blocking = Get-VcfCheckBlockingStatusFromCatalog -CheckId $CheckId
    $validationCriteria = $catalogEntry.validationCriteria
    $remediation = $catalogEntry.remediation

    try {
        $vcenterFqdns = Get-VcfCheckAllVCenterFqdns -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $CheckId -Area $Area -Status Error `
            -Exception $_.Exception.Message -ValidationCriteria $validationCriteria -Remediation $remediation -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resolvedDisplayName
    }

    $outcomes = foreach ($vcenterFqdn in $vcenterFqdns) {
        $iterationStartedAt = Get-Date
        $outcome = try {
            Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
            $bodyResult = & $Body $Context $vcenterFqdn
            $bodyResult | Add-Member -NotePropertyName VCenterFqdn -NotePropertyValue $vcenterFqdn -Force
            $bodyResult | Add-Member -NotePropertyName Blocking -NotePropertyValue $blocking -Force
            $bodyResult
        } catch {
            [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = $_.Exception.Message; Blocking = $blocking; Rows = @() }
        }
        $outcome | Add-Member -NotePropertyName StartedAt -NotePropertyValue $iterationStartedAt -Force
        $outcome | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date) -Force
        $outcome
    }

    return New-VcfCheckPerDomainResults -Context $Context -PerVCenterOutcome $outcomes -CheckId $CheckId -Area $Area `
        -ValidationCriteria $validationCriteria -Remediation $remediation -StartedAt $startedAt -DisplayName $resolvedDisplayName
}
function Get-VcfCheckManagementDomain {

    <#
        .SYNOPSIS
        Resolves and caches the management domain object.

        .DESCRIPTION
        Queries Invoke-VcfGetDomains with -Type 'MANAGEMENT' and returns the full domain object
        (with Id, Name, and other properties). Used to get domain-wide information. Filters on
        domain Type, not -IsManagementSsoDomain - see Get-VcfCheckManagementVCenterFqdn for why
        that flag does not identify the management domain.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .OUTPUTS
        [PSObject] the management domain object.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ($Context.ManagementDomainObject) {
        return $Context.ManagementDomainObject
    }

    $domains = Get-VcfCheckDomains -Type 'MANAGEMENT'
    $managementDomain = $domains | Select-Object -First 1
    if (-not $managementDomain) {
        throw [System.InvalidOperationException]::new('SDDC Manager did not return a management domain.')
    }

    $Context.ManagementDomainObject = $managementDomain
    return $managementDomain
}
function Get-VcfCheckManagementDomainId {

    <#
        .SYNOPSIS
        Resolves and caches the management domain's SDDC Manager domain ID.

        .DESCRIPTION
        Wraps Invoke-VcfGetDomains -Type 'MANAGEMENT', mirroring
        Get-VcfCheckManagementVCenterFqdn's resolution/caching pattern but returning the
        domain ID itself - needed by domain-scoped inventory calls (e.g. Invoke-VcfGetVcenters
        -DomainId, Invoke-VcfGetNsxUpgradeResources -DomainId).

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .OUTPUTS
        [String] the management domain's ID.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ($Context.ManagementDomainId) {
        return $Context.ManagementDomainId
    }

    $domains = Get-VcfCheckDomains -Type 'MANAGEMENT'
    $managementDomain = $domains | Select-Object -First 1
    if (-not $managementDomain -or [String]::IsNullOrWhiteSpace($managementDomain.Id)) {
        throw [System.InvalidOperationException]::new('SDDC Manager did not return a management domain ID.')
    }

    $Context.ManagementDomainId = $managementDomain.Id
    return $managementDomain.Id
}
function Get-VcfCheckVcfVersion {

    <#
        .SYNOPSIS
        Returns the SDDC Manager version string.

        .DESCRIPTION
        Queries the SDDC Manager API to retrieve its version (e.g. "5.2.1.0-24305054")
        and caches the result to avoid repeated API calls. Returns the Version property
        of the management domain's SDDC Manager.

        .PARAMETER Context
        The VcfCheck.Context object.

        .OUTPUTS
        [String] The SDDC Manager version string.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ($Context.VcfVersion) {
        return $Context.VcfVersion
    }

    try {
        $managementDomain = Get-VcfCheckManagementDomain -Context $Context
        $response = Invoke-VcfGetSddcManagers
        $sddcManager = $response.Elements | Where-Object { $_.Domain.Id -eq $managementDomain.Id } | Select-Object -First 1
        $version = $sddcManager.Version

        if ([String]::IsNullOrWhiteSpace($version)) {
            throw [System.InvalidOperationException]::new("SDDC Manager did not return a version string.")
        }

        $Context.VcfVersion = $version
        return $version
    } catch {
        throw [System.InvalidOperationException]::new("Failed to retrieve the SDDC Manager version: $($_.Exception.Message)", $_.Exception)
    }
}
function Get-VcfCheckVCenterSsoDomainName {

    <#
        .SYNOPSIS
        Resolves the name of the SSO domain that owns a vCenter's PSC/SYSTEM credential.

        .DESCRIPTION
        SDDC Manager registers a vCenter's PSC/SYSTEM credential against the SSO domain that owns
        it, not against the vCenter's own FQDN - looking a credential up via -ResourceName
        <vCenter FQDN> silently returns no match for a workload domain vCenter (confirmed live:
        SDDC Manager returned no PSC/SYSTEM credential for a workload domain vCenter with a
        working SSO login).

        A workload domain either owns an isolated SSO domain (its own PSC/SYSTEM credential,
        registered under its own domain name) or joined the Management domain's shared SSO domain
        (IsManagementSsoDomain = $true on the domain object) - in the latter case the Management
        domain's own PSC/SYSTEM credential must be used instead, since no separate credential is
        ever registered under the workload domain's name. Shared by
        Get-VcfCheckVCenterSsoCredential (needs a PSCredential) and
        Test-VcfVcenterPasswordPolicyExpiry (needs the raw credential ID).

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER Fqdn
        vCenter FQDN whose owning SSO domain name should be resolved.

        .OUTPUTS
        [String] the name of the domain whose PSC/SYSTEM credential owns this vCenter's SSO login.

        .EXAMPLE
        $ssoDomainName = Get-VcfCheckVCenterSsoDomainName -Context $Context -Fqdn 'w01-vc01.example.com'
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn
    )

    $domainName = Get-VcfCheckVCenterDomainName -Context $Context -Fqdn $Fqdn
    if ([String]::IsNullOrWhiteSpace($domainName)) {
        throw [System.InvalidOperationException]::new("Could not resolve the workload domain that owns vCenter `"$Fqdn`" - cannot determine which domain's PSC/SYSTEM credential to use.")
    }

    $domain = $Context.DomainsByName[$domainName]
    if ($domain -and $domain.IsManagementSsoDomain) {
        return (Get-VcfCheckManagementDomain -Context $Context).Name
    }
    return $domainName
}
function Get-VcfCheckVCenterSsoCredential {

    <#
        .SYNOPSIS
        Resolves and caches a vCenter's PSC/SYSTEM (SSO) credential via its owning domain.

        .DESCRIPTION
        Resolves the vCenter's owning SSO domain via Get-VcfCheckVCenterSsoDomainName, then
        queries Invoke-VcfGetCredentials by that domain's name (-DomainName) instead of the
        vCenter's FQDN - see that function's comment for why FQDN-based lookup (as
        Get-VcfCheckComponentCredential does for every other resource type) does not work for
        PSC/SYSTEM credentials.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER Fqdn
        vCenter FQDN whose owning domain's PSC/SYSTEM credential should be resolved.

        .OUTPUTS
        [PSCredential]

        .EXAMPLE
        $ssoCredential = Get-VcfCheckVCenterSsoCredential -Context $Context -Fqdn 'w01-vc01.example.com'
    #>

    [CmdletBinding()]
    [OutputType([PSCredential])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn
    )

    $ssoDomainName = Get-VcfCheckVCenterSsoDomainName -Context $Context -Fqdn $Fqdn

    $cacheKey = "PSC|SYSTEM|$ssoDomainName"
    if ($Context.ComponentCredentialCache.ContainsKey($cacheKey)) {
        return $Context.ComponentCredentialCache[$cacheKey]
    }

    Write-LogMessage -Type DEBUG -Message "Retrieving PSC/SYSTEM credential for domain `"$ssoDomainName`" (vCenter `"$Fqdn`")."
    try {
        $response = Invoke-VcfGetCredentials -ResourceType PSC -AccountType SYSTEM -DomainName $ssoDomainName -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("Failed to retrieve the PSC/SYSTEM credential for domain `"$ssoDomainName`" from SDDC Manager. Verify the SDDC Manager connection and that the domain is properly registered.")
    }

    $match = $response.Elements | Select-Object -First 1
    if (-not $match) {
        throw [System.InvalidOperationException]::new("SDDC Manager returned no PSC/SYSTEM credential for domain `"$ssoDomainName`" (vCenter `"$Fqdn`").")
    }

    $secure = ConvertTo-SecureStringForCredential -PlainText $match.Password
    $credential = [PSCredential]::new($match.Username, $secure)
    Remove-Variable -Name match, response -ErrorAction SilentlyContinue

    $Context.ComponentCredentialCache[$cacheKey] = $credential
    return $credential
}
function Connect-VcfCheckVCenter {

    <#
        .SYNOPSIS
        Connects to a vCenter using its SSO credential retrieved from SDDC Manager.

        .DESCRIPTION
        Wraps Connect-VIServer using the PSC/SYSTEM credential (administrator@vsphere.local) -
        confirmed against a live lab to be the correct resource/account type for vCenter SSO
        login (NOT "VCENTER", which is the appliance's guest OS account - see
        Get-VcfCheckComponentCredential). Resolved via Get-VcfCheckVCenterSsoCredential
        (domain-based lookup), not Get-VcfCheckComponentCredential's FQDN-based lookup - see
        that function's own comment for why. Requires DefaultVIServerMode = Multiple (set at
        module import) so more than one vCenter can be connected simultaneously, which
        Invoke-VcfApplianceCommand relies on to address appliance VMs by bare name + -Server.

        Runs a TCP reachability pre-flight check (Test-VcfCheckTcpConnectivity) against
        <Fqdn>:443 first, the same pattern Connect-VcfCheckSddcManager uses. On failure - or on
        a Connect-VIServer failure - the reason is cached on $Context.UnreachableVCenters so every
        later check targeting the same vCenter fails fast with the same message instead of each
        independently re-running the TCP/auth attempt and surfacing whatever raw PowerCLI
        exception text that particular check's own cmdlet happened to throw (confirmed live: a
        vCenter that drops mid-run produced a different message per check - "Server X is not
        connected" from Get-VIMachineCertificate, a different one from Get-VMHost - for one real
        outage).

        Before assuming an already-connected vCenter is still usable, verifies it against
        $global:DefaultVIServers rather than trusting $Context.ConnectedVCenters alone - a session
        can drop mid-run (VPN blip, vCenter service restart) after a prior check connected
        successfully, and Get-VIServer/etc. calls made against the stale entry would otherwise
        surface the same confusing per-check "not connected" errors this function exists to avoid.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER Fqdn
        vCenter FQDN to connect to.

        .PARAMETER ConnectivityTimeoutSeconds
        Maximum time to wait for the TCP reachability pre-flight check. Defaults to 15 seconds -
        shorter than Connect-VcfCheckSddcManager's 30, since this same check can now run once
        per vCenter for every check in the run rather than once per run.

        .OUTPUTS
        None. Mutates $Context.ConnectedVCenters and $Context.UnreachableVCenters.

        .EXAMPLE
        Connect-VcfCheckVCenter -Context $Context -Fqdn 'm01-vc01.example.com'
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn,
        [Parameter(Mandatory = $false)] [Int]$ConnectivityTimeoutSeconds = 15
    )

    if ($Context.UnreachableVCenters.ContainsKey($Fqdn)) {
        throw [System.InvalidOperationException]::new($Context.UnreachableVCenters[$Fqdn])
    }

    if ($Context.ConnectedVCenters -contains $Fqdn) {
        $stillConnected = $global:DefaultVIServers | Where-Object { $_.Name -eq $Fqdn -and $_.IsConnected }
        if ($stillConnected) {
            return
        }
        $null = $Context.ConnectedVCenters.Remove($Fqdn)
    }

    if (-not (Test-VcfCheckTcpConnectivity -ComputerName $Fqdn -Port 443 -TimeoutSeconds $ConnectivityTimeoutSeconds)) {
        $reason = "Could not reach vCenter `"$Fqdn`" on port 443 within $ConnectivityTimeoutSeconds second(s). Check VPN/network connectivity to the environment, firewall rules, and that the FQDN resolves to the correct address, then retry."
        $Context.UnreachableVCenters[$Fqdn] = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    $credential = Get-VcfCheckVCenterSsoCredential -Context $Context -Fqdn $Fqdn
    Write-LogMessage -Type INFO -Message "Connecting to vCenter `"$Fqdn`"..." -NoNewline
    try {
        $null = Connect-VIServer -Server $Fqdn -Credential $credential -ErrorAction Stop
        Write-Host " Connected" -ForegroundColor White
    } catch {
        Write-Host " Failed" -ForegroundColor Red
        Write-LogMessage -Type DEBUG -Message "Connect-VIServer to `"$Fqdn`" raised: $($_.Exception.GetType().FullName): $($_.Exception.ToString())"
        if ($_.Exception.Message -match 'SSL connection could not be established|invalid.*certificate|certificate.*invalid') {
            $reason = "Failed to connect to vCenter `"$Fqdn`" because its TLS certificate is not trusted. Either install a certificate this system trusts on the vCenter, or - for lab/test environments only - review whether `"Set-PowerCLIConfiguration -InvalidCertificateAction Ignore`" is appropriate (check current setting with `"Get-PowerCLIConfiguration`"). See: https://techdocs.broadcom.com/us/en/vmware-cis/vcf/power-cli/latest/powercli/configuring-vmware-vsphere-powercli/configuring-powercli-invalid-server-certificate-actions/configure-invalid-server-certificate-action.html"
        } elseif ($_.Exception.Message -match '(?i)NonInteractive mode|Read and Prompt functionality') {
            $reason = "Failed to connect to vCenter `"$Fqdn`" because PowerCLI tried to show an interactive prompt that this non-interactive session cannot answer. This most commonly happens when a connection to another vCenter is already open in the same run (e.g. the management vCenter) and PowerCLI's `"DefaultVIServerMode`" is not set to `"Multiple`" - it then asks to confirm connecting to an additional vCenter, which cannot be answered non-interactively. Check with `"Get-PowerCLIConfiguration`" and, if needed, run: Set-PowerCLIConfiguration -Scope User -DefaultVIServerMode Multiple. If DefaultVIServerMode is already `"Multiple`", this can instead be a certificate prompt not gated by InvalidCertificateAction - e.g. a hostname mismatch (verify CN/SAN with: openssl s_client -connect `"$Fqdn`":443 -servername `"$Fqdn`" </dev/null | openssl x509 -noout -subject -ext subjectAltName) or a recently reissued certificate whose thumbprint PowerCLI has not yet accepted (fix by connecting once interactively: Connect-VIServer -Server `"$Fqdn`")."
        } elseif ($_.Exception.Message -match '(?i)UNAUTHORIZED|not authorized|invalid credentials|incorrect user ?name or password|authentication failed|cannot complete login|401\b') {
            $reason = "Authentication failed connecting to vCenter `"$Fqdn`" as `"$($credential.UserName)`" (the PSC/SYSTEM credential SDDC Manager has on file for this vCenter's SSO domain). The vCenter itself is reachable - this is a rejected credential, not a network problem. Verify that account's password in SDDC Manager matches the vCenter's SSO domain, and re-sync/rotate it there if it has drifted."
        } else {
            $reason = "Failed to connect to vCenter `"$Fqdn`" as `"$($credential.UserName)`": $($_.Exception.Message)"
        }
        $Context.UnreachableVCenters[$Fqdn] = $reason
        throw [System.InvalidOperationException]::new($reason)
    }

    $Context.ConnectedVCenters.Add($Fqdn)
}
function Test-VcfCheckEsxHostConnectivity {

    <#
        .SYNOPSIS
        Tests TCP connectivity to an ESX host on ports 443 and 902 (required for VMware Tools).

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to vCenter.

        .PARAMETER VcenterFqdn
        FQDN of the vCenter managing the ESX host.

        .PARAMETER VmName
        Name of the VM to resolve to an ESX host.

        .PARAMETER TimeoutSeconds
        Maximum time to wait for each TCP port check. Defaults to 30 seconds.

        .OUTPUTS
        [PSObject] with Success (bool), Hostname (string), Error (null or message). Success=true
        means either the host was found and is reachable, or the host couldn't be determined
        (skipped check - will be caught by Invoke-VMScript if there's an actual connectivity issue).
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterFqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VmName,
        [Parameter(Mandatory = $false)] [Int]$TimeoutSeconds = 30
    )

    try {
        Write-LogMessage -Type DEBUG -Message "Resolving ESX host for VM `"$VmName`"..."
        $vmMatches = @(Get-VcfCheckVM -VmName $VmName -Server $VcenterFqdn)

        if ($vmMatches.Count -eq 0) {
            Write-LogMessage -Type WARNING -Message "No VM named `"$VmName`" was found on vCenter `"$VcenterFqdn`". Skipping ESX host connectivity pre-check - the guest command resolves the VM independently and will report its own specific error if it truly can't be reached."
            return [PSCustomObject]@{
                Success  = $true
                Hostname = $null
                Error    = $null
            }
        }
        if ($vmMatches.Count -gt 1) {
            Write-LogMessage -Type WARNING -Message "Found $($vmMatches.Count) VMs named `"$VmName`" on vCenter `"$VcenterFqdn`" (ambiguous). Skipping ESX host connectivity pre-check - actual connectivity will be verified during guest operations."
            return [PSCustomObject]@{
                Success  = $true
                Hostname = $null
                Error    = $null
            }
        }

        $esxHostname = $vmMatches[0].Host.Name
        if ([String]::IsNullOrWhiteSpace($esxHostname)) {
            Start-Sleep -Seconds 2
            $vmMatches = @(Get-VcfCheckVM -VmName $VmName -Server $VcenterFqdn)
            $esxHostname = if ($vmMatches.Count -eq 1) { $vmMatches[0].Host.Name } else { $null }
        }
        if ([String]::IsNullOrWhiteSpace($esxHostname)) {
            Write-LogMessage -Type DEBUG -Message "VM `"$VmName`" has no assigned ESX host even after a retry. Skipping ESX host connectivity pre-check - actual connectivity will be verified during guest operations."
            return [PSCustomObject]@{
                Success  = $true
                Hostname = $null
                Error    = $null
            }
        }

        Write-LogMessage -Type DEBUG -Message "VM `"$VmName`" is on ESX host `"$esxHostname`". Testing TCP connectivity to ports 443 and 902..."

        $failedPorts = @()
        foreach ($port in @(443, 902)) {
            if (-not (Test-VcfCheckTcpConnectivity -ComputerName $esxHostname -Port $port -TimeoutSeconds $TimeoutSeconds)) {
                $failedPorts += $port
                Write-LogMessage -Type WARNING -Message "Could not reach ESX host `"$esxHostname`" on TCP port $port."
            }
        }

        if ($failedPorts.Count -eq 0) {
            Write-LogMessage -Type DEBUG -Message "ESX host `"$esxHostname`" is reachable on ports 443 and 902."
            return [PSCustomObject]@{
                Success  = $true
                Hostname = $esxHostname
                Error    = $null
            }
        } else {
            $portList = $failedPorts -join ', '
            $msg = "ESX host `"$esxHostname`" is not reachable on TCP port(s) $portList. Verify network connectivity, firewall rules, and host configuration."
            Write-LogMessage -Type WARNING -Message $msg
            return [PSCustomObject]@{
                Success  = $false
                Hostname = $esxHostname
                Error    = $msg
            }
        }
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to resolve ESX host for connectivity check: $($_.Exception.Message)"
        Write-LogMessage -Type WARNING -Message "Skipping ESX host connectivity pre-check - actual connectivity will be verified during guest operations."
        return [PSCustomObject]@{
            Success  = $true
            Hostname = $null
            Error    = $null
        }
    }
}
function Test-VcfCheckSddcManagerRootCredential {

    <#
        .SYNOPSIS
        Verifies the SDDC Manager appliance root credential end-to-end, not just that a value was typed.

        .DESCRIPTION
        Reuses the exact chain already proven out by the checks under Private/Checks/SddcManager
        (e.g. Test-VcfSddcLockTable): resolve the management domain's vCenter
        (Get-VcfCheckManagementVCenterFqdn), connect to it (Connect-VcfCheckVCenter), then run
        a lightweight guest command against the SDDC Manager VM via VMware Tools guest operations
        (Invoke-VcfApplianceCommand) using the supplied root credential. `hostname` is used purely
        as a low-cost "does this credential actually authenticate against the appliance" probe,
        deliberately not a real check with pass/fail business logic of its own.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager (so
        $Context.SddcManagerFqdn is available to resolve the management vCenter and derive the
        appliance VM name).

        .PARAMETER RootCredential
        The SDDC Manager appliance's root (or other guest OS account) credential to verify.

        .OUTPUTS
        [PSObject] with Success (bool), Detail (string, populated on success), ErrorCategory
        (string, populated on failure - see Get-VcfApplianceErrorCategory), and ErrorMessage
        (string, populated on failure).

        .EXAMPLE
        Test-VcfCheckSddcManagerRootCredential -Context $Context -RootCredential $rootCred
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [PSCredential]$RootCredential
    )

    try {
        Write-LogMessage -Type DEBUG -Message "Resolving management vCenter for root credential validation..."
        $vcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        Write-LogMessage -Type DEBUG -Message "Management vCenter resolved to `"$vcenterFqdn`". Connecting..."
        Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
        Write-LogMessage -Type DEBUG -Message "Connected to management vCenter `"$vcenterFqdn`"."
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to resolve/connect to management vCenter during root credential validation: $($_.Exception.Message)"
        return [PSCustomObject]@{
            Success      = $false
            Detail       = $null
            ErrorCategory = 'Unknown'
            ErrorMessage = "Could not connect to the management domain's vCenter. Verify the SDDC Manager connection is active and the management domain is configured correctly."
        }
    }

    $vmName = ($Context.SddcManagerFqdn -split '\.')[0]
    Write-LogMessage -Type DEBUG -Message "Invoking guest command on SDDC Manager appliance `"$vmName`" via vCenter `"$vcenterFqdn`" using Invoke-VMScript..."
    $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $vcenterFqdn -Credential $RootCredential -ScriptText 'hostname'
    Write-LogMessage -Type DEBUG -Message "Guest command invocation completed. Success=$($commandResult.Success), ErrorCategory=$($commandResult.ErrorCategory)"

    if (-not $commandResult.Success) {
        return [PSCustomObject]@{
            Success      = $false
            Detail       = $null
            ErrorCategory = $commandResult.ErrorCategory
            ErrorMessage = $commandResult.ErrorMessage
        }
    }

    return [PSCustomObject]@{
        Success      = $true
        Detail       = "Root credential verified against `"$vmName`" via `"$vcenterFqdn`" (hostname: $($commandResult.ScriptOutput.Trim()))."
        ErrorCategory = $null
        ErrorMessage = $null
    }
}
function Get-VcfCheckManagementNsxManagerFqdn {

    <#
        .SYNOPSIS
        Resolves and caches the management domain's NSX Manager cluster VIP FQDN.

        .DESCRIPTION
        Wraps Invoke-VcfGetDomains -Type 'MANAGEMENT', mirroring
        Get-VcfCheckManagementVCenterFqdn - confirmed via reflection that the Domain model's
        NsxtCluster.VipFqdn field is the NSX Manager cluster VIP for that domain.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .OUTPUTS
        [String] the management domain's NSX Manager cluster VIP FQDN.

        .EXAMPLE
        $mgmtNsxFqdn = Get-VcfCheckManagementNsxManagerFqdn -Context $Context
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    if ($Context.ManagementNsxManagerFqdn) {
        return $Context.ManagementNsxManagerFqdn
    }

    $domains = Get-VcfCheckDomains -Type 'MANAGEMENT'
    $managementDomain = $domains | Select-Object -First 1
    if (-not $managementDomain) {
        throw [System.InvalidOperationException]::new('SDDC Manager did not return a management domain.')
    }

    $fqdn = $managementDomain.NsxtCluster.VipFqdn
    if ([String]::IsNullOrWhiteSpace($fqdn)) {
        throw [System.InvalidOperationException]::new('The management domain has no NSX Manager VIP FQDN.')
    }

    $Context.ManagementNsxManagerFqdn = $fqdn
    return $fqdn
}
function Connect-VcfCheckNsxManager {

    <#
        .SYNOPSIS
        Connects to NSX Manager using its admin credential retrieved from SDDC Manager.

        .DESCRIPTION
        Wraps Connect-NsxServer (VMware.Sdk.Nsx.Policy). Confirmed against a live lab that
        NSXT_MANAGER/SYSTEM covers admin/audit/root accounts for the same resource, so -Username
        'admin' disambiguates which one to use (see Get-VcfCheckComponentCredential).

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER Fqdn
        NSX Manager (cluster VIP) FQDN to connect to.

        .OUTPUTS
        None. Mutates $Context.ConnectedNsxManagers.

        .EXAMPLE
        Connect-VcfCheckNsxManager -Context $Context -Fqdn 'm01-nsx01.example.com'
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn
    )

    if ($Context.ConnectedNsxManagers -contains $Fqdn) {
        return
    }

    $credential = Get-VcfCheckComponentCredential -Context $Context -ResourceType NSXT_MANAGER -AccountType SYSTEM -Fqdn $Fqdn -Username 'admin'
    Write-LogMessage -Type INFO -Message "Connecting to NSX Manager `"$Fqdn`"..."
    try {
        $null = Connect-NsxServer -Server $Fqdn -Credential $credential -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("Failed to connect to NSX Manager `"$Fqdn`". Verify network connectivity and that NSX Manager is reachable.")
    }

    $Context.ConnectedNsxManagers.Add($Fqdn)
    Write-LogMessage -Type INFO -Message "Connected to NSX Manager `"$Fqdn`"."
}
function Disconnect-VcfCheckComponent {

    <#
        .SYNOPSIS
        Tears down the vCenter connection for a single FQDN and clears its cached credentials.

        .DESCRIPTION
        Intended to be called immediately after the last check for a component's area finishes,
        satisfying REQUIREMENTS.md's "after each component's health is verified, connections
        will be destroyed" - granular teardown, not just at the end of the whole run. Clears
        every ComponentCredentialCache entry for this Fqdn regardless of resource/account type,
        since a check-set run may have pulled more than one account for the same target.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER Fqdn
        FQDN of the component to disconnect.

        .EXAMPLE
        Disconnect-VcfCheckComponent -Context $Context -Fqdn 'm01-vc01.example.com'
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Fqdn
    )

    if ($Context.ConnectedVCenters -contains $Fqdn) {
        try {
            Disconnect-VIServer -Server $Fqdn -Confirm:$false -Force -ErrorAction Stop
            Write-LogMessage -Type INFO -Message "Disconnected from vCenter `"$Fqdn`"."
        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to disconnect from vCenter `"$Fqdn`": $($_.Exception.Message)"
        }
        $null = $Context.ConnectedVCenters.Remove($Fqdn)
    }

    if ($Context.ConnectedNsxManagers -contains $Fqdn) {
        try {
            Disconnect-NsxServer -Server $Fqdn -Force -ErrorAction Stop
            Write-LogMessage -Type INFO -Message "Disconnected from NSX Manager `"$Fqdn`"."
        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to disconnect from NSX Manager `"$Fqdn`": $($_.Exception.Message)"
        }
        $null = $Context.ConnectedNsxManagers.Remove($Fqdn)
    }

    $keysToRemove = @($Context.ComponentCredentialCache.Keys | Where-Object { $_ -like "*|$Fqdn|*" })
    foreach ($key in $keysToRemove) {
        $Context.ComponentCredentialCache.Remove($key)
    }
}
function Disconnect-VcfCheckAll {

    <#
        .SYNOPSIS
        Safety-net teardown of every connection and cached credential on the context.

        .DESCRIPTION
        Called unconditionally from Invoke-VcfCheck's top-level finally block. Idempotent -
        covers any component whose area-specific Disconnect-VcfCheckComponent call didn't
        run because the run errored before reaching it. Verifies (but does not throw on) any
        vCenter connection that remains after disconnect, since masking the real run result
        with a teardown exception would be worse than logging a warning. Finishes with a
        best-effort GC sweep for any plain strings that may be existed transciently.

        .PARAMETER Context
        The VcfCheck.Context object to tear down.

        .EXAMPLE
        try { ... } finally { Disconnect-VcfCheckAll -Context $Context }
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )

    foreach ($fqdn in @($Context.ConnectedVCenters)) {
        try {
            Disconnect-VIServer -Server $fqdn -Confirm:$false -Force -ErrorAction Stop
        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to disconnect from vCenter `"$fqdn`" during teardown: $($_.Exception.Message)"
        }
    }
    $Context.ConnectedVCenters.Clear()

    if ($Global:DefaultVIServer) {
        Write-LogMessage -Type WARNING -Message "A vCenter connection ($($Global:DefaultVIServer.Name)) remained active after teardown."
    }

    foreach ($fqdn in @($Context.ConnectedNsxManagers)) {
        try {
            Disconnect-NsxServer -Server $fqdn -Force -ErrorAction Stop
        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to disconnect from NSX Manager `"$fqdn`" during teardown: $($_.Exception.Message)"
        }
    }
    $Context.ConnectedNsxManagers.Clear()

    if ($Context.SddcManagerConnection) {
        try {
            Disconnect-VcfSddcManagerServer -Server $Context.SddcManagerFqdn -Force -ErrorAction Stop
        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to disconnect from SDDC Manager during teardown: $($_.Exception.Message)"
        }
        $Context.SddcManagerConnection = $null
    }

    $Context.ComponentCredentialCache.Clear()
    $Context.SddcManagerRootCredential = $null

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    Write-LogMessage -Type INFO -Message 'Teardown complete.'
}

#endregion Connections
