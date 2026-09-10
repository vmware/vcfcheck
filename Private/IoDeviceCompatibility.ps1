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
function Get-VcfCheckVMHostNetworkDevices {

    <#
        .SYNOPSIS
        Returns physical network adapters (vmnics) for an ESX host, including driver and firmware details.

        .OUTPUTS
        [PSCustomObject[]] with Name, Vendor, Model, Driver, DriverVersion, FirmwareVersion, DeviceType.
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
            $driver = ''
            $driverVersion = ''
            $firmwareVersion = ''

            if ($nic.ExtensionData.Pci -and $pciDevices) {
                $pciId = $nic.ExtensionData.Pci
                $pciDevice = $pciDevices | Where-Object { $_.Id -eq $pciId } | Select-Object -First 1
                if ($pciDevice) {
                    $vendor = $pciDevice.VendorName
                    $model = $pciDevice.DeviceName
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
                Name             = $nic.Name
                Vendor           = $vendor
                Model            = $model
                Driver           = $driver
                DriverVersion    = $driverVersion
                FirmwareVersion  = $firmwareVersion
                DeviceType       = 'Network'
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
        [PSCustomObject[]] with Name, Vendor, Model, Type, Driver, Status, DeviceType.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost
    )

    $devices = @()
    $hbas = @($VMHost | Get-VMHostHba -ErrorAction SilentlyContinue)
    $pciDevices = @($VMHost | Get-VMHostPciDevice -ErrorAction SilentlyContinue)

    foreach ($hba in $hbas) {
        if ($hba) {
            $vendor = ''
            $model = ''
            $pciDevice = $null

            if ($hba.ExtensionData.Pci -and $pciDevices) {
                $pciId = $hba.ExtensionData.Pci
                $pciDevice = $pciDevices | Where-Object { $_.Id -eq $pciId } | Select-Object -First 1
                if ($pciDevice) {
                    $vendor = $pciDevice.VendorName
                    $model = $pciDevice.DeviceName
                }
            }

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
                Name       = $hba.Name
                Vendor     = $vendor
                Model      = $model
                Type       = $humanType
                Driver     = $hba.Driver
                Status     = $hba.Status
                DeviceType = $humanType
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
        [PSCustomObject[]] with Name, Vendor, Model, Type, Capacity, Status, DeviceType.
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
        }
    }

    return $devices
}

#endregion
