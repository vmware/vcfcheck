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
#region Tools
#
# PowerShell-side lifecycle wrappers around Tools/Manage-VcfCheckServer.py, which
# implements the actual start/stop/status logic (PID file at <base>/Logs/vcf-check-server.pid,
# detached-process launch, SIGTERM-then-poll shutdown) - see that file's docstring.
# Provides python3-then-python discovery, open-in-browser convenience, and a thin
# PowerShell interface over a self-contained Python process manager.

function Test-VcfCheckCatalogJson {
    <#
        .SYNOPSIS
        Validates and analyzes CheckCatalog.json, providing detailed error context and auto-remediation.

        .DESCRIPTION
        Attempts to parse CheckCatalog.json using PowerShell's ConvertFrom-Json. On success,
        returns $true. On failure, performs detailed analysis:
        - Extracts the exact line and column number from the parser error
        - Reads the file and displays the problematic stanza with surrounding context
        - Identifies likely causes (unescaped newlines in markdown links, missing commas, trailing commas, etc.)
        - Attempts automatic remediation where safe (e.g., consolidating split markdown links to single lines)
        - Suggests manual fixes for remaining issues

        This early validation (before Python tries to load the file) catches syntax errors
        with friendly, actionable error messages instead of cryptic server crashes.

        .PARAMETER CatalogPath
        Full path to CheckCatalog.json.

        .PARAMETER AutoFix
        Reserved for future use. Currently unused. Default $true.

        .OUTPUTS
        [Boolean] $true if the file is valid JSON (after any auto-fix), $false otherwise.

        .EXAMPLE
        if (-not (Test-VcfCheckCatalogJson -CatalogPath "$baseDirectory/Data/CheckCatalog.json")) {
            return 1
        }
    #>

    [CmdletBinding()]
    [OutputType([Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [String]$CatalogPath,
        [Parameter(Mandatory = $false)] [Bool]$AutoFix = $true
    )

    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        Write-LogMessage -Type ERROR -Message "CheckCatalog.json not found at: $CatalogPath"
        return $false
    }

    try {
        $content = Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop
        $null = $content | ConvertFrom-Json -ErrorAction Stop
        return $true
    } catch {
        $errorMsg = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "CheckCatalog.json contains syntax errors and cannot be parsed."
        Write-LogMessage -Type ERROR -Message "File: $CatalogPath"

        $lines = @($content -split "`n")

        $lineNum = $null
        $colNum = $null
        if ($errorMsg -match "line (\d+)\D+(\d+)") {
            $lineNum = [Int]$matches[1]
            $colNum = [Int]$matches[2]
        }

        if ($null -ne $lineNum) {
            Write-LogMessage -Type ERROR -Message "Error at line $lineNum, column ${colNum}:"

            $startLine = [Math]::Max(1, $lineNum - 2)
            $endLine = [Math]::Min($lines.Count, $lineNum + 2)

            for ($i = $startLine; $i -le $endLine; $i++) {
                $line = $lines[$i - 1]
                $marker = if ($i -eq $lineNum) { ">>> " } else { "    " }
                Write-LogMessage -Type ERROR -Message "$marker$($i.ToString().PadLeft(4)): $line"
            }

            if ($lineNum -le $lines.Count) {
                $probLine = $lines[$lineNum - 1]
                $prevLine = if ($lineNum -gt 1) { $lines[$lineNum - 2] } else { "" }
                $nextLine = if ($lineNum -lt $lines.Count) { $lines[$lineNum] } else { "" }

                $isMarkdownLinkSpanError = ($prevLine -match '\]\(https?://') -and -not ($prevLine -match '\)\s*[,"]?\s*$')

                if ($isMarkdownLinkSpanError) {
                    Write-LogMessage -Type ERROR -Message "LIKELY CAUSE: Markdown link URL spans multiple lines without escaping the newline."
                    Write-LogMessage -Type ERROR -Message "MANUAL FIX: Consolidate the markdown link on line $($lineNum - 1) to a single line without splitting the URL."
                } elseif ($errorMsg -match "unexpected character") {
                    if ($probLine -match '^\s*"' -and $prevLine -match '"[^:]*:\s*["\[\{]?[^,]*["\]\}]?\s*$') {
                        Write-LogMessage -Type ERROR -Message "LIKELY CAUSE: Missing comma after previous property value."
                        Write-LogMessage -Type ERROR -Message "FIX: Add a comma at the end of line $($lineNum - 1) after the property value."
                    } elseif ($probLine -notmatch ',$|[{[\:]$|^}' -and ($lineNum -lt $lines.Count) -and ($nextLine -match '^\s*[\w"]')) {
                        Write-LogMessage -Type ERROR -Message "LIKELY CAUSE: Missing comma between object properties."
                        Write-LogMessage -Type ERROR -Message "FIX: Add a comma at the end of line $lineNum after the property value."
                    } else {
                        Write-LogMessage -Type ERROR -Message "LIKELY CAUSE: Unexpected character in JSON structure (possibly a missing or misplaced comma)."
                    }
                } elseif ($probLine -match ',$' -and ($lineNum -lt $lines.Count) -and ($nextLine -match '^\s*[}\]]')) {
                    Write-LogMessage -Type ERROR -Message "LIKELY CAUSE: Trailing comma before closing bracket/brace."
                    Write-LogMessage -Type ERROR -Message "FIX: Remove the comma at the end of line $lineNum."
                } elseif ($errorMsg -match "Invalid escape sequence") {
                    Write-LogMessage -Type ERROR -Message "LIKELY CAUSE: Invalid escape sequence in a string."
                    Write-LogMessage -Type ERROR -Message "FIX: Check line $lineNum for backslashes that need to be escaped as \\\\ or review the escape syntax."
                } else {
                    Write-LogMessage -Type ERROR -Message "LIKELY CAUSE: $errorMsg"
                }
            }
        } else {
            Write-LogMessage -Type ERROR -Message "Parser error: $errorMsg"
        }

        return $false
    }
}
function Test-VcfCheckRequiredJsonFiles {
    <#
        .SYNOPSIS
        Validates settings.json and environments.json before the server starts.

        .DESCRIPTION
        Start-VcfCheckServer already refuses to launch on a malformed CheckCatalog.json
        (Test-VcfCheckCatalogJson) but previously left settings.json/environments.json
        unchecked at startup - a syntax error in either one only surfaced later, as a 500
        from the Python server's own /api/settings or /api/environments endpoint (see
        Start-VcfCheckServer.py's _load_json_file/_run_safely), well after the operator had
        already been told the server started successfully. Calling Get-VcfCheckSettings and
        Get-VcfCheckEnvironments here reuses their existing parse/shape validation
        (Settings.ps1, Environments.ps1) and turns the same failure into a pre-flight message
        with the file path and cause, instead of a confusing in-browser 500.

        .PARAMETER BaseDirectory
        The resolved VcfCheck base directory containing Config/settings.json and
        Config/environments.json.

        .OUTPUTS
        [Boolean] $true if both files are absent-or-valid, $false if either is malformed.

        .EXAMPLE
        if (-not (Test-VcfCheckRequiredJsonFiles -BaseDirectory $baseDirectory)) { return 1 }
    #>

    [CmdletBinding()]
    [OutputType([Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$BaseDirectory
    )

    $isValid = $true

    try {
        $null = Get-VcfCheckSettings
    } catch {
        # Get-VcfCheckSettings also throws when settings.json is well-formed JSON but omits the
        # legacy single-environment SddcManagerFqdn/SddcManagerUser keys - the normal shape for a
        # multi-environment settings.json, which only ever carries browser preferences like Theme.
        # Only a genuine parse failure should block server startup here.
        if ($_.Exception.Message -like 'Failed to parse settings file*') {
            Write-LogMessage -Type ERROR -Message "settings.json is invalid and must be fixed before the server can start: $($_.Exception.Message)"
            $isValid = $false
        }
    }

    $environmentsPath = Join-Path -Path (Join-Path -Path $BaseDirectory -ChildPath 'Config') -ChildPath 'environments.json'
    try {
        $null = Get-VcfCheckEnvironments -Path $environmentsPath
    } catch {
        Write-LogMessage -Type ERROR -Message "environments.json is invalid and must be fixed before the server can start: $($_.Exception.Message)"
        $isValid = $false
    }

    return $isValid
}
function Find-VcfCheckPythonInterpreter {
    <#
        .SYNOPSIS
        Locates a usable python3 (or python) interpreter.

        .OUTPUTS
        [String] path to the interpreter.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    $candidate = Get-Command -Name python3 -ErrorAction SilentlyContinue
    if (-not $candidate) {
        $candidate = Get-Command -Name python -ErrorAction SilentlyContinue
    }
    if (-not $candidate) {
        if ($IsWindows) {
            $installGuidance = 'Install it with "winget install --id Python.Python.3.13 -e", from the Microsoft Store ("Python 3.13"), or from https://www.python.org/downloads/windows/.'
        }
        elseif ($IsMacOS -or $IsLinux) {
            $installGuidance = 'Python 3 is normally included by default on macOS and most Linux distributions; reinstall or repair your Python 3 package via your OS package manager.'
        }
        else {
            $installGuidance = 'Install Python 3.13+ for your platform from https://www.python.org/downloads/.'
        }
        throw [System.InvalidOperationException]::new("No python3/python interpreter found on PATH. $installGuidance")
    }
    return $candidate.Source
}
function Get-VcfCheckTcpListenerProcessId {

    <#
        .SYNOPSIS
        Returns the process id currently listening on a local TCP port, or $null.

        .DESCRIPTION
        Cross-platform port-owner lookup: Get-NetTCPConnection on Windows, lsof on macOS/Linux.
        Used by -Force on Start-/Stop-VcfCheckServer to detect and kill a stale server process even
        when it was started by invoking Start-VcfCheckServer.py directly (bypassing this
        wrapper entirely, so no PID file was ever written for it) - confirmed as a real gap via
        live testing, where a leftover process from an earlier direct invocation held the
        default port with no PID file to identify it.

        .PARAMETER Port
        TCP port to check.

        .OUTPUTS
        [Int] or $null if nothing is listening (or the lookup tool - lsof - is not installed).

        .EXAMPLE
        Get-VcfCheckTcpListenerProcessId -Port 8766
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(1, 65535)] [Int]$Port
    )

    if ($IsWindows) {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $conn) { return $null }
        return [Int]$conn.OwningProcess
    }

    if ($null -eq (Get-Command -Name lsof -ErrorAction SilentlyContinue)) { return $null }

    $pidLines = @(& lsof -nP "-iTCP:$Port" -sTCP:LISTEN -t 2>/dev/null)
    foreach ($line in $pidLines) {
        $ownerPid = 0
        if ([Int]::TryParse($line.Trim(), [ref]$ownerPid) -and $ownerPid -gt 0) {
            return $ownerPid
        }
    }
    return $null
}
function Invoke-VcfCheckServerManager {
    <#
        .SYNOPSIS
        Thin wrapper around `python3 Manage-VcfCheckServer.py <action> ...` (see file header for
        why this wrapper exists - mirrors the project's established pattern of isolating external
        process calls behind a mockable function for unit testing).

        .PARAMETER Python
        Path to the python interpreter.

        .PARAMETER ManagerScript
        Path to Manage-VcfCheckServer.py.

        .PARAMETER Arguments
        Arguments to pass to the script.

        .OUTPUTS
        [PSCustomObject] with Output (string[]) and ExitCode.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Python,
        [Parameter(Mandatory = $true)] [String]$ManagerScript,
        [Parameter(Mandatory = $true)] [String[]]$Arguments
    )
    $output = & $Python $ManagerScript @Arguments
    return [PSCustomObject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}
