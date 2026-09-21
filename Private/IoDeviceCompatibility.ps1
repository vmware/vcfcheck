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
#region IoDeviceCompatibility

function Get-VcfCheckVMHostCpuInfo {

    <#
        .SYNOPSIS
        Returns CPU series information and specifications for an ESX host.

        .OUTPUTS
        [PSCustomObject] with CpuSeries, TotalCores, TotalThreads, Sockets, MhzPerCpu.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost
    )

    $cpuInfo = $VMHost.ExtensionData.Summary.Hardware.CpuModel
    $numCpuCores = $VMHost.ExtensionData.Summary.Hardware.NumCpuCores
    $numCpuThreads = $VMHost.ExtensionData.Summary.Hardware.NumCpuThreads
    $numCpuPkgs = $VMHost.ExtensionData.Summary.Hardware.NumCpuPkgs
    $cpuHz = $VMHost.ExtensionData.Summary.Hardware.CpuMhz

    return [PSCustomObject]@{
        CpuSeries    = $cpuInfo
        TotalCores   = $numCpuCores
        TotalThreads = $numCpuThreads
        Sockets      = $numCpuPkgs
        MhzPerCpu    = $cpuHz
    }
}
function ConvertTo-VcfCheckPciHexId {

    <#
        .SYNOPSIS
        Normalizes a PCI VendorId/DeviceId/SubVendorId/SubDeviceId to a lowercase 4-hex-digit
        string, matching the id format used by the packaged vSAN HCL asset.

        .DESCRIPTION
        vSphere reports these ids as signed 16-bit values, so any id with the high bit set (>=
        0x8000, common for storage controller and NIC subsystem ids) arrives as a negative
        [Int]. Masking with 0xFFFF before formatting discards the sign-extended high bits so the
        result is always the correct 4-hex-digit code instead of an 8-digit two's-complement
        string that can never match a shipped HCL entry.

        .OUTPUTS
        [String] lowercase 4-hex-digit id, or '' if Value is $null or not convertible.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [Object]$Value
    )

    if ($null -eq $Value) { return '' }
    try {
        return ('{0:x4}' -f ([Int]$Value -band 0xFFFF))
    } catch {
        return ''
    }
}
function Get-VcfCheckHbaPciIdentity {

    <#
        .SYNOPSIS
        Resolves an HBA's vendor/model strings and normalized PCI VendorId/DeviceId/SubVendorId/
        SubDeviceId from the host's PCI device list.

        .OUTPUTS
        [PSCustomObject] with Vendor, Model, VendorId, DeviceId, SubVendorId, SubDeviceId - all ''
        if the HBA has no matching PCI device.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Hba,
        [Parameter(Mandatory = $false)] [PSObject[]]$PciDevices = @()
    )

    $identity = [PSCustomObject]@{ Vendor = ''; Model = ''; VendorId = ''; DeviceId = ''; SubVendorId = ''; SubDeviceId = '' }
    if (-not $Hba.ExtensionData.Pci -or -not $PciDevices) { return $identity }

    $pciDevice = $PciDevices | Where-Object { $_.Id -eq $Hba.ExtensionData.Pci } | Select-Object -First 1
    if (-not $pciDevice) { return $identity }

    $identity.Vendor = $pciDevice.VendorName
    $identity.Model = $pciDevice.DeviceName
    $identity.VendorId = ConvertTo-VcfCheckPciHexId -Value $pciDevice.VendorId
    $identity.DeviceId = ConvertTo-VcfCheckPciHexId -Value $pciDevice.DeviceId
    $identity.SubVendorId = ConvertTo-VcfCheckPciHexId -Value $pciDevice.SubVendorId
    $identity.SubDeviceId = ConvertTo-VcfCheckPciHexId -Value $pciDevice.SubDeviceId
    return $identity
}
function Get-VcfCheckHbaDriverVersion {

    <#
        .SYNOPSIS
        Resolves the installed driver version for an HBA via the loaded VMkernel module's esxcli
        details.

        .OUTPUTS
        [String] driver version, or '' if unavailable.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [PSObject]$EsxCli,
        [Parameter(Mandatory = $true)] [String]$DriverName
    )

    if (-not $EsxCli -or -not $DriverName) { return '' }

    try {
        $moduleDetails = Invoke-VcfCheckWithTimeout -TimeoutSeconds 30 -ArgumentList $EsxCli, $DriverName -ScriptBlock {
            param($InnerEsxCli, $InnerDriverName)
            $InnerEsxCli.system.module.get.Invoke(@{module = $InnerDriverName })
        }
        if ($moduleDetails -and $moduleDetails.Version) { return $moduleDetails.Version }
        return ''
    } catch {
        return ''
    }
}
function Get-VcfCheckVMHostNetworkDevices {

    <#
        .SYNOPSIS
        Returns physical network adapters (vmnics) for an ESX host, including driver and firmware details.

        .OUTPUTS
        [PSCustomObject[]] with Name, Vendor, Model, VendorId, DeviceId, SubVendorId, SubDeviceId,
        Driver, DriverVersion, FirmwareVersion, DeviceType.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost
    )

    $devices = @()
    $nics = @($VMHost | Get-VMHostNetworkAdapter -Physical -ErrorAction SilentlyContinue)
    $pciDevices = @($VMHost | Get-VMHostPciDevice -ErrorAction SilentlyContinue)
    $esxcli = $null

    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2 -ErrorAction SilentlyContinue
    } catch {
        $esxcli = $null
    }

    foreach ($nic in $nics) {
        if ($nic) {
            $vendor = ''
            $model = ''
            $vendorId = ''
            $deviceId = ''
            $subVendorId = ''
            $subDeviceId = ''
            $driver = ''
            $driverVersion = ''
            $firmwareVersion = ''

            if ($nic.ExtensionData.Pci -and $pciDevices) {
                $pciId = $nic.ExtensionData.Pci
                $pciDevice = $pciDevices | Where-Object { $_.Id -eq $pciId } | Select-Object -First 1
                if ($pciDevice) {
                    $vendor = $pciDevice.VendorName
                    $model = $pciDevice.DeviceName
                    $vendorId = ConvertTo-VcfCheckPciHexId -Value $pciDevice.VendorId
                    $deviceId = ConvertTo-VcfCheckPciHexId -Value $pciDevice.DeviceId
                    $subVendorId = ConvertTo-VcfCheckPciHexId -Value $pciDevice.SubVendorId
                    $subDeviceId = ConvertTo-VcfCheckPciHexId -Value $pciDevice.SubDeviceId
                }
            }

            if ($esxcli) {
                try {
                    $nicDetails = Invoke-VcfCheckWithTimeout -TimeoutSeconds 30 -ArgumentList $esxcli, $nic.Name -ScriptBlock {
                        param($EsxCli, $NicName)
                        $EsxCli.network.nic.get.Invoke(@{nicname = $NicName })
                    }
                    if ($nicDetails) {
                        $driver = if ($nicDetails.Driver) { $nicDetails.Driver } else { '' }
                        $driverVersion = if ($nicDetails.DriverVersion) { $nicDetails.DriverVersion } else { '' }
                        $firmwareVersion = if ($nicDetails.FirmwareVersion) { $nicDetails.FirmwareVersion } else { '' }
                    }
                } catch {
                    $driver = ''
                    $driverVersion = ''
                    $firmwareVersion = ''
                }
            }

            $devices += [PSCustomObject]@{
                Name            = $nic.Name
                Vendor          = $vendor
                Model           = $model
                VendorId        = $vendorId
                DeviceId        = $deviceId
                SubVendorId     = $subVendorId
                SubDeviceId     = $subDeviceId
                Driver          = $driver
                DriverVersion   = $driverVersion
                FirmwareVersion = $firmwareVersion
                DeviceType      = 'Network'
            }
        }
    }

    return $devices
}
function Get-VcfCheckVMHostStorageAdapters {

    <#
        .SYNOPSIS
        Returns storage Host Bus Adapters (SAS, Fibre Channel, SATA, NVMe) for an ESX host with human-readable type descriptions.

        .OUTPUTS
        [PSCustomObject[]] with Name, Vendor, Model, VendorId, DeviceId, SubVendorId, SubDeviceId,
        Type, Driver, DriverVersion, Status, DeviceType.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost
    )

    $devices = @()
    $hbas = @($VMHost | Get-VMHostHba -ErrorAction SilentlyContinue)
    $pciDevices = @($VMHost | Get-VMHostPciDevice -ErrorAction SilentlyContinue)
    $esxcli = $null

    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2 -ErrorAction SilentlyContinue
    } catch {
        $esxcli = $null
    }

    foreach ($hba in $hbas) {
        if ($hba) {
            $pciIdentity = Get-VcfCheckHbaPciIdentity -Hba $hba -PciDevices $pciDevices
            $vendor = $pciIdentity.Vendor
            $model = $pciIdentity.Model
            $vendorId = $pciIdentity.VendorId
            $deviceId = $pciIdentity.DeviceId
            $subVendorId = $pciIdentity.SubVendorId
            $subDeviceId = $pciIdentity.SubDeviceId
            $driverVersion = Get-VcfCheckHbaDriverVersion -EsxCli $esxcli -DriverName $hba.Driver

            if (-not $vendor) {
                $vendor = $hba.Vendor
            }
            if (-not $model) {
                $model = if ($hba.Model -and $hba.Model -ne 'N/A') { $hba.Model } else { $hba.Name }
            }

            $rawType = switch ($hba.Type) {
                0 { 'Block' }
                1 { 'FibreChannel' }
                2 { 'iSCSI' }
                3 { 'ParallelScsi' }
                'FibreChannel' { 'FibreChannel' }
                'iSCSI' { 'iSCSI' }
                'SAS' { 'SAS' }
                'SATA' { 'SATA' }
                'ParallelScsi' { 'ParallelScsi' }
                'SoftwareNVMe' { 'SoftwareNVMe' }
                default { $hba.Type }
            }

            $humanType = switch -Wildcard ($rawType) {
                'FibreChannel' { 'Fibre Channel Host Bus Adapter (HBA)' }
                'iSCSI' {
                    if ($hba.IsSoftware) { 'Software iSCSI Initiator' } else { 'Hardware iSCSI Adapter' }
                }
                'Block' {
                    if ($model -like '*NVMe*') {
                        'NVMe Controller'
                    } elseif ($model -like '*RAID*' -or $model -like '*PERC*' -or $model -like '*Smart Array*') {
                        'Hardware RAID Controller'
                    } else {
                        'SAS / SATA Host Bus Adapter'
                    }
                }
                'SAS' { 'SAS Host Bus Adapter' }
                'SATA' { 'SATA Controller' }
                'ParallelScsi' { 'Parallel SCSI Controller' }
                'SoftwareNVMe' { 'Software NVMe over Fabrics (NVMe-oF)' }
                default {
                    if ($model -like '*NVMe*') { 'NVMe Controller' } else { $rawType }
                }
            }

            $devices += [PSCustomObject]@{
                Name          = $hba.Name
                Vendor        = $vendor
                Model         = $model
                VendorId      = $vendorId
                DeviceId      = $deviceId
                SubVendorId   = $subVendorId
                SubDeviceId   = $subDeviceId
                Type          = $humanType
                Driver        = $hba.Driver
                DriverVersion = $driverVersion
                Status        = $hba.Status
                DeviceType    = $humanType
            }
        }
    }

    return $devices
}
function Get-VcfCheckVMHostScsiDevices {

    <#
        .SYNOPSIS
        Returns SCSI logical units (storage devices) for an ESX host with protocol and media type information.

        .OUTPUTS
        [PSCustomObject[]] with Name, Vendor, Model, Type, Capacity, Status, DeviceType, Revision,
        HbaName (the owning vmhbaN parsed from RuntimeName - for an NVMe drive this is the drive's
        own PCIe endpoint and can be joined back to Get-VcfCheckVMHostStorageAdapters for its PCI
        identity; for a SAS/SATA drive it is a shared HBA and carries no drive-specific identity).
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    Param (
        [Parameter(Mandatory = $true)]
        [PSObject]$VMHost
    )

    $luns = Get-ScsiLun -VMHost $VMHost -LunType disk -ErrorAction SilentlyContinue

    # Assign directly to array to avoid expensive array rebuilding (+=$)
    $devices = foreach ($lun in $luns) {
        if (-not $lun) { continue }

        $media = if ($lun.IsSsd) { 'SSD' } else { 'HDD' }

        # Determine protocol using switch statement
        $protocol = switch ($lun) {
            { $_.CanonicalName -like 'nvme.*' -or $_.CanonicalName -like 'eui.*' -or $_.Model -like '*NVMe*' } { 'NVMe'; break }
            { $_.CanonicalName -like 't10.ATA*' -or $_.Model -like '*SATA*' } { 'SATA'; break }
            { $_.CanonicalName -like 'naa.5*' } { 'SAS'; break }
            default { 'SCSI' }
        }

        # Trim vendor to handle fixed-width trailing spaces typical in vSphere SCSI inquiry data
        $trimmedVendor = "$($lun.Vendor)".Trim()

        # Check Vendor and override generic bus protocol names with 'Unknown'
        $vendor = switch -Exact ($trimmedVendor) {
            'ATA'     { 'Unknown' }
            'NVMe'    { 'Unknown' }
            'SAS'     { 'Unknown' }
            'SATA'    { 'Unknown' }
            'SCSI'    { 'Unknown' }
            default   { $trimmedVendor }
        }

        [PSCustomObject]@{
            Name       = $lun.CanonicalName
            Vendor     = $vendor
            Model      = $lun.Model
            Type       = "$protocol $media"
            Capacity   = [Math]::Round($lun.CapacityGB, 2)
            Status     = $lun.RuntimeStatus
            DeviceType = 'SCSI'
            Revision   = "$($lun.ExtensionData.Revision)".Trim()
            HbaName    = "$($lun.RuntimeName)".Split(':')[0]
        }
    }

    return $devices
}
function Get-VcfCheckVMHostVCenterFqdn {

    <#
        .SYNOPSIS
        Extracts the connected vCenter FQDN from a VMHost object's Uid.

        .OUTPUTS
        [String] the vCenter FQDN, or an empty string if it cannot be determined.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost
    )

    if ($VMHost.Uid -match '@([^@/]+):\d+/') {
        return $Matches[1]
    }
    return ''
}
function Get-VcfCheckCachedHostHardwareDetail {

    <#
        .SYNOPSIS
        Returns network and storage adapter hardware detail for an ESX host, cached per run.

        .DESCRIPTION
        Wraps Get-VcfCheckVMHostNetworkDevices, Get-VcfCheckVMHostStorageAdapters, and
        Get-VcfCheckVMHostScsiDevices behind a per-run cache on
        $Context.EsxHostHardwareDetailCache, keyed by vCenter FQDN + host name, so multiple checks
        that need the same host's device data (e.g. Test-VcfEsxHardwareDetails and
        Test-VcfVsanHclCompliance) don't each pay for the expensive per-host esxcli/SCSI
        collection independently.

        .PARAMETER Context
        The VcfCheck.Context object.

        .PARAMETER VMHost
        A VMHost inventory object retrieved via Get-VcfCheckVMHostInventory.

        .OUTPUTS
        [PSCustomObject] with NetworkAdapters, StorageAdapters, and Drives - the raw arrays
        returned by Get-VcfCheckVMHostNetworkDevices / Get-VcfCheckVMHostStorageAdapters /
        Get-VcfCheckVMHostScsiDevices.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [PSObject]$VMHost
    )

    $vcenterFqdn = Get-VcfCheckVMHostVCenterFqdn -VMHost $VMHost
    $cacheKey = "$vcenterFqdn|$($VMHost.Name)"

    if ($Context.EsxHostHardwareDetailCache.ContainsKey($cacheKey)) {
        return $Context.EsxHostHardwareDetailCache[$cacheKey]
    }

    $detail = [PSCustomObject]@{
        NetworkAdapters = @(Get-VcfCheckVMHostNetworkDevices -VMHost $VMHost -ErrorAction SilentlyContinue)
        StorageAdapters = @(Get-VcfCheckVMHostStorageAdapters -VMHost $VMHost -ErrorAction SilentlyContinue)
        Drives          = @(Get-VcfCheckVMHostScsiDevices -VMHost $VMHost -ErrorAction SilentlyContinue)
    }
    $Context.EsxHostHardwareDetailCache[$cacheKey] = $detail
    return $detail
}

#endregion
