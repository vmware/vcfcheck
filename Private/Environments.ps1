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
#region Environments
#
# Multi-environment support: environments.json holds an array of named SDDC Manager targets
# (Id/Name/SddcManagerFqdn/SddcManagerUser/EnableRootCredentialChecks/CreatedAt/UpdatedAt) so the
# browser UI can manage more than one target without re-typing the FQDN/username every time. Per
# Get-VcfCheckSettings's existing rule (Private/Settings.ps1) and requirements, a password
# is NEVER part of this file - Save-VcfCheckEnvironments hard-fails (not just warns) if any
# environment object (including nested Integrations/Endpoints entries) carries a password-shaped
# key, since this file is reachable from the browser's Add/Edit form and not just from a
# hand-edited config.
#
# Integrations is an optional array of components attached to the environment that SDDC Manager
# has zero knowledge of (e.g. a standalone Aria Operations instance deployed outside SDDC
# Manager/VRSLCM). Each entry: Type ('AriaOperations' today), SharedCredentials (bool),
# Username (used by every endpoint when SharedCredentials is true), and Endpoints (array of
# Name/Fqdn, plus its own Username when SharedCredentials is false). See
# Get-VcfCheckEnvironmentAriaOpsEndpoints (Private/AriaOpsHelpers.ps1) for how a check resolves
# this into connectable targets. Passwords are never stored here either way - always resolved at
# run time (session-only prompt/launcher param), keyed by whichever username applies.
#
# CRUD for the browser UI itself lives in Start-VcfCheckServer.py (plain JSON list edits, no
# subprocess needed) - the functions here exist so Invoke-VcfCheck/CLI users get the same
# capability from the module directly, both sides agreeing on the same file/schema.

