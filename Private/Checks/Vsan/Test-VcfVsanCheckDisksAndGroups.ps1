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

function Get-VcfCheckVsanTroubleshootingKbText {

    <#
        .SYNOPSIS
        Formats a standard troubleshooting KB message sentence.

        .DESCRIPTION
        Formats a standardized KB reference string used across vSAN precheck fail and warning messages,
        ensuring consistent formatting and central maintenance of KB numbers and URLs.

        .PARAMETER Number
        The KB article number (e.g. '326929').

        .PARAMETER Url
        The full KB article URL.

        .PARAMETER Prefix
        Text preceding the KB reference (defaults to 'For troubleshooting guidance, see').

        .OUTPUTS
        [String] Formatted troubleshooting KB message string.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [String]$Number,
        [Parameter(Mandatory = $true)] [String]$Url,
        [Parameter(Mandatory = $false)] [String]$Prefix = 'For troubleshooting guidance, see'
    )

    return "$Prefix KB $Number`: $Url"
}

function Get-VcfCheckEsxCliPropertyValue {

    <#
        .SYNOPSIS
        Reads a property off an ESXCLI V2 result object, tolerant of field name and casing variations.

        .DESCRIPTION
        Inspects ESXCLI result objects case-insensitively after stripping spaces and underscores
        to ensure reliable property retrieval across varying ESX release schemas.

        .PARAMETER InputObject
        One ESXCLI result entry (e.g., an element returned by ESXCLI invocation).

        .PARAMETER Name
        The property field name to retrieve.

        .OUTPUTS
        [Object] The matched property value, or $null if not found.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$InputObject,
        [Parameter(Mandatory = $true)] [String]$Name
    )

    $normalizedTarget = $Name -replace '[\s_]', ''
    $match = $InputObject.PSObject.Properties | Where-Object { ($_.Name -replace '[\s_]', '') -eq $normalizedTarget } | Select-Object -First 1

    if ($match) {
        return $match.Value
    }
    return $null
}

function ConvertTo-VcfCheckVsanDiskEsxCliDetail {

    <#
        .SYNOPSIS
        Extracts ESXCLI disk attributes for a specified canonical disk device.

        .DESCRIPTION
        Queries ESXCLI `vsan.storage.list` entries for a matching canonical device name and extracts
        disk-level attributes including Checksum, Checksum OK, In CMMDS, Used by host, Deduplication,
        Compression, Encryption, and Encryption Metadata Checksum OK.

        Returns $null if no matching device entry is found, allowing the caller to fall back to
        cluster-level configuration values.

        .PARAMETER EsxCliEntries
        Array of ESXCLI `vsan.storage.list` entries for the host, or $null if unavailable.

        .PARAMETER CanonicalName
        The canonical device name of the disk to match.

        .OUTPUTS
        [PSCustomObject] Structured disk attributes from ESXCLI, or $null if unmatched.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$EsxCliEntries,
        [Parameter(Mandatory = $true)] [String]$CanonicalName
    )

    if (-not $EsxCliEntries -or $EsxCliEntries.Count -eq 0) {
        return $null
    }

    $entry = $EsxCliEntries | Where-Object { [String](Get-VcfCheckEsxCliPropertyValue -InputObject $_ -Name 'Device') -eq $CanonicalName } | Select-Object -First 1
    if (-not $entry) {
        return $null
    }

    return [PSCustomObject]@{
        DisplayName                  = Get-VcfCheckEsxCliPropertyValue -InputObject $entry -Name 'Display Name'
        InCmmds                      = Get-VcfCheckEsxCliPropertyValue -InputObject $entry -Name 'In CMMDS'
        UsedByThisHost               = Get-VcfCheckEsxCliPropertyValue -InputObject $entry -Name 'Used by this host'
        Deduplication                = Get-VcfCheckEsxCliPropertyValue -InputObject $entry -Name 'Deduplication'
        Compression                  = Get-VcfCheckEsxCliPropertyValue -InputObject $entry -Name 'Compression'
        Checksum                     = Get-VcfCheckEsxCliPropertyValue -InputObject $entry -Name 'Checksum'
        ChecksumOk                   = Get-VcfCheckEsxCliPropertyValue -InputObject $entry -Name 'Checksum OK'
        Encryption                   = Get-VcfCheckEsxCliPropertyValue -InputObject $entry -Name 'Encryption'
        EncryptionMetadataChecksumOk = Get-VcfCheckEsxCliPropertyValue -InputObject $entry -Name 'Encryption Metadata Checksum OK'
    }
}

