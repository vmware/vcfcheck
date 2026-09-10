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
function Test-VcfVcenterCheckDiskSpaceInodeAndHprof {

    <#
        .SYNOPSIS
        Checks disk space and inode utilization on the vCenter appliance's filesystems, and scans
        for leftover Java heap-dump (.hprof) files.

        .DESCRIPTION
        Executes guest commands via Invoke-VcfApplianceCommand on every vCenter appliance VM
        managed by SDDC Manager to inspect filesystem capacity, inode utilization, and leftover Java
        heap dump (.hprof) files in a single appliance execution.

        Disk Space and Inode Evaluation:
        - Executes `df -h` and `df -i` to measure disk space and inode usage.
        - Any filesystem reporting disk space or inode utilization at or above 80% returns a Warning status.

        Heap Dump Scanning:
        - Executes `find / -xdev -name '*.hprof' 2>/dev/null` to identify leftover heap dumps from prior
          service crashes.
        - Any detected .hprof files raise a Warning status and list the file paths in the result detail.

        Target Addressing:
        - Connects to and executes commands against vCenter appliance VMs via the management vCenter
          (Get-VcfCheckManagementVCenterFqdn), as all vCenter appliance VMs reside on management
          domain compute.
        - Evaluates each vCenter and delegates per-domain result aggregation to
          Invoke-VcfCheckPerVCenterCheck.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .OUTPUTS
        [PSObject] a VcfCheck.Result.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'vcenter_disk_space_inode_and_hprof_check'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }

    try {
        $managementVCenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Area vCenter -Status Error `
            -Exception $_.Exception.Message -ValidationCriteria $catalogEntry.validationCriteria -Remediation $catalogEntry.remediation -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    return Invoke-VcfCheckPerVCenterCheck -Context $Context -CheckId $checkId -Area vCenter -DisplayName $DisplayName -Body {
        param($Context, $VCenterFqdn)
        Connect-VcfCheckVCenter -Context $Context -Fqdn $managementVCenterFqdn
        $rootCredential = Get-VcfCheckComponentCredential -Context $Context -ResourceType VCENTER -AccountType USER -Fqdn $VCenterFqdn -Username 'root'
        $vmName = ($VCenterFqdn -split '\.')[0]

        $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $managementVCenterFqdn -Credential $rootCredential `
            -ScriptText 'df -h --output=target,pcent | tail -n +2; echo "---INODES---"; df -i --output=target,ipcent | tail -n +2; echo "---HPROF---"; find / -xdev -name "*.hprof" 2>/dev/null'

        if (-not $commandResult.Success) {
            if ($commandResult.ErrorCategory -eq 'ToolsNotRunning') {
                $detail = "This check cannot run without VMware Tools running on the target appliance - skipped for now. $($commandResult.ErrorMessage)"
                return [PSCustomObject]@{ Status = 'Skipped'; Detail = $detail; SkipReasonTag = 'VMware Tools not running'; Rows = @() }
            }
            return [PSCustomObject]@{ Status = 'Error'; Detail = $commandResult.ErrorMessage; Rows = @() }
        }

        $sections = $commandResult.ScriptOutput -split '---INODES---|---HPROF---'
        $filesystemData = @{}
        $flagged = [System.Collections.Generic.List[String]]::new()

        foreach ($line in ($sections[0] -split "`n")) {
            $line = $line.Trim()
            if (-not $line) { continue }
            $parts = $line -split '\s+'
            if ($parts.Count -lt 2) { continue }
            $mountPoint = $parts[-1]
            $percentStr = $parts[-2]
            $percent = 0
            if ([Int32]::TryParse(($percentStr -replace '%', ''), [ref]$percent)) {
                if (-not $filesystemData[$mountPoint]) { $filesystemData[$mountPoint] = @{} }
                $filesystemData[$mountPoint]['SpacePercent'] = $percent
                if ($percent -ge 80) {
                    $flagged.Add("$mountPoint (space): $percent%")
                }
            }
        }

        foreach ($line in ($sections[1] -split "`n")) {
            $line = $line.Trim()
            if (-not $line) { continue }
            $parts = $line -split '\s+'
            if ($parts.Count -lt 2) { continue }
            $mountPoint = $parts[0]
            $percent = 0
            if ([Int32]::TryParse(($parts[1] -replace '%', ''), [ref]$percent)) {
                if (-not $filesystemData[$mountPoint]) { $filesystemData[$mountPoint] = @{} }
                $filesystemData[$mountPoint]['InodePercent'] = $percent
                if ($percent -ge 80) {
                    $flagged.Add("$mountPoint (inode): $percent%")
                }
            }
        }

        $hprofFiles = @($sections[2] -split "`n" | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })

        $rows = @($filesystemData.Keys | ForEach-Object {
            $target = $_
            $data = $filesystemData[$target]
            $spacePercent = if ($data.ContainsKey('SpacePercent')) { $data['SpacePercent'] } else { 0 }
            $inodePercent = if ($data.ContainsKey('InodePercent')) { $data['InodePercent'] } else { 0 }
            $status = if ($spacePercent -ge 80) { 'Warning' } else { 'Pass' }
            [PSCustomObject]@{ MountedOn = $target; SpaceUsedPercent = $spacePercent; InodeUsedPercent = $inodePercent; Status = $status }
        })

        $detailParts = [System.Collections.Generic.List[String]]::new()
        if ($flagged.Count -gt 0) {
            $detailParts.Add("Filesystem(s) at or above 80% utilization: $($flagged -join '; ')")
        }
        if ($hprofFiles.Count -gt 0) {
            $detailParts.Add("Found $($hprofFiles.Count) heap dump file(s): $($hprofFiles -join '; ')")
        }

        if ($detailParts.Count -gt 0) {
            return [PSCustomObject]@{ Status = 'Warning'; Detail = ($detailParts -join ' '); Rows = $rows }
        }

        return [PSCustomObject]@{ Status = 'Pass'; Detail = 'Every filesystem is below 80% disk space and inode utilization, and no heap dump files were found.'; Rows = $rows }
    }
}
