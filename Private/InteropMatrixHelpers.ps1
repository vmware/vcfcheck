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
#region InteropMatrixHelpers

$Script:VcfCheckInteropMatrixProductIds = @{
    'SDDC_MANAGER' = 851; 'VCENTER' = 2; 'ESX' = 1; 'NSX' = 912
    'VRA' = 114; 'VROPS' = 116; 'VRNI' = 285; 'VRO' = 13; 'VRSLCM' = 337; 'VRLI' = 88; 'VIDM' = 140
}
$Script:VcfCheckMarketingVersionAliasCache = @{}
function Get-VcfCheckMarketingVersionAliasMap {

    <#
        .SYNOPSIS
        Loads and caches one component's marketing-version alias data
        (Data/MarketingVersionAliases/EsxMarketingVersionAliases.json / Data/MarketingVersionAliases/VcenterMarketingVersionAliases.json).

        .PARAMETER Component
        'ESX' or 'VCENTER'.

        .OUTPUTS
        [Hashtable] marketing name -> @{ Version; ReleaseDate }, or an empty hashtable if the
        file is missing or fails to parse.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet('ESX', 'VCENTER')] [String]$Component
    )

    if (-not $Script:VcfCheckMarketingVersionAliasCache.ContainsKey($Component)) {
        $fileName = if ($Component -eq 'ESX') { 'EsxMarketingVersionAliases.json' } else { 'VcenterMarketingVersionAliases.json' }
        $path = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path '..' -ChildPath (Join-Path -Path 'Data' -ChildPath (Join-Path -Path 'MarketingVersionAliases' -ChildPath $fileName)))
        $map = @{}
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $map = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not parse marketing version alias file `"$path`": $($_.Exception.Message)"
                $map = @{}
            }
        }
        $Script:VcfCheckMarketingVersionAliasCache[$Component] = $map
    }

    return $Script:VcfCheckMarketingVersionAliasCache[$Component]
}
function Resolve-VcfCheckMarketingVersionAliasKeyFromBuild {

    <#
        .SYNOPSIS
        Resolves a live component's raw installed version string to its Broadcom Interop Matrix
        marketing release name (e.g. "8.0U3k"), so that name can be used as the Interop Matrix row
        key for a real compatibility-verdict lookup
        (Get-VcfCheckInteropMatrixCompatibilityVerdict).

        .DESCRIPTION
        A live vCenter/ESX self-reports a raw build number (e.g. "8.0.3.00600-24853646"), never a
        marketing name - matches by extracting the trailing digit run (the real public build
        number, same extraction Test-VcfCheckBomVersionMatch relies on for the same
        reason: separators before the build number are inconsistent, e.g. a period instead of a
        hyphen on some components) and searching the shipped alias data
        (Get-VcfCheckMarketingVersionAliasMap's backing file) for the marketing entry whose
        canonical version ends in that same build number.

        .PARAMETER Component
        'ESX' or 'VCENTER'.

        .PARAMETER RawVersion
        The raw version string as reported live by the component.

        .OUTPUTS
        [String] the matching marketing name (e.g. "8.0U3k"), or $null if RawVersion has no
        trailing digit run, or no alias entry's build number matches it.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet('ESX', 'VCENTER')] [String]$Component,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$RawVersion
    )

    $build = [Regex]::Match($RawVersion, '(\d+)$').Value
    if ([String]::IsNullOrEmpty($build)) { return $null }

    foreach ($kvp in (Get-VcfCheckMarketingVersionAliasMap -Component $Component).GetEnumerator()) {
        $entryBuild = [Regex]::Match([String]$kvp.Value.Version, '(\d+)$').Value
        if ($entryBuild -and $entryBuild -eq $build) {
            return $kvp.Key
        }
    }
    return $null
}