function Test-VcfCheckEsxCliValueIsFalse {

    <#
        .SYNOPSIS
        Determines whether an ESXCLI property explicitly evaluates to false.

        .DESCRIPTION
        Parses string-based or boolean property values returned by ESXCLI queries, returning $true
        only when the value explicitly matches 'false' (case-insensitive). Treats $null or empty
        values as false signals to avoid false-positive failure reporting when ESXCLI data is unavailable.

        .PARAMETER Value
        The raw property value to evaluate.

        .OUTPUTS
        [Bool] $true if the value explicitly equals 'false'; otherwise $false.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [Object]$Value
    )

    if ($null -eq $Value -or [String]::IsNullOrWhiteSpace([String]$Value)) {
        return $false
    }
    return [String]$Value -ieq 'false'
}

function Get-VcfCheckVsanDiskRowFailureReasons {

    <#
        .SYNOPSIS
        Evaluates failure conditions for an individual vSAN disk-group member disk.

        .DESCRIPTION
        Evaluates disk group mount status and granular ESXCLI health attributes (Checksum OK,
        In CMMDS, Used by this host, Encryption Metadata Checksum OK) to identify specific
        disk failure reasons.

        .PARAMETER IsMounted
        Indicates whether the parent disk group is currently mounted.

        .PARAMETER EsxCliDetail
        Structured ESXCLI detail object for the disk, or $null if unavailable.

        .OUTPUTS
        [String[]] Array of identified failure reason keys (e.g., 'Unmounted', 'ChecksumFailed', 'NotInCmmds').
    #>

    [CmdletBinding()]
    [OutputType([String[]])]
    Param (
        [Parameter(Mandatory = $true)] [Bool]$IsMounted,
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$EsxCliDetail
    )

    $reasons = @()
    if (-not $IsMounted) { $reasons += 'Unmounted' }

    if ($EsxCliDetail) {
        if (Test-VcfCheckEsxCliValueIsFalse -Value $EsxCliDetail.ChecksumOk) { $reasons += 'ChecksumFailed' }
        if (Test-VcfCheckEsxCliValueIsFalse -Value $EsxCliDetail.EncryptionMetadataChecksumOk) { $reasons += 'EncryptionMetadataChecksumFailed' }
        if (Test-VcfCheckEsxCliValueIsFalse -Value $EsxCliDetail.InCmmds) { $reasons += 'NotInCmmds' }
        if (Test-VcfCheckEsxCliValueIsFalse -Value $EsxCliDetail.UsedByThisHost) { $reasons += 'NotUsedByThisHost' }
    }

    return $reasons
}

