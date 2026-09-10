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
function Test-VcfVcenterDetectHcxplugin {

    <#
        .SYNOPSIS
        Detects whether the HCX plugin is registered as a vCenter extension.

        .DESCRIPTION
        Discovers whether the HCX plugin is registered as a vCenter extension using the
        Get-VcfCheckVCenterExtension wrapper (see Private/InventoryHelpers.ps1). Matches
        extensions whose Key or Description contains "hcx" (case-insensitive substring, not a
        hardcoded exact key). Reports Skipped (not Fail) when absent, since HCX not being present
        is a normal, valid environment state.

        When present, the registered extension's Version is parsed and compared against 9.1:
        Pass (no action needed) when already at or above 9.1, Warning when below 9.1 (HCX must be
        upgraded to HCX 9.1 before upgrading to VCF 9.1), and Warning with a "verify manually"
        remediation when the version string cannot be parsed as a [Version] - erring toward
        surfacing the requirement rather than silently passing an unrecognized version string.

        New-VcfCheckResult (via New-VcfCheckPerDomainResults) falls back to the catalog's
        remediation text whenever a result's Remediation isn't explicitly set, regardless of that
        result's own Status - so relying on that fallback here would leak the HCX-9.1 remediation
        onto Skipped/Pass outcomes too. Remediation is therefore set explicitly per outcome after
        New-VcfCheckPerDomainResults returns, populated only for outcomes that actually need it.

        Iterates every vCenter attached to SDDC Manager (Get-VcfCheckAllVCenterFqdns) and
        turns the per-vCenter outcomes into one result per vCenter domain via
        New-VcfCheckPerDomainResults.

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
    $checkId = 'vcenter_detect_hcxplugin'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }
    $blocking = Get-VcfCheckBlockingStatusFromCatalog -CheckId $checkId
    $validationCriteria = $catalogEntry.validationCriteria
    $remediation = $catalogEntry.remediation
    $minimumSupportedVersion = [Version]'9.1'

    try {
        $vcenterFqdns = Get-VcfCheckAllVCenterFqdns -Context $Context
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Area vCenter -Status Error `
            -Exception $_.Exception.Message -ValidationCriteria $validationCriteria -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $outcomes = foreach ($vcenterFqdn in $vcenterFqdns) {
        $iterationStartedAt = Get-Date
        $outcome = try {
            Connect-VcfCheckVCenter -Context $Context -Fqdn $vcenterFqdn
            $extensions = Get-VcfCheckVCenterExtension -Server $vcenterFqdn
            $hcxExtension = $extensions | Where-Object {
                $_.Key -match 'hcx' -or $_.Description.Label -match 'HCX'
            } | Select-Object -First 1

            if (-not $hcxExtension) {
                [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Skipped'; Detail = 'HCX plugin is not registered as a vCenter extension.'; SkipReasonTag = 'HCX not installed'; Blocking = $blocking; Rows = @(); Remediation = $null }
            } else {
                $rows = @([PSCustomObject]@{
                    Key = $hcxExtension.Key
                    Description = $hcxExtension.Description.Label
                    Version = $hcxExtension.Version
                })
                $parsedVersion = $null
                $versionParsed = [Version]::TryParse($hcxExtension.Version, [ref]$parsedVersion)

                if ($versionParsed -and $parsedVersion -ge $minimumSupportedVersion) {
                    [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Pass'; Detail = "HCX plugin detected: extension key `"$($hcxExtension.Key)`", version $($hcxExtension.Version) (meets the HCX 9.1 minimum required for VCF 9.1)."; Blocking = $blocking; Rows = $rows; Remediation = $null }
                } elseif ($versionParsed) {
                    [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Warning'; Detail = "HCX plugin detected: extension key `"$($hcxExtension.Key)`", version $($hcxExtension.Version) (below the HCX 9.1 minimum required for VCF 9.1)."; Blocking = $blocking; Rows = $rows; Remediation = $remediation }
                } else {
                    [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Warning'; Detail = "HCX plugin detected: extension key `"$($hcxExtension.Key)`", version `"$($hcxExtension.Version)`" could not be parsed to confirm it meets the HCX 9.1 minimum required for VCF 9.1 - verify manually."; Blocking = $blocking; Rows = $rows; Remediation = $remediation }
                }
            }
        } catch {
            [PSCustomObject]@{ VCenterFqdn = $vcenterFqdn; Status = 'Error'; Detail = $_.Exception.Message; Blocking = $blocking; Rows = @(); Remediation = $null }
        }
        $outcome | Add-Member -NotePropertyName StartedAt -NotePropertyValue $iterationStartedAt -Force
        $outcome | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date) -Force
        $outcome
    }

    $results = New-VcfCheckPerDomainResults -Context $Context -PerVCenterOutcome $outcomes -CheckId $checkId -Area vCenter `
        -ValidationCriteria $validationCriteria -StartedAt $startedAt -DisplayName $displayName

    foreach ($result in $results) {
        $outcomeRemediation = ($outcomes | Where-Object { $_.VCenterFqdn -eq $result.TargetComponent } | Select-Object -First 1).Remediation
        $result.Remediation = $outcomeRemediation
    }

    return $results
}
