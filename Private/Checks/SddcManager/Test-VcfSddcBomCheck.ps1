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
$Script:VcfCheckDefaultDestinationRelease = 'latest'
function Test-VcfSddcBomCheck {

    <#
        .SYNOPSIS
        Validates SDDC Manager, vCenters, ESX Hosts/Clusters, and NSX components
        across all VCF domains against required minimum release thresholds.

        .DESCRIPTION
        Queries SDDC Manager and all workload domains to build a detailed compliance report.
        Aggregates host compliance at the cluster level when versions are identical, or
        expands cluster details per host when version drift is detected.

        Every component is judged independently against the destination release's own
        requirement - a disjoint sBOM (e.g. vCenter already ahead of the target while NSX sits
        exactly at its floor) is expected and fine; this never requires every component to match
        one release's exact version set.

        Each component's Compliant verdict is decided in this priority order (see
        New-VcfCheckBomComplianceRow):
        1. PRIMARY - Broadcom's public Interop Matrix's own real per-version-pair upgrade-path
           status (Get-VcfCheckInteropMatrixCompatibilityVerdict, with FailureReason detail
           from Get-VcfCheckInteropMatrixFailureReason), not a floor comparison. A
           floor only approximates compatibility; the matrix encodes real exceptions a floor
           cannot see - confirmed live: ESX build 25595708 ("8.0U3k") is Incompatible with VCF ESX
           release 9.1.0.0100 because 8.0U3k's own release date is later than 9.1.0.0100's (a
           release-date-based exception), even though a floor comparison would call it compliant.
           For ESX/vCenter, resolving the installed raw build to its Interop Matrix row requires
           the marketing-name alias data shipped in Data/MarketingVersionAliases/EsxMarketingVersionAliases.json /
           Data/MarketingVersionAliases/VcenterMarketingVersionAliases.json (regenerate via
           InternalTools/Update-VcfMarketingVersionAliases.ps1); NSX/SDDC Manager match by parsed version
           directly, no alias needed.
        2. FALLBACK - a floor (>=) comparison against MinimumVersion, used only when the shipped
           Interop Matrix snapshot (Data/Interoperability/*.json) has no resolvable verdict for
           this exact pair: the installed build couldn't be resolved to a matrix row, or the
           specific pair isn't listed. Each Rows entry's FailureReason text distinguishes which
           path produced a non-compliant ReadyforUpgrade value, so a report reader can tell a
           proven Interop Matrix verdict from a minimum-version approximation.
        MinimumVersion itself (the floor's threshold) is resolved live, in this order:
        1. Get-VcfCheckReleaseBom -Version <release> - the connected SDDC Manager's own
           release catalog. Exact, and in SDDC Manager's own version-string format, so no
           build-number-format mismatch risk.
        2. If SDDC Manager's local catalog has no entry for that release (e.g. an offline/
           air-gapped instance that hasn't synced it yet), falls back to this check's default
           floor thresholds (SDDC Manager 5.2, vCenter/ESX 8.0.3, NSX 4.2) and adds a
           Note recording whether Broadcom's public Interop Matrix at least confirms
           -VcfDestinationRelease is a real, published SDDC Manager release (a sanity check only,
           not a compatibility judgment - see Test-VcfCheckInteropMatrixVersionPublished).
           That confirmatory call requires internet access; if it also fails (or none is
           available), the Note says so and the default floor thresholds are still used - this
           check never fails or errors out solely because that lookup didn't succeed.

        A row that the Interop Matrix itself confirms Incompatible blocks the check (Status
        'Fail', Blocking $true) - the destination release genuinely does not support that
        component. A row that only misses the MinimumVersion floor, with no Interop Matrix
        verdict either way, is reported as Status 'Warning' instead and does not block - the
        shipped Interop Matrix snapshot may simply not have caught up to a newly-published
        release yet, so a floor miss alone is not treated as confirmed non-compliance.

        Returns a VcfCheck.Result object containing a structured 'Rows' table detailing
        Domain, Component, Target, InstalledVersion, MinimumVersion, ReadyforUpgrade,
        VerdictSource, and FailureReason. Cluster names are folded into Target (rather than kept
        as their own column) for the ESX Host rows that carry one, to save a column in an
        already-wide report.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER VcfDestinationRelease
        Either a full concrete VCF release (e.g. '9.1.0.0300'), a release family - major.minor.
        patch only, e.g. '9.1.0' - or 'latest'. A family or 'latest' is resolved independently
        per component (SDDC Manager, vCenter, ESX, NSX) to that component's own newest published
        release matching the request, via Resolve-VcfCheckInteropMatrixReleaseInFamily -
        two components in the same release train can ship a different newest 4th-digit patch
        (e.g. NSX 9.1.0.0300 while vCenter is still at 9.1.0.0100), so resolving once centrally
        would misrepresent at least one of them. A full concrete release skips resolution
        entirely and is used exactly as given, unchanged from this parameter's original
        behavior. Defaults to $Script:VcfCheckDefaultDestinationRelease ('latest').

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [PSObject] A single VcfCheck.Result object.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$VcfDestinationRelease = $Script:VcfCheckDefaultDestinationRelease,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'sddc_bom_check'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }
    $legacyMinVersions = @{
        'SDDC_MANAGER' = '5.2'
        'VCENTER'      = '8.0.3'
        'ESX'          = '8.0.3'
        'NSX_MANAGER'  = '4.2'
        'NSX_EDGE'     = '4.2'
    }

    $isDestinationReleaseFamily = ($VcfDestinationRelease -eq 'latest') -or ($VcfDestinationRelease -match '^\d+\.\d+\.\d+$')
    $destinationVersions = @{}
    foreach ($interopComponent in @('SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX')) {
        $destinationVersions[$interopComponent] = $VcfDestinationRelease
        if ($isDestinationReleaseFamily) {
            $resolvedRelease = Resolve-VcfCheckInteropMatrixReleaseInFamily -Component $interopComponent -Family $VcfDestinationRelease
            if ($resolvedRelease) { $destinationVersions[$interopComponent] = $resolvedRelease }
        }
    }

    $bomResolution = Resolve-VcfCheckBomDestinationThreshold -VcfDestinationRelease $destinationVersions['SDDC_MANAGER'] -LegacyMinVersions $legacyMinVersions
    $minVersions = $bomResolution.MinVersions

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $nonCompliant = [System.Collections.Generic.List[String]]::new()
    $unconfirmedNonCompliant = [System.Collections.Generic.List[String]]::new()

    try {
        $domains = @((Invoke-VcfGetDomains -ErrorAction Stop).Elements)

        $mgmtDomain = $domains | Where-Object { $_.Type -eq 'MANAGEMENT' } | Select-Object -First 1
        $mgmtDomainName = if ($mgmtDomain -and $mgmtDomain.Name) { $mgmtDomain.Name } else { 'Management' }

        # ----------------------------------------------------
        # 1. SDDC Manager Check
        # ----------------------------------------------------
        foreach ($sddc in @((Invoke-VcfGetSddcManagers -ErrorAction Stop).Elements)) {
            $targetName = if ($sddc.Fqdn) { $sddc.Fqdn } else { $Context.SddcManagerFqdn }
            $row = New-VcfCheckBomComplianceRow -Domain $mgmtDomainName -Component 'SDDC Manager' `
                -Target $targetName -InstalledVersion $sddc.Version -MinimumVersion $minVersions['SDDC_MANAGER'] `
                -InteropComponent 'SDDC_MANAGER' -DestinationVersion $destinationVersions['SDDC_MANAGER']
            $rows.Add($row)
            Add-VcfCheckBomComplianceMessage -Row $row -Label "SDDC Manager (${targetName})" `
                -NonCompliant $nonCompliant -UnconfirmedNonCompliant $unconfirmedNonCompliant
        }

        # ----------------------------------------------------
        # 2. Iterate All VCF Domains
        # ----------------------------------------------------
        foreach ($domain in $domains) {
            $domainName = $domain.Name
            $domainId = $domain.Id

            # --- Domain vCenters ---
            foreach ($vc in @((Invoke-VcfGetVcenters -DomainId $domainId -ErrorAction Stop).Elements)) {
                $row = New-VcfCheckBomComplianceRow -Domain $domainName -Component 'vCenter' `
                    -Target $vc.Fqdn -InstalledVersion $vc.Version -MinimumVersion $minVersions['VCENTER'] `
                    -InteropComponent 'VCENTER' -DestinationVersion $destinationVersions['VCENTER']
                $rows.Add($row)
                Add-VcfCheckBomComplianceMessage -Row $row -Label "Domain [$domainName] vCenter ($($vc.Fqdn))" `
                    -NonCompliant $nonCompliant -UnconfirmedNonCompliant $unconfirmedNonCompliant
            }

            # --- ESX Hosts, Grouped by Cluster ---
            $hostsByCluster = Get-VcfCheckHostsGroupedByCluster -DomainId $domainId
            foreach ($clusterName in $hostsByCluster.Keys) {
                $clusterHosts = $hostsByCluster[$clusterName]
                $uniqueVersions = @($clusterHosts | Select-Object -ExpandProperty EsxiVersion -Unique)

                if ($uniqueVersions.Count -eq 1) {
                    # All hosts in this cluster share the same version - report the cluster as one row.
                    $targetText = "Cluster [$clusterName]: All $($clusterHosts.Count) hosts have the same version"
                    $row = New-VcfCheckBomComplianceRow -Domain $domainName -Component 'ESX Host' `
                        -Target $targetText -InstalledVersion $uniqueVersions[0] -MinimumVersion $minVersions['ESX'] `
                        -InteropComponent 'ESX' -DestinationVersion $destinationVersions['ESX']
                    $rows.Add($row)
                    Add-VcfCheckBomComplianceMessage -Row $row -Label "Domain [$domainName] $targetText" `
                        -NonCompliant $nonCompliant -UnconfirmedNonCompliant $unconfirmedNonCompliant
                } else {
                    # Version drift detected in the cluster - expand each host individually.
                    foreach ($hostObj in $clusterHosts) {
                        $targetText = "Cluster [$clusterName]: $($hostObj.Fqdn)"
                        $row = New-VcfCheckBomComplianceRow -Domain $domainName -Component 'ESX Host' `
                            -Target $targetText -InstalledVersion $hostObj.EsxiVersion -MinimumVersion $minVersions['ESX'] `
                            -InteropComponent 'ESX' -DestinationVersion $destinationVersions['ESX']
                        $rows.Add($row)
                        Add-VcfCheckBomComplianceMessage -Row $row -Label "Domain [$domainName] $targetText" `
                            -NonCompliant $nonCompliant -UnconfirmedNonCompliant $unconfirmedNonCompliant
                    }
                }
            }

            # --- NSX Components Check ---
            $nsxResources = $null
            try {
                $nsxResources = Invoke-VcfGetNsxUpgradeResources -DomainId $domainId -ErrorAction Stop
            } catch {
                # Safeguard if domain NSX resources cannot be queried
                Write-LogMessage -Type WARNING -Message "Could not query NSX upgrade resources for domain $domainId`: $($_.Exception.Message)"
            }

            if ($nsxResources) {
                if ($nsxResources.NsxtManagerCluster) {
                    $targetName = if ($nsxResources.NsxtManagerCluster.Name) { $nsxResources.NsxtManagerCluster.Name } else { "NSX-Manager-$domainName" }
                    $row = New-VcfCheckBomComplianceRow -Domain $domainName -Component 'NSX Manager' `
                        -Target $targetName -InstalledVersion $nsxResources.NsxtManagerCluster.Version -MinimumVersion $minVersions['NSX_MANAGER'] `
                        -InteropComponent 'NSX' -DestinationVersion $destinationVersions['NSX']
                    $rows.Add($row)
                    Add-VcfCheckBomComplianceMessage -Row $row -Label "Domain [$domainName] NSX Manager (${targetName})" `
                        -NonCompliant $nonCompliant -UnconfirmedNonCompliant $unconfirmedNonCompliant
                }

                foreach ($edgeCluster in @($nsxResources.NsxtEdgeClusters)) {
                    $row = New-VcfCheckBomComplianceRow -Domain $domainName -Component 'NSX Edge Cluster' `
                        -Target $edgeCluster.Name -InstalledVersion $edgeCluster.Version -MinimumVersion $minVersions['NSX_EDGE'] `
                        -InteropComponent 'NSX' -DestinationVersion $destinationVersions['NSX']
                    $rows.Add($row)
                    Add-VcfCheckBomComplianceMessage -Row $row -Label "Domain [$domainName] Edge Cluster ($($edgeCluster.Name))" `
                        -NonCompliant $nonCompliant -UnconfirmedNonCompliant $unconfirmedNonCompliant
                }
            }
        }
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $Context.SddcManagerFqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    if ($nonCompliant.Count -gt 0) {
        $status = 'Fail'
        $detail = "Not ready to upgrade to VCF $VcfDestinationRelease`: $($nonCompliant -join '; ')"
    } elseif ($unconfirmedNonCompliant.Count -gt 0) {
        $status = 'Warning'
        $detail = "Below the minimum version floor for VCF $VcfDestinationRelease, but Broadcom's Interop Matrix has no data yet for this exact pair - unconfirmed, not a blocking failure: $($unconfirmedNonCompliant -join '; ')"
    } else {
        $status = 'Pass'
        $detail = "SDDC Manager, vCenters, ESX host clusters, and NSX resources across all domains meet the minimum versions required for VCF $VcfDestinationRelease."
    }
    if (-not [String]::IsNullOrWhiteSpace($bomResolution.Note)) {
        $detail += " $($bomResolution.Note)"
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
    } elseif ($status -eq 'Warning') {
        $resultParams['Blocking'] = $false
    }

    return New-VcfCheckResult @resultParams -DisplayName $displayName
}
function Add-VcfCheckBomComplianceMessage {

    <#
        .SYNOPSIS
        Routes one non-compliant Test-VcfSddcBomCheck row's formatted message into the confirmed
        or unconfirmed non-compliance list, based on which source decided its verdict.

        .DESCRIPTION
        A row whose VerdictSource is 'Interop Matrix' is a real, confirmed non-compliance - it
        goes into NonCompliant and blocks the check. A row that only missed the MinimumVersion
        floor (VerdictSource 'Minimum Version Floor') goes into UnconfirmedNonCompliant instead,
        since the shipped Interop Matrix snapshot may simply not have data for this pair yet -
        see New-VcfCheckBomComplianceRow's InteropComponent parameter notes. A compliant row is a
        no-op.

        .PARAMETER Row
        One New-VcfCheckBomComplianceRow result.

        .PARAMETER Label
        Human-readable identifier for the row's target, forwarded to
        Format-VcfCheckBomNonCompliantMessage.

        .PARAMETER NonCompliant
        The check's confirmed non-compliance message list.

        .PARAMETER UnconfirmedNonCompliant
        The check's unconfirmed (floor-only) non-compliance message list.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Row,
        [Parameter(Mandatory = $true)] [String]$Label,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [System.Collections.Generic.List[String]]$NonCompliant,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [System.Collections.Generic.List[String]]$UnconfirmedNonCompliant
    )

    if ($Row.ReadyforUpgrade) { return }

    $message = Format-VcfCheckBomNonCompliantMessage -Row $Row -Label $Label
    if ($Row.VerdictSource -eq 'Interop Matrix') {
        $NonCompliant.Add($message)
    } else {
        $UnconfirmedNonCompliant.Add($message)
    }
}
function Format-VcfCheckBomNonCompliantMessage {

    <#
        .SYNOPSIS
        Formats one Test-VcfSddcBomCheck non-compliant component's call to action, worded
        differently depending on why it's non-compliant.

        .DESCRIPTION
        A component below its minimum version just needs upgrading. A component the Interop
        Matrix itself flags Incompatible (FailureReason starting with 'Incompatible') is a
        different, more important case: the installed version may already clear any numeric
        floor, but no published VCF release combination supports it yet (e.g. a release-date-based
        exception - see New-VcfCheckBomComplianceRow's .NOTES). Upgrading that component alone
        would not fix this - the destination VCF release itself needs to move forward, so the
        call to action is to wait for a newer VCF 9.x release rather than to change the component.

        .PARAMETER Row
        One New-VcfCheckBomComplianceRow result, already confirmed non-compliant.

        .PARAMETER Label
        Human-readable identifier for the row's target, e.g. 'SDDC Manager (vcf01.example.com)'.

        .OUTPUTS
        [String] one ready-to-join sentence for the check's Detail message.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Row,
        [Parameter(Mandatory = $true)] [String]$Label
    )

    if ($Row.FailureReason -like 'Incompatible*' -or $Row.FailureReason -like 'Not Supported*') {
        return "$Label (Installed: $($Row.InstalledVersion)) - $($Row.FailureReason) - wait for a newer VCF 9.x release before upgrading"
    }
    return "$Label (Installed: $($Row.InstalledVersion), Required: $($Row.MinimumVersion))"
}
function Resolve-VcfCheckBomDestinationThreshold {

    <#
        .SYNOPSIS
        Resolves per-component minimum-version thresholds for Test-VcfSddcBomCheck's chosen
        destination VCF release.

        .DESCRIPTION
        Tries Get-VcfCheckReleaseBom first - the connected SDDC Manager's own release catalog,
        exact and in SDDC Manager's own version-string format. Falls back to LegacyMinVersions
        (default floor thresholds) only when that catalog has no entry for the requested
        release, in which case it also asks Broadcom's public Interop Matrix (SDDC Manager
        product ID 851) whether the requested release even exists, purely so an environment
        falling back silently still gets a diagnostic note distinguishing "SDDC Manager just
        hasn't synced this real release yet" from "this release string isn't real." That
        confirmatory call is best-effort: no internet access or an API failure still returns
        the default thresholds, just with a note that the release could not be confirmed either
        way - never as a compliance failure.

        .PARAMETER VcfDestinationRelease
        The VCF release requested by the check's caller, e.g. '9.1.0.0'.

        .PARAMETER LegacyMinVersions
        Hashtable of component-type -> minimum version to fall back to when no live BOM is found.

        .OUTPUTS
        [PSObject] with MinVersions (Hashtable, same shape as LegacyMinVersions) and Note (String)
        describing which source was used.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [String]$VcfDestinationRelease,
        [Parameter(Mandatory = $true)] [Hashtable]$LegacyMinVersions
    )

    $bom = $null
    try {
        $bom = Get-VcfCheckReleaseBom -Version $VcfDestinationRelease -ErrorAction Stop
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not resolve VCF $VcfDestinationRelease from SDDC Manager's release catalog: $($_.Exception.Message)"
    }

    if ($bom -and $bom.Count -gt 0) {
        $nsxManagerVersion = Find-VcfCheckBomVersionForComponent -Bom $bom -ComponentType 'NSX_T_MANAGER'
        $minVersions = @{
            'SDDC_MANAGER' = Find-VcfCheckBomVersionForComponent -Bom $bom -ComponentType 'SDDC_MANAGER'
            'VCENTER'      = Find-VcfCheckBomVersionForComponent -Bom $bom -ComponentType 'VCENTER'
            'ESX'          = Find-VcfCheckBomVersionForComponent -Bom $bom -ComponentType 'ESX_HOST'
            'NSX_MANAGER'  = $nsxManagerVersion
            'NSX_EDGE'     = $nsxManagerVersion
        }
        $unresolvedComponents = @($minVersions.Keys | Where-Object { [String]::IsNullOrWhiteSpace($minVersions[$_]) })
        foreach ($componentKey in $unresolvedComponents) {
            $minVersions[$componentKey] = $LegacyMinVersions[$componentKey]
        }

        # A clean resolution needs no note - only the fallback case below and an unresolved
        # component are actionable enough to surface in the check's Detail message.
        $note = if ($unresolvedComponents.Count -gt 0) {
            "Could not match a BOM entry for: $($unresolvedComponents -join ', '); used default fallback thresholds for those."
        } else {
            ''
        }
        return [PSCustomObject]@{ MinVersions = $minVersions; Note = $note }
    }

    $publishedCheck = $null
    try {
        $publishedCheck = Test-VcfCheckInteropMatrixVersionPublished -ProductId 851 -Version $VcfDestinationRelease
    } catch {
        Write-LogMessage -Type WARNING -Message "Interop Matrix release-existence check failed for VCF $VcfDestinationRelease`: $($_.Exception.Message)"
    }

    # $true/unconfirmable are both expected, non-actionable outcomes of a normal default-threshold
    # fallback (an offline SDDC Manager catalog, or no internet access) - only a confirmed-false
    # result (a fictitious/typo'd version string) is worth surfacing to the user.
    $note = "SDDC Manager's release catalog has no entry for VCF $VcfDestinationRelease; used default minimum-version thresholds instead."
    if ($publishedCheck -eq $false) {
        $note += " Broadcom's Interop Matrix does not list this as a published release - double-check the version string."
    }

    return [PSCustomObject]@{ MinVersions = $LegacyMinVersions; Note = $note }
}
function New-VcfCheckBomComplianceRow {

    <#
        .SYNOPSIS
        Parses one component's installed version against its minimum threshold and builds its
        Test-VcfSddcBomCheck Rows entry.

        .DESCRIPTION
        Shared by every component type Test-VcfSddcBomCheck evaluates (SDDC Manager, vCenter, ESX
        Host, NSX Manager, NSX Edge Cluster) so the parse-compare-build sequence lives in exactly
        one place instead of being repeated per component.

        .PARAMETER Domain
        Domain name to stamp on the row (or 'N/A' for a single-target component).

        .PARAMETER Component
        Human-readable component label, e.g. 'SDDC Manager', 'ESX Host'.

        .PARAMETER Target
        The specific target this row describes (an FQDN, or a summary string for a cluster-wide
        row such as "Cluster [m01-cl01]: All 4 hosts have the same version" - the cluster
        name is folded into Target by the caller rather than carried as its own row property, to
        save a column in an already-wide report).

        .PARAMETER InstalledVersion
        Raw version string as reported by the component. May be $null/empty if the component
        never reported one - ConvertTo-VcfCheckSimpleVersion treats that as non-compliant.

        .PARAMETER MinimumVersion
        Minimum required version string from Test-VcfSddcBomCheck's threshold map - either a
        fallback floor (e.g. '8.0.3') or a live BOM entry that may carry a build suffix (e.g.
        '9.0.0.0-24755230'); parsed the same way as InstalledVersion before comparing. Only used
        as a fallback when InteropComponent/DestinationVersion don't produce a real verdict.

        .PARAMETER InteropComponent
        'SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI', or
        'VIDM' - when supplied along with DestinationVersion,
        the row's Compliant status is primarily decided by Broadcom's public Interop Matrix's own
        real per-version-pair upgrade-path status (Get-VcfCheckInteropMatrixCompatibilityVerdict)
        rather than a floor comparison, since a floor only approximates compatibility and misses
        real exceptions (e.g. a release-date-based one - see this function's own .NOTES). Falls
        back to the MinimumVersion floor comparison when the shipped Interop Matrix snapshot has
        no resolvable verdict for this exact pair (unresolvable row, or pair not listed) - that
        fallback is a best-effort estimate, not a confirmed verdict, since the shipped snapshot
        (Data/Interoperability/*.json) is refreshed manually and can lag behind a newly-published
        release; the caller uses VerdictSource to avoid blocking an upgrade on an unconfirmed
        floor miss the way it would on a real Interop Matrix Incompatible result.

        .PARAMETER DestinationVersion
        The destination VCF release version (e.g. '9.1.0.0'), required alongside
        InteropComponent for the shipped Interop Matrix snapshot lookup.

        .OUTPUTS
        [PSObject] one Rows entry: Domain, Component, Target, InstalledVersion, MinimumVersion,
        ReadyforUpgrade, VerdictSource ('Interop Matrix' when a real per-pair verdict was found,
        'Minimum Version Floor' when it fell back to the floor comparison), FailureReason (from
        Get-VcfCheckInteropMatrixFailureReason when the Interop Matrix path decided the verdict;
        a minimum-version-floor message otherwise; 'N/A' when ReadyforUpgrade is true).
        When VerdictSource is 'Interop Matrix', MinimumVersion is recomputed on the fly via
        Get-VcfCheckInteropMatrixMinimumCompatibleVersion (the lowest source version the shipped
        snapshot marks Compatible for DestinationVersion) rather than echoing back the
        passed-in floor, which played no part in the verdict. Falls back to
        'N/A (Interop Matrix per-pair verdict)' only if that lookup itself returns nothing.

        .NOTES
        CONFIRMED live, 2026-08-18: ESX build 25595708 ("8.0U3k") reports Incompatible against VCF
        ESX release 9.1.0.0100 via the Interop Matrix (a release-date-based exception - 8.0U3k's
        own release date is later than 9.1.0.0100's), while a floor comparison alone would have
        called it compliant (8.0.3 >= 8.0.3 floor, or even against a 9.x floor if this were a
        newer ESX build). This is why InteropComponent/DestinationVersion take priority over
        MinimumVersion whenever a real verdict is available.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds and returns a PSCustomObject Rows entry - no system state is changed despite the New- verb.')]
    Param (
        [Parameter(Mandatory = $true)] [String]$Domain,
        [Parameter(Mandatory = $true)] [String]$Component,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Target,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$InstalledVersion,
        [Parameter(Mandatory = $true)] [String]$MinimumVersion,
        [Parameter(Mandatory = $false)] [ValidateSet('SDDC_MANAGER', 'VCENTER', 'ESX', 'NSX', 'VRA', 'VROPS', 'VRNI', 'VRO', 'VRSLCM', 'VRLI', 'VIDM')] [String]$InteropComponent,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$DestinationVersion
    )

    $checkedAgainst = 'Minimum Version Floor'
    $isCompliant = $null

    $askedInteropMatrix = $InteropComponent -and -not [String]::IsNullOrWhiteSpace($DestinationVersion) -and -not [String]::IsNullOrWhiteSpace($InstalledVersion)
    if ($askedInteropMatrix) {
        $verdict = $null
        try {
            $verdict = Get-VcfCheckInteropMatrixCompatibilityVerdict -Component $InteropComponent -InstalledVersion $InstalledVersion -DestinationVersion $DestinationVersion -ErrorAction Stop
        } catch {
            Write-LogMessage -Type WARNING -Message "Interop Matrix compatibility lookup failed for $Component ($InstalledVersion -> $DestinationVersion): $($_.Exception.Message)"
        }
        if ($verdict) {
            $checkedAgainst = 'Interop Matrix'
            $isCompliant = ($verdict -eq 'Compatible')
        }
    }

    if ($null -eq $isCompliant) {
        $parsedActual = ConvertTo-VcfCheckSimpleVersion -VersionString $InstalledVersion
        $parsedRequired = ConvertTo-VcfCheckSimpleVersion -VersionString $MinimumVersion
        $isCompliant = ($null -ne $parsedActual -and $null -ne $parsedRequired -and $parsedActual -ge $parsedRequired)
    }

    $failureReason = 'N/A'
    if (-not $isCompliant) {
        if ($checkedAgainst -eq 'Interop Matrix') {
            $failureReason = Get-VcfCheckInteropMatrixFailureReason -Component $InteropComponent -InstalledVersion $InstalledVersion -DestinationVersion $DestinationVersion
            if (-not $failureReason) { $failureReason = "Incompatible - flagged by Broadcom's Interop Matrix, wait for a newer VCF 9.x release before upgrading" }
        } else {
            $failureReason = "Below Minimum Version Floor, unconfirmed - no Interop Matrix data for this pair (Installed: $InstalledVersion, Required: $MinimumVersion)"
        }
    }

    $displayedMinimumVersion = $MinimumVersion
    if ($checkedAgainst -eq 'Interop Matrix') {
        $interopFloor = $null
        try {
            $interopFloor = Get-VcfCheckInteropMatrixMinimumCompatibleVersion -Component $InteropComponent -DestinationVersion $DestinationVersion -ErrorAction Stop
        } catch {
            Write-LogMessage -Type WARNING -Message "Interop Matrix floor lookup failed for $Component (-> $DestinationVersion): $($_.Exception.Message)"
        }
        $displayedMinimumVersion = if ($interopFloor) { $interopFloor } else { 'N/A (Interop Matrix per-pair verdict)' }
    }

    return [PSCustomObject]@{
        Domain           = $Domain
        Component        = $Component
        Target           = $Target
        InstalledVersion = $InstalledVersion
        MinimumVersion   = $displayedMinimumVersion
        ReadyforUpgrade  = $isCompliant
        VerdictSource    = $checkedAgainst
        FailureReason    = $failureReason
    }
}
function ConvertTo-VcfCheckSimpleVersion {

    <#
        .SYNOPSIS
        Parses a VCF component version string into a comparable [Version].

        .DESCRIPTION
        VCF component version strings mix a marketing version with a numeric build suffix (e.g.
        "8.0.3.00600-24853646", "4.2.0.0.0.24105817"). [Version] only supports up to four numeric
        parts (Major.Minor.Build.Revision) and throws on anything else, so this strips a trailing
        "-<build>" suffix, then collects numeric groups left-to-right until either four groups are
        collected or a 7+ digit group is seen - that length reliably identifies a trailing
        build/changeset number rather than a version segment, confirmed against real VCF
        component version strings. Pads with zeros up to all four [Version] parts so that
        differently-truncated strings for the same release (e.g. Interop Matrix "5.2.2" versus
        an installed build's "5.2.2.0") normalize to the same [Version] value and compare equal.

        .PARAMETER VersionString
        Raw version string as reported by a VCF component (SDDC Manager, vCenter, ESX host, NSX
        Manager/Edge).

        .OUTPUTS
        [Version], or $null if the input was empty or had no leading numeric version information
        - lets a caller treat "could not determine a version" as simply non-compliant instead of
        wrapping every call site in its own try/catch.

        .EXAMPLE
        ConvertTo-VcfCheckSimpleVersion -VersionString '8.0.3.00600-24853646'
        # 8.0.3.600
    #>

    [CmdletBinding()]
    [OutputType([Version])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$VersionString
    )

    if ([String]::IsNullOrWhiteSpace($VersionString)) { return $null }

    $clean = ($VersionString -replace '-.*$', '').Trim()
    $regexMatches = [Regex]::Matches($clean, '\d+')
    if ($regexMatches.Count -eq 0) { return $null }

    $validParts = [System.Collections.Generic.List[Int]]::new()
    foreach ($match in $regexMatches) {
        if ($match.Value.Length -ge 7) { break }
        $validParts.Add([Int]$match.Value)
        if ($validParts.Count -eq 4) { break }
    }

    while ($validParts.Count -lt 4) {
        $validParts.Add(0)
    }

    try {
        return [Version]($validParts -join '.')
    } catch {
        return $null
    }
}
function Get-VcfCheckHostsGroupedByCluster {

    <#
        .SYNOPSIS
        Resolves and groups a domain's ESX hosts by cluster name, for Test-VcfSddcBomCheck.

        .DESCRIPTION
        Invoke-VcfGetHosts's own Host elements don't reliably carry a resolved cluster name
        across every VCF version, so this cross-references Invoke-VcfGetClusters's Id->Name map
        and per-cluster Hosts membership list as a fallback, trying (in order): the cluster
        membership list keyed by the host's Fqdn/Id, then the host's own Cluster.Name/
        ClusterName, then the cluster Id map keyed by the host's ClusterId/Cluster.Id. A host
        whose cluster cannot be resolved by any of these is grouped under 'Unassigned' rather
        than dropped, so a version-drift issue on an otherwise-unmapped host still surfaces in
        the report.

        .PARAMETER DomainId
        The VCF domain Id to query hosts and clusters for.

        .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary] cluster name -> List[PSObject] of that
        cluster's ESX host objects (Invoke-VcfGetHosts's own Host elements).
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    Param (
        [Parameter(Mandatory = $true)] [String]$DomainId
    )

    $clusterIdMap = @{}
    $hostClusterMap = @{}
    try {
        foreach ($cluster in @((Invoke-VcfGetClusters -DomainId $DomainId -ErrorAction Stop).Elements)) {
            if ($cluster.Id -and $cluster.Name) {
                $clusterIdMap[$cluster.Id] = $cluster.Name
            }
            foreach ($clusterHost in @($cluster.Hosts)) {
                if ($clusterHost.Fqdn) { $hostClusterMap[$clusterHost.Fqdn] = $cluster.Name }
                if ($clusterHost.Id) { $hostClusterMap[$clusterHost.Id] = $cluster.Name }
                if ($clusterHost.HostName) { $hostClusterMap[$clusterHost.HostName] = $cluster.Name }
            }
        }
    } catch {
        # A domain whose cluster query fails still reports its hosts below, grouped as 'Unassigned'.
        Write-LogMessage -Type WARNING -Message "Could not resolve cluster membership for domain $DomainId`: $($_.Exception.Message)"
    }

    $hostsByCluster = [Ordered]@{}
    foreach ($hostObj in @((Invoke-VcfGetHosts -DomainId $DomainId -ErrorAction Stop).Elements)) {
        $clusterName = switch ($true) {
            { $hostObj.Fqdn -and $hostClusterMap.ContainsKey($hostObj.Fqdn) } { $hostClusterMap[$hostObj.Fqdn]; break }
            { $hostObj.Id -and $hostClusterMap.ContainsKey($hostObj.Id) } { $hostClusterMap[$hostObj.Id]; break }
            { $hostObj.Cluster.Name } { $hostObj.Cluster.Name; break }
            { $hostObj.ClusterName } { $hostObj.ClusterName; break }
            { $hostObj.ClusterId -and $clusterIdMap.ContainsKey($hostObj.ClusterId) } { $clusterIdMap[$hostObj.ClusterId]; break }
            { $hostObj.Cluster.Id -and $clusterIdMap.ContainsKey($hostObj.Cluster.Id) } { $clusterIdMap[$hostObj.Cluster.Id]; break }
            default { 'Unassigned' }
        }
        if ([String]::IsNullOrWhiteSpace($clusterName)) {
            $clusterName = 'Unassigned'
        }

        if (-not $hostsByCluster.Contains($clusterName)) {
            $hostsByCluster[$clusterName] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $hostsByCluster[$clusterName].Add($hostObj)
    }

    return $hostsByCluster
}