function ConvertTo-VcfCheckVsanDiskRow {

    <#
        .SYNOPSIS
        Constructs a report row for a vSAN disk-group member disk, combining inventory and ESXCLI details.

        .DESCRIPTION
        Merges base disk group properties, PowerCLI vSAN disk inventory data, and granular ESXCLI disk
        attributes into a unified report object. Evaluates row-level failure reasons via
        Get-VcfCheckVsanDiskRowFailureReasons to determine row Status ('Pass' or 'Fail') and Issue keys.

        .PARAMETER BaseRow
        Hashtable containing base disk group attributes (Host, DiskGroup, DiskGroupType, IsMounted).

        .PARAMETER Disk
        PowerCLI VsanDisk object, or $null if disk inventory is unavailable.

        .PARAMETER EsxCliDetail
        ESXCLI detail object for the disk, or $null if unavailable.

        .PARAMETER Fallback
        Hashtable containing cluster-level fallback settings (Deduplication, Compression, Encryption).

        .PARAMETER DeviceWhenUnknown
        Device identifier string to use when $Disk is $null.

        .OUTPUTS
        [PSCustomObject] A structured report row for the disk.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [Hashtable]$BaseRow,
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$Disk,
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$EsxCliDetail,
        [Parameter(Mandatory = $true)] [Hashtable]$Fallback,
        [Parameter(Mandatory = $false)] [String]$DeviceWhenUnknown = ''
    )

    $failureReasons = Get-VcfCheckVsanDiskRowFailureReasons -IsMounted $BaseRow.IsMounted -EsxCliDetail $EsxCliDetail

    return [PSCustomObject]($BaseRow + @{
        Device                       = if ($Disk) { $Disk.CanonicalName } else { $DeviceWhenUnknown }
        DisplayName                  = if ($EsxCliDetail) { $EsxCliDetail.DisplayName } else { '' }
        Tier                         = if ($Disk) { if ($Disk.IsCacheDisk) { 'Cache' } else { 'Capacity' } } else { '' }
        IsSsd                        = if ($Disk) { $Disk.IsSsd } else { '' }
        CapacityGB                   = if ($Disk) { $Disk.CapacityGB } else { '' }
        DiskUuid                     = if ($Disk) { $Disk.Uuid } else { '' }
        Deduplication                = if ($EsxCliDetail) { $EsxCliDetail.Deduplication } else { $Fallback.Deduplication }
        Compression                  = if ($EsxCliDetail) { $EsxCliDetail.Compression } else { $Fallback.Compression }
        Encryption                   = if ($EsxCliDetail) { $EsxCliDetail.Encryption } else { $Fallback.Encryption }
        Checksum                     = if ($EsxCliDetail) { $EsxCliDetail.Checksum } else { $null }
        ChecksumOk                   = if ($EsxCliDetail) { $EsxCliDetail.ChecksumOk } else { $null }
        InCmmds                      = if ($EsxCliDetail) { $EsxCliDetail.InCmmds } else { $null }
        UsedByThisHost               = if ($EsxCliDetail) { $EsxCliDetail.UsedByThisHost } else { $null }
        EncryptionMetadataChecksumOk = if ($EsxCliDetail) { $EsxCliDetail.EncryptionMetadataChecksumOk } else { $null }
        Issue                        = $failureReasons -join '; '
        Status                       = if ($failureReasons.Count -gt 0) { 'Fail' } else { 'Pass' }
    })
}

function ConvertTo-VcfCheckVsanDiskGroupRows {

    <#
        .SYNOPSIS
        Expands a vSAN disk group into individual report rows for each member disk.

        .DESCRIPTION
        Retrieves member disk inventory for a vSAN disk group and constructs individual report rows
        enriched with ESXCLI disk details and cluster-level configuration fallbacks.

        If member disk inventory retrieval fails, generates a single placeholder row marked with
        'Unknown' device status to preserve overall precheck visibility.

        .PARAMETER DiskGroup
        The vSAN disk group object to expand.

        .PARAMETER ClusterConfig
        Cluster configuration object for fallback values, or $null if unavailable.

        .PARAMETER EsxCliEntries
        Array of ESXCLI storage list entries for the host, or $null if unavailable.

        .OUTPUTS
        [PSCustomObject] Object containing 'Rows' ([PSObject[]]) and 'DiskDetailFailed' ([Bool]).
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$DiskGroup,
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$ClusterConfig,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$EsxCliEntries
    )

    $fallback = @{
        Deduplication = if ($ClusterConfig) { $ClusterConfig.SpaceEfficiencyEnabled } else { $null }
        Compression   = if ($ClusterConfig) { $ClusterConfig.SpaceCompressionEnabled } else { $null }
        Encryption    = if ($ClusterConfig) { $ClusterConfig.EncryptionEnabled } else { $null }
    }
    $baseRow = @{
        Host          = $DiskGroup.VMHost.Name
        DiskGroup     = $DiskGroup.Uuid
        DiskGroupType = $DiskGroup.DiskGroupType
        IsMounted     = [Bool]$DiskGroup.IsMounted
    }

    $diskDetailFailed = $false
    $disks = @()
    try {
        $disks = @(Get-VcfCheckVsanDiskInventory -VsanDiskGroup $DiskGroup)
    } catch {
        $diskDetailFailed = $true
    }

    if ($disks.Count -eq 0) {
        $deviceWhenUnknown = if ($diskDetailFailed) { 'Unknown' } else { '' }
        $row = ConvertTo-VcfCheckVsanDiskRow -BaseRow $baseRow -Disk $null -EsxCliDetail $null -Fallback $fallback -DeviceWhenUnknown $deviceWhenUnknown
        return [PSCustomObject]@{ Rows = @($row); DiskDetailFailed = $diskDetailFailed }
    }

    $rows = @($disks | ForEach-Object {
        $esxcliDetail = ConvertTo-VcfCheckVsanDiskEsxCliDetail -EsxCliEntries $EsxCliEntries -CanonicalName $_.CanonicalName
        ConvertTo-VcfCheckVsanDiskRow -BaseRow $baseRow -Disk $_ -EsxCliDetail $esxcliDetail -Fallback $fallback
    })

    return [PSCustomObject]@{ Rows = $rows; DiskDetailFailed = $diskDetailFailed }
}