$Script:VcfCheckInteropMatrixDataFileNames = @{
    851 = 'SddcManager'; 1 = 'Esx'; 2 = 'Vcenter'; 912 = 'Nsx'
    114 = 'Vra'; 116 = 'Vrops'; 285 = 'Vrni'; 13 = 'Vro'; 337 = 'Vrslcm'; 88 = 'Vrli'; 140 = 'Vidm'
}
$Script:VcfCheckInteropMatrixDataCache = @{}
function Invoke-VcfCheckInteropMatrixUpgrades {

    <#
        .SYNOPSIS
        Loads one product's shipped Interop Matrix upgrade-path snapshot.

        .DESCRIPTION
        Reads Data/Interoperability/<ProductName>.json - a snapshot of the same public JSON
        endpoint the https://interopmatrix.broadcom.com "Download CSV" button reads from
        (POST /external/upgrades), captured at release-prep time by
        InternalTools/Update-VcfInteropMatrixData.ps1 and shipped with the product. That live endpoint
        requires a static x-auth-key header embedded in the site's own public JavaScript bundle -
        not a secret, but a value Broadcom could rotate or remove without notice, so calling it
        live from every precheck run would make a shipped product silently depend on it. Reading
        a shipped snapshot instead means a key rotation only ever affects the next scheduled
        regeneration, never a customer's live run.

        Returns only same-product upgrade-path data (which versions of this one product exist,
        and which can upgrade directly from which) - it does not expose cross-product
        compatibility (e.g. "is vCenter version A compatible with NSX version B"); no such public
        endpoint exists on this API (interoptype values other than 'upgrade' and 'database'
        return HTTP 400, and every release's 'components' field is consistently empty).

        .PARAMETER ProductId
        The interop matrix product ID, e.g. 851 (SDDC Manager), 1 (ESX), 2 (vCenter Server),
        912 (VMware NSX).

        .OUTPUTS
        [PSObject] the shipped snapshot (.name, .upgradeProducts[]), or $null if the file is
        missing or fails to parse - callers treat that as "could not confirm," never as "not
        compatible."
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [Int]$ProductId
    )

    if (-not $Script:VcfCheckInteropMatrixDataCache.ContainsKey($ProductId)) {
        $data = $null
        $fileName = $Script:VcfCheckInteropMatrixDataFileNames[$ProductId]
        if (-not $fileName) {
            Write-LogMessage -Type WARNING -Message "No shipped Interop Matrix data file is mapped to product ID ${ProductId}"
        } else {
            $path = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path '..' -ChildPath (Join-Path -Path 'Data' -ChildPath (Join-Path -Path 'Interoperability' -ChildPath "$fileName.json")))
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                try {
                    $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    Write-LogMessage -Type WARNING -Message "Could not parse Interop Matrix data file `"$path`": $($_.Exception.Message)"
                    $data = $null
                }
            } else {
                Write-LogMessage -Type WARNING -Message "No shipped Interop Matrix data file for product ID ${ProductId}: `"$path`" not found"
            }
        }
        $Script:VcfCheckInteropMatrixDataCache[$ProductId] = $data
    }

    return $Script:VcfCheckInteropMatrixDataCache[$ProductId]
}
function Test-VcfCheckInteropMatrixVersionPublished {

    <#
        .SYNOPSIS
        Confirms whether a version string is a real, published release of a product, per
        Broadcom's public Interop Matrix.

        .DESCRIPTION
        Used only as a fallback sanity check when a destination VCF release could not be resolved
        against SDDC Manager's own release catalog (Get-VcfCheckReleaseBom) - e.g. an
        air-gapped/offline SDDC Manager whose local catalog hasn't synced that release yet. This
        cannot validate compatibility (see Invoke-VcfCheckInteropMatrixUpgrades), only whether
        the requested version string corresponds to something Broadcom has actually shipped, so a
        typo'd or fictitious destination release doesn't silently fall through to
        minimum-version thresholds unnoticed.

        .PARAMETER ProductId
        The interop matrix product ID to check the version against.

        .PARAMETER Version
        The version string to look for, e.g. '9.1.0.0'.

        .OUTPUTS
        [Nullable[Boolean]] $true if the version was found, $false if the API responded but the
        version was not among any product/release version it returned, or $null if the API call
        itself failed (unknown, not a negative result).
    #>

    [CmdletBinding()]
    [OutputType([Nullable[Boolean]])]
    Param (
        [Parameter(Mandatory = $true)] [Int]$ProductId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Version
    )

    $response = Invoke-VcfCheckInteropMatrixUpgrades -ProductId $ProductId
    if (-not $response -or -not $response.upgradeProducts) {
        return $null
    }

    $knownVersions = [System.Collections.Generic.HashSet[String]]::new()
    foreach ($upgradeProduct in @($response.upgradeProducts)) {
        [void]$knownVersions.Add($upgradeProduct.version)
        foreach ($release in @($upgradeProduct.releases)) {
            [void]$knownVersions.Add($release.version)
        }
    }

    return $knownVersions.Contains($Version)
}
function Resolve-VcfCheckInteropMatrixSourceProduct {

    <#
        .SYNOPSIS
        Resolves one component's shipped Interop Matrix snapshot to the top-level upgradeProducts
        entry matching an installed version, shared by
        Get-VcfCheckInteropMatrixCompatibilityVerdict and
        Get-VcfCheckInteropMatrixFailureReason so the marketing-name-vs-parsed-version
        resolution rule (see Get-VcfCheckInteropMatrixCompatibilityVerdict's .DESCRIPTION)
        lives in exactly one place.

        .PARAMETER Component
        'SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI',
        or 'VIDM'.

        .PARAMETER InstalledVersion
        The component's raw installed version string, as reported live.

        .OUTPUTS
        [PSObject] the matching upgradeProducts entry (carrying that release's own .genGuided /
        .techGuided / .releases[]), or $null if the snapshot is unreachable or no entry matches.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet('SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI', 'VIDM')] [String]$Component,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InstalledVersion
    )

    $response = Invoke-VcfCheckInteropMatrixUpgrades -ProductId $Script:VcfCheckInteropMatrixProductIds[$Component]
    if (-not $response -or -not $response.upgradeProducts) { return $null }

    $installedMajor = [Regex]::Match($InstalledVersion, '\d+')
    $useMarketingName = ($Component -in @('ESX', 'VCENTER')) -and $installedMajor.Success -and ([Int]$installedMajor.Value -lt 9)

    if ($useMarketingName) {
        $marketingKey = Resolve-VcfCheckMarketingVersionAliasKeyFromBuild -Component $Component -RawVersion $InstalledVersion
        if (-not $marketingKey) { return $null }
        return $response.upgradeProducts | Where-Object { $_.version -eq $marketingKey } | Select-Object -First 1
    }

    $installedParsed = ConvertTo-VcfCheckSimpleVersion -VersionString $InstalledVersion
    if (-not $installedParsed) { return $null }
    return $response.upgradeProducts | Where-Object { (ConvertTo-VcfCheckSimpleVersion -VersionString $_.version) -eq $installedParsed } | Select-Object -First 1
}
function Get-VcfCheckInteropMatrixFailureReason {

    <#
        .SYNOPSIS
        Builds a human-readable reason a component's installed-to-destination upgrade pair is not
        ready to upgrade, per Broadcom's public Interop Matrix.

        .DESCRIPTION
        Distinguishes the two failure shapes the matrix actually reports for failure reason reporting:
        - An explicit release-date-based (or similar) incompatibility for this exact pair
          (status 2) - returned as "Incompatible - <Broadcom's own footnote text>".
        - The installed release itself being past its own support window (its .genGuided /
          .techGuided flags), independent of any specific destination - returned as
          "Not Supported - Past End of General Support" or "...Technical Guidance".

        .PARAMETER Component
        'SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI',
        or 'VIDM'.

        .PARAMETER InstalledVersion
        The component's raw installed version string, as reported live.

        .PARAMETER DestinationVersion
        The destination VCF release version, e.g. '9.1.0.0'.

        .OUTPUTS
        [String] the failure reason, or $null if the pair could not be resolved in the shipped
        snapshot (unknown - callers should fall back to their own minimum-version message) or the
        pair is actually compatible.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet('SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI', 'VIDM')] [String]$Component,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InstalledVersion,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DestinationVersion
    )

    $sourceProduct = Resolve-VcfCheckInteropMatrixSourceProduct -Component $Component -InstalledVersion $InstalledVersion
    if (-not $sourceProduct) { return $null }

    $destinationParsed = ConvertTo-VcfCheckSimpleVersion -VersionString $DestinationVersion
    if (-not $destinationParsed) { return $null }
    $releaseEntry = $sourceProduct.releases | Where-Object { (ConvertTo-VcfCheckSimpleVersion -VersionString $_.version) -eq $destinationParsed } | Select-Object -First 1

    if ($releaseEntry -and [Int]$releaseEntry.status -eq 2) {
        $footnote = if ([String]::IsNullOrWhiteSpace($releaseEntry.footnotes)) { "Broadcom's Interop Matrix flags this direct upgrade path unsupported, you may need to perform a data migration instead" } else { $releaseEntry.footnotes }
        return "Incompatible - $footnote"
    }
    if ($sourceProduct.genGuided -eq $false -and $sourceProduct.techGuided -eq $false) {
        return 'Not Supported - Past End of General Support'
    }
    if ($sourceProduct.genGuided -eq $false) {
        return 'Not Supported - Past End of Technical Guidance'
    }
    return $null
}
function Get-VcfCheckInteropMatrixCompatibilityVerdict {

    <#
        .SYNOPSIS
        Looks up the real, specific upgrade-path compatibility verdict for one component between
        an installed version and a destination version, from Broadcom's public Interop Matrix -
        the primary data source for BOM compliance decisions.

        .DESCRIPTION
        A floor (>=) comparison only approximates compatibility and misses Broadcom's real
        upgrade-path exceptions - confirmed live: ESX "8.0U2f" to VCF ESX release 9.1.0.0100 is
        flagged Incompatible by the matrix (a release-date-based exception: 8.0U2f's own release
        date is later than 9.1.0.0100's) despite clearing any numeric floor. This function reads
        that matrix's own per-version-pair status field directly instead of approximating it.

        Resolution: for ESX/vCenter, InstalledVersion is first resolved to its Interop Matrix
        marketing-name row (Resolve-VcfCheckMarketingVersionAliasKeyFromBuild) since the matrix
        labels pre-VCF9 releases that way and no live API ever reports a marketing name. For
        NSX/SDDC Manager, and for any VCF9+ installed version (already in the matrix's own
        unified numeric format), InstalledVersion is matched by parsed-version equality instead -
        exact string matching would be brittle against formatting differences like a missing
        leading zero (e.g. "9.1.0.100" vs the matrix's own "9.1.0.0100").

        DestinationVersion is always matched by parsed-version equality against that row's
        releases[] entries, since a chosen destination is always a VCF9+ unified numeric release
        (the default destination-release floor is 9.0.0.0).

        .PARAMETER Component
        'SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI',
        or 'VIDM'. The Aria Suite components (VRA/VROPS/VRNI/VRO/VRSLCM/VRLI/VIDM) always report a
        unified numeric build live, so - unlike ESX/VCENTER - they are matched by parsed-version
        equality, never a marketing-name lookup.

        .PARAMETER InstalledVersion
        The component's raw installed version string, as reported live.

        .PARAMETER DestinationVersion
        The destination VCF release version, e.g. '9.1.0.0'.

        .OUTPUTS
        [String] 'Compatible' or 'Incompatible' when the matrix has a real verdict for this exact
        pair; otherwise $null (unknown - could not resolve a row, the pair isn't listed, or the
        shipped snapshot couldn't be read), meaning the caller should fall back to a floor
        comparison instead of treating $null as either a pass or a fail.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet('SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI', 'VIDM')] [String]$Component,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InstalledVersion,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DestinationVersion
    )

    $sourceProduct = Resolve-VcfCheckInteropMatrixSourceProduct -Component $Component -InstalledVersion $InstalledVersion
    if (-not $sourceProduct) { return $null }

    $destinationParsed = ConvertTo-VcfCheckSimpleVersion -VersionString $DestinationVersion
    if (-not $destinationParsed) { return $null }
    $releaseEntry = $sourceProduct.releases | Where-Object { (ConvertTo-VcfCheckSimpleVersion -VersionString $_.version) -eq $destinationParsed } | Select-Object -First 1
    if (-not $releaseEntry -or $null -eq $releaseEntry.status) { return $null }

    switch ([Int]$releaseEntry.status) {
        { $_ -in @(1, 3) } { return 'Compatible' }
        2 { return 'Incompatible' }
        default { return $null }
    }
}
function Get-VcfCheckInteropMatrixMinimumCompatibleVersion {

    <#
        .SYNOPSIS
        Resolves one component's lowest installed version that Broadcom's public Interop Matrix
        marks Compatible for direct upgrade to a given destination version.

        .DESCRIPTION
        Callers use a minimum-version floor only as a fallback when
        Get-VcfCheckInteropMatrixCompatibilityVerdict cannot resolve a real per-pair verdict for
        the component's own actual installed version. That floor must itself come from the same
        shipped snapshot (Invoke-VcfCheckInteropMatrixUpgrades), never a hardcoded literal - a
        literal silently drifts out of sync with the matrix (e.g. VROPS 8.18.0-8.18.5 are flagged
        Incompatible for VCF 9.1.1.0, with 8.18.6 the actual floor). This scans every
        upgradeProducts entry, keeps the ones whose releases[] row for DestinationVersion has
        status 1 or 3 (Compatible - see Get-VcfCheckInteropMatrixCompatibilityVerdict), and
        returns the lowest such source version.

        .PARAMETER Component
        'SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI',
        or 'VIDM'.

        .PARAMETER DestinationVersion
        The destination VCF release version, e.g. '9.1.1.0'.

        .OUTPUTS
        [String] the lowest compatible source version string, or $null if the shipped snapshot is
        unreachable, has no resolvable status for DestinationVersion on any source version, or
        DestinationVersion itself doesn't parse - callers should fall back to their own last-resort
        floor default, never treat $null as "any version is compatible."
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet('SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI', 'VIDM')] [String]$Component,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DestinationVersion
    )

    $response = Invoke-VcfCheckInteropMatrixUpgrades -ProductId $Script:VcfCheckInteropMatrixProductIds[$Component]
    if (-not $response -or -not $response.upgradeProducts) { return $null }

    $destinationParsed = ConvertTo-VcfCheckSimpleVersion -VersionString $DestinationVersion
    if (-not $destinationParsed) { return $null }

    $compatibleSources = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($upgradeProduct in @($response.upgradeProducts)) {
        $releaseEntry = @($upgradeProduct.releases) | Where-Object { (ConvertTo-VcfCheckSimpleVersion -VersionString $_.version) -eq $destinationParsed } | Select-Object -First 1
        if (-not $releaseEntry -or $null -eq $releaseEntry.status -or [Int]$releaseEntry.status -notin @(1, 3)) { continue }
        $parsedSource = ConvertTo-VcfCheckSimpleVersion -VersionString $upgradeProduct.version
        if ($parsedSource) { $compatibleSources.Add([PSCustomObject]@{ Raw = $upgradeProduct.version; Parsed = $parsedSource }) }
    }
    if ($compatibleSources.Count -eq 0) { return $null }

    return ($compatibleSources | Sort-Object -Property Parsed | Select-Object -First 1).Raw
}
function Resolve-VcfCheckInteropMatrixReleaseInFamily {

    <#
        .SYNOPSIS
        Resolves a destination release family (major.minor.patch, e.g. '9.1.0') - or the literal
        'latest' - to one component's own newest concrete published release within that family,
        per its shipped Interop Matrix snapshot.

        .DESCRIPTION
        The top-level "VCF destination release" selector lets a user pick a release family rather
        than a specific 4th-digit patch build, since two components in the same VCF release train
        can ship a different newest patch (e.g. NSX 9.1.0.0300 while vCenter is still at
        9.1.0.0100) - a single shared concrete version would either miss a component's real
        latest patch or invent one it never shipped. Resolving independently per component
        against its own shipped snapshot (Invoke-VcfCheckInteropMatrixUpgrades) instead
        returns each component's real newest release in that family.

        Every version string appearing anywhere in the snapshot (both top-level upgradeProducts
        entries and their nested releases[]) is a real published release of this component, so
        the candidate pool is the union of both.

        .PARAMETER Component
        'SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI',
        or 'VIDM'.

        .PARAMETER Family
        A major.minor.patch string (e.g. '9.1.0'), or 'latest' for this component's overall
        newest known release regardless of family.

        .OUTPUTS
        [String] the resolved concrete version string (e.g. '9.1.0.0300'), or $null if the
        snapshot is unreachable/unparsable, or no release matches the requested family.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet('SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI', 'VIDM')] [String]$Component,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Family
    )

    $response = Invoke-VcfCheckInteropMatrixUpgrades -ProductId $Script:VcfCheckInteropMatrixProductIds[$Component]
    if (-not $response -or -not $response.upgradeProducts) { return $null }

    $candidates = @($response.upgradeProducts | ForEach-Object { $_.version }) +
        @($response.upgradeProducts | ForEach-Object { $_.releases } | Where-Object { $_ } | ForEach-Object { $_.version })

    $parsedCandidates = @($candidates | Where-Object { $_ } | Select-Object -Unique | ForEach-Object {
        $parsed = ConvertTo-VcfCheckSimpleVersion -VersionString $_
        if ($parsed) { [PSCustomObject]@{ Raw = $_; Parsed = $parsed } }
    })
    if ($parsedCandidates.Count -eq 0) { return $null }

    if ($Family -eq 'latest') {
        return ($parsedCandidates | Sort-Object -Property Parsed -Descending | Select-Object -First 1).Raw
    }

    $familyParsed = ConvertTo-VcfCheckSimpleVersion -VersionString $Family
    if (-not $familyParsed) { return $null }

    $inFamily = @($parsedCandidates | Where-Object {
        $_.Parsed.Major -eq $familyParsed.Major -and $_.Parsed.Minor -eq $familyParsed.Minor -and $_.Parsed.Build -eq $familyParsed.Build
    })
    if ($inFamily.Count -eq 0) { return $null }

    return ($inFamily | Sort-Object -Property Parsed -Descending | Select-Object -First 1).Raw
}

#endregion
