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
#region Aria

function ConvertTo-VcfCheckBytes {

    <#
        .SYNOPSIS
        Converts size strings (e.g., '9.8G', '853M') to bytes.

        .PARAMETER Size
        The size string to convert.

        .OUTPUTS
        [Double] the value in bytes.
    #>

    [CmdletBinding()]
    [OutputType([Double])]
    Param (
        [Parameter(Mandatory = $true)] [String]$Size
    )

    if ([String]::IsNullOrWhiteSpace($Size)) { return 0 }
    if ($Size -match '^([\d\.]+)\s*([KMGTPE]?B?)$') {
        $val = [Double]$Matches[1]
        switch ($Matches[2].ToUpper().TrimEnd('B')) {
            'M' { return $val * 1MB }
            'G' { return $val * 1GB }
            'T' { return $val * 1TB }
            default { return $val }
        }
    }
    return 0
}
function Test-VcfVrslcmDiskSpace {

    <#
        .SYNOPSIS
        Verifies that the root filesystem on the Aria Suite Lifecycle Manager (vRSLCM) appliance
        has at least 3 GB of free space.

        .DESCRIPTION
        Queries mounted filesystems on the vRSLCM appliance using Get-VcfCheckVrslcmConnection and
        Invoke-VcfCheckVrslcmApi against '/lcm/lcops/api/v2/settings/system-details/disks'
        (falling back to '/lcm/lcops/api/v2/settings/system-details' if the disks endpoint is unavailable).

        Evaluates free space on the root volume ('/' or '/root') against a 3.0 GB threshold.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if Aria Suite Lifecycle Manager is not deployed in the environment.
        - Pass: Returns 'Pass' if the root filesystem has at least 3.0 GB of free space.
        - Warning: Returns 'Warning' if the root filesystem has less than 3.0 GB of free space.
        - Error: Returns 'Error' if connection to vRSLCM fails, disk endpoints return no data, or size strings cannot be parsed.

        Constructs a detailed breakdown table ('Rows') of all reported filesystems (Total, Used, UsedPercent),
        assigning 'Pass'/'Warning' to the root filesystem and 'N/A' to non-root volumes.

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
    $checkId = 'vrslcm_disk_space_report'
    $requiredFreeGB = 3.0

    try {
        $connection = Get-VcfCheckVrslcmConnection -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    if (-not $connection) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Suite Lifecycle Manager is not deployed in this environment.' -SkipReasonTag 'vRSLCM not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    try {
        Write-LogMessage -Type DEBUG -Message "Attempting to query /lcm/lcops/api/v2/settings/system-details/disks endpoint."
        $disks = Invoke-VcfCheckVrslcmApi -Connection $connection -Path '/lcm/lcops/api/v2/settings/system-details/disks'
    } catch {
        Write-LogMessage -Type DEBUG -Message "Disks endpoint failed ($_), falling back to system-details endpoint."
        try {
            $systemDetails = Invoke-VcfCheckVrslcmApi -Connection $connection -Path '/lcm/lcops/api/v2/settings/system-details'
            if ($systemDetails -and $systemDetails.storagePercentage) {
                $disks = @([PSCustomObject]@{
                    diskName          = '/'
                    storagePercentage = $systemDetails.storagePercentage
                    usedStorage       = $systemDetails.usedStorage
                    totalStorage      = $systemDetails.totalStorage
                })
            }
        } catch {
            return New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $connection.Fqdn `
                -Exception (ConvertTo-VcfCheckFriendlyVrslcmError -Fqdn $connection.Fqdn -ErrorMessage $_.Exception.Message) `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }
    }

    if (-not $disks) {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $connection.Fqdn `
            -Exception 'No disk information returned from the API.' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    # Normalize disk array handling across API responses and fallback
    $diskArray = if ($disks.diskStorageDTO) { @($disks.diskStorageDTO) } else { @($disks) }

    if (-not $diskArray -or $diskArray.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $connection.Fqdn `
            -Exception 'No disk storage data found in the API response.' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    Write-LogMessage -Type DEBUG -Message "Found $($diskArray.Count) disk(s) from API: $(($diskArray | ForEach-Object { $_.diskName }) -join ', ')"

    # Identify the root filesystem (accepts either '/root' or '/')
    $rootDisk = $diskArray | Where-Object { $_.diskName -in @('/root', '/') } | Select-Object -First 1

    if (-not $rootDisk) {
        $availableDisks = ($diskArray | ForEach-Object { $_.diskName }) -join ', '
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $connection.Fqdn `
            -Exception "Root filesystem ('/root' or '/') was not found in the disk space report. Available disks: $availableDisks" `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    # Calculate free space in bytes
    $totalBytes = ConvertTo-VcfCheckBytes $rootDisk.totalStorage
    $usedBytes  = ConvertTo-VcfCheckBytes $rootDisk.usedStorage

    if ($totalBytes -gt 0) {
        if ($usedBytes -gt 0) {
            $freeBytes = $totalBytes - $usedBytes
        } elseif ($rootDisk.storagePercentage) {
            $usedPercent = [double]($rootDisk.storagePercentage -replace '[^\d\.]', '')
            $freeBytes = $totalBytes * (1 - ($usedPercent / 100))
        } else {
            $freeBytes = 0
        }
    } else {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $connection.Fqdn `
            -Exception "Unable to parse total storage size for /root volume ('$($rootDisk.totalStorage)')." `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }

    $freeGB = [math]::Round($freeBytes / 1GB, 2)

    # Return Pass if >= 3GB free, Warning if under 3GB free
    if ($freeGB -ge $requiredFreeGB) {
        $status = 'Pass'
        $detail = "The /root filesystem has $freeGB GB of free space available."
    } else {
        $status = 'Warning'
        $detail = "The /root filesystem has only $freeGB GB of free space available (recommended minimum: $requiredFreeGB GB)."
    }

    # Build results table with row-specific status
    $rows = @($diskArray | ForEach-Object {
        $isRoot = $_.diskName -in @('/root', '/')

        $rowStatus = if ($isRoot) {
            if ($freeGB -ge $requiredFreeGB) { 'Pass' } else { 'Warning' }
        } else {
            'N/A'
        }

        [PSCustomObject]@{
            Filesystem  = $_.diskName
            Total       = $_.totalStorage
            Used        = $_.usedStorage
            UsedPercent = $_.storagePercentage
            Status      = $rowStatus
        }
    })

    return New-VcfCheckResult -CheckId $checkId -Status $status `
        -TargetComponent $connection.Fqdn -Detail $detail -Rows $rows `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
#endregion