function Get-VcfCheckVsanDiskFailureReasonCatalog {

    <#
        .SYNOPSIS
        Returns the catalog mapping vSAN disk failure reason keys to descriptive text and KB references.

        .DESCRIPTION
        Provides a centralized dictionary mapping failure reason keys (such as 'Unmounted', 'ChecksumFailed',
        'NotInCmmds') to user-friendly failure descriptions and relevant Knowledge Base article links.

        .OUTPUTS
        [OrderedDictionary] Catalog mapping failure reason keys to hashtables containing 'Text' and 'Kb' entries.
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    Param ()

    return [Ordered]@{
        Unmounted                        = @{ Text = 'unmounted disk group(s)'; Kb = 'KB 413551 (https://knowledge.broadcom.com/external/article/413551/upgrade-precheck-failed-with-vsan-health.html)' }
        ChecksumFailed                   = @{ Text = 'disk(s) failing checksum verification'; Kb = 'KB 326850 (https://knowledge.broadcom.com/external/article/326850/vmware-vsan-disk-encounters-medium-error.html)' }
        EncryptionMetadataChecksumFailed = @{ Text = 'disk(s) failing encryption metadata checksum verification'; Kb = 'KB 326850 (https://knowledge.broadcom.com/external/article/326850/vmware-vsan-disk-encounters-medium-error.html)' }
        NotInCmmds                       = @{ Text = 'disk(s) missing from CMMDS (cluster directory service)'; Kb = 'KB 383362 (https://knowledge.broadcom.com/external/article/383362/vsan-skyline-health-reports-error-physi.html)' }
        NotUsedByThisHost                = @{ Text = 'disk(s) reporting as not in use by their host'; Kb = 'KB 390534 (https://knowledge.broadcom.com/external/article/390534/vsan-troubleshooting-disk-failure-issue.html)' }
    }
}

function ConvertTo-VcfCheckVsanDiskHostDetailDetailText {

    <#
        .SYNOPSIS
        Generates detailed failure explanation text for a vSAN disk report row.

        .DESCRIPTION
        Parses failure reason keys from a disk row's Issue field and maps them against
        Get-VcfCheckVsanDiskFailureReasonCatalog to produce detailed explanation text with KB references.

        .PARAMETER Row
        The structured disk report row to evaluate.

        .OUTPUTS
        [String] Formatted detail message describing the disk health state or specific failure reasons.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Row
    )

    if ($Row.Status -ne 'Fail') {
        return 'Mounted and healthy.'
    }

    $catalog = Get-VcfCheckVsanDiskFailureReasonCatalog
    $reasonKeys = @($Row.Issue -split '; ' | Where-Object { $_ })
    $messages = @(foreach ($reasonKey in $reasonKeys) {
        if (-not $catalog.Contains($reasonKey)) { continue }
        $catalogEntry = $catalog[$reasonKey]
        "$($catalogEntry.Text -creplace '\(s\)', ''). See $($catalogEntry.Kb)."
    })

    return $messages -join ' '
}

