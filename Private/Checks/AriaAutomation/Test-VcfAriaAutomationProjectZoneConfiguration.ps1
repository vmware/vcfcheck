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
#region AriaAutomation
function Test-VcfAriaAutomationProjectZoneConfiguration {

    <#
        .SYNOPSIS
        Verifies that every Aria Automation project has at least one Cloud Zone assigned.

        .DESCRIPTION
        Calls Get-VcfCheckAriaAutomationTargets to connect to every known Aria Automation
        instance (the SDDC-Manager-known one, plus any standalone endpoint declared on the
        environment - see Private/AriaAutomationHelpers.ps1) and calls GET /iaas/api/projects
        against each, returning one result per target. A project is flagged when its Zones
        property is empty - per the IaaS API schema, a project with no Cloud Zone assignment
        cannot place any workload and blocks every deployment attempt against it.

        Outcome behavior:
        - Skipped: Returns 'Skipped' if no Aria Automation instance is known at all.
        - Pass: Returns 'Pass' for a target if every project has at least one Cloud Zone
          assigned, including when no projects are configured at all.
        - Fail: Returns 'Fail' for a target if one or more projects have zero Cloud Zones
          assigned.
        - Error: Returns 'Error' for a target if connecting or querying it fails.

        Builds a detailed breakdown table ('Rows') of every project's Name, ZoneCount, and
        AdministratorCount.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER DisplayName
        Optional friendly display name for the check result.

        .OUTPUTS
        [Object[]] One VcfCheck.Result object per known Aria Automation instance.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date
    $checkId = 'aria_automation_project_zone_configuration'

    $targets = Get-VcfCheckAriaAutomationTargets -Context $Context
    if ($targets.Count -eq 0) {
        return New-VcfCheckResult -CheckId $checkId -Status Skipped `
            -Detail 'Aria Automation is not deployed in this environment.' -SkipReasonTag 'Aria Automation not deployed' `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName -Component 'Aria Automation'
    }

    $results = foreach ($target in $targets) {
        $resultDisplayName = if ($targets.Count -gt 1) { "$DisplayName ($($target.Name))" } else { $DisplayName }

        if ($target.ConnectError) {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn -Exception $target.ConnectError `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        try {
            $response = Invoke-VcfCheckAriaAutomationApi -CredentialInfo $target.CredentialInfo -Path '/iaas/api/projects'
        } catch {
            New-VcfCheckResult -CheckId $checkId -Status Error `
                -TargetComponent $target.Fqdn `
                -Exception "Failed to query Aria Automation for projects: $($_.Exception.Message)" `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        $projects = @($response.content)
        if ($projects.Count -eq 0) {
            New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $target.Fqdn -Detail 'No projects are configured in Aria Automation.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
            continue
        }

        Write-LogMessage -Type DEBUG -Message "Found $($projects.Count) project(s) on `"$($target.Fqdn)`": $(($projects | ForEach-Object { $_.name }) -join ', ')"

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $flagged = [System.Collections.Generic.List[String]]::new()

        foreach ($project in $projects) {
            $zoneCount = @($project.zones).Count
            $rows.Add([PSCustomObject]@{
                Name                 = $project.name
                ZoneCount            = $zoneCount
                AdministratorCount   = @($project.administrators).Count
            })

            if ($zoneCount -eq 0) {
                $flagged.Add("$($project.name): no Cloud Zone assigned")
            }
        }

        if ($flagged.Count -eq 0) {
            $status = 'Pass'
            $detail = "All $($projects.Count) Aria Automation project(s) have at least one Cloud Zone assigned."
        } else {
            $status = 'Fail'
            $detail = ($flagged.ToArray()) -join '; '
        }

        New-VcfCheckResult -CheckId $checkId -Status $status `
            -TargetComponent $target.Fqdn -Detail $detail -Rows ($rows.ToArray() | Sort-Object -Property Name) `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $resultDisplayName -Component 'Aria Automation'
    }

    return @($results)
}
#endregion
