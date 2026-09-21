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
#region Logging

function Protect-VcfCheckLogMessage {

    <#
        .SYNOPSIS
        Redacts known secret-bearing patterns from a message before it is logged or reported.

        .DESCRIPTION
        A denylist of known secret-bearing patterns (HTTP Authorization headers, Basic/Bearer
        auth schemes, JSON password/token fields). This is a defense-in-depth backstop, not the
        primary control—the primary control is that this module never builds a command string
        or log message containing a plaintext secret in the first place (guest-ops credentials
        are passed via -GuestCredential parameter binding, never embedded in ScriptText).
        Applied to every message Write-LogMessage writes, and to Exception text before it is
        placed in a VcfCheck.Result.

        .PARAMETER Message
        The raw message text.

        .OUTPUTS
        [String] the redacted message.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Message
    )

    $redacted = $Message
    $redacted = $redacted -replace '(?i)Authorization:\s*[^\r\n]+', 'Authorization: [REDACTED]'
    $redacted = $redacted -replace '(?i)Basic\s+[A-Za-z0-9+/=]{8,}', 'Basic [REDACTED]'
    $redacted = $redacted -replace '(?i)Bearer\s+[A-Za-z0-9\-._~+/]{8,}=*', 'Bearer [REDACTED]'
    $redacted = $redacted -replace '(?i)("(?:password|token|secret|pwd)"\s*:\s*)"[^"]*"', '$1"[REDACTED]"'
    $redacted = $redacted -replace '(?i)(-w\s+|--password[= ]|-GuestPassword\s+)\S+', '$1[REDACTED]'
    return $redacted
}
function Write-LogMessage {

    <#
        .SYNOPSIS
        Writes a timestamped, type-prefixed log message to console and/or log file.

        .DESCRIPTION
        Screen output is filtered by the configured log level threshold (set via
        Initialize-VcfCheckLogging). Only messages at or above the configured level are
        displayed on the console. All messages are always written to the log file regardless
        of level, so DEBUG context needed to diagnose a run is never silently discarded. When
        the orchestrator is executing a check, it sets $Script:VcfCheckCurrentCheckId to
        that check's ID, and every message logged during execution is tagged with
        "[<CheckId>]" so a given log line can be traced back to the check that produced it.

        .PARAMETER Type
        Message type: DEBUG, INFO, WARNING, ERROR.

        .PARAMETER Message
        The message text. Never pass a plaintext secret.

        .EXAMPLE
        Write-LogMessage -Type INFO -Message "Connected to SDDC Manager vcf01-sddcmgr01."

        .EXAMPLE
        Write-LogMessage -Type ERROR -Message "Check sddc_lock_table failed: $($_.Exception.Message)"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR')] [String]$Type,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Message,
        [Parameter(Mandatory = $false)] [Switch]$NoNewline
    )

    $levelOrder = @{ 'DEBUG' = 0; 'INFO' = 1; 'WARNING' = 2; 'ERROR' = 3 }
    $configuredLevel = if ($Script:VcfCheckLogLevel) { $Script:VcfCheckLogLevel } else { 'INFO' }
    $aboveScreenThreshold = $levelOrder[$Type] -ge $levelOrder[$configuredLevel]

    $sanitizedMessage = Protect-VcfCheckLogMessage -Message $Message
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $checkTag = if ($Script:VcfCheckCurrentCheckId) { " [$($Script:VcfCheckCurrentCheckId)]" } else { '' }
    $formattedMessage = "[$timestamp] [$Type]$checkTag $sanitizedMessage"

    if ($aboveScreenThreshold) {
        switch ($Type) {
            'DEBUG'   { Write-Host $formattedMessage -ForegroundColor Gray -NoNewline:$NoNewline }
            'INFO'    { Write-Host $formattedMessage -ForegroundColor White -NoNewline:$NoNewline }
            'WARNING' { Write-Host $formattedMessage -ForegroundColor Yellow -NoNewline:$NoNewline }
            'ERROR'   { Write-Host $formattedMessage -ForegroundColor Red -NoNewline:$NoNewline }
        }
    }

    if ($Script:VcfCheckLogFilePath) {
        try {
            $fileExists = Test-Path -LiteralPath $Script:VcfCheckLogFilePath
            Add-Content -LiteralPath $Script:VcfCheckLogFilePath -Value $formattedMessage -ErrorAction Stop

            if (-not $fileExists -and $PSVersionTable.Platform -ne 'Win32NT') {
                & chmod 600 $Script:VcfCheckLogFilePath 2>$null
            }
        } catch {
            Write-Host "Warning: Could not write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
function Get-VcfCheckLogDirectory {

    <#
        .SYNOPSIS
        Returns the directory where VcfCheck logs are written.

        .DESCRIPTION
        Returns the configured log directory if logging has been initialized, otherwise
        the default Logs/ directory relative to the module installation directory. Useful
        for the bundled Python report server, which tails the same log directory.

        .OUTPUTS
        [String] Fully qualified path to the log directory.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    if ($Script:VcfCheckLogDirectory) {
        return $Script:VcfCheckLogDirectory
    }

    return Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Logs'
}
function Initialize-VcfCheckLogging {

    <#
        .SYNOPSIS
        Initializes logging for a VcfCheck run.

        .DESCRIPTION
        Resolves the log directory (explicit param > $env:VcfCheckBaseDirectory\Logs),
        creates it with owner-only permissions if missing, and opens a new dated log file.
        All severities are always written to the file; only messages at or above LogLevel
        are echoed to the console.

        .PARAMETER LogDirectory
        Absolute or relative path to the log directory. When omitted, resolved from
        $env:VcfCheckBaseDirectory. Throws if neither is available.

        .PARAMETER LogLevel
        Minimum log level to display on console: DEBUG, INFO, WARNING, ERROR. Default INFO.

        .OUTPUTS
        [String] Absolute path to the active log file.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$LogDirectory = '',
        [Parameter(Mandatory = $false)] [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR')] [String]$LogLevel = 'INFO'
    )

    $Script:VcfCheckLogLevel = $LogLevel

    if ([String]::IsNullOrWhiteSpace($LogDirectory)) {
        if ([String]::IsNullOrWhiteSpace($env:VcfCheckBaseDirectory)) {
            throw [System.InvalidOperationException]::new(
                "`$env:$($Script:VCF_CHECK_ENV_VAR) is not set. Run Initialize-VcfCheck before starting a precheck run, or pass -LogDirectory explicitly."
            )
        }
        $Script:VcfCheckLogDirectory = Join-Path -Path $env:VcfCheckBaseDirectory.Trim() -ChildPath $Script:CHECK_LOGS_DIR_NAME
    } elseif ([System.IO.Path]::IsPathRooted($LogDirectory)) {
        $Script:VcfCheckLogDirectory = $LogDirectory
    } else {
        $Script:VcfCheckLogDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath $LogDirectory
    }

    if (-not (Test-Path -LiteralPath $Script:VcfCheckLogDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Script:VcfCheckLogDirectory -Force
        if ($PSVersionTable.Platform -ne 'Win32NT') {
            & chmod 700 $Script:VcfCheckLogDirectory 2>$null
        }
    }

    # Naming uses a PascalCase prefix, ISO-like hyphenated date, one file per calendar day,
    # and no per-run ID in the name.
    $fileTimeStamp = Get-Date -Format 'yyyy-MM-dd'
    $Script:VcfCheckLogFilePath = Join-Path -Path $Script:VcfCheckLogDirectory -ChildPath "VcfCheckEngine-$fileTimeStamp.log"

    if (-not (Test-Path -LiteralPath $Script:VcfCheckLogFilePath)) {
        New-Item -ItemType File -Path $Script:VcfCheckLogFilePath -Force | Out-Null
    }

    return $Script:VcfCheckLogFilePath
}
function Write-VcfCheckRuntimeInfo {

    <#
        .SYNOPSIS
        Logs PowerShell, PowerCLI, VcfCheck module, and environment information to the log.

        .DESCRIPTION
        Writes a single INFO log line with PowerShell version, VMware PowerCLI version,
        VcfCheck module version, Python version, and OS. Called once per precheck run
        immediately after Initialize-VcfCheckLogging. Detects Python version from the
        environment variable if set, otherwise attempts to query the python3, python, or py
        executable on PATH, logging a DEBUG line with the reason when detection fails.
        Non-fatal — continues even if detection fails.

        .EXAMPLE
        Initialize-VcfCheckLogging -LogDirectory $LogDirectory | Out-Null
        Write-VcfCheckRuntimeInfo
    #>

    [CmdletBinding()]
    Param ()

    try {
        $pcliMod = Get-Module -Name 'VCF.PowerCLI' -ListAvailable -ErrorAction SilentlyContinue |
            Sort-Object { [Version]$_.Version } -Descending | Select-Object -First 1
        $checkMod = Get-Module -Name 'VcfCheck' -ErrorAction SilentlyContinue
        $pcliVer = if ($pcliMod) { $pcliMod.Version.ToString() } else { 'not loaded' }
        $checkVer = if ($checkMod) { $checkMod.Version.ToString() } else { 'unknown' }

        # Detect Python version from environment variable or by querying executable
        $pyVer = 'unknown'
        if ($env:VCF_CHECK_PYTHON_VERSION) {
            $pyVer = $env:VCF_CHECK_PYTHON_VERSION
        } else {
            try {
                $pythonExe = @('python3', 'python', 'py') |
                    Where-Object { $null -ne (Get-Command $_ -ErrorAction SilentlyContinue) } |
                    Select-Object -First 1
                if ($pythonExe) {
                    $pyVersionOutput = & $pythonExe --version 2>&1
                    if ($pyVersionOutput -match '(\d+\.\d+(?:\.\d+)?)') {
                        $pyVer = $matches[1]
                    } else {
                        Write-LogMessage -Type DEBUG -Message "Python detection: '$pythonExe --version' produced unparsable output '$pyVersionOutput'"
                    }
                } else {
                    Write-LogMessage -Type DEBUG -Message 'Python detection: no python3, python, or py executable found on PATH'
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Python detection failed: $($_.Exception.Message)"
            }
        }

        # $PSVersionTable.OS reports the kernel build (e.g. "10.0.20348"), which is ambiguous
        # between Windows Server 2022 and Windows 10/11 21H2+. ProductName from the registry
        # disambiguates on Windows; other platforms keep the $PSVersionTable.OS string.
        $osInfo = $PSVersionTable.OS
        if ($PSVersionTable.Platform -eq 'Win32NT') {
            try {
                $winVer = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
                if ($winVer.ProductName) {
                    $osInfo = "$($winVer.ProductName) $($winVer.CurrentBuildNumber)"
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Windows ProductName detection failed: $($_.Exception.Message)"
            }
        }

        Write-LogMessage -Type INFO -Message "Runtime: PowerShell=$($PSVersionTable.PSVersion) | VCF.PowerCLI=$pcliVer | VcfCheck=v$checkVer | Python=$pyVer | OS=$osInfo"
    } catch {
        # Non-fatal: still log even if something fails above
        Write-LogMessage -Type INFO -Message "Runtime: PowerShell=$($PSVersionTable.PSVersion) | VCF.PowerCLI=unknown | VcfCheck=unknown | Python=unknown | OS=$($PSVersionTable.OS)"
    }

    Write-VcfCheckProcessIdentityInfo
}
function Write-VcfCheckProcessIdentityInfo {

    <#
        .SYNOPSIS
        Logs the current process identity, elevation, and PowerCLI configuration scopes.

        .DESCRIPTION
        Writes a single DEBUG log line with the current OS account, whether it is elevated,
        and the Session/User/AllUsers-scope InvalidCertificateAction/DefaultVIServerMode
        values as seen by this process. Read-only - never changes any configuration.
        Called once per run from Write-VcfCheckRuntimeInfo, and again immediately before each
        guest-ops call in Invoke-VcfApplianceCommand, so the values are captured even when that
        specific call fails or hangs before the run-start snapshot would otherwise be useful.

        PowerCLI's documented precedence is Session (highest) > User > AllUsers (lowest) - a
        set Session value should already win regardless of User/AllUsers. But Session is
        per-process and in-memory only, never persisted to disk, so a launcher subprocess (a
        fresh "pwsh -NoProfile -NonInteractive" per check run) never inherits the operator's own
        interactive-shell Session setting - it starts with Session unset and should then fall
        through to User, then AllUsers. Confirmed against a customer environment where that
        fallthrough did not happen for Invoke-VMScript guest-ops specifically: Session was unset
        in the subprocess, User had no override, and AllUsers reported "Ignore", yet guest-ops
        calls still failed TLS validation until the User scope was set explicitly
        (Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore). So this logs a
        WARNING whenever Session has no override of its own, User has no override either, and
        AllUsers is "Ignore" - the one combination where the documented fallthrough to AllUsers
        is known not to reliably apply to guest-ops calls.

        .EXAMPLE
        Write-VcfCheckProcessIdentityInfo
    #>

    [CmdletBinding()]
    Param ()

    try {
        $identityName = 'unknown'
        $isElevated = 'unknown'
        if ($PSVersionTable.Platform -eq 'Win32NT') {
            # $env:USERDOMAIN/$env:USERNAME avoid the SID-to-account-name LSA lookup that
            # WindowsIdentity.GetCurrent().Name performs, which can hang when AD/DNS is unreachable.
            $identityName = "$env:USERDOMAIN\$env:USERNAME"
            $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } else {
            $identityName = & whoami 2>$null
            $isElevated = ($env:SUDO_USER -or ($null -ne (& id -u 2>$null) -and (& id -u 2>$null) -eq '0'))
        }

        $sessionConfig = Get-PowerCLIConfiguration -Scope Session -ErrorAction SilentlyContinue
        $userConfig = Get-PowerCLIConfiguration -Scope User -ErrorAction SilentlyContinue
        $allUsersConfig = Get-PowerCLIConfiguration -Scope AllUsers -ErrorAction SilentlyContinue

        Write-LogMessage -Type DEBUG -Message "Process identity=$identityName | Elevated=$isElevated | PowerCLI Session(InvalidCertificateAction=$($sessionConfig.InvalidCertificateAction), DefaultVIServerMode=$($sessionConfig.DefaultVIServerMode)) | User(InvalidCertificateAction=$($userConfig.InvalidCertificateAction), DefaultVIServerMode=$($userConfig.DefaultVIServerMode)) | AllUsers(InvalidCertificateAction=$($allUsersConfig.InvalidCertificateAction), DefaultVIServerMode=$($allUsersConfig.DefaultVIServerMode))"

        $sessionHasNoOverride = [String]::IsNullOrWhiteSpace($sessionConfig.InvalidCertificateAction) -or $sessionConfig.InvalidCertificateAction -eq 'Unset'
        $userHasNoOverride = [String]::IsNullOrWhiteSpace($userConfig.InvalidCertificateAction) -or $userConfig.InvalidCertificateAction -eq 'Unset'
        if ($sessionHasNoOverride -and $userHasNoOverride -and $allUsersConfig.InvalidCertificateAction -eq 'Ignore') {
            Write-LogMessage -Type WARNING -Message 'PowerCLI InvalidCertificateAction is "Ignore" at AllUsers scope only - Session and User have no override in this process. Guest-ops calls (Invoke-VMScript) have been observed to not reliably fall through to AllUsers the way PowerCLI''s documented Session > User > AllUsers precedence implies, and can still fail TLS certificate validation. If a guest-ops call fails with a certificate error, run: Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore'
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Process identity/PowerCLI configuration detection failed: $($_.Exception.Message)"
    }
}

#endregion Logging
