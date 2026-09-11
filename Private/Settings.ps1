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
#region Settings

function Resolve-VcfCheckAllowInsecureTls {

    <#
        .SYNOPSIS
        Resolves whether this run should accept untrusted/self-signed TLS certificates.

        .DESCRIPTION
        VcfCheck has no setting of its own for this - the decision is derived entirely from
        PowerCLI's own InvalidCertificateAction setting (Get-PowerCLIConfiguration -Scope
        Session), so every connector (Connect-VIServer, Connect-VcfOpsServer, and the hand-written
        REST helpers for Aria Automation/VRSLCM/NSX Manager) makes the same choice an operator
        already made once via `Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction
        Ignore` (lab, self-signed certificates) or the default `Fail`/`Warn` (production). Logs
        the resolved value unconditionally (INFO), not only when insecure TLS is allowed, since
        that is the most common source of "a check accepted/rejected an untrusted cert
        unexpectedly". Never throws - a failed read defaults to $false (secure).

        .OUTPUTS
        [Bool] $true when untrusted/self-signed certificates should be accepted this run.

        .EXAMPLE
        $allowInsecureTls = Resolve-VcfCheckAllowInsecureTls
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param ()

    $allowInsecureTls = $false
    try {
        $invalidCertificateAction = (Get-PowerCLIConfiguration -Scope Session -ErrorAction Stop).InvalidCertificateAction
        $allowInsecureTls = $invalidCertificateAction -eq 'Ignore'
        Write-LogMessage -Type INFO -Message "PowerCLI InvalidCertificateAction is `"$invalidCertificateAction`" - untrusted/self-signed certificates on all endpoints will $(if ($allowInsecureTls) { 'be accepted' } else { 'NOT be accepted' }) this run. Change with `"Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore`" or `"...-InvalidCertificateAction Fail`"."
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not read PowerCLI's InvalidCertificateAction (defaulting to secure - untrusted certificates will NOT be accepted this run): $($_.Exception.Message)"
    }

    return $allowInsecureTls
}
function Get-VcfCheckSettings {

    <#
        .SYNOPSIS
        Loads and validates settings.json.

        .DESCRIPTION
        settings.json may only carry SddcManagerFqdn and SddcManagerUser - per requirements,
        the password is never persisted to disk and is always resolved separately (see
        Get-VcfCheckCredential). Returns $null if Path does not exist so callers can fall
        back entirely to interactive/explicit-parameter input.

        Whether untrusted/self-signed certificates are accepted is not a settings.json key at
        all - it is derived from PowerCLI's own InvalidCertificateAction setting (see
        Invoke-VcfCheck in Orchestrator.ps1), so it is intentionally absent from this function's
        output.

        .PARAMETER Path
        Path to settings.json. When omitted, resolved from
        $env:VcfCheckBaseDirectory\Config\settings.json.

        .OUTPUTS
        [PSCustomObject] with SddcManagerFqdn/SddcManagerUser, or $null if no settings file
        exists.

        .EXAMPLE
        $settings = Get-VcfCheckSettings -Path '~/VcfCheck/Config/settings.json'
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Path = ''
    )

    $resolvedPath = $Path
    if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
        if ([String]::IsNullOrWhiteSpace($env:VcfCheckBaseDirectory)) {
            return $null
        }
        $resolvedPath = Join-Path -Path $env:VcfCheckBaseDirectory.Trim() -ChildPath (Join-Path -Path $Script:CHECK_CONFIG_DIR_NAME -ChildPath $Script:CHECK_SETTINGS_FILE_NAME)
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        Write-LogMessage -Type DEBUG -Message "No settings file found at `"$resolvedPath`" - will rely on explicit parameters or interactive prompts."
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 10 -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("Failed to parse settings file `"$resolvedPath`": $($_.Exception.Message)")
    }

    if ('SddcManagerPassword' -in $raw.PSObject.Properties.Name) {
        Write-LogMessage -Type WARNING -Message "settings.json at `"$resolvedPath`" contains an SddcManagerPassword field. This value will be ignored - VcfCheck never reads a password from disk."
    }

    $missingKeys = @('SddcManagerFqdn', 'SddcManagerUser') | Where-Object { [String]::IsNullOrWhiteSpace($raw.$_) }
    if ($missingKeys.Count -gt 0) {
        throw [System.InvalidOperationException]::new("Settings file `"$resolvedPath`" is missing required key(s): $($missingKeys -join ', ')")
    }

    return [PSCustomObject]@{
        SddcManagerFqdn = $raw.SddcManagerFqdn
        SddcManagerUser = $raw.SddcManagerUser
    }
}
function Get-VcfCheckThemePreference {

    <#
        .SYNOPSIS
        Resolves the browser's saved dark/light theme preference from settings.json.

        .DESCRIPTION
        Tools/vcf-check-ui.html persists the user's theme toggle to settings.json's Theme key via
        /api/settings so the browser report reopens in the same theme. Export-VcfCheckReportHtml
        reads it back through this function so the static Findings-folder report matches - without
        it, the static report always renders in the CSS default (dark) regardless of what the user
        last chose. Falls back to 'dark' (the CSS default) whenever settings.json is missing,
        unreadable, or has no recognised Theme value, so a bad read degrades to the existing
        behaviour rather than throwing.

        .PARAMETER Path
        Path to settings.json. When omitted, resolved from
        $env:VcfCheckBaseDirectory\Config\settings.json.

        .OUTPUTS
        [String] either 'light' or 'dark'.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Path = ''
    )

    $resolvedPath = $Path
    if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
        if ([String]::IsNullOrWhiteSpace($env:VcfCheckBaseDirectory)) {
            return 'dark'
        }
        $resolvedPath = Join-Path -Path $env:VcfCheckBaseDirectory.Trim() -ChildPath (Join-Path -Path $Script:CHECK_CONFIG_DIR_NAME -ChildPath $Script:CHECK_SETTINGS_FILE_NAME)
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return 'dark'
    }

    try {
        $raw = Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 10 -ErrorAction Stop
    } catch {
        Write-LogMessage -Type DEBUG -Message "Failed to read theme preference from `"$resolvedPath`": $($_.Exception.Message). Defaulting to dark."
        return 'dark'
    }

    if ($raw.Theme -eq 'light') {
        return 'light'
    }
    return 'dark'
}
function Get-VcfCheckCredential {

    <#
        .SYNOPSIS
        Resolves the SDDC Manager FQDN, username, and password to connect with.

        .DESCRIPTION
        Precedence for Fqdn/User: explicit parameter > settings.json > interactive Read-Host.
        The Password is NEVER read from or written to settings.json - if not passed explicitly
        as a SecureString, the operator is always prompted via Read-Host -AsSecureString.

        .PARAMETER Settings
        Result of Get-VcfCheckSettings, or $null.

        .PARAMETER SddcManagerFqdn
        Explicit FQDN override.

        .PARAMETER SddcManagerUser
        Explicit username override.

        .PARAMETER SddcManagerPassword
        Explicit SecureString override. When omitted, the operator is prompted.

        .OUTPUTS
        [PSCustomObject] with Fqdn, User, Password (SecureString).

        .EXAMPLE
        $cred = Get-VcfCheckCredential -Settings $settings
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$Settings = $null,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$SddcManagerFqdn = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$SddcManagerUser = '',
        [Parameter(Mandatory = $false)] [AllowNull()] [SecureString]$SddcManagerPassword = $null
    )

    $fqdn = $SddcManagerFqdn
    if ([String]::IsNullOrWhiteSpace($fqdn)) { $fqdn = $Settings.SddcManagerFqdn }
    while ([String]::IsNullOrWhiteSpace($fqdn)) {
        $fqdn = Read-Host -Prompt 'Enter the SDDC Manager FQDN'
    }

    $user = $SddcManagerUser
    if ([String]::IsNullOrWhiteSpace($user)) { $user = $Settings.SddcManagerUser }
    while ([String]::IsNullOrWhiteSpace($user)) {
        $user = Read-Host -Prompt 'Enter the SDDC Manager username'
    }

    $password = $SddcManagerPassword
    if ($null -eq $password) {
        $password = Read-Host -Prompt "Enter the password for $user@$fqdn" -AsSecureString
    }
    if ($password.Length -eq 0) {
        throw [System.InvalidOperationException]::new('SDDC Manager password must not be empty.')
    }

    return [PSCustomObject]@{
        Fqdn     = $fqdn
        User     = $user
        Password = $password
    }
}
function Test-VcfCheckDependencies {

    <#
        .SYNOPSIS
        Checks that VcfCheck's prerequisites are present before initializing.

        .DESCRIPTION
        Collects every unmet requirement before returning, rather than failing fast on the first miss, so
        a user sees the full remediation list in one pass. PowerShell version, VCF.PowerCLI, and
        PowerCLI's DefaultVIServerMode session setting are hard requirements (checks cannot run
        without them - VCF Check connects to more than one vCenter Server in the same session);
        Python is a soft requirement (only needed to view reports via Start-VcfCheckServer -
        Invoke-VcfCheck itself does not need it) and is reported as a Warning-level finding, not
        a failure.

        .OUTPUTS
        [PSObject] with IsSatisfied (bool, considers only hard requirements) and Findings
        (string[], one line per unmet requirement including soft ones).

        .EXAMPLE
        $deps = Test-VcfCheckDependencies
        if (-not $deps.IsSatisfied) { $deps.Findings | ForEach-Object { Write-Warning $_ } }
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param ()

    $findings = [System.Collections.Generic.List[String]]::new()
    $hardRequirementsMet = $true
    $minimumPowerShellVersion = [Version]'7.4'
    $minimumPythonVersion = [Version]'3.13'

    if ($PSVersionTable.PSVersion -lt $minimumPowerShellVersion) {
        $findings.Add("PowerShell $minimumPowerShellVersion or later is required (found $($PSVersionTable.PSVersion)). Install a current PowerShell release from https://github.com/PowerShell/PowerShell.")
        $hardRequirementsMet = $false
    }

    $vcfPowerCli = Get-Module -ListAvailable -Name 'VCF.PowerCLI' -ErrorAction SilentlyContinue | Sort-Object -Property Version -Descending | Select-Object -First 1
    if (-not $vcfPowerCli) {
        $vmwarePowerCli = Get-Module -ListAvailable -Name 'VMware.PowerCLI' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($vmwarePowerCli) {
            $findings.Add('VCF.PowerCLI is required and was not found, but the conflicting VMware.PowerCLI module is installed. Remove it first with: Uninstall-Module -Name VMware.PowerCLI -AllVersions, then install VCF.PowerCLI with: Install-Module -Name VCF.PowerCLI -Scope CurrentUser')
        } else {
            $findings.Add('VCF.PowerCLI is required and was not found. Install it with: Install-Module -Name VCF.PowerCLI -Scope CurrentUser')
        }
        $hardRequirementsMet = $false
    }

    $viServerMode = (Get-PowerCLIConfiguration -Scope Session -ErrorAction SilentlyContinue).DefaultVIServerMode
    if ($viServerMode -ne 'Multiple') {
        $findings.Add("PowerCLI DefaultVIServerMode is `"$viServerMode`", not `"Multiple`" (required to connect to more than one vCenter Server in the same session). Run: Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Scope Session")
        $hardRequirementsMet = $false
    }

    $pythonCommand = Get-Command -Name python3 -ErrorAction SilentlyContinue
    if (-not $pythonCommand) {
        $pythonCommand = Get-Command -Name python -ErrorAction SilentlyContinue
    }
    if (-not $pythonCommand) {
        $findings.Add('(Optional) Python 3.13+ was not found - the web UI (Start-VcfCheckServer) will not be usable until it is installed.')
    } else {
        try {
            $versionOutput = & $pythonCommand.Source '--version' 2>&1
            if ($versionOutput -match '(\d+)\.(\d+)\.(\d+)') {
                $foundVersion = [Version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
                if ($foundVersion -lt $minimumPythonVersion) {
                    $findings.Add("(Optional) Python $minimumPythonVersion or later is recommended for the web UI (found $foundVersion).")
                }
            }
        } catch {
            $findings.Add("(Optional) Could not determine the Python version at `"$($pythonCommand.Source)`": $($_.Exception.Message)")
        }
    }

    return [PSCustomObject]@{
        IsSatisfied = $hardRequirementsMet
        Findings    = $findings.ToArray()
    }
}
function Test-VcfCheckModuleUpdate {

    <#
        .SYNOPSIS
        Checks whether a newer VcfCheck version is published on the PowerShell Gallery.

        .DESCRIPTION
        Queries the PowerShell Gallery (NuGet v2 OData query against
        https://www.powershellgallery.com/api/v2/FindPackagesById()). This is explicitly
        provisional: the project's actual plan is a private depot for distributing this module,
        not the public PowerShell Gallery (VcfCheck may never be published there at all) - so
        this check fails silently (returns UpdateAvailable=$false, Error populated) on any
        network/parse failure rather than treating "can't reach the Gallery" as noteworthy in an
        air-gapped lab environment, which is the expected common case, not an error condition
        worth alarming the user about. Never called automatically - opt-in only.

        .OUTPUTS
        [PSObject] with CurrentVersion, LatestVersion, UpdateAvailable, GalleryUrl, Error.

        .EXAMPLE
        Test-VcfCheckModuleUpdate
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param ()

    $currentVersion = $Script:VcfCheckVersion
    $galleryUrl = 'https://www.powershellgallery.com/packages/VcfCheck'

    try {
        $apiUrl = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='VcfCheck'&`$orderby=Version%20desc&`$top=1"
        [Xml]$response = Invoke-RestMethod -Uri $apiUrl -Method Get -ErrorAction Stop
        $versionNode = $response.feed.entry.properties.Version
        if (-not $versionNode) {
            return [PSCustomObject]@{ CurrentVersion = $currentVersion; LatestVersion = $null; UpdateAvailable = $false; GalleryUrl = $galleryUrl; Error = 'VcfCheck is not published on the PowerShell Gallery (expected - this project plans to use a private depot instead).' }
        }

        $latestVersion = [Version]$versionNode
        $updateAvailable = $latestVersion -gt [Version]$currentVersion

        return [PSCustomObject]@{
            CurrentVersion  = $currentVersion
            LatestVersion   = $versionNode
            UpdateAvailable = $updateAvailable
            GalleryUrl      = $galleryUrl
            Error           = $null
        }
    } catch {
        return [PSCustomObject]@{ CurrentVersion = $currentVersion; LatestVersion = $null; UpdateAvailable = $false; GalleryUrl = $galleryUrl; Error = $_.Exception.Message }
    }
}
function New-VcfCheckOwnerOnlyDirectory {

    <#
        .SYNOPSIS
        Creates a directory restricted to the current user on both Windows and non-Windows platforms.

        .DESCRIPTION
        Wraps New-Item -ItemType Directory so every directory this module creates under the base
        working directory is non-world-readable from the moment it exists, with no TOCTOU window.
        On non-Windows platforms, sets mode 0700 immediately after creation. On Windows, disables
        inherited permissions and grants only the current user FullControl, with container/object
        inheritance so files and subdirectories created later inherit the same restriction.
        Permissions are re-applied every time this function is called for a given path - including
        when the directory already exists - so a directory created by an older version of this
        module is self-healed the next time Initialize-VcfCheck touches it. Permission-hardening
        failures are logged as WARNING and are non-fatal; directory-creation failures propagate
        exactly as New-Item would.

        .PARAMETER Path
        Full path of the directory to create.

        .PARAMETER Force
        Suppresses the error when the directory already exists and creates any missing
        intermediate parent directories, matching New-Item -Force semantics.

        .OUTPUTS
        [System.IO.DirectoryInfo]

        .EXAMPLE
        $null = New-VcfCheckOwnerOnlyDirectory -Path $findingsDir -Force
    #>

    [CmdletBinding()]
    [OutputType([System.IO.DirectoryInfo])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path,
        [Parameter(Mandatory = $false)] [Switch]$Force
    )

    $directoryInfo = New-Item -ItemType Directory -Path $Path -Force:$Force.IsPresent

    if (-not $IsWindows) {
        & chmod 700 $Path 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-LogMessage -Type WARNING -Message "New-VcfCheckOwnerOnlyDirectory: chmod 700 failed (exit $LASTEXITCODE) on `"$Path`". Directory may be readable by other OS users."
        }
    } else {
        try {
            $acl = Get-Acl -Path $Path
            $acl.SetAccessRuleProtection($true, $false)
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $currentUser,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
            Set-Acl -Path $Path -AclObject $acl
        } catch {
            Write-LogMessage -Type WARNING -Message "New-VcfCheckOwnerOnlyDirectory: Could not restrict ACL on `"$Path`": $($_.Exception.Message). Directory may be readable by other OS users."
        }
    }

    return $directoryInfo
}
function Resolve-VcfCheckBaseDirectory {

    <#
        .SYNOPSIS
        Resolves the VcfCheck base directory interactively.

        .DESCRIPTION
        Handles three cases in order:
          1. $env:VcfCheckBaseDirectory is set and the path does not exist - clears the stale
             session value and falls through to the prompt.
          2. $env:VcfCheckBaseDirectory is set and is a valid directory - offers the operator
             the choice to keep it or pick a different one.
          3. No env var set - prompts with the default path as the proposed value.

        Returns the operator-chosen (or defaulted) absolute path, or $null when the session is
        non-interactive (Read-Host throws) or when the chosen path falls outside $HOME.

        .PARAMETER DefaultBaseDirectory
        Default directory path shown to the operator at the prompt.

        .OUTPUTS
        [String] Absolute resolved base directory path, or $null on failure.

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.

        .EXAMPLE
        $baseDir = Resolve-VcfCheckBaseDirectory -DefaultBaseDirectory "$HOME/VcfCheck"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DefaultBaseDirectory
    )

    $envRaw = $env:VcfCheckBaseDirectory

    if (-not [String]::IsNullOrWhiteSpace($envRaw)) {
        $trimmed = $envRaw.Trim()

        if (-not (Test-Path -LiteralPath $trimmed)) {
            Write-Host ''
            Write-Host "  Note: `$env:VcfCheckBaseDirectory pointed at a path that does not exist:" -ForegroundColor Yellow
            Write-Host "    $trimmed" -ForegroundColor White
            $env:VcfCheckBaseDirectory = $null
            Write-Host '  Stale value cleared from session. Choose a folder below.' -ForegroundColor Green
        } elseif (Test-Path -LiteralPath $trimmed -PathType Container) {
            Write-Host "  Detected: `$env:VcfCheckBaseDirectory is set to $trimmed" -ForegroundColor Green
            try {
                $response = Read-Host '  Keep this directory or set a different one? [(K)eep / (C)hange, default: K]'
            } catch {
                Write-LogMessage -Type ERROR -Message "Initialize-VcfCheck requires an interactive session to change the base directory. $($_.Exception.Message)"
                return $null
            }
            if ($response.Trim() -inotmatch '^c(hange)?$') {
                # K, Enter, or anything other than C -> keep the existing directory.
                return (Resolve-Path -LiteralPath $trimmed -ErrorAction Stop).Path
            }
            # C -> fall through to the path prompt so the operator can choose a new directory.
        }
    }

    Write-Host "  Default base directory: $DefaultBaseDirectory" -ForegroundColor White
    Write-Host ''
    try {
        $inputValue = Read-Host 'Press Enter to use the default, or type a full directory path'
    } catch {
        Write-LogMessage -Type ERROR -Message "Initialize-VcfCheck requires an interactive session. $($_.Exception.Message)"
        return $null
    }

    $chosen = if ([String]::IsNullOrWhiteSpace($inputValue)) { $DefaultBaseDirectory } else { $inputValue.Trim() }

    if (-not [System.IO.Path]::IsPathRooted($chosen)) {
        $chosen = Join-Path -Path $HOME -ChildPath $chosen
    }
    $chosen = [System.IO.Path]::GetFullPath($chosen)

    $homeFull = [System.IO.Path]::GetFullPath($HOME)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    if (-not $chosen.StartsWith($homeFull + $separator, [StringComparison]::OrdinalIgnoreCase) -and $chosen -ine $homeFull) {
        Write-LogMessage -Type ERROR -Message "BaseDirectory must be within the home directory. Chosen: `"$chosen`"."
        return $null
    }

    return $chosen
}
function Resolve-VcfCheckActiveBaseDirectory {

    <#
        .SYNOPSIS
        Resolves the current session's VcfCheck base directory, offering to run
        Initialize-VcfCheck on the operator's behalf if none is configured.

        .DESCRIPTION
        Server-lifecycle entry points (Start-VcfCheckServer, Invoke-VcfCheck) need
        $env:VcfCheckBaseDirectory to be a valid directory before they can do anything useful.
        Rather than throwing a raw exception - which surfaces a PowerShell stack trace for what is
        really a one-time setup step - this offers to run Initialize-VcfCheck right there in an
        interactive session, and falls back to a plain, actionable log message otherwise.

        .OUTPUTS
        [String] The resolved base directory path, or $null if none is configured and the
        operator declined setup (or the session is non-interactive).

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.

        .EXAMPLE
        $baseDirectory = Resolve-VcfCheckActiveBaseDirectory
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    $existing = ([String]$env:VcfCheckBaseDirectory).Trim()
    if (-not [String]::IsNullOrWhiteSpace($existing) -and (Test-Path -LiteralPath $existing -PathType Container)) {
        return $existing
    }

    Write-Host ''
    Write-Host '  VcfCheck has not been set up in this session yet.' -ForegroundColor Yellow
    try {
        $response = Read-Host '  Run initial setup now (Initialize-VcfCheck)? [(Y)es / (N)o, default: Y]'
    } catch {
        Write-LogMessage -Type ERROR -Message "VcfCheck has not been set up. Run Initialize-VcfCheck first, or pass -BaseDirectory/-OutputPath explicitly. $($_.Exception.Message)"
        return $null
    }

    if ($response.Trim() -imatch '^n(o)?$') {
        Write-LogMessage -Type WARNING -Message 'Setup skipped. Run Initialize-VcfCheck when you are ready.'
        return $null
    }

    return Initialize-VcfCheck
}
function Invoke-VcfCheckPersistBaseDirectory {

    <#
        .SYNOPSIS
        Persists $env:VcfCheckBaseDirectory for the current session and future sessions.

        .DESCRIPTION
        Sets the environment variable for the current session. On Windows, also writes it to the
        user environment registry via [System.Environment]::SetEnvironmentVariable so new
        sessions and Explorer-launched processes inherit it. On all platforms, writes or updates
        the assignment in $PROFILE, replacing any stale prior value via regex rather than blindly
        appending - ensuring clean configuration over time.

        .PARAMETER ResolvedBaseDirectory
        Fully resolved absolute path to persist.

        .PARAMETER ProfilePath
        Overrides $PROFILE - exists solely so tests can redirect profile writes to a temp file
        instead of the real one. Defaults to $PROFILE when omitted.

        .OUTPUTS
        None. Mutates $env:VcfCheckBaseDirectory, the Windows user environment (Windows only),
        and $PROFILE (or -ProfilePath).
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ResolvedBaseDirectory,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$ProfilePath = ''
    )

    $resolvedProfilePath = $ProfilePath
    if ([String]::IsNullOrWhiteSpace($resolvedProfilePath)) {
        $resolvedProfilePath = $PROFILE
    }

    $env:VcfCheckBaseDirectory = $ResolvedBaseDirectory

    if ($IsWindows) {
        try {
            [System.Environment]::SetEnvironmentVariable($Script:VCF_CHECK_ENV_VAR, $ResolvedBaseDirectory, [System.EnvironmentVariableTarget]::User)
            $verifyValue = [System.Environment]::GetEnvironmentVariable($Script:VCF_CHECK_ENV_VAR, [System.EnvironmentVariableTarget]::User)
            if ($verifyValue -ne $ResolvedBaseDirectory) {
                Write-LogMessage -Type WARNING -Message "VcfCheckBaseDirectory registry write appeared to succeed but read-back returned `"$verifyValue`"."
            }
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not persist VcfCheckBaseDirectory to the user environment: $($_.Exception.Message)"
        }
    }

    $profileLine = "`$env:$($Script:VCF_CHECK_ENV_VAR) = `"$ResolvedBaseDirectory`""
    try {
        $profileDir = Split-Path -Path $resolvedProfilePath -Parent
        if (-not (Test-Path -LiteralPath $profileDir)) {
            $null = New-VcfCheckOwnerOnlyDirectory -Path $profileDir -Force
        }
        if (-not (Test-Path -LiteralPath $resolvedProfilePath)) {
            $null = New-Item -ItemType File -Path $resolvedProfilePath -Force
        }

        $existingContent = Get-Content -LiteralPath $resolvedProfilePath -Raw -ErrorAction SilentlyContinue
        if ($null -eq $existingContent) { $existingContent = '' }

        if ($existingContent -notmatch [Regex]::Escape($profileLine)) {
            $stalePattern = "(?m)^\`$env:$($Script:VCF_CHECK_ENV_VAR)\s*=\s*[`"'][^`"']*[`"']\r?\n?"
            $cleanedContent = $existingContent -replace $stalePattern, ''
            Set-Content -LiteralPath $resolvedProfilePath -Value ($cleanedContent.TrimEnd() + "`n$profileLine") -Encoding UTF8 -NoNewline
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not update `$PROFILE (`"$resolvedProfilePath`"): $($_.Exception.Message)"
    }
}
function Initialize-VcfCheck {

    <#
        .SYNOPSIS
        Sets up the user working directory for VcfCheck on first use.

        .DESCRIPTION
        Copies the module's bundled Data/, Docs/, Config/, and Tools/ files into a user working
        directory (default ~/VcfCheck) and persists the base directory to
        $env:VcfCheckBaseDirectory for the current session, the Windows user environment (on
        Windows), and $PROFILE (for future sessions on any platform). The module tree itself
        stays read-only/versioned; the user copy is where settings.json, findings, logs, and
        server state files actually live.

        When -BaseDirectory is omitted (and this isn't a -RefreshTools/-RefreshData-only run),
        prompts interactively via Resolve-VcfCheckBaseDirectory instead of silently defaulting
        - offering to keep an already-configured directory, change it, or pick one from scratch.
        Pass -BaseDirectory explicitly to skip the prompt entirely (e.g. from a script or test).

        .PARAMETER BaseDirectory
        Target working directory. When omitted, resolved interactively (default proposed:
        "$HOME/VcfCheck") unless -RefreshTools/-RefreshData is specified and
        $env:VcfCheckBaseDirectory already points at a valid directory, in which case that
        existing directory is used directly.

        .PARAMETER RefreshTools
        When specified, overwrites Tools/ in the working directory with the module's bundled
        copy even if the working directory already exists (use after a module upgrade). Implies
        partial-refresh mode: skips the dependency check and the interactive directory prompt -
        unless $env:VcfCheckBaseDirectory is not set or no longer exists, in which case it
        falls back to full interactive setup instead of failing.

        .PARAMETER RefreshData
        When specified, overwrites Data/ and Docs/ in the working directory with the module's
        bundled copy.
        Implies partial-refresh mode: skips the dependency check and the interactive directory prompt -
        unless $env:VcfCheckBaseDirectory is not set or no longer exists, in which case it
        falls back to full interactive setup instead of failing.

        .PARAMETER SkipDependencyCheck
        Skip Test-VcfCheckDependencies. Intended for -RefreshTools/-RefreshData-only re-runs
        where the environment was already validated on first init.

        .OUTPUTS
        [String] The resolved base directory path, or $null if requirements were not met or no
        base directory could be resolved (already logged via Write-LogMessage -Type ERROR).

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.

        .EXAMPLE
        Initialize-VcfCheck

        .EXAMPLE
        Initialize-VcfCheck -BaseDirectory ~/VcfCheckLab -SkipDependencyCheck

        .EXAMPLE
        Initialize-VcfCheck -RefreshTools -RefreshData
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$BaseDirectory = '',
        [Parameter(Mandatory = $false)] [Switch]$RefreshTools,
        [Parameter(Mandatory = $false)] [Switch]$RefreshData,
        [Parameter(Mandatory = $false)] [Switch]$SkipDependencyCheck
    )

    $isPartialRefresh = $RefreshTools.IsPresent -or $RefreshData.IsPresent

    if (-not $SkipDependencyCheck.IsPresent -and -not $isPartialRefresh) {
        $dependencies = Test-VcfCheckDependencies
        foreach ($finding in $dependencies.Findings) {
            Write-LogMessage -Type WARNING -Message $finding
        }
        if (-not $dependencies.IsSatisfied) {
            Write-LogMessage -Type ERROR -Message "VcfCheck's requirements are not met - see the warnings above for remediation steps."
            return $null
        }
        if ($dependencies.Findings.Count -gt 0) {
            # All findings reaching here are soft (Python-only) - IsSatisfied would have already
            # returned above otherwise. Still worth an explicit choice, not a silent warn-and-
            Write-Host ''
            Write-Host '  Setup can continue, but the web UI will not be usable until Python is installed (see the warning above).' -ForegroundColor Yellow
            try {
                $response = Read-Host '  Continue setup anyway? [(Y)es / (N)o, default: N]'
            } catch {
                $response = 'N'
            }
            if ($response.Trim() -inotmatch '^y(es)?$') {
                Write-LogMessage -Type WARNING -Message 'Setup cancelled. Install Python 3.13+, then re-run Initialize-VcfCheck.'
                return $null
            }
        }
    }

    $resolvedBase = $BaseDirectory
    if ([String]::IsNullOrWhiteSpace($resolvedBase)) {
        $existingBase = ([String]$env:VcfCheckBaseDirectory).Trim()
        $existingBaseIsValid = (-not [String]::IsNullOrWhiteSpace($existingBase)) -and (Test-Path -LiteralPath $existingBase -PathType Container)

        if ($isPartialRefresh -and $existingBaseIsValid) {
            $resolvedBase = $existingBase
        } else {
            if ($isPartialRefresh) {
                Write-LogMessage -Type WARNING -Message '$env:VcfCheckBaseDirectory is not set or does not exist - running full setup instead of a partial refresh.'
            }
            $defaultBase = Join-Path -Path $HOME -ChildPath $Script:VCF_CHECK_DEFAULT_DIR
            $resolvedBase = Resolve-VcfCheckBaseDirectory -DefaultBaseDirectory $defaultBase
            if ([String]::IsNullOrWhiteSpace($resolvedBase)) {
                return $null
            }
        }
    }

    $moduleRoot = Split-Path -Parent $PSScriptRoot

    if (-not (Test-Path -LiteralPath $resolvedBase -PathType Container)) {
        $null = New-VcfCheckOwnerOnlyDirectory -Path $resolvedBase -Force
    }

    $subDirs = @($Script:CHECK_CONFIG_DIR_NAME, $Script:CHECK_DATA_DIR_NAME, $Script:CHECK_DOCS_DIR_NAME, $Script:CHECK_FINDINGS_DIR_NAME, $Script:CHECK_LOGS_DIR_NAME, $Script:CHECK_RUN_DIR_NAME, $Script:CHECK_TOOLS_DIR_NAME)
    foreach ($subDir in $subDirs) {
        $target = Join-Path -Path $resolvedBase -ChildPath $subDir
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            $null = New-VcfCheckOwnerOnlyDirectory -Path $target -Force
        }
    }

    $dataSource = Join-Path -Path $moduleRoot -ChildPath $Script:CHECK_DATA_DIR_NAME
    $dataTarget = Join-Path -Path $resolvedBase -ChildPath $Script:CHECK_DATA_DIR_NAME
    if ((Test-Path -LiteralPath $dataSource) -and ($RefreshData -or -not (Test-Path -LiteralPath (Join-Path -Path $dataTarget -ChildPath 'CheckCatalog.json')))) {
        Copy-Item -Path (Join-Path -Path $dataSource -ChildPath '*') -Destination $dataTarget -Recurse -Force
        Write-LogMessage -Type INFO -Message "Copied check catalog data to `"$dataTarget`"."
    }

    $docsSource = Join-Path -Path $moduleRoot -ChildPath $Script:CHECK_DOCS_DIR_NAME
    $docsTarget = Join-Path -Path $resolvedBase -ChildPath $Script:CHECK_DOCS_DIR_NAME
    $readmeSource = Join-Path -Path $docsSource -ChildPath 'README.html'
    if ((Test-Path -LiteralPath $readmeSource) -and ($RefreshData -or -not (Test-Path -LiteralPath (Join-Path -Path $docsTarget -ChildPath 'README.html')))) {
        Copy-Item -Path $readmeSource -Destination $docsTarget -Force
        Write-LogMessage -Type DEBUG -Message "Copied documentation to `"$docsTarget`"."
    }

    $configSource = Join-Path -Path $moduleRoot -ChildPath $Script:CHECK_CONFIG_DIR_NAME
    $configTarget = Join-Path -Path $resolvedBase -ChildPath $Script:CHECK_CONFIG_DIR_NAME
    $settingsExample = Join-Path -Path $configSource -ChildPath 'settings.example.json'
    if (Test-Path -LiteralPath $settingsExample) {
        Copy-Item -Path $settingsExample -Destination $configTarget -Force
    }

    $toolsSource = Join-Path -Path $moduleRoot -ChildPath $Script:CHECK_TOOLS_DIR_NAME
    $toolsTarget = Join-Path -Path $resolvedBase -ChildPath $Script:CHECK_TOOLS_DIR_NAME
    foreach ($toolFile in $Script:CHECK_TOOL_FILE_NAMES) {
        $source = Join-Path -Path $toolsSource -ChildPath $toolFile
        $target = Join-Path -Path $toolsTarget -ChildPath $toolFile
        if ((Test-Path -LiteralPath $source) -and ($RefreshTools -or -not (Test-Path -LiteralPath $target))) {
            $targetDir = Split-Path -Path $target -Parent
            if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
                $null = New-VcfCheckOwnerOnlyDirectory -Path $targetDir -Force
            }
            Copy-Item -Path $source -Destination $target -Force
            Write-LogMessage -Type DEBUG -Message "Copied tool file `"$toolFile`" to `"$toolsTarget`"."
        }
    }

    Invoke-VcfCheckPersistBaseDirectory -ResolvedBaseDirectory $resolvedBase

    Write-LogMessage -Type INFO -Message "VcfCheck initialized at `"$resolvedBase`"."
    return $resolvedBase
}

#endregion Settings
