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
#region Catalog
function Test-VcfCheckStrictJson {

    <#
        .SYNOPSIS
        Throws unless a file contains strictly valid JSON.

        .DESCRIPTION
        PowerShell's own ConvertFrom-Json is lenient about a trailing comma before a closing
        `}`/`]` - it silently accepts what is not actually valid JSON. Data/CheckCatalog.json is
        also read by Tools/Start-VcfCheckServer.py via Python's
        strict json.load, so a trailing comma that ConvertFrom-Json waves through still breaks
        the running server's /api/checks endpoint with a 500 - confirmed live (2026-08-04): the
        PowerShell engine ran every check normally while the file had a trailing comma, because
        nothing on the PowerShell side ever parsed it strictly. Uses
        System.Text.Json.JsonDocument's default (strict) parsing options - part of the PowerShell
        7 runtime already, no Add-Type needed - to catch that class of bug before ConvertFrom-Json
        ever runs.

        .PARAMETER Path
        Path to the JSON file to validate.

        .OUTPUTS
        None. Throws [System.InvalidOperationException] when the file is not strictly valid JSON.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $jsonDocument = $null
    try {
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse($content)
    } catch {
        throw [System.InvalidOperationException]::new("`"$Path`" is not strictly valid JSON (e.g. a trailing comma) - this can silently pass PowerShell's own ConvertFrom-Json while still breaking Python's json.load reading the same file: $($_.Exception.Message)")
    } finally {
        if ($jsonDocument) { $jsonDocument.Dispose() }
    }
}
function Get-VcfCheckCatalog {

    <#
        .SYNOPSIS
        Loads and caches Data/CheckCatalog.json.

        .DESCRIPTION
        The catalog is the single source of truth mapping a check ID to its
        implementing function, product area, blocking flag, and required connections.
        Discovery is deliberately explicit (this catalog) rather
        than reflection over Get-Command -Name 'Test-Vcf*', so check ordering is deterministic
        and metadata that reflection can't carry (Blocking, RequiresConnections) has a home.

        .PARAMETER Path
        Path to CheckCatalog.json. Defaults to $env:VcfCheckBaseDirectory\Data\CheckCatalog.json,
        falling back to the module's bundled copy if the environment variable is unset (useful
        for tests that haven't called Initialize-VcfCheck).

        .PARAMETER Force
        Bypasses the in-memory cache and reloads from disk.

        .OUTPUTS
        [Hashtable] keyed by check id.

        .EXAMPLE
        $catalog = Get-VcfCheckCatalog
        $catalog['sddc_lock_table'].Function
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Path = '',
        [Parameter(Mandatory = $false)] [Switch]$Force
    )

    if ($Script:VcfCheckCatalogCache -and -not $Force) {
        return $Script:VcfCheckCatalogCache
    }

    $resolvedPath = $Path
    if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
        if (-not [String]::IsNullOrWhiteSpace($env:VcfCheckBaseDirectory)) {
            $candidate = Join-Path -Path $env:VcfCheckBaseDirectory.Trim() -ChildPath 'Data/CheckCatalog.json'
            if (Test-Path -LiteralPath $candidate) { $resolvedPath = $candidate }
        }
        if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
            $moduleRoot = Split-Path -Parent $PSScriptRoot
            $resolvedPath = Join-Path -Path $moduleRoot -ChildPath 'Data/CheckCatalog.json'
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new("Check catalog not found at `"$resolvedPath`".")
    }

    Test-VcfCheckStrictJson -Path $resolvedPath

    try {
        $raw = Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 10 -AsHashtable -ErrorAction Stop
    } catch {
        # ConvertFrom-Json's own error (e.g. "unexpected character... line 1, position 25") never
        # names the file it was parsing - unhelpful when this same catalog is also read by
        # Tools/Start-VcfCheckServer.py, so a syntax typo could otherwise be diagnosed from
        # either side without knowing which file to actually go fix.
        throw [System.InvalidOperationException]::new("`"$resolvedPath`" is not valid JSON: $($_.Exception.Message)")
    }
    $Script:VcfCheckCatalogCache = $raw
    return $raw
}
function Resolve-VcfCheckCheckList {

    <#
        .SYNOPSIS
        Resolves an ordered list of checks to run from the catalog.

        .DESCRIPTION
        Cross-references Get-VcfCheckCatalog to build a de-duplicated, ordered dispatch list.
        When CheckId is empty, every check in the catalog is returned (in catalog order) - the
        "full run" path.

        .PARAMETER CheckId
        One or more explicit check IDs to run. Empty (default) runs every check in the catalog.

        .OUTPUTS
        [PSCustomObject[]] each with Id, Function, Area, DisplayName, Blocking,
        RequiresConnections, RequiresSddcManagerRootCredential.

        .EXAMPLE
        Resolve-VcfCheckCheckList -CheckId 'sddc_lock_table', 'sddc_bom_check'
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $false)] [String[]]$CheckId = @()
    )

    $catalog = Get-VcfCheckCatalog
    $orderedIds = @()
    if ($CheckId.Count -gt 0) {
        $seenIds = [System.Collections.Generic.HashSet[String]]::new()
        foreach ($id in $CheckId) {
            if ($seenIds.Add($id)) {
                $orderedIds += $id
            }
        }
    } else {
        $orderedIds = @($catalog.Keys)
    }

    $resolved = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($id in $orderedIds) {
        if (-not $catalog.ContainsKey($id)) {
            throw [System.InvalidOperationException]::new("Check id `"$id`" is not present in the check catalog.")
        }
        $entry = $catalog[$id]
        $resolved.Add([PSCustomObject]@{
            Id                                 = $id
            Function                           = $entry.function
            Area                               = $entry.area
            DisplayName                        = $entry.displayName
            Blocking                           = [bool]$entry.blocking
            RequiresConnections                = @($entry.requiresConnections)
            RequiresSddcManagerRootCredential   = [bool]$entry.requiresSddcManagerRootCredential
        })
    }

    return $resolved.ToArray()
}
#endregion Catalog