function Start-VcfCheckServer {

    <#
        .SYNOPSIS
        Starts the bundled Python report viewer in foreground or background mode.

        .DESCRIPTION
        Refreshes the working directory's Tools/ and Data/ files from the module's own bundled
        copy (Initialize-VcfCheck -RefreshTools -RefreshData) before doing anything else.

        By default, the server runs in the foreground and blocks until Ctrl+C is pressed.
        When -Background is specified, the server is launched as a detached background process
        (cross-platform: setsid on macOS/Linux, DETACHED_PROCESS on Windows). Use
        Stop-VcfCheckServer to stop a background server and Get-VcfCheckServerStatus
        to check whether it is running.

        The refresh exists because Tools/ and Data/ are otherwise only ever copied once, on
        first Initialize-VcfCheck - a module upgrade with no explicit -RefreshTools/-RefreshData
        would silently keep running whatever server/launcher code and check catalog were bundled
        at initial setup time, no matter how many times -Force restarted the underlying process.
        Confirmed live: -Force alone (killing a stale process) gave no indication that the code
        being restarted was stale too, and a stale Data/CheckCatalog.json silently ran fewer
        checks than the module actually defines with no error of any kind.

        .PARAMETER Background
        Start the server as a background process. Returns immediately after confirming startup.
        Use Stop-VcfCheckServer to stop a background server. Without this switch, the server
        runs in the foreground and blocks until Ctrl+C is pressed.

        .PARAMETER Port
        TCP port to listen on. Default 8766.

        .PARAMETER NoBrowser
        Skip opening the report viewer in the default browser after starting.

        .PARAMETER Force
        If another process is already listening on Port, kill it first (via
        Get-VcfCheckTcpListenerProcessId + Stop-Process) instead of failing - even if that
        process has no PID file (e.g. it was started by invoking Start-VcfCheckServer.py
        directly). Without -Force, a port already in use throws instead of silently binding
        to/replacing an unrelated process.

        .OUTPUTS
        [Int] Exit code (foreground mode) or 0 (background mode successfully started).

        .EXAMPLE
        Start-VcfCheckServer

        .EXAMPLE
        Start-VcfCheckServer -Background

        .EXAMPLE
        Start-VcfCheckServer -Force

        .EXAMPLE
        Start-VcfCheckServer -Background -NoBrowser -Port 9000
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$Background,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 65535)] [Int]$Port = 8766,
        [Parameter(Mandatory = $false)] [Switch]$NoBrowser,
        [Parameter(Mandatory = $false)] [Switch]$Force
    )

    $baseDirectory = Resolve-VcfCheckActiveBaseDirectory
    if ([String]::IsNullOrWhiteSpace($baseDirectory)) {
        return 1
    }

    Initialize-VcfCheck -RefreshTools -RefreshData | Out-Null

    $catalogPath = Join-Path -Path (Join-Path -Path $baseDirectory -ChildPath 'Data') -ChildPath 'CheckCatalog.json'
    if (-not (Test-VcfCheckCatalogJson -CatalogPath $catalogPath)) {
        return 1
    }

    if (-not (Test-VcfCheckRequiredJsonFiles -BaseDirectory $baseDirectory)) {
        return 1
    }

    $portOwner = Get-VcfCheckTcpListenerProcessId -Port $Port
    if ($null -ne $portOwner) {
        if (-not $Force.IsPresent) {
            Write-LogMessage -Type ERROR -Message "Port $Port is already in use by process $portOwner. Stop it first, or re-run with -Force to stop it automatically."
            return 1
        }
        Write-LogMessage -Type WARNING -Message "Port $Port is held by process $portOwner - stopping it (-Force)."
        Stop-VcfCheckServer -Port $Port
    }

    $loadedModule = Get-Module -Name 'VcfCheck' -All | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($loadedModule) {
        $env:VCFCHECK_MODULE_PSD1 = Join-Path -Path $loadedModule.ModuleBase -ChildPath 'VcfCheck.psd1'
    }

    $python = Find-VcfCheckPythonInterpreter
    $toolsPath = Join-Path -Path $baseDirectory -ChildPath 'Tools'
    $serverScript = Join-Path -Path $toolsPath -ChildPath 'Start-VcfCheckServer.py'

    if (-not (Test-Path -LiteralPath $serverScript)) {
        throw [System.InvalidOperationException]::new("Start-VcfCheckServer.py not found at `"$serverScript`" - run Initialize-VcfCheck to copy the bundled Tools/ files.")
    }

    $managerScript = Join-Path -Path $toolsPath -ChildPath 'Manage-VcfCheckServer.py'
    if (-not (Test-Path -LiteralPath $managerScript)) {
        throw [System.InvalidOperationException]::new("Manage-VcfCheckServer.py not found at `"$managerScript`" - run Initialize-VcfCheck to copy the bundled Tools/ files.")
    }

    if ($Background) {
        Write-LogMessage -Type INFO -Message "Starting VcfCheck Server in background on port $Port..."
    } else {
        Write-LogMessage -Type INFO -Message "Starting VcfCheck Server on port $Port..."
        Write-LogMessage -Type INFO -Message "Web UI will be available at http://127.0.0.1:$Port"
    }

    $serverArgs = @('start', "--port=$Port")
    if ($NoBrowser.IsPresent) {
        $serverArgs += '--no-browser'
    }

    $result = Invoke-VcfCheckServerManager -Python $python -ManagerScript $managerScript -Arguments $serverArgs
    if ($result.ExitCode -ne 0) {
        throw [System.Exception]::new("Manage-VcfCheckServer.py exited with code $($result.ExitCode): $($result.Output -join '; ')")
    }

    if ($Background) {
        Write-LogMessage -Type INFO -Message "Background server started. Use Stop-VcfCheckServer to stop it."
        return 0
    }

    Write-LogMessage -Type INFO -Message "Server started"
    Write-LogMessage -Type INFO -Message "Press Ctrl+C to stop the server"

    if (-not $NoBrowser.IsPresent) {
        Start-Sleep -Milliseconds 500
        $url = "http://127.0.0.1:$Port"
        if ($IsWindows) {
            Start-Process -FilePath $url
        } elseif ($IsMacOS) {
            Start-Process -FilePath 'open' -ArgumentList $url
        } elseif ($IsLinux) {
            Start-Process -FilePath 'xdg-open' -ArgumentList $url
        } else {
            Write-LogMessage -Type WARNING -Message "Unable to detect platform to auto-open a browser. Open $url manually."
        }
    }

    return 0
}
function Stop-VcfCheckServer {

    <#
        .SYNOPSIS
        Stops the bundled Python report viewer if it is running.

        .DESCRIPTION
        Stops the PID-file-tracked process (via Manage-VcfCheckServer.py stop), then
        independently re-checks Port: if something is still listening on it - whether that's
        the same process not yet dead, or an entirely untracked process that never had a PID
        file (e.g. started by invoking Start-VcfCheckServer.py directly) - it is killed too.
        This second check is what makes -Force on Start-VcfCheckServer actually reliable.

        If $env:VcfCheckBaseDirectory is not set or no longer exists (e.g. a fresh session
        that never ran Initialize-VcfCheck), the tracked-server stop is skipped - there is no
        PID file to read - and only the Port-based check below runs.

        .PARAMETER Port
        TCP port to check for a lingering listener after the tracked process is stopped.
        Default 8766.

        .OUTPUTS
        None.

        .EXAMPLE
        Stop-VcfCheckServer
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 65535)] [Int]$Port = 8766
    )

    $baseDirectory = ([String]$env:VcfCheckBaseDirectory).Trim()
    if (-not [String]::IsNullOrWhiteSpace($baseDirectory) -and (Test-Path -LiteralPath $baseDirectory -PathType Container)) {
        $python = Find-VcfCheckPythonInterpreter
        $managerScript = Join-Path -Path (Join-Path -Path $baseDirectory -ChildPath 'Tools') -ChildPath 'Manage-VcfCheckServer.py'
        Invoke-VcfCheckServerManager -Python $python -ManagerScript $managerScript `
            -Arguments @('stop') | Out-Null
    } else {
        Write-LogMessage -Type INFO -Message 'VcfCheck has not been set up in this session - checking the port directly instead of the tracked server state.'
    }

    $portOwner = Get-VcfCheckTcpListenerProcessId -Port $Port
    if ($null -ne $portOwner) {
        Write-LogMessage -Type WARNING -Message "Port $Port is still held by process $portOwner after stopping the tracked server (it may be an untracked process with no PID file) - stopping it too."
        Stop-Process -Id $portOwner -ErrorAction SilentlyContinue
    }
}
function Get-VcfCheckServerStatus {

    <#
        .SYNOPSIS
        Reports whether the bundled Python report viewer is currently running.

        .DESCRIPTION
        If $env:VcfCheckBaseDirectory is not set or no longer exists (e.g. a fresh session
        that never ran Initialize-VcfCheck), there is no PID-file-tracked server to report on
        - VcfCheck was never started from this working directory - so this reports Running =
        $false directly instead of erroring.

        .OUTPUTS
        [PSObject] with Running/Pid/Port properties.

        .EXAMPLE
        Get-VcfCheckServerStatus
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param ()

    $baseDirectory = ([String]$env:VcfCheckBaseDirectory).Trim()
    if ([String]::IsNullOrWhiteSpace($baseDirectory) -or -not (Test-Path -LiteralPath $baseDirectory -PathType Container)) {
        Write-LogMessage -Type INFO -Message 'VcfCheck has not been set up in this session - reporting no tracked server.'
        return [PSCustomObject]@{
            Running = $false
            Pid     = $null
            Port    = $null
        }
    }

    $python = Find-VcfCheckPythonInterpreter
    $managerScript = Join-Path -Path (Join-Path -Path $baseDirectory -ChildPath 'Tools') -ChildPath 'Manage-VcfCheckServer.py'
    $result = Invoke-VcfCheckServerManager -Python $python -ManagerScript $managerScript `
        -Arguments @('status')
    $parsed = $result.Output | ConvertFrom-Json -ErrorAction Stop

    return [PSCustomObject]@{
        Running = [Bool]$parsed.running
        Pid     = $parsed.pid
        Port    = $parsed.port
    }
}
function Restart-VcfCheckServer {

    <#
        .SYNOPSIS
        Stops and restarts the bundled Python report viewer.

        .PARAMETER Port
        TCP port to listen on. Default 8766.

        .PARAMETER NoBrowser
        Skip opening the report viewer in the default browser after restarting.

        .PARAMETER Force
        Forwarded to Start-VcfCheckServer - kill anything still holding Port (tracked or not)
        instead of failing.

        .OUTPUTS
        None.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 65535)] [Int]$Port = 8766,
        [Parameter(Mandatory = $false)] [Switch]$NoBrowser,
        [Parameter(Mandatory = $false)] [Switch]$Force
    )

    Stop-VcfCheckServer -Port $Port
    Start-VcfCheckServer -Port $Port -NoBrowser:$NoBrowser.IsPresent -Force:$Force.IsPresent
}

#endregion Tools