function Find-VcfCheckPasswordLikePropertyName {

    <#
        .SYNOPSIS
        Recursively searches an object (including nested Integrations/Endpoints arrays) for a
        password-shaped property name.

        .DESCRIPTION
        Shared by Get-VcfCheckEnvironments (read-time warning) and Save-VcfCheckEnvironments
        (write-time hard failure) so both scan the same way. A flat, top-level-only scan would
        miss a password entered on a nested Integrations[].Endpoints[] object, which is reachable
        from the browser's Add/Edit form exactly like every other field on an environment.

        .PARAMETER InputObject
        The object (or array) to scan.

        .OUTPUTS
        [String] the first matching property name found, or $null if none.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [Object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [String]) {
        foreach ($item in $InputObject) {
            $found = Find-VcfCheckPasswordLikePropertyName -InputObject $item
            if ($found) {
                return $found
            }
        }
        return $null
    }

    if ($InputObject.PSObject -and $InputObject.PSObject.Properties) {
        # Only NoteProperty members are followed - the kind ConvertFrom-Json/PSCustomObject
        # literals produce for actual data fields. Adapted .NET properties (e.g. DateTime.Date,
        # which itself returns a DateTime) are excluded on purpose: recursing into those causes
        # infinite recursion (DateTime.Date.Date.Date...), confirmed live when CreatedAt/UpdatedAt
        # round-tripped through ConvertFrom-Json as [DateTime] rather than [String].
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($property.MemberType -ne 'NoteProperty') {
                continue
            }
            if ($property.Name -match '(?i)password') {
                return $property.Name
            }
            $found = Find-VcfCheckPasswordLikePropertyName -InputObject $property.Value
            if ($found) {
                return $found
            }
        }
    }

    return $null
}
function Get-VcfCheckEnvironments {

    <#
        .SYNOPSIS
        Loads the list of saved environments from environments.json.

        .DESCRIPTION
        Returns an empty array if environments.json does not exist and there is nothing to
        migrate. If environments.json does not exist yet but settings.json (Get-VcfCheckSettings)
        has SddcManagerFqdn/SddcManagerUser, synthesizes a single environment from it and persists
        that migration immediately, so an existing single-environment user's setup is not lost.

        .PARAMETER Path
        Path to environments.json. When omitted, resolved from
        $env:VcfCheckBaseDirectory\Config\environments.json.

        .PARAMETER SettingsPath
        Path to settings.json, used only for the one-time migration described above. When
        omitted, resolved the same way Get-VcfCheckSettings resolves it by default.

        .OUTPUTS
        [Object[]] of environment PSCustomObjects (Id, Name, SddcManagerFqdn, SddcManagerUser,
        EnableRootCredentialChecks, CreatedAt, UpdatedAt), or an empty array.

        .EXAMPLE
        $environments = Get-VcfCheckEnvironments
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Path = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$SettingsPath = ''
    )

    $resolvedPath = Resolve-VcfCheckEnvironmentsPath -Path $Path

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        $settings = $null
        try {
            $settings = Get-VcfCheckSettings -Path $SettingsPath
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not read settings.json while checking for an environments migration: $($_.Exception.Message)"
        }

        if (-not $settings -or [String]::IsNullOrWhiteSpace($settings.SddcManagerFqdn) -or [String]::IsNullOrWhiteSpace($settings.SddcManagerUser)) {
            return @()
        }

        $migratedAt = (Get-Date).ToUniversalTime().ToString('o')
        $migrated = @([PSCustomObject]@{
            Id                         = New-VcfCheckEnvironmentId
            Name                       = $settings.SddcManagerFqdn
            SddcManagerFqdn            = $settings.SddcManagerFqdn
            SddcManagerUser            = $settings.SddcManagerUser
            EnableRootCredentialChecks = $false
            CreatedAt                  = $migratedAt
            UpdatedAt                  = $migratedAt
        })

        Write-LogMessage -Type INFO -Message "Migrated settings.json's single SDDC Manager target into environments.json as `"$($migrated[0].Name)`"."
        Save-VcfCheckEnvironments -Environments $migrated -Path $resolvedPath
        return $migrated
    }

    try {
        $raw = @(Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 10 -ErrorAction Stop)
    } catch {
        throw [System.InvalidOperationException]::new("Failed to parse environments file `"$resolvedPath`": $($_.Exception.Message)")
    }

    foreach ($environment in $raw) {
        $passwordLikeProperties = @($environment.PSObject.Properties.Name | Where-Object { $_ -match '(?i)password' })
        foreach ($passwordLikeProperty in $passwordLikeProperties) {
            Write-LogMessage -Type WARNING -Message "environments.json at `"$resolvedPath`" contains a `"$passwordLikeProperty`" field on environment `"$($environment.Name)`". This value will be ignored - VcfCheck never reads a password from disk."
            $environment.PSObject.Properties.Remove($passwordLikeProperty)
        }

        $nestedPasswordLikeProperty = Find-VcfCheckPasswordLikePropertyName -InputObject $environment.Integrations
        if ($nestedPasswordLikeProperty) {
            Write-LogMessage -Type WARNING -Message "environments.json at `"$resolvedPath`" contains a `"$nestedPasswordLikeProperty`" field nested under Integrations on environment `"$($environment.Name)`". This value will be ignored - VcfCheck never reads a password from disk. Remove it by re-saving the environment via the UI."
        }
    }

    return $raw
}
function Save-VcfCheckEnvironments {

    <#
        .SYNOPSIS
        Persists the full list of environments to environments.json.

        .DESCRIPTION
        Writes atomically (temp file in the same directory, then Move-Item -Force) so a reader
        never observes a partially-written file. Hard-fails if any environment object carries a
        password-shaped property name - this is a write-time guardrail (not just the read-time
        warning Get-VcfCheckEnvironments/Get-VcfCheckSettings give), because this path is
        reachable from the browser's Add/Edit form, not only from a hand-edited config file.

        .PARAMETER Environments
        The full array of environment objects to write (not a delta - callers read, mutate, and
        pass back the complete list).

        .PARAMETER Path
        Path to environments.json. When omitted, resolved from
        $env:VcfCheckBaseDirectory\Config\environments.json.

        .OUTPUTS
        None.

        .EXAMPLE
        Save-VcfCheckEnvironments -Environments $environments
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$Environments,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Path = ''
    )

    foreach ($environment in $Environments) {
        $passwordLikeProperty = Find-VcfCheckPasswordLikePropertyName -InputObject $environment
        if ($passwordLikeProperty) {
            throw [System.InvalidOperationException]::new("Environment `"$($environment.Name)`" carries a `"$passwordLikeProperty`" field (top-level or nested under Integrations). environments.json may never contain a password - resolve it interactively or via the launcher's session-only credential fields instead.")
        }
    }

    $resolvedPath = Resolve-VcfCheckEnvironmentsPath -Path $Path
    $parentDirectory = Split-Path -Path $resolvedPath -Parent
    if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
        $null = New-VcfCheckOwnerOnlyDirectory -Path $parentDirectory -Force
    }

    $json = $null
    foreach ($depth in @(5, 3, 2)) {
        try {
            $json = $Environments | ConvertTo-Json -Depth $depth -ErrorAction Stop
            break
        }
        catch {
            if ($depth -eq 2) {
                throw $_
            }
        }
    }
    $tempPath = Join-Path -Path $parentDirectory -ChildPath "environments.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        Set-Content -LiteralPath $tempPath -Value $json -ErrorAction Stop
        Move-Item -LiteralPath $tempPath -Destination $resolvedPath -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}
