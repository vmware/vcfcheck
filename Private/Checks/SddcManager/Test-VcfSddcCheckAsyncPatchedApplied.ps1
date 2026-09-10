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
function Test-VcfSddcCheckAsyncPatchedApplied {

    <#
        .SYNOPSIS
        Checks whether any async-patch upgrade history exists on SDDC Manager.

        .DESCRIPTION
        Inspects the SDDC Manager appliance for async-patch tool upgrade history by checking
        files matching 'upgrade_history*' under '/var/log/vmware/vcf/lcm/tools/asyncpatchtool/'.

        Execution is performed directly on the SDDC Manager appliance via Invoke-VcfApplianceCommand
        using vCenter guest operations, grepping for 'apTool' context along with bundleId, id, status,
        and taskId fields without retrieving or extracting log archives off-node.

        Evaluation logic:
        - Pass: Log directory does not exist (no async-patch tool execution history).
        - Warning: Log directory exists but contains no upgrade_history files.
        - Fail: Async-patch upgrade history files are found.
        - Error: Appliance command execution fails or returns unexpected output.

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
    $checkId = 'sddc_check_async_patched_applied'
    $logDir = '/var/log/vmware/vcf/lcm/tools/asyncpatchtool/'

    try {
        $vcenterFqdn = Get-VcfCheckManagementVCenterFqdn -Context $Context
        Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
        $rootCredential = Get-VcfCheckSddcManagerRootCredential -Context $Context
        $vmName = ($Context.SddcManagerFqdn -split '\.')[0]

        $script = @"
if [ ! -d '$logDir' ]; then echo 'CHECK_NO_DIR'; exit 0; fi
files=`$(find '$logDir' -maxdepth 1 -name 'upgrade_history*' -type f)
if [ -z "`$files" ]; then echo 'CHECK_NO_FILES'; exit 0; fi
echo 'CHECK_FILES_FOUND'
for f in `$files; do grep 'apTool' -A 15 -B 1 "`$f" | grep -e 'bundleId' -e 'id' -e 'status' -e 'taskId'; done
"@

        $commandResult = Invoke-VcfApplianceCommand -VmName $vmName -Server $vcenterFqdn -Credential $rootCredential -ScriptText $script

        if (-not $commandResult.Success) {
            return New-VcfCheckApplianceCommandFailureResult -CommandResult $commandResult -CheckId $checkId `
                -TargetComponent $vmName -StartedAt $startedAt
        }

        $output = $commandResult.ScriptOutput

        if ($output -match 'CHECK_NO_DIR') {
            return New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $vmName -Detail 'Async-patch tool log directory does not exist - no upgrade history to review.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        if ($output -match 'CHECK_NO_FILES') {
            return New-VcfCheckResult -CheckId $checkId -Status Warning `
                -TargetComponent $vmName -Detail 'Async-patch tool log directory exists but contains no upgrade_history files.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        if ($output -match 'CHECK_FILES_FOUND') {
            $detailLines = ($output -split "`n" | Where-Object { $_ -and $_ -ne 'CHECK_FILES_FOUND' }) -join "`n"
            return New-VcfCheckResult -CheckId $checkId -Status Fail `
                -TargetComponent $vmName -Detail "Async-patch upgrade history found:`n$detailLines" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
        }

        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $vmName -Detail "Unexpected guest command output: $output" `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
    }
}