function ConvertTo-VcfCheckVsanDiskHostDetail {

    <#
        .SYNOPSIS
        Transforms a disk report row into a HostDetails card representation for UI rendering.

        .DESCRIPTION
        Maps disk evaluation row attributes to a structured HostDetails object optimized for card-based
        display in precheck reports. Groups properties under the device identifier and includes detailed
        failure messaging.

        .PARAMETER Row
        The structured disk report row to transform.

        .OUTPUTS
        [PSCustomObject] A formatted HostDetails card object.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Row
    )

    $detail = [Ordered]@{
        HostName = $Row.Device
        Status   = $Row.Status
        Detail   = ConvertTo-VcfCheckVsanDiskHostDetailDetailText -Row $Row
        Host     = $Row.Host
        DiskGroup     = $Row.DiskGroup
        DiskGroupType = $Row.DiskGroupType
        IsMounted     = $Row.IsMounted
    }
    if ($Row.DisplayName -and $Row.DisplayName -ne $Row.Device) {
        $detail['DisplayName'] = $Row.DisplayName
    }
    $detail['Tier']                         = $Row.Tier
    $detail['IsSsd']                        = $Row.IsSsd
    $detail['CapacityGB']                   = $Row.CapacityGB
    $detail['DiskUuid']                     = $Row.DiskUuid
    $detail['Deduplication']                = $Row.Deduplication
    $detail['Compression']                  = $Row.Compression
    $detail['Encryption']                   = $Row.Encryption
    $detail['Checksum']                     = $Row.Checksum
    $detail['ChecksumOk']                   = $Row.ChecksumOk
    $detail['InCmmds']                      = $Row.InCmmds
    $detail['UsedByThisHost']               = $Row.UsedByThisHost
    $detail['EncryptionMetadataChecksumOk'] = $Row.EncryptionMetadataChecksumOk

    return [PSCustomObject]$detail
}

function Format-VcfCheckVsanDiskGroupCheckDetail {

    <#
        .SYNOPSIS
        Formats the overall summary detail message for the vSAN disk and disk group check.

        .DESCRIPTION
        Aggregates failure keys across all report rows and formats a comprehensive detail summary.
        Groups affected hosts by failure type and attaches specific Broadcom KB articles for remediation guidance.

        .PARAMETER Rows
        Array of expanded disk report rows.

        .PARAMETER DiskGroupCount
        Total number of vSAN disk groups evaluated.

        .OUTPUTS
        [String] Formatted summary detail message.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [Object[]]$Rows,
        [Parameter(Mandatory = $true)] [Int]$DiskGroupCount
    )

    $failingRows = @($Rows | Where-Object { $_.Status -eq 'Fail' })
    if ($failingRows.Count -eq 0) {
        return "Checked $DiskGroupCount disk group(s); all disks are mounted and healthy."
    }

    $reasonCatalog = Get-VcfCheckVsanDiskFailureReasonCatalog

    $messages = @()
    foreach ($reasonKey in $reasonCatalog.Keys) {
        $matchingRows = @($failingRows | Where-Object { ($_.Issue -split '; ') -contains $reasonKey })
        if ($matchingRows.Count -eq 0) { continue }
        $hostNames = ($matchingRows | ForEach-Object { $_.Host } | Select-Object -Unique) -join '; '
        $catalogEntry = $reasonCatalog[$reasonKey]
        $messages += "$($matchingRows.Count) $($catalogEntry.Text) found on: $hostNames. See $($catalogEntry.Kb)."
    }

    return $messages -join ' '
}

