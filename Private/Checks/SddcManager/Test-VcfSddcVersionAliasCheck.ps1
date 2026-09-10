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
function Test-VcfSddcVersionAliasCheck {

    <#
        .SYNOPSIS
        Validates that every vCenter, ESX host, and NSX Manager across all VCF domains either
        matches the current release's declared BOM version directly, or is covered by a
        registered LCM version alias.

        .DESCRIPTION
        Queries SDDC Manager domains and verifies that vCenter, ESX host, and NSX Manager
        components match their domain's current release Bill of Materials (BOM) version or are
        covered by a registered LCM version alias.

        When async patches or hotfixes are applied to components, their exact version string may
        differ from the base BOM version. Registering version aliases in SDDC Manager maps these
        patch versions to expected base releases, preventing validation failures during lifecycle
        operations.

        Evaluates every host in every domain:
        - ESX hosts within a cluster sharing the same version and alias coverage are rolled up into
          a single cluster row.
        - Clusters experiencing version drift expand to individual per-host rows.

        Resolves domain current release BOM via Invoke-VcfGetReleases and alias mappings via
        Invoke-VcfGetVersionAliasConfiguration. Evaluates coverage and populates a structured Rows
        table detailing Domain, Cluster, Component, Target, InstalledVersion, ExpectedBomVersion,
        AliasApplied, Covered, and Note.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [PSObject] A single VcfCheck.Result object.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'sddc_version_alias_check'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $uncoveredCount = 0
    $domainsMissingBom = [System.Collections.Generic.List[String]]::new()

    try {
        $domains = @((Invoke-VcfGetDomains -ErrorAction Stop).Elements)
        $aliasMap = Get-VcfCheckVersionAliasMap

        foreach ($domain in $domains) {
            $domainName = $domain.Name
            $domainId = $domain.Id

            $currentBom = Get-VcfCheckDomainCurrentBom -DomainId $domainId
            if (-not $currentBom -or $currentBom.Count -eq 0) {
                $domainsMissingBom.Add($domainName)
                continue
            }

            $bomComponentNames = @($currentBom.Keys)

            foreach ($vc in @((Invoke-VcfGetVcenters -DomainId $domainId -ErrorAction Stop).Elements)) {
                $bomVersion = Find-VcfCheckBomVersionForComponent -Bom $currentBom -ComponentType 'VCENTER'
                $row = New-VcfCheckVersionAliasRow -Domain $domainName -Cluster 'N/A' -Component 'vCenter' -ComponentType 'VCENTER' `
                    -Target $vc.Fqdn -InstalledVersion $vc.Version -BomVersion $bomVersion -BomComponentNames $bomComponentNames -AliasMap $aliasMap
                $rows.Add($row)
                if (-not $row.Covered) { $uncoveredCount++ }
            }

            $bomVersion = Find-VcfCheckBomVersionForComponent -Bom $currentBom -ComponentType 'ESX_HOST'
            $hostsByCluster = Get-VcfCheckHostsGroupedByCluster -DomainId $domainId
            foreach ($clusterName in ($hostsByCluster.Keys | Sort-Object)) {
                $clusterRows = @(New-VcfCheckVersionAliasClusterRowSet -Domain $domainName -Cluster $clusterName `
                        -ClusterHosts $hostsByCluster[$clusterName] -BomVersion $bomVersion -BomComponentNames $bomComponentNames -AliasMap $aliasMap)
                foreach ($clusterRow in $clusterRows) {
                    $rows.Add($clusterRow)
                    if (-not $clusterRow.Covered) { $uncoveredCount++ }
                }
            }

            $nsxResources = $null
            try {
                $nsxResources = Invoke-VcfGetNsxUpgradeResources -DomainId $domainId -ErrorAction Stop
            } catch {
                # Safeguard if domain NSX resources cannot be queried - vCenter/ESX rows still stand.
            }

            if ($nsxResources -and $nsxResources.NsxtManagerCluster) {
                $targetName = if ($nsxResources.NsxtManagerCluster.Name) { $nsxResources.NsxtManagerCluster.Name } else { "NSX-Manager-$domainName" }
                $bomVersion = Find-VcfCheckBomVersionForComponent -Bom $currentBom -ComponentType 'NSX_T_MANAGER'
                $row = New-VcfCheckVersionAliasRow -Domain $domainName -Cluster 'N/A' -Component 'NSX Manager' -ComponentType 'NSX_T_MANAGER' `
                    -Target $targetName -InstalledVersion $nsxResources.NsxtManagerCluster.Version -BomVersion $bomVersion -BomComponentNames $bomComponentNames -AliasMap $aliasMap
                $rows.Add($row)
                if (-not $row.Covered) { $uncoveredCount++ }
            }
        }
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $Context.SddcManagerFqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    if ($uncoveredCount -gt 0) {
        $status = 'Fail'
        $detail = "$uncoveredCount of $($rows.Count) evaluated component(s) are running a build that does not match the current release BOM and is not covered by a registered version alias. See the Rows table for details."
    } else {
        $status = 'Pass'
        $detail = "All $($rows.Count) evaluated component(s) across all domains are covered."
    }

    if ($domainsMissingBom.Count -gt 0) {
        $detail += " No current-release BOM could be resolved for domain(s): $($domainsMissingBom -join ', '); those domains were skipped."
    }

    $resultParams = @{
        CheckId         = $checkId
        Status          = $status
        TargetComponent = $Context.SddcManagerFqdn
        Detail          = $detail
        Rows            = $rows.ToArray()
        StartedAt       = $startedAt
        CompletedAt     = (Get-Date)
    }

    if ($status -eq 'Fail') {
        $resultParams['Blocking'] = $true
    }

    return New-VcfCheckResult @resultParams -DisplayName $displayName
}
function New-VcfCheckVersionAliasClusterRowSet {

    <#
        .SYNOPSIS
        Builds the ESX Host Rows entries for one cluster, rolled up to a single row when every
        host in the cluster is covered and shares the same version.

        .DESCRIPTION
        Reports one aggregated row for the cluster when all hosts share the same EsxiVersion and
        coverage outcome. Expands to individual host rows when version drift is detected within
        the cluster.

        .PARAMETER Domain
        Domain name to stamp on each row.

        .PARAMETER Cluster
        Cluster name to stamp on each row.

        .PARAMETER ClusterHosts
        The cluster's host objects (Invoke-VcfGetHosts elements, from
        Get-VcfCheckHostsGroupedByCluster).

        .PARAMETER BomVersion
        The current release's declared ESX version for this domain, or $null if unresolved.

        .PARAMETER BomComponentNames
        The current release BOM's actual component name keys, passed straight through to
        New-VcfCheckVersionAliasRow for its diagnostic Note when BomVersion is $null.

        .PARAMETER AliasMap
        Hashtable from Get-VcfCheckVersionAliasMap.

        .OUTPUTS
        [PSObject[]] one aggregated row, or one row per host.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [String]$Domain,
        [Parameter(Mandatory = $true)] [String]$Cluster,
        [Parameter(Mandatory = $true)] [System.Collections.Generic.List[PSCustomObject]]$ClusterHosts,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$BomVersion,
        [Parameter(Mandatory = $false)] [AllowNull()] [String[]]$BomComponentNames = @(),
        [Parameter(Mandatory = $true)] [Hashtable]$AliasMap
    )

    $uniqueVersions = @($ClusterHosts | Select-Object -ExpandProperty EsxiVersion -Unique)

    if ($uniqueVersions.Count -eq 1) {
        $targetText = "All $($ClusterHosts.Count) hosts have the same version"
        return @(New-VcfCheckVersionAliasRow -Domain $Domain -Cluster $Cluster -Component 'ESX Host' -ComponentType 'ESX_HOST' `
                -Target $targetText -InstalledVersion $uniqueVersions[0] -BomVersion $BomVersion -BomComponentNames $BomComponentNames -AliasMap $AliasMap)
    }

    return @($ClusterHosts | ForEach-Object {
            New-VcfCheckVersionAliasRow -Domain $Domain -Cluster $Cluster -Component 'ESX Host' -ComponentType 'ESX_HOST' `
                -Target $_.Fqdn -InstalledVersion $_.EsxiVersion -BomVersion $BomVersion -BomComponentNames $BomComponentNames -AliasMap $AliasMap
        })
}
function New-VcfCheckVersionAliasRow {

    <#
        .SYNOPSIS
        Parses one component's installed version against its current-release BOM version (falling
        back to a registered version alias) and builds its Test-VcfSddcVersionAliasCheck Rows entry.

        .DESCRIPTION
        Compares an installed component version against the expected BOM version. If the installed
        version does not match directly, checks for a registered version alias in AliasMap mapping
        the installed version to an expected base version.

        Populates row fields including Domain, Cluster, Component, Target, InstalledVersion,
        ExpectedBomVersion, AliasApplied, Covered, and diagnostic Note details.

        .PARAMETER Domain
        Domain name to stamp on the row.

        .PARAMETER Cluster
        Cluster name to stamp on the row, or 'N/A' for a component with no cluster association.

        .PARAMETER Component
        Human-readable component label, e.g. 'vCenter', 'ESX Host', 'NSX Manager'.

        .PARAMETER ComponentType
        The version-alias BundleComponentType code for this component (e.g. 'VCENTER'), used to
        look up any registered alias in AliasMap.

        .PARAMETER Target
        The specific target this row describes, e.g. an FQDN.

        .PARAMETER InstalledVersion
        Raw version string as reported by the component. May be $null/empty.

        .PARAMETER BomVersion
        The current release's declared version for this component, or $null if it could not be
        resolved from the domain's BOM.

        .PARAMETER BomComponentNames
        The current release BOM's actual component name keys (e.g. from
        Get-VcfCheckDomainCurrentBom's .Keys), used only to build a diagnostic Note when
        BomVersion is $null.

        .PARAMETER AliasMap
        Hashtable from Get-VcfCheckVersionAliasMap: ComponentType -> Hashtable of
        aliasVersion -> baseVersion.

        .OUTPUTS
        [PSObject] one Rows entry: Domain, Cluster, Component, Target, InstalledVersion,
        ExpectedBomVersion, AliasApplied, Covered, Note.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [String]$Domain,
        [Parameter(Mandatory = $true)] [String]$Cluster,
        [Parameter(Mandatory = $true)] [String]$Component,
        [Parameter(Mandatory = $true)] [String]$ComponentType,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Target,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$InstalledVersion,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$BomVersion,
        [Parameter(Mandatory = $false)] [AllowNull()] [String[]]$BomComponentNames = @(),
        [Parameter(Mandatory = $true)] [Hashtable]$AliasMap
    )

    $aliasApplied = $false
    $note = ''

    if ([String]::IsNullOrWhiteSpace($BomVersion)) {
        $covered = $false
        $note = 'Current release BOM has no declared version for this component.'
        if ($BomComponentNames -and $BomComponentNames.Count -gt 0) {
            $note += " Actual BOM component name(s) seen for this domain: $($BomComponentNames -join ', ')."
        }
    } elseif (Test-VcfCheckBomVersionMatch -Actual $InstalledVersion -Expected $BomVersion) {
        $covered = $true
    } else {
        $aliasedBase = $null
        if ($AliasMap.ContainsKey($ComponentType) -and -not [String]::IsNullOrWhiteSpace($InstalledVersion)) {
            $componentAliases = $AliasMap[$ComponentType]
            if ($componentAliases.ContainsKey($InstalledVersion.Trim())) {
                $aliasedBase = $componentAliases[$InstalledVersion.Trim()]
            }
        }

        if (-not [String]::IsNullOrWhiteSpace($aliasedBase) -and (Test-VcfCheckBomVersionMatch -Actual $aliasedBase -Expected $BomVersion)) {
            $covered = $true
            $aliasApplied = $true
            $note = "Covered by a version alias mapping to base version $aliasedBase."
        } else {
            $covered = $false
            $note = 'No registered version alias covers this build.'
        }
    }

    return [PSCustomObject]@{
        Domain             = $Domain
        Cluster            = $Cluster
        Component          = $Component
        Target             = $Target
        InstalledVersion   = $InstalledVersion
        ExpectedBomVersion = $BomVersion
        AliasApplied       = $aliasApplied
        Covered            = $covered
        Note               = $note
    }
}
function Get-VcfCheckDomainCurrentBom {

    <#
        .SYNOPSIS
        Looks up the current, already-running release's BOM (component name -> version) for a
        domain.

        .DESCRIPTION
        Queries domain release details via Invoke-VcfGetReleases -DomainId to retrieve the
        active release and constructs a Hashtable mapping BOM component names to expected
        version strings.

        .PARAMETER DomainId
        The VCF domain Id to resolve the current release BOM for.

        .OUTPUTS
        [Hashtable] component name -> version string, or $null if the domain has no resolvable
        current release.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [String]$DomainId
    )

    $releases = @((Invoke-VcfGetReleases -DomainId $DomainId -ErrorAction Stop).Elements)
    $release = $releases | Select-Object -First 1
    if (-not $release) {
        return $null
    }

    $bom = @{}
    foreach ($entry in @($release.Bom)) {
        if ($entry -and -not [String]::IsNullOrWhiteSpace($entry.Name)) {
            $bom[$entry.Name] = $entry.Version
        }
    }
    return $bom
}
function Get-VcfCheckVersionAliasMap {

    <#
        .SYNOPSIS
        Builds a lookup of every registered LCM version alias, by bundle component type.

        .DESCRIPTION
        Queries registered LCM version aliases via Invoke-VcfGetVersionAliasConfiguration and
        flattens the result into a lookup Hashtable: BundleComponentType -> (aliasVersion -> baseVersion).

        .OUTPUTS
        [Hashtable] BundleComponentType -> Hashtable of aliasVersion -> baseVersion. Empty if no
        aliases are registered.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param ()

    $map = @{}
    $page = Invoke-VcfGetVersionAliasConfiguration -ErrorAction Stop
    foreach ($entry in @($page.Elements)) {
        if (-not $entry -or [String]::IsNullOrWhiteSpace($entry.BundleComponentType)) {
            continue
        }

        $componentMap = @{}
        foreach ($baseAlias in @($entry.VersionAliases)) {
            if (-not $baseAlias) { continue }
            foreach ($aliasVersion in @($baseAlias.Aliases)) {
                if (-not [String]::IsNullOrWhiteSpace($aliasVersion)) {
                    $componentMap[$aliasVersion.Trim()] = $baseAlias.Version
                }
            }
        }
        $map[$entry.BundleComponentType] = $componentMap
    }
    return $map
}
function Find-VcfCheckBomVersionForComponent {

    <#
        .SYNOPSIS
        Resolves the current-release BOM's declared version for a version-alias component type.

        .DESCRIPTION
        Matches version-alias BundleComponentType codes (such as 'VCENTER', 'ESX_HOST', 'NSX_T_MANAGER',
        'SDDC_MANAGER') against BOM component keys using candidate keywords.

        Accounts for varying component naming conventions (e.g., 'HOST' or 'ESX' for ESX hosts)
        and returns the matching BOM version string.

        .PARAMETER Bom
        Hashtable from Get-VcfCheckDomainCurrentBom: component name -> version string.

        .PARAMETER ComponentType
        The version-alias BundleComponentType code to resolve a BOM version for, e.g. 'VCENTER'.

        .OUTPUTS
        [String] the matched BOM version, or $null if no BOM entry name matched any of the
        component type's candidate keywords.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [Hashtable]$Bom,
        [Parameter(Mandatory = $true)] [String]$ComponentType
    )

    if (-not $Bom -or $Bom.Count -eq 0) {
        return $null
    }

    $keywordsByComponentType = @{
        'SDDC_MANAGER'  = @('SDDC_MANAGER', 'SDDC Manager')
        'VCENTER'       = @('VCENTER', 'vCenter')
        'ESX_HOST'      = @('HOST', 'ESX')
        'NSX_T_MANAGER' = @('NSX_T_MANAGER', 'NSX')
    }

    $keywords = $keywordsByComponentType[$ComponentType]
    if (-not $keywords -or $keywords.Count -eq 0) {
        return $null
    }

    foreach ($keyword in $keywords) {
        $matchKey = $Bom.Keys | Where-Object { $_ -match [Regex]::Escape($keyword) } | Select-Object -First 1
        if ($matchKey) {
            return $Bom[$matchKey]
        }
    }
    return $null
}
