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
#region VsanHclHelpers

$Script:VcfCheckVsanHclDataCache = $null
$Script:VcfCheckVsanHclDataIndexCache = $null
$Script:VcfCheckVsanHclDriveDataCache = $null
$Script:VcfCheckVsanHclDriveDataIndexCache = $null
$Script:VcfCheckVsanHclLinksCache = $null

function Get-VcfCheckVsanHclData {

    <#
        .SYNOPSIS
        Loads and caches the shipped vSAN Hardware Compatibility List snapshot
        (Data/VsanHcl/VsanHclCompatibility.json).

        .DESCRIPTION
        Reads a snapshot captured by InternalTools/Update-VcfVsanHclData.ps1 at release-prep time
        from the public feed backing https://vvs.broadcom.com/service/vsan/all.json, so
        Resolve-VcfCheckVsanHclCompatibility can match host storage controller/NIC PCI identities
        against the vSAN HCL entirely offline.

        .OUTPUTS
        [PSObject[]] array of controller/NIC entries (.id, .vid, .did, .ssid, .svid, .rel), or an
        empty array if the file is missing or fails to parse - callers treat that as "could not
        confirm," never as "not compatible."
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param ()

    if ($null -eq $Script:VcfCheckVsanHclDataCache) {
        $data = @()
        $path = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path '..' -ChildPath (Join-Path -Path 'Data' -ChildPath (Join-Path -Path 'VsanHcl' -ChildPath 'VsanHclCompatibility.json')))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $data = @(Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not parse vSAN HCL data file `"$path`": $($_.Exception.Message)"
                $data = @()
            }
        } else {
            Write-LogMessage -Type WARNING -Message "No shipped vSAN HCL data file found: `"$path`" not found"
        }
        $Script:VcfCheckVsanHclDataCache = $data
    }

    return $Script:VcfCheckVsanHclDataCache
}
function Get-VcfCheckVsanHclDataIndex {

    <#
        .SYNOPSIS
        Builds and caches a PCI-identity lookup index over the shipped vSAN HCL controller/NIC
        snapshot, so Resolve-VcfCheckVsanHclCompatibility can match in O(1) instead of scanning
        every shipped entry per host component.

        .DESCRIPTION
        Keys Get-VcfCheckVsanHclData's entries by "vid|did|svid|ssid"; entries with no vid are
        skipped since Resolve-VcfCheckVsanHclCompatibility never looks one up with an empty
        VendorId. When more than one entry shares a key, the first one encountered wins, matching
        the prior Where-Object | Select-Object -First 1 behavior.

        .OUTPUTS
        [Hashtable] keyed by "vid|did|svid|ssid" to the matching HCL entry.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param ()

    if ($null -eq $Script:VcfCheckVsanHclDataIndexCache) {
        $index = @{}
        foreach ($entry in @(Get-VcfCheckVsanHclData)) {
            if ([String]::IsNullOrEmpty($entry.vid)) { continue }
            $key = "$($entry.vid)|$($entry.did)|$($entry.svid)|$($entry.ssid)"
            if (-not $index.ContainsKey($key)) { $index[$key] = $entry }
        }
        $Script:VcfCheckVsanHclDataIndexCache = $index
    }

    return $Script:VcfCheckVsanHclDataIndexCache
}
function Get-VcfCheckVsanHclDriveData {

    <#
        .SYNOPSIS
        Loads and caches the shipped vSAN Hardware Compatibility List drive snapshot
        (Data/VsanHcl/VsanHclDriveCompatibility.json).

        .DESCRIPTION
        Reads a snapshot captured by InternalTools/Update-VcfVsanHclData.ps1 at release-prep time
        from the public feed backing https://vvs.broadcom.com/service/vsan/all.json, so
        Resolve-VcfCheckVsanHclDriveCompatibility can match host SSD/HDD drives against the vSAN
        HCL entirely offline. Every entry is keyed by trimmed, lowercased model string, with a
        trimmed, lowercased productid string as a secondary key for entries whose model is a
        marketing description rather than the terse string ESX actually reports; NVMe drive entries
        (roughly a third of the asset) also carry vid/did/svid/ssid, since an NVMe drive is its own
        PCIe endpoint rather than sitting behind a shared HBA like SAS/SATA.

        .OUTPUTS
        [PSObject[]] array of drive entries (.id, .vendor, .model, .productid, .vid, .did, .svid,
        .ssid, .rel - the PCI id and productid properties are empty strings when the feed had none
        for that entry), or an empty array if the file is missing or fails to parse - callers treat
        that as "could not confirm," never as "not compatible."
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param ()

    if ($null -eq $Script:VcfCheckVsanHclDriveDataCache) {
        $data = @()
        $path = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path '..' -ChildPath (Join-Path -Path 'Data' -ChildPath (Join-Path -Path 'VsanHcl' -ChildPath 'VsanHclDriveCompatibility.json')))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $data = @(Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not parse vSAN HCL drive data file `"$path`": $($_.Exception.Message)"
                $data = @()
            }
        } else {
            Write-LogMessage -Type WARNING -Message "No shipped vSAN HCL drive data file found: `"$path`" not found"
        }
        $Script:VcfCheckVsanHclDriveDataCache = $data
    }

    return $Script:VcfCheckVsanHclDriveDataCache
}
function Get-VcfCheckVsanHclDriveDataIndex {

    <#
        .SYNOPSIS
        Builds and caches PCI-identity, model, and productid lookup indexes over the shipped vSAN
        HCL drive snapshot, so Resolve-VcfCheckVsanHclDriveCompatibility can match in O(1) instead
        of scanning every shipped entry per host drive.

        .DESCRIPTION
        Keys Get-VcfCheckVsanHclDriveData's entries three ways: PciIndex by "vid|did|svid|ssid"
        (entries with no vid are skipped, mirroring Get-VcfCheckVsanHclDataIndex), ModelIndex by
        the entry's already-normalized model string (first entry wins on a collision, matching the
        prior Where-Object | Select-Object -First 1 behavior), and ProductIdIndex by productid to
        an array of every entry sharing it, since Resolve-VcfCheckVsanHclDriveCompatibility narrows
        productid matches by vendor rather than taking the first one.

        .OUTPUTS
        [PSCustomObject] with PciIndex, ModelIndex (both [Hashtable] entry-by-key), and
        ProductIdIndex ([Hashtable] entry-array-by-key).
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param ()

    if ($null -eq $Script:VcfCheckVsanHclDriveDataIndexCache) {
        $pciIndex = @{}
        $modelIndex = @{}
        $productIdIndex = @{}
        foreach ($entry in @(Get-VcfCheckVsanHclDriveData)) {
            if (-not [String]::IsNullOrEmpty($entry.vid)) {
                $pciKey = "$($entry.vid)|$($entry.did)|$($entry.svid)|$($entry.ssid)"
                if (-not $pciIndex.ContainsKey($pciKey)) { $pciIndex[$pciKey] = $entry }
            }
            if (-not [String]::IsNullOrEmpty($entry.model) -and -not $modelIndex.ContainsKey($entry.model)) {
                $modelIndex[$entry.model] = $entry
            }
            if (-not [String]::IsNullOrEmpty($entry.productid)) {
                if (-not $productIdIndex.ContainsKey($entry.productid)) { $productIdIndex[$entry.productid] = @() }
                $productIdIndex[$entry.productid] += $entry
            }
        }
        $Script:VcfCheckVsanHclDriveDataIndexCache = [PSCustomObject]@{ PciIndex = $pciIndex; ModelIndex = $modelIndex; ProductIdIndex = $productIdIndex }
    }

    return $Script:VcfCheckVsanHclDriveDataIndexCache
}
function Get-VcfCheckVsanHclLinkData {

    <#
        .SYNOPSIS
        Loads and caches the shipped vSAN HCL id-to-VCG-program side table
        (Data/VsanHcl/VsanHclLinks.json).

        .DESCRIPTION
        Reads a side table captured by InternalTools/Update-VcfVsanHclData.ps1 alongside the main
        match assets. Every VCG "view in Compatibility Guide" link is
        https://compatibilityguide.broadcom.com/detail?program=<program>&productId=<id>&persona=live
        with productId always equal to the entry's own id, so this table only needs to carry the
        per-id program value (e.g. "ssd", "hdd", "rdmanic", "vsanio") rather than the full URL;
        Get-VcfCheckVsanHclLink reconstructs the URL from it.

        .OUTPUTS
        [PSObject] property bag keyed by HCL entry id (string) with the matching program value,
        or an empty PSObject if the file is missing or fails to parse.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param ()

    if ($null -eq $Script:VcfCheckVsanHclLinksCache) {
        $data = [PSCustomObject]@{}
        $path = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path '..' -ChildPath (Join-Path -Path 'Data' -ChildPath (Join-Path -Path 'VsanHcl' -ChildPath 'VsanHclLinks.json')))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not parse vSAN HCL links file `"$path`": $($_.Exception.Message)"
                $data = [PSCustomObject]@{}
            }
        } else {
            Write-LogMessage -Type WARNING -Message "No shipped vSAN HCL links file found: `"$path`" not found"
        }
        $Script:VcfCheckVsanHclLinksCache = $data
    }

    return $Script:VcfCheckVsanHclLinksCache
}
function Get-VcfCheckVsanHclLink {

    <#
        .SYNOPSIS
        Reconstructs the "view in VCG" URL for a matched vSAN HCL entry id.

        .DESCRIPTION
        Looks up Id's program value via Get-VcfCheckVsanHclLinkData and formats it back into the
        Broadcom Compatibility Guide detail URL. Id is used as-is for productId, matching how
        InternalTools/Update-VcfVsanHclData.ps1 populated the side table.

        .PARAMETER Id
        The matched HCL entry's numeric id (as returned in .MatchedId by
        Resolve-VcfCheckVsanHclCompatibility or Resolve-VcfCheckVsanHclDriveCompatibility).

        .OUTPUTS
        [String] the full VCG detail URL, or $null if Id has no entry in the links side table.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Id
    )

    $links = Get-VcfCheckVsanHclLinkData
    $program = $links.$Id
    if ([String]::IsNullOrEmpty($program)) { return $null }

    return "https://compatibilityguide.broadcom.com/detail?program=$program&productId=$Id&persona=live"
}
function Resolve-VcfCheckVsanHclOlderFamily {

    <#
        .SYNOPSIS
        Finds the newest pre-target-family ESX release a matched vSAN HCL entry is certified for.

        .DESCRIPTION
        Used by Resolve-VcfCheckVsanHclCompatibility and Resolve-VcfCheckVsanHclDriveCompatibility
        when a matched entry has no release data for the target ESX family (e.g. '9.1'), to tell
        "on the HCL but only certified for an older release" (IncompatibleWithTargetRelease) apart from
        "no release data at all for this entry" (Unknown). Shipped release keys for a given major
        version can include update releases (e.g. '8.0', '8.0 U1', '8.0 U2', '8.0 U3'); the highest
        key by ordinary string sort is returned with its update suffix stripped, since a component
        certified for '8.0 U3' is also meaningfully described as an '8.0.x' device to an operator.

        .PARAMETER Rel
        The matched HCL entry's .rel property (PSCustomObject keyed by normalized release, e.g.
        '9.1', '8.0 U3'), or $null.

        .PARAMETER TargetFamily
        The target ESX major.minor family being checked against, e.g. '9.1' - release keys
        starting with this family's major version digit are excluded from consideration.

        .OUTPUTS
        [String] the newest older major.minor family found (e.g. '8.0'), or $null if Rel is $null,
        has no properties, or has no release key outside TargetFamily's major version.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$Rel,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TargetFamily
    )

    if ($null -eq $Rel) { return $null }

    $targetMajor = ($TargetFamily -split '\.')[0]
    $olderKeys = @($Rel.PSObject.Properties.Name | Where-Object { ($_ -split '\.')[0] -ne $targetMajor })
    if ($olderKeys.Count -eq 0) { return $null }

    $newestOlderKey = $olderKeys | Sort-Object -Descending | Select-Object -First 1
    return ($newestOlderKey -split ' ')[0]
}
function Resolve-VcfCheckVsanHclCompatibility {

    <#
        .SYNOPSIS
        Flags whether an ESX host's storage controller or NIC appears on Broadcom's published
        vSAN Hardware Compatibility List for a given ESX release, and whether its driver/firmware
        is a supported combination.

        .DESCRIPTION
        Matches VendorId/DeviceId/SubVendorId/SubDeviceId against each shipped HCL entry's
        vid/did/svid/ssid (see InternalTools/Update-VcfVsanHclData.ps1 for how the asset is
        trimmed from the live feed). ESXi 9.0/9.1 data drives this check's Compatible/
        FirmwareUnsupported verdicts; ESXi 8.0.x data is also shipped solely so a component with
        no 9.x release data can be told apart as IncompatibleWithTargetRelease rather than Unknown (see
        Resolve-VcfCheckVsanHclOlderFamily). When DriverName/DriverVersion/FirmwareVersion are
        supplied, the match drills into
        the entry's per-driver firmware list; when they are omitted, the release-level supported
        vSAN types are returned without a driver/firmware-specific verdict.

        .PARAMETER VendorId
        The host PCI VendorId, normalized lowercase 4-hex-digit (e.g. "1000").

        .PARAMETER DeviceId
        The host PCI DeviceId, normalized lowercase 4-hex-digit.

        .PARAMETER SubVendorId
        The host PCI SubVendorId, normalized lowercase 4-hex-digit.

        .PARAMETER SubDeviceId
        The host PCI SubDeviceId, normalized lowercase 4-hex-digit.

        .PARAMETER EsxVersion
        The ESX release family to check against, e.g. '9.0' or '9.1'.

        .PARAMETER DriverName
        The driver module name in use on the host, e.g. "lsi_msgpt3". Optional - omit to skip the
        driver/firmware-specific match and only resolve release-level HCL presence.

        .PARAMETER DriverVersion
        The driver version in use on the host. Optional, ignored unless DriverName is supplied.

        .PARAMETER FirmwareVersion
        The firmware version in use on the host. Optional, ignored unless DriverName and
        DriverVersion are supplied.

        .OUTPUTS
        [PSObject] with .Status ('Compatible', 'FirmwareUnsupported', 'IncompatibleWithTargetRelease',
        'NotListed', or 'Unknown'), .SupportedVsanTypes (string array, e.g.
        "All Flash:Pass-Through"), .MatchedId (the matched HCL entry's numeric id, or $null), and
        .LatestCompatibleRelease (the ESX major.minor family the component is certified for, e.g.
        '9.0', when Status is 'Compatible' or 'FirmwareUnsupported'; the newest older family it IS
        certified for, e.g. '8.0', when Status is 'IncompatibleWithTargetRelease'; $null otherwise).
        'NotListed'
        means no shipped entry's PCI identity matched - this may be a genuinely unsupported
        component, or this check's shipped data is out of date; it is not a certified verdict.
        'FirmwareUnsupported' means the component matched but the supplied driver/version/firmware
        combination did not. 'IncompatibleWithTargetRelease' means the component matched an HCL entry
        that has release data for an older ESX family but none for EsxVersion's family - it is
        certified, just not for the target release. 'Unknown' means VendorId/DeviceId was empty,
        EsxVersion could not be parsed to a major.minor family, no HCL data could be loaded, or the
        matched entry has no release data for EsxVersion's family or any older family shipped.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$VendorId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$DeviceId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$SubVendorId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$SubDeviceId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxVersion,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$DriverName,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$DriverVersion,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$FirmwareVersion
    )

    $unknown = [PSCustomObject]@{ Status = 'Unknown'; SupportedVsanTypes = @(); MatchedId = $null; LatestCompatibleRelease = $null }
    if ([String]::IsNullOrWhiteSpace($VendorId) -or [String]::IsNullOrWhiteSpace($DeviceId)) { return $unknown }

    $esxFamily = [Regex]::Match($EsxVersion, '^\d+\.\d+').Value
    if ([String]::IsNullOrEmpty($esxFamily)) { return $unknown }

    $data = @(Get-VcfCheckVsanHclData)
    if ($data.Count -eq 0) { return $unknown }

    $matchedEntry = (Get-VcfCheckVsanHclDataIndex)["$VendorId|$DeviceId|$SubVendorId|$SubDeviceId"]
    if ($null -eq $matchedEntry) { return [PSCustomObject]@{ Status = 'NotListed'; SupportedVsanTypes = @(); MatchedId = $null; LatestCompatibleRelease = $null } }

    $release = $matchedEntry.rel.$esxFamily
    if ($null -eq $release) {
        $olderFamily = Resolve-VcfCheckVsanHclOlderFamily -Rel $matchedEntry.rel -TargetFamily $esxFamily
        if ($null -ne $olderFamily) {
            return [PSCustomObject]@{ Status = 'IncompatibleWithTargetRelease'; SupportedVsanTypes = @(); MatchedId = $matchedEntry.id; LatestCompatibleRelease = $olderFamily }
        }
        return $unknown
    }

    if ([String]::IsNullOrWhiteSpace($DriverName)) {
        return [PSCustomObject]@{ Status = 'Compatible'; SupportedVsanTypes = @($release.vs); MatchedId = $matchedEntry.id; LatestCompatibleRelease = $esxFamily }
    }

    $driverVersions = $release.drv.$DriverName
    $versionEntry = if ($driverVersions) { $driverVersions.$DriverVersion } else { $null }
    if ($null -eq $versionEntry) {
        return [PSCustomObject]@{ Status = 'FirmwareUnsupported'; SupportedVsanTypes = @(); MatchedId = $matchedEntry.id; LatestCompatibleRelease = $esxFamily }
    }

    $matchedFirmware = @($versionEntry.fws) | Where-Object { $_.fw -eq $FirmwareVersion } | Select-Object -First 1
    if ($null -eq $matchedFirmware) {
        return [PSCustomObject]@{ Status = 'FirmwareUnsupported'; SupportedVsanTypes = @(); MatchedId = $matchedEntry.id; LatestCompatibleRelease = $esxFamily }
    }

    return [PSCustomObject]@{ Status = 'Compatible'; SupportedVsanTypes = @($matchedFirmware.vs); MatchedId = $matchedEntry.id; LatestCompatibleRelease = $esxFamily }
}
function Get-VcfCheckVsanHclDriveHbaPciIdentity {

    <#
        .SYNOPSIS
        Resolves an NVMe drive's PCI identity via its owning HBA, for vSAN HCL drive matching.

        .DESCRIPTION
        An NVMe drive is its own PCIe endpoint, so ESX enumerates it as its own single-LUN HBA
        (e.g. `vmhba6`) - unlike a SAS/SATA drive, which sits behind a shared HBA/RAID controller
        whose PCI identity describes the controller chip, not any one drive behind it. Joins
        Drive.HbaName (from Get-VcfCheckVMHostScsiDevices) to the matching entry in
        StorageAdapters (from Get-VcfCheckVMHostStorageAdapters) only when Drive.Type indicates
        NVMe, so a shared SAS/RAID HBA's identity is never misattributed to the drives behind it.

        .PARAMETER Drive
        One drive entry as returned by Get-VcfCheckVMHostScsiDevices.

        .PARAMETER StorageAdapters
        The host's storage adapters, as returned by Get-VcfCheckVMHostStorageAdapters.

        .OUTPUTS
        [PSCustomObject] with VendorId, DeviceId, SubVendorId, SubDeviceId - all '' when Drive is
        not NVMe or has no matching storage adapter.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Drive,
        [Parameter(Mandatory = $false)] [PSObject[]]$StorageAdapters = @()
    )

    $empty = [PSCustomObject]@{ VendorId = ''; DeviceId = ''; SubVendorId = ''; SubDeviceId = '' }
    if ("$($Drive.Type)" -notlike 'NVMe *' -or [String]::IsNullOrEmpty($Drive.HbaName)) { return $empty }

    $owningHba = $StorageAdapters | Where-Object { $_.Name -eq $Drive.HbaName } | Select-Object -First 1
    if (-not $owningHba) { return $empty }

    return [PSCustomObject]@{
        VendorId    = $owningHba.VendorId
        DeviceId    = $owningHba.DeviceId
        SubVendorId = $owningHba.SubVendorId
        SubDeviceId = $owningHba.SubDeviceId
    }
}
function Resolve-VcfCheckVsanHclDriveCompatibility {

    <#
        .SYNOPSIS
        Flags whether an ESX host's SSD/HDD drive appears on Broadcom's published vSAN Hardware
        Compatibility List for a given ESX release, and whether its firmware revision is a
        supported combination.

        .DESCRIPTION
        Prefers matching the drive's PCI VendorId/DeviceId/SubVendorId/SubDeviceId (available only
        for NVMe drives, which are their own PCIe endpoint - see
        Get-VcfCheckVsanHclDriveHbaPciIdentity) against a shipped drive HCL entry's vid/did/svid/
        ssid when all four are supplied and present on an entry, since OEMs frequently rebrand a
        drive's reported Model string without changing its underlying PCI identity. Falls back to
        matching the reported Model string (trimmed, case-insensitive) against each shipped drive
        HCL entry's model, then - since some HCL entries carry a marketing description in `model`
        rather than the terse string ESX actually reports (e.g. a Dell-rebranded Toshiba SAS SSD
        whose HCL `model` is "1920GB Solid State Drive..." while ESX reports "PX05SRB192Y", which
        matches the HCL entry's `productid` instead) - to matching Model against each shipped
        entry's productid. productid is not unique across entries (the same physical part is
        sometimes re-listed under multiple HCL ids, occasionally under different vendor strings), so
        productid matches are narrowed to entries whose vendor matches the supplied Vendor
        (case-insensitive) first when more than one productid match exists, otherwise the first
        match wins - this is the only option for SAS/SATA drives, which carry no PCI identity of
        their own (see InternalTools/Update-VcfVsanHclData.ps1 for how the asset is trimmed from the
        live feed). ESXi 9.0/9.1 data drives this check's Compatible/FirmwareUnsupported verdicts;
        ESXi 8.0.x data is also shipped solely so a drive with no 9.x release data can be told
        apart as IncompatibleWithTargetRelease rather than Unknown (see Resolve-VcfCheckVsanHclOlderFamily).
        Some HCL entries carry no firmware value at all (the feed's `firmware` field is blank), in which case any
        reported FirmwareRevision is accepted and the release-level supported vSAN types are
        returned; entries that do carry firmware values require FirmwareRevision to match one of
        them.

        .PARAMETER Model
        The drive's reported Model string, as returned by Get-VcfCheckVMHostScsiDevices.

        .PARAMETER Vendor
        The drive's reported Vendor string, as returned by Get-VcfCheckVMHostScsiDevices. Optional -
        only used to narrow a productid match when more than one shipped entry shares that
        productid; omitting it just means the first productid match wins ties.

        .PARAMETER VendorId
        The drive's owning HBA PCI VendorId, normalized lowercase 4-hex-digit. Optional - omit (or
        supply alongside an empty DeviceId/SubVendorId/SubDeviceId) to skip PCI-identity matching
        and match on Model alone. Only meaningful for NVMe drives (see
        Get-VcfCheckVsanHclDriveHbaPciIdentity) - passing a SAS/SATA HBA's shared PCI identity here
        would incorrectly attribute every drive behind that HBA with the controller's identity.

        .PARAMETER DeviceId
        The drive's owning HBA PCI DeviceId, normalized lowercase 4-hex-digit.

        .PARAMETER SubVendorId
        The drive's owning HBA PCI SubVendorId, normalized lowercase 4-hex-digit.

        .PARAMETER SubDeviceId
        The drive's owning HBA PCI SubDeviceId, normalized lowercase 4-hex-digit.

        .PARAMETER EsxVersion
        The ESX release family to check against, e.g. '9.0' or '9.1'.

        .PARAMETER FirmwareRevision
        The drive's reported firmware revision. Optional - omit to skip the firmware-specific
        match and only resolve release-level HCL presence.

        .OUTPUTS
        [PSObject] with .Status ('Compatible', 'FirmwareUnsupported', 'IncompatibleWithTargetRelease',
        'NotListed', or 'Unknown'), .SupportedVsanTypes (string array, e.g. "AF-Cache"),
        .MatchedId (the matched HCL entry's numeric id, or $null), and .LatestCompatibleRelease (the
        ESX major.minor family the drive is certified for, e.g. '9.0', when Status is 'Compatible'
        or 'FirmwareUnsupported'; the newest older family it IS certified for, e.g. '8.0', when
        Status is 'IncompatibleWithTargetRelease'; $null otherwise). 'NotListed' means no shipped entry's PCI
        identity, model, or productid matched - this may be a genuinely unsupported drive, or this
        check's shipped data is out of date; it is not a certified verdict. 'FirmwareUnsupported'
        means the drive matched but the supplied firmware revision did not, for an entry that does
        track firmware. 'IncompatibleWithTargetRelease' means the drive matched an HCL entry that has
        release data for an older ESX family but none for EsxVersion's family - it is certified,
        just not for the target release. 'Unknown' means Model was empty with no usable PCI
        identity supplied, EsxVersion could not be parsed to a major.minor family, no HCL drive
        data could be loaded, or the matched entry has no release data for EsxVersion's family or
        any older family shipped.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$Model,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$Vendor,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$VendorId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$DeviceId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$SubVendorId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$SubDeviceId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxVersion,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$FirmwareRevision
    )

    $unknown = [PSCustomObject]@{ Status = 'Unknown'; SupportedVsanTypes = @(); MatchedId = $null; LatestCompatibleRelease = $null }
    $hasPciIdentity = -not ([String]::IsNullOrWhiteSpace($VendorId) -or [String]::IsNullOrWhiteSpace($DeviceId) -or `
            [String]::IsNullOrWhiteSpace($SubVendorId) -or [String]::IsNullOrWhiteSpace($SubDeviceId))
    if (-not $hasPciIdentity -and [String]::IsNullOrWhiteSpace($Model)) { return $unknown }

    $esxFamily = [Regex]::Match($EsxVersion, '^\d+\.\d+').Value
    if ([String]::IsNullOrEmpty($esxFamily)) { return $unknown }

    $data = @(Get-VcfCheckVsanHclDriveData)
    if ($data.Count -eq 0) { return $unknown }

    $index = Get-VcfCheckVsanHclDriveDataIndex
    $matchedEntry = $null
    if ($hasPciIdentity) {
        $matchedEntry = $index.PciIndex["$VendorId|$DeviceId|$SubVendorId|$SubDeviceId"]
    }
    if ($null -eq $matchedEntry -and -not [String]::IsNullOrWhiteSpace($Model)) {
        $normalizedModel = $Model.Trim().ToLowerInvariant()
        $matchedEntry = $index.ModelIndex[$normalizedModel]
        if ($null -eq $matchedEntry) {
            $productIdMatches = @(if ($index.ProductIdIndex.ContainsKey($normalizedModel)) { $index.ProductIdIndex[$normalizedModel] })
            if ($productIdMatches.Count -gt 1 -and -not [String]::IsNullOrWhiteSpace($Vendor)) {
                $normalizedVendor = $Vendor.Trim().ToLowerInvariant()
                $vendorNarrowed = @($productIdMatches | Where-Object { "$($_.vendor)".Trim().ToLowerInvariant() -eq $normalizedVendor })
                if ($vendorNarrowed.Count -gt 0) { $productIdMatches = $vendorNarrowed }
            }
            $matchedEntry = $productIdMatches | Select-Object -First 1
        }
    }
    if ($null -eq $matchedEntry) { return [PSCustomObject]@{ Status = 'NotListed'; SupportedVsanTypes = @(); MatchedId = $null; LatestCompatibleRelease = $null } }

    $release = $matchedEntry.rel.$esxFamily
    if ($null -eq $release) {
        $olderFamily = Resolve-VcfCheckVsanHclOlderFamily -Rel $matchedEntry.rel -TargetFamily $esxFamily
        if ($null -ne $olderFamily) {
            return [PSCustomObject]@{ Status = 'IncompatibleWithTargetRelease'; SupportedVsanTypes = @(); MatchedId = $matchedEntry.id; LatestCompatibleRelease = $olderFamily }
        }
        return $unknown
    }

    $trackedFirmwares = @($release.fws | Where-Object { -not [String]::IsNullOrEmpty($_.fw) })
    if ($trackedFirmwares.Count -eq 0) {
        return [PSCustomObject]@{ Status = 'Compatible'; SupportedVsanTypes = @($release.vs); MatchedId = $matchedEntry.id; LatestCompatibleRelease = $esxFamily }
    }

    $matchedFirmware = $trackedFirmwares | Where-Object { $_.fw -eq $FirmwareRevision } | Select-Object -First 1
    if ($null -eq $matchedFirmware) {
        return [PSCustomObject]@{ Status = 'FirmwareUnsupported'; SupportedVsanTypes = @(); MatchedId = $matchedEntry.id; LatestCompatibleRelease = $esxFamily }
    }

    return [PSCustomObject]@{ Status = 'Compatible'; SupportedVsanTypes = @($matchedFirmware.vs); MatchedId = $matchedEntry.id; LatestCompatibleRelease = $esxFamily }
}
function Get-VcfCheckVsanHclHostMemberDiskCanonicalNames {

    <#
        .SYNOPSIS
        Returns the canonical names of a host's drives that belong to a vSAN disk group.

        .DESCRIPTION
        Reads the host's vCenter's vSAN disk group inventory (Get-VcfCheckVsanDiskGroupInventory),
        cached per vCenter FQDN on $Context.VsanDiskGroupInventoryCache since every host in a
        cluster shares the same disk group list, filters to the disk groups owned by VMHost, and
        collects the CanonicalName of each member disk (Get-VcfCheckVsanDiskInventory) - the same
        identity Get-VcfCheckVMHostScsiDevices reports as .Name, so Get-VcfCheckVsanHclHostDetail
        can flag whether each drive is currently used by vSAN. vSAN ESA has no disk groups at all -
        a storage pool's drives are never reported by Get-VsanDiskGroup - so when VMHost has no
        disk groups, this falls back to esxcli's vsan.storage.list (Get-VcfCheckVsanStorageListForHost),
        keeping every drive esxcli reports as "Used by this host", cached per vCenter FQDN + host
        name on $Context.VsanEsaMemberDiskNameCache since it is a per-host esxcli round-trip. A
        vCenter with no vSAN configured, or a lookup failure in either source, yields an empty set -
        callers treat that as "not a vSAN member," not an error, since this is a supplementary flag
        on the HCL check, not its subject.

        .PARAMETER Context
        The VcfCheck.Context object, used to cache the per-vCenter disk group inventory and the
        per-host esxcli fallback.

        .PARAMETER VMHost
        A VMHost inventory object retrieved via Get-VcfCheckVMHostInventory.

        .OUTPUTS
        [String[]] canonical names (e.g. "naa.xxx", "eui.xxx") of VMHost's drives that belong to a
        vSAN disk group, or - for a vSAN ESA host with no disk groups - that esxcli reports as
        used by the host, or an empty array.
    #>

    [CmdletBinding()]
    [OutputType([String[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [PSObject]$VMHost
    )

    $vcenterFqdn = Get-VcfCheckVMHostVCenterFqdn -VMHost $VMHost

    if (-not $Context.VsanDiskGroupInventoryCache.ContainsKey($vcenterFqdn)) {
        $diskGroups = try {
            @(Get-VcfCheckVsanDiskGroupInventory -Server $vcenterFqdn)
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not retrieve vSAN disk group inventory for `"$vcenterFqdn`": $($_.Exception.Message)"
            @()
        }
        $Context.VsanDiskGroupInventoryCache[$vcenterFqdn] = $diskGroups
    }

    $hostDiskGroups = @($Context.VsanDiskGroupInventoryCache[$vcenterFqdn] | Where-Object { $_.VMHost.Name -eq $VMHost.Name })
    if ($hostDiskGroups.Count -gt 0) {
        return @($hostDiskGroups | ForEach-Object {
                try { Get-VcfCheckVsanDiskInventory -VsanDiskGroup $_ } catch { @() }
            } | ForEach-Object { $_.CanonicalName } | Where-Object { -not [String]::IsNullOrEmpty($_) })
    }

    $cacheKey = "$vcenterFqdn|$($VMHost.Name)"
    if (-not $Context.VsanEsaMemberDiskNameCache.ContainsKey($cacheKey)) {
        $esaMemberDiskNames = try {
            @(Get-VcfCheckVsanStorageListForHost -VMHost $VMHost | Where-Object {
                    "$(Get-VcfCheckEsxCliPropertyValue -InputObject $_ -Name 'Used by this host')" -eq 'true'
                } | ForEach-Object { Get-VcfCheckEsxCliPropertyValue -InputObject $_ -Name 'Device' } | Where-Object { -not [String]::IsNullOrEmpty($_) })
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not retrieve vSAN ESA storage pool membership for `"$($VMHost.Name)`": $($_.Exception.Message)"
            @()
        }
        $Context.VsanEsaMemberDiskNameCache[$cacheKey] = $esaMemberDiskNames
    }

    return $Context.VsanEsaMemberDiskNameCache[$cacheKey]
}
function Get-VcfCheckVsanHclHostInUseDeviceNames {

    <#
        .SYNOPSIS
        Returns the storage controller and network adapter device names currently used by vSAN on
        a host.

        .DESCRIPTION
        Storage controllers: reads vsan.debug.controller.list filtered to controllers used by
        vSAN (Get-VcfCheckVsanControllerListForHost, the esxcli equivalent of `esxcli vsan debug
        controller list --used-by-vsan`) and returns each controller's device name (e.g.
        "vmhba0") - the same identity Get-VcfCheckVMHostStorageAdapters reports as .Name.

        Network adapters: reads vsan.network.list (Get-VcfCheckVsanNetworkListForHost) to find the
        VMkernel adapter(s) carrying vSAN traffic, resolves each to its port group
        (Get-VMHostNetworkAdapter), and returns the physical uplink(s) backing that port group -
        the active/standby NICs of the port group's teaming policy for a standard vSwitch
        (Get-VirtualPortGroup | Get-NicTeamingPolicy), or every physical uplink of the owning
        distributed switch as a best-effort fallback when the port group is distributed, since no
        PowerCLI cmdlet reports a distributed port group's active uplinks directly.

        Both esxcli round trips and the network-to-uplink resolution are cached per vCenter FQDN +
        host name on $Context.VsanInUseDeviceNameCache, since Get-VcfCheckVsanHclHostDetail is the
        only caller and should only pay for them once per host per run. A lookup failure for
        either device type yields an empty set for that type - callers treat that as "not
        currently in use," not an error, since this is a supplementary flag on the HCL check, not
        its subject.

        .PARAMETER Context
        The VcfCheck.Context object, used to cache the per-host in-use device names.

        .PARAMETER VMHost
        A VMHost inventory object retrieved via Get-VcfCheckVMHostInventory.

        .OUTPUTS
        [PSCustomObject] with ControllerNames and NetworkAdapterNames ([String[]] each).
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [PSObject]$VMHost
    )

    $vcenterFqdn = Get-VcfCheckVMHostVCenterFqdn -VMHost $VMHost
    $cacheKey = "$vcenterFqdn|$($VMHost.Name)"

    if ($Context.VsanInUseDeviceNameCache.ContainsKey($cacheKey)) {
        return $Context.VsanInUseDeviceNameCache[$cacheKey]
    }

    $controllerNames = try {
        @(Get-VcfCheckVsanControllerListForHost -VMHost $VMHost | ForEach-Object { Get-VcfCheckVsanHclEsxCliFieldValue -EsxCliResult $_ -CandidateNames @('Device', 'VmhbaName', 'DeviceName', 'Name') } | Where-Object { -not [String]::IsNullOrEmpty($_) })
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not retrieve vSAN controller usage for `"$($VMHost.Name)`": $($_.Exception.Message)"
        @()
    }

    $networkAdapterNames = try {
        $vmkNicNames = @(Get-VcfCheckVsanNetworkListForHost -VMHost $VMHost | ForEach-Object { Get-VcfCheckVsanHclEsxCliFieldValue -EsxCliResult $_ -CandidateNames @('VmkNicName', 'InterfaceName', 'VmknicName') } | Where-Object { -not [String]::IsNullOrEmpty($_) })
        @($vmkNicNames | ForEach-Object { Resolve-VcfCheckVsanHclVmkNicUplinkNames -VMHost $VMHost -VmkNicName $_ } | Select-Object -Unique)
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not retrieve vSAN network usage for `"$($VMHost.Name)`": $($_.Exception.Message)"
        @()
    }

    $inUseDeviceNames = [PSCustomObject]@{
        ControllerNames      = $controllerNames
        NetworkAdapterNames  = $networkAdapterNames
    }
    $Context.VsanInUseDeviceNameCache[$cacheKey] = $inUseDeviceNames
    return $inUseDeviceNames
}
function Get-VcfCheckVsanHclEsxCliFieldValue {

    <#
        .SYNOPSIS
        Reads the first present property from an esxcli V2 Invoke() result, tolerating the
        display-name-derived property naming that varies across ESX releases.

        .PARAMETER EsxCliResult
        A single row object returned by an esxcli V2 Invoke() call.

        .PARAMETER CandidateNames
        Property names to try, in order of preference.

        .OUTPUTS
        [String] the first matching property's value, or $null if none of CandidateNames is present.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$EsxCliResult,
        [Parameter(Mandatory = $true)] [String[]]$CandidateNames
    )

    $propertyNames = @($EsxCliResult.PSObject.Properties.Name)
    foreach ($candidateName in $CandidateNames) {
        if ($propertyNames -contains $candidateName) { return "$($EsxCliResult.$candidateName)" }
    }
    return $null
}
function Resolve-VcfCheckVsanHclVmkNicUplinkNames {

    <#
        .SYNOPSIS
        Resolves the physical NIC(s) backing a VMkernel adapter's port group.

        .DESCRIPTION
        Looks up the VMkernel adapter's port group (Get-VcfCheckVMHostVmkNicPortGroupName) and,
        for a standard vSwitch port group, returns its teaming policy's active and standby
        physical NICs (Get-VcfCheckStandardPortGroupTeamingNicNames). For a distributed port
        group, falls back to every physical uplink of the owning distributed switch
        (Get-VcfCheckDistributedPortGroupUplinkNames) - a best-effort superset, not the exact
        active-teaming subset, since no PowerCLI cmdlet reports a distributed port group's active
        uplinks directly. A lookup failure at any stage yields an empty set, not an error, since
        this is a supplementary flag on the HCL check, not its subject.

        .PARAMETER VMHost
        A VMHost inventory object retrieved via Get-VcfCheckVMHostInventory.

        .PARAMETER VmkNicName
        The VMkernel adapter's device name (e.g. "vmk1"), as reported by vsan.network.list.

        .OUTPUTS
        [String[]] physical NIC device names (e.g. "vmnic0"), or an empty array if the adapter or
        its port group could not be resolved.
    #>

    [CmdletBinding()]
    [OutputType([String[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [String]$VmkNicName
    )

    $portGroupName = try { Get-VcfCheckVMHostVmkNicPortGroupName -VMHost $VMHost -Name $VmkNicName } catch { $null }
    if ([String]::IsNullOrEmpty($portGroupName)) { return @() }

    $standardUplinkNames = try { @(Get-VcfCheckStandardPortGroupTeamingNicNames -VMHost $VMHost -PortGroupName $portGroupName) } catch { @() }
    if ($standardUplinkNames.Count -gt 0) { return @($standardUplinkNames | Select-Object -Unique) }

    $distributedUplinkNames = try { @(Get-VcfCheckDistributedPortGroupUplinkNames -VMHost $VMHost -PortGroupName $portGroupName) } catch { @() }
    return @($distributedUplinkNames | Select-Object -Unique)
}
function Group-VcfCheckVsanHclComponentsByModel {

    <#
        .SYNOPSIS
        Collapses a host's per-device vSAN HCL component verdicts into one row per distinct
        Vendor/Model/Status combination, for display.

        .DESCRIPTION
        A host with several identical NICs or drives otherwise produces one component row per
        device (Name vmnic0, vmnic1, ...), which makes the vSAN HCL Compliance Check's per-host
        component table far longer than it needs to be. Groups by DeviceType/Vendor/Model/Status/
        SupportedVsanTypes/LatestCompatibleRelease/CurrentlyUsedByvSAN (not just Vendor/Model, since
        identical models can carry different driver/firmware and therefore different verdicts, or
        one device can currently be used by vSAN while an identical device in the same host is
        not) and rolls the grouped device names into a single comma-delimited Devices property.

        .PARAMETER Components
        Array of per-component PSCustomObjects as built by Get-VcfCheckVsanHclHostDetail (.Name,
        .DeviceType, .Vendor, .Model, .Status, .SupportedVsanTypes, .LatestCompatibleRelease,
        .CurrentlyUsedByvSAN).

        .OUTPUTS
        [PSCustomObject[]] one row per distinct DeviceType/Vendor/Model/Status/SupportedVsanTypes/
        LatestCompatibleRelease/CurrentlyUsedByvSAN combination, with .Devices (comma-delimited, sorted
        device names) in place of .Name.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$Components = @()
    )

    $groups = [Ordered]@{}
    foreach ($component in @($Components)) {
        $vsanTypesKey = ($component.SupportedVsanTypes -join ',')
        $key = @($component.DeviceType, $component.Vendor, $component.Model, $component.Status, $vsanTypesKey, $component.LatestCompatibleRelease, $component.CurrentlyUsedByvSAN) -join '|'
        if (-not $groups.Contains($key)) {
            $groups[$key] = [Ordered]@{
                DeviceType          = $component.DeviceType
                Vendor              = $component.Vendor
                Model               = $component.Model
                Status              = $component.Status
                SupportedVsanTypes  = $component.SupportedVsanTypes
                LatestCompatibleRelease  = $component.LatestCompatibleRelease
                CurrentlyUsedByvSAN = $component.CurrentlyUsedByvSAN
                DeviceNames         = [System.Collections.Generic.List[String]]::new()
            }
        }
        $groups[$key].DeviceNames.Add($component.Name)
    }

    return ,@($groups.Values | ForEach-Object {
            [PSCustomObject]@{
                DeviceType          = $_.DeviceType
                Vendor              = $_.Vendor
                Model               = $_.Model
                Devices             = (($_.DeviceNames | Sort-Object) -join ', ')
                Status              = $_.Status
                SupportedVsanTypes  = $_.SupportedVsanTypes
                LatestCompatibleRelease  = $_.LatestCompatibleRelease
                CurrentlyUsedByvSAN = $_.CurrentlyUsedByvSAN
            }
        })
}

#endregion