function Test-VcfVsanCheckDisksAndGroups {

    <#
        .SYNOPSIS
        Checks that every vSAN disk and disk group, across every vCenter attached to SDDC Manager, is mounted and healthy.

        .DESCRIPTION
        Queries vSAN disk groups and member disks across all vCenter appliances connected to SDDC Manager
        using Get-VcfCheckVsanDiskGroupInventory, Get-VcfCheckVsanDiskInventory, and ESXCLI storage commands.

        Evaluates disk group mount state and member disk health indicators:
        - Pass: All vSAN disk groups are mounted, and all member disks report healthy status across CMMDS,
          checksum, host usage, and encryption metadata checks.
        - Fail: One or more disk groups are unmounted, or individual member disks fail checksum, CMMDS membership,
          or host usage validations.
        - Skipped: No vSAN disk groups are present on the target vCenter.

        Enriches results with ESXCLI disk storage attributes and constructs detailed HostDetails card
        objects for individual disk visualization in precheck reporting.

        Delegates per-vCenter execution and per-domain outcome packaging to Invoke-VcfCheckPerVCenterCheck.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [PSObject[]] Per-vCenter check results generated by Invoke-VcfCheckPerVCenterCheck.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    return Invoke-VcfCheckPerVCenterCheck -Context $Context -CheckId 'vsan_check_disks_and_groups' -Area vSAN -DisplayName $DisplayName -Body {
        param($Context, $VCenterFqdn)

        $diskGroups = @(Get-VcfCheckVsanDiskGroupInventory -Server $VCenterFqdn)

        if ($diskGroups.Count -eq 0) {
            return [PSCustomObject]@{ Status = 'Skipped'; Detail = 'No vSAN disk groups found on this vCenter.'; SkipReasonTag = 'no vSAN disk groups'; Rows = @() }
        }

        $clusterConfigs = @(Get-VcfCheckVsanClusterConfig -Server $VCenterFqdn)
        $esxCliEntriesByHost = @{}
        $diskDetailFailures = 0

        $expandedRows = @($diskGroups | ForEach-Object {
            $diskGroup = $_
            $hostName = $diskGroup.VMHost.Name

            if (-not $esxCliEntriesByHost.ContainsKey($hostName)) {
                try {
                    $esxCliEntriesByHost[$hostName] = @(Get-VcfCheckVsanStorageListForHost -VMHost $diskGroup.VMHost)
                } catch {
                    $esxCliEntriesByHost[$hostName] = $null
                }
            }

            $cluster = Get-VcfCheckClusterForVMHost -VMHost $diskGroup.VMHost -Server $VCenterFqdn
            $clusterConfig = $clusterConfigs | Where-Object { $cluster -and $_.Cluster.Name -eq $cluster.Name } | Select-Object -First 1

            $expanded = ConvertTo-VcfCheckVsanDiskGroupRows -DiskGroup $diskGroup -ClusterConfig $clusterConfig -EsxCliEntries $esxCliEntriesByHost[$hostName]
            if ($expanded.DiskDetailFailed) { $diskDetailFailures++ }
            $expanded.Rows
        })

        $rows = @($expandedRows | Sort-Object -Property Host, DiskGroup, Device)

        $detail = Format-VcfCheckVsanDiskGroupCheckDetail -Rows $rows -DiskGroupCount $diskGroups.Count
        if ($diskDetailFailures -gt 0) {
            $detail += " Disk-level detail could not be retrieved for $diskDetailFailures disk group(s) - this usually means the host is Not Responding/Disconnected in vCenter rather than a problem with the disk group itself; see KB 344682 (https://knowledge.broadcom.com/external/article/344682/troubleshooting-an-esxi-host-in-a-not-re.html)."
        }

        $status = if ($rows | Where-Object { $_.Status -eq 'Fail' }) { 'Fail' } else { 'Pass' }
        $hostDetails = @($rows | ForEach-Object { ConvertTo-VcfCheckVsanDiskHostDetail -Row $_ })
        return [PSCustomObject]@{ Status = $status; Detail = $detail; Rows = @(); HostDetails = $hostDetails; HostDetailsLabel = 'Disks' }
    }
}