function New-VcfCheckEnvironmentId {

    <#
        .SYNOPSIS
        Generates a short, unique environment id.

        .DESCRIPTION
        Matches the run-id length convention used server-side
        (Tools/Start-VcfCheckServer.py's uuid.uuid4().hex[:12]).

        .OUTPUTS
        [String] a 12-character lowercase hex id.

        .EXAMPLE
        $id = New-VcfCheckEnvironmentId
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    return [Guid]::NewGuid().ToString('N').Substring(0, 12)
}
function Test-VcfCheckEnvironmentIsValid {

    <#
        .SYNOPSIS
        Validates an environment's required fields.

        .DESCRIPTION
        Shared by Add-VcfCheckEnvironment and Set-VcfCheckEnvironment so both paths apply
        the same rules: Name, SddcManagerFqdn, and SddcManagerUser must all be non-empty.

        .PARAMETER Environment
        The environment object to validate.

        .OUTPUTS
        [PSObject] with IsValid (bool) and Errors (string[]).

        .EXAMPLE
        $validation = Test-VcfCheckEnvironmentIsValid -Environment $environment
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Environment
    )

    $errors = [System.Collections.Generic.List[String]]::new()

    if ([String]::IsNullOrWhiteSpace($Environment.Name)) {
        $errors.Add('Name must not be empty.')
    }
    if ([String]::IsNullOrWhiteSpace($Environment.SddcManagerFqdn)) {
        $errors.Add('SddcManagerFqdn must not be empty.')
    }
    if ([String]::IsNullOrWhiteSpace($Environment.SddcManagerUser)) {
        $errors.Add('SddcManagerUser must not be empty.')
    }

    foreach ($integration in @($Environment.Integrations)) {
        if (-not $integration) {
            continue
        }
        if ([String]::IsNullOrWhiteSpace($integration.Type)) {
            $errors.Add('Each integration must have a Type.')
        }
        if ($integration.SharedCredentials -and [String]::IsNullOrWhiteSpace($integration.Username)) {
            $errors.Add("Integration `"$($integration.Type)`" has SharedCredentials enabled but no Username.")
        }
        $endpoints = @($integration.Endpoints)
        if ($endpoints.Count -eq 0) {
            $errors.Add("Integration `"$($integration.Type)`" must have at least one endpoint.")
        }
        foreach ($endpoint in $endpoints) {
            if ([String]::IsNullOrWhiteSpace($endpoint.Name)) {
                $errors.Add("Integration `"$($integration.Type)`" has an endpoint with no Name.")
            }
            if ([String]::IsNullOrWhiteSpace($endpoint.Fqdn)) {
                $errors.Add("Integration `"$($integration.Type)`" endpoint `"$($endpoint.Name)`" has no Fqdn.")
            }
            if (-not $integration.SharedCredentials -and [String]::IsNullOrWhiteSpace($endpoint.Username)) {
                $errors.Add("Integration `"$($integration.Type)`" endpoint `"$($endpoint.Name)`" has no Username (SharedCredentials is disabled, so each endpoint needs its own).")
            }
        }
    }

    return [PSCustomObject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = $errors.ToArray()
    }
}
function Add-VcfCheckEnvironment {

    <#
        .SYNOPSIS
        Creates and persists a new saved environment.

        .PARAMETER Name
        Friendly display name.

        .PARAMETER SddcManagerFqdn
        SDDC Manager FQDN.

        .PARAMETER SddcManagerUser
        SDDC Manager username.

        .PARAMETER EnableRootCredentialChecks
        Whether checks that require the SDDC Manager appliance root credential (VMware Tools
        guest operations) should be offered/run for this environment.

        .PARAMETER Path
        Path to environments.json. When omitted, resolved from
        $env:VcfCheckBaseDirectory\Config\environments.json.

        .OUTPUTS
        [PSObject] the newly created environment.

        .EXAMPLE
        Add-VcfCheckEnvironment -Name 'Production East' -SddcManagerFqdn 'sddc.example.com' -SddcManagerUser 'administrator@vsphere.local'
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Name,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SddcManagerFqdn,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SddcManagerUser,
        [Parameter(Mandatory = $false)] [Bool]$EnableRootCredentialChecks = $false,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$Integrations = @(),
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Path = ''
    )

    $resolvedPath = Resolve-VcfCheckEnvironmentsPath -Path $Path
    $environments = [System.Collections.Generic.List[Object]]::new()
    # @(...) wraps the call before assignment - Get-VcfCheckEnvironments returning an empty
    # array is otherwise unrolled to $null by PowerShell's pipeline output semantics, which would
    # make AddRange($null) throw ([Object[]]$null stays $null, it does not coerce to an empty
    # array the way @($null-returning-call) does).
    $environments.AddRange(@(Get-VcfCheckEnvironments -Path $resolvedPath -SettingsPath (Resolve-VcfCheckSettingsPathSibling -EnvironmentsPath $resolvedPath)))

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $newEnvironment = [PSCustomObject]@{
        Id                         = New-VcfCheckEnvironmentId
        Name                       = $Name
        SddcManagerFqdn            = $SddcManagerFqdn
        SddcManagerUser            = $SddcManagerUser
        EnableRootCredentialChecks = $EnableRootCredentialChecks
        Integrations               = @($Integrations)
        CreatedAt                  = $now
        UpdatedAt                  = $now
    }

    $validation = Test-VcfCheckEnvironmentIsValid -Environment $newEnvironment
    if (-not $validation.IsValid) {
        throw [System.InvalidOperationException]::new("Cannot add environment: $($validation.Errors -join ' ')")
    }

    $environments.Add($newEnvironment)
    Save-VcfCheckEnvironments -Environments $environments.ToArray() -Path $resolvedPath
    return $newEnvironment
}
function Set-VcfCheckEnvironment {

    <#
        .SYNOPSIS
        Updates and persists an existing saved environment's fields.

        .DESCRIPTION
        Only fields actually supplied by the caller are changed - $PSBoundParameters is checked
        rather than defaulting every parameter, so a partial update (e.g. renaming only) does not
        clobber the other fields with empty defaults.

        .PARAMETER Id
        Id of the environment to update.

        .PARAMETER Name
        New friendly display name.

        .PARAMETER SddcManagerFqdn
        New SDDC Manager FQDN.

        .PARAMETER SddcManagerUser
        New SDDC Manager username.

        .PARAMETER EnableRootCredentialChecks
        New root-credential-checks setting.

        .PARAMETER Path
        Path to environments.json. When omitted, resolved from
        $env:VcfCheckBaseDirectory\Config\environments.json.

        .OUTPUTS
        [PSObject] the updated environment.

        .EXAMPLE
        Set-VcfCheckEnvironment -Id 'a1b2c3d4e5f6' -Name 'Production East (renamed)'
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Id,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Name = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$SddcManagerFqdn = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$SddcManagerUser = '',
        [Parameter(Mandatory = $false)] [Bool]$EnableRootCredentialChecks,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$Integrations,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Path = ''
    )

    $resolvedPath = Resolve-VcfCheckEnvironmentsPath -Path $Path
    $environments = @(Get-VcfCheckEnvironments -Path $resolvedPath -SettingsPath (Resolve-VcfCheckSettingsPathSibling -EnvironmentsPath $resolvedPath))
    $existing = $environments | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $existing) {
        throw [System.InvalidOperationException]::new("No environment found with id `"$Id`".")
    }

    if ($PSBoundParameters.ContainsKey('Name')) { $existing.Name = $Name }
    if ($PSBoundParameters.ContainsKey('SddcManagerFqdn')) { $existing.SddcManagerFqdn = $SddcManagerFqdn }
    if ($PSBoundParameters.ContainsKey('SddcManagerUser')) { $existing.SddcManagerUser = $SddcManagerUser }
    if ($PSBoundParameters.ContainsKey('EnableRootCredentialChecks')) { $existing.EnableRootCredentialChecks = $EnableRootCredentialChecks }
    if ($PSBoundParameters.ContainsKey('Integrations')) {
        if ($existing.PSObject.Properties.Name -contains 'Integrations') {
            $existing.Integrations = @($Integrations)
        } else {
            $existing | Add-Member -MemberType NoteProperty -Name Integrations -Value @($Integrations)
        }
    }
    $existing.UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')

    $validation = Test-VcfCheckEnvironmentIsValid -Environment $existing
    if (-not $validation.IsValid) {
        throw [System.InvalidOperationException]::new("Cannot update environment: $($validation.Errors -join ' ')")
    }

    Save-VcfCheckEnvironments -Environments $environments -Path $resolvedPath
    return $existing
}
function Remove-VcfCheckEnvironment {

    <#
        .SYNOPSIS
        Removes and persists the removal of a saved environment.

        .PARAMETER Id
        Id of the environment to remove.

        .PARAMETER Path
        Path to environments.json. When omitted, resolved from
        $env:VcfCheckBaseDirectory\Config\environments.json.

        .OUTPUTS
        None.

        .EXAMPLE
        Remove-VcfCheckEnvironment -Id 'a1b2c3d4e5f6'
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Id,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Path = ''
    )

    $resolvedPath = Resolve-VcfCheckEnvironmentsPath -Path $Path
    $environments = @(Get-VcfCheckEnvironments -Path $resolvedPath -SettingsPath (Resolve-VcfCheckSettingsPathSibling -EnvironmentsPath $resolvedPath))
    $remaining = @($environments | Where-Object { $_.Id -ne $Id })
    if ($remaining.Count -eq $environments.Count) {
        throw [System.InvalidOperationException]::new("No environment found with id `"$Id`".")
    }

    Save-VcfCheckEnvironments -Environments $remaining -Path $resolvedPath
}
function Resolve-VcfCheckEnvironmentsPath {

    <#
        .SYNOPSIS
        Resolves the effective environments.json path.

        .DESCRIPTION
        Internal helper shared by every function in this file - not exported (absent from
        VcfCheck.psd1's FunctionsToExport), matching how path-resolution logic elsewhere
        in this module is inlined per-function rather than sharing an unexported helper; separated
        here only because five functions in this file all need the identical resolution.

        .PARAMETER Path
        Explicit override. When empty, resolved from
        $env:VcfCheckBaseDirectory\Config\environments.json.

        .OUTPUTS
        [String]
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Path = ''
    )

    if (-not [String]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([String]::IsNullOrWhiteSpace($env:VcfCheckBaseDirectory)) {
        throw [System.InvalidOperationException]::new('No environments.json path was provided and $env:VcfCheckBaseDirectory is not set.')
    }

    return Join-Path -Path $env:VcfCheckBaseDirectory.Trim() -ChildPath (Join-Path -Path $Script:CHECK_CONFIG_DIR_NAME -ChildPath $Script:CHECK_ENVIRONMENTS_FILE_NAME)
}
function Resolve-VcfCheckSettingsPathSibling {

    <#
        .SYNOPSIS
        Resolves the settings.json path that lives alongside a given (already-resolved)
        environments.json path.

        .DESCRIPTION
        Add-/Set-/Remove-VcfCheckEnvironment must pass this to Get-VcfCheckEnvironments's
        -SettingsPath explicitly rather than letting it default - Get-VcfCheckSettings's own
        default falls back to $env:VcfCheckBaseDirectory, which is only correct when
        -EnvironmentsPath also came from that same env var. Calling
        Add-VcfCheckEnvironment with an explicit -Path elsewhere (e.g. a test's own tempdir, or
        any caller not using the default base directory) still silently migrated the ambient
        default settings.json's SddcManagerFqdn/User into the explicitly-targeted environments
        file, mixing two unrelated targets. Deriving the sibling path from the resolved
        environments path instead keeps both files scoped to the same base directory in every
        case, matching Get-VcfCheckSettings' own default when neither override is given.

        .PARAMETER EnvironmentsPath
        The already-resolved (non-empty) environments.json path.

        .OUTPUTS
        [String]
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EnvironmentsPath
    )

    return Join-Path -Path (Split-Path -Path $EnvironmentsPath -Parent) -ChildPath $Script:CHECK_SETTINGS_FILE_NAME
}

#endregion Environments
