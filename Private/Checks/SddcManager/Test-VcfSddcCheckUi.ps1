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
function Test-VcfSddcCheckUi {

    <#
        .SYNOPSIS
        Runs SDDC Manager's pre-upgrade check-set assessment and reports per-resource results.

        .DESCRIPTION
        Queries applicable UPGRADE-type check-sets per domain via Invoke-VcfQueryCheckSets,
        triggers a check run against returned resources via Invoke-VcfTriggerCheckRun, and
        polls the run to completion via Invoke-VcfGetResult.

        The check run produces an AssessmentOutput object whose detail is structured as a recursive
        EntityRest tree under PhysicalPresentedData. The tree is flattened by Get-VcfCheckUiCheckRunRowSet
        into structured result rows representing resource classifications and error details.

        Status determination:
        - Fail: Any flattened check reports an ERROR or FAIL severity, or the run orchestration fails.
        - Warning: Any check reports a WARNING severity and no errors are present.
        - Error: The check run is canceled, returns no per-check results, times out, or encounters execution failures.
        - Pass: All checks complete without warnings or errors.

        If SDK Guid path parameter formatting issues prevent status retrieval, polling falls back to direct
        REST requests using Get-VcfCheckCheckSetResultViaRest.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER InitialDelaySeconds
        Delay before the first status poll. Default 30.

        .PARAMETER MaxPollAttempts
        Maximum number of status polls before giving up. Default 40.

        .PARAMETER PollDelaySeconds
        Delay between polls. Default 20.

        .OUTPUTS
        [PSObject] a VcfCheck.Result.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = '',
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$InitialDelaySeconds = 30,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$MaxPollAttempts = 40,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$PollDelaySeconds = 20
    )

    $startedAt = Get-Date
    $checkId = 'sddc_pre_check_ui'
    $catalogEntry = (Get-VcfCheckCatalog)[$checkId]
    $displayName = if ([String]::IsNullOrEmpty($DisplayName)) { $catalogEntry.displayName } else { $DisplayName }

    try {
        $domains = @((Invoke-VcfGetDomains -ErrorAction Stop).Elements)
        $domainResources = @($domains | ForEach-Object { Initialize-VcfCheckSetQueryDomainResources -DomainId $_.Id })
        if ($domainResources.Count -eq 0) {
            return New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $Context.SddcManagerFqdn -Detail 'No domains were found to query for applicable check-sets.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
        }

        $queryInput = Initialize-VcfCheckSetQueryInput -CheckSetType 'UPGRADE' -Domains $domainResources
        $queryResult = Invoke-VcfQueryCheckSets -CheckSetQueryInput $queryInput -ErrorAction Stop
        $resourceResults = @($queryResult.Resources | Where-Object { $_ -and @($_.CheckSets).Count -gt 0 })

        if ($resourceResults.Count -eq 0) {
            return New-VcfCheckResult -CheckId $checkId -Status Pass `
                -TargetComponent $Context.SddcManagerFqdn -Detail 'No resources with an applicable upgrade check-set were found.' `
                -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
        }

        $resourceSelections = @($resourceResults | ForEach-Object {
                $resourceResult = $_
                $domainInfo = Initialize-VcfDomainInfo -DomainId $resourceResult.Domain.DomainId -DomainName $resourceResult.Domain.DomainName
                $candidates = @($resourceResult.CheckSets | ForEach-Object { Initialize-VcfSelectedCheckSetCandidate -CheckSetId $_.CheckSetId })
                Initialize-VcfCheckSetResourceSelection -ResourceName $resourceResult.ResourceName -ResourceId $resourceResult.ResourceId `
                    -ResourceType $resourceResult.ResourceType -Domain $domainInfo -CheckSets $candidates
            })

        $runInput = Initialize-VcfCheckSetRunInput -QueryId $queryResult.QueryId -Resources $resourceSelections
        $task = Invoke-VcfTriggerCheckRun -CheckSetRunInput $runInput -ErrorAction Stop
        $runId = $task.Id
    } catch {
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $Context.SddcManagerFqdn -Exception $_.Exception.Message `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $result = $null
    $status = ''
    Write-VcfCheckSubProgress -Context $Context -Current 0 -Total $MaxPollAttempts -Unit 'poll attempts' `
        -Label 'SDDC Manager check-set run status: starting'

    if ($InitialDelaySeconds -gt 0) {
        Start-Sleep -Seconds $InitialDelaySeconds
    }

    $attempt = 0
    $useRestFallback = $false
    while (([String]::IsNullOrWhiteSpace($status) -or $status -match 'IN_?PROGRESS') -and $attempt -lt $MaxPollAttempts) {
        try {
            $result = if ($useRestFallback) {
                Get-VcfCheckCheckSetResultViaRest -Context $Context -RunId $runId
            } else {
                Invoke-VcfGetResult -RunId $runId -ErrorAction Stop
            }
        } catch {
            if ($useRestFallback -or $_.Exception.Message -notmatch 'Variant,\d+,Version,\d+ is not a valid runId') {
                return New-VcfCheckResult -CheckId $checkId -Status Error `
                    -TargetComponent $Context.SddcManagerFqdn -Exception $_.Exception.Message `
                    -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
            }
            # Fall back to direct REST requests if SDK Guid path-parameter formatting fails
            Write-LogMessage -Type DEBUG -Message "SDDC Manager SDK's Invoke-VcfGetResult hit a Guid path-parameter issue for run `"$runId`" - falling back to direct REST API calls."
            $useRestFallback = $true
            try {
                $result = Get-VcfCheckCheckSetResultViaRest -Context $Context -RunId $runId
            } catch {
                return New-VcfCheckResult -CheckId $checkId -Status Error `
                    -TargetComponent $Context.SddcManagerFqdn `
                    -Detail "SDDC Manager rejected run `"$runId`" due to a client library Guid path-parameter formatting issue, and the direct REST fallback also failed: $($_.Exception.Message)" `
                    -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
            }
        }
        $status = [String]$result.Status
        $attempt++
        Write-LogMessage -Type DEBUG -Message "SDDC Manager check-set run `"$runId`" poll $attempt/$MaxPollAttempts status: `"$status`"."
        Write-VcfCheckSubProgress -Context $Context -Current $attempt -Total $MaxPollAttempts -Unit 'poll attempts' `
            -Label "SDDC Manager check-set run status: $(if ([String]::IsNullOrWhiteSpace($status)) { 'starting' } else { $status })"

        if (([String]::IsNullOrWhiteSpace($status) -or $status -match 'IN_?PROGRESS') -and $attempt -lt $MaxPollAttempts) {
            Start-Sleep -Seconds $PollDelaySeconds
        }
    }

    if ([String]::IsNullOrWhiteSpace($status) -or $status -match 'IN_?PROGRESS') {
        $elapsedSeconds = [Int][Math]::Round(((Get-Date) - $startedAt).TotalSeconds)
        Write-LogMessage -Type WARNING -Message "SDDC Manager check-set run `"$runId`" hit its poll budget ($MaxPollAttempts attempt(s), $elapsedSeconds second(s) elapsed) while still reporting `"$status`"."
        return New-VcfCheckResult -CheckId $checkId -Status Error `
            -TargetComponent $Context.SddcManagerFqdn `
            -Detail "SDDC Manager check-set run `"$runId`" did not complete after $MaxPollAttempts poll(s) ($elapsedSeconds second(s)). Check the SDDC Manager Tasks tab for its live status." `
            -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $displayName
    }

    $rows = @(Get-VcfCheckUiCheckRunRowSet -Entity $result.PhysicalPresentedData)

    $hasError = @($rows | Where-Object { $_.Status -match 'ERROR|FAIL' }).Count -gt 0
    $hasWarning = @($rows | Where-Object { $_.Status -match 'WARN' }).Count -gt 0

    if ($status -match 'FAILURE|ERROR' -or $hasError) {
        $resultStatus = 'Fail'
        $detail = "SDDC Manager's own pre-upgrade check-set assessment found $(@($rows | Where-Object { $_.Status -match 'ERROR|FAIL' }).Count) failing check(s)."
    } elseif ($status -match 'CANCEL') {
        $resultStatus = 'Error'
        $detail = "SDDC Manager check-set run `"$runId`" was cancelled."
    } elseif ($rows.Count -eq 0) {
        $resultStatus = 'Pass'
        $detail = "SDDC Manager's own pre-upgrade check-set assessment completed with status `"$status`" and returned no per-check results, which SDDC Manager reports when there is nothing to flag."
    } elseif ($hasWarning) {
        $resultStatus = 'Warning'
        $detail = "SDDC Manager's own pre-upgrade check-set assessment found $(@($rows | Where-Object { $_.Status -match 'WARN' }).Count) check(s) with warnings."
    } else {
        $resultStatus = 'Pass'
        $detail = "SDDC Manager's own pre-upgrade check-set assessment found no failures or warnings across $($rows.Count) check(s)."
    }

    $resultParams = @{
        CheckId         = $checkId
        Status          = $resultStatus
        TargetComponent = $Context.SddcManagerFqdn
        Detail          = $detail
        Rows            = $rows
        StartedAt       = $startedAt
        CompletedAt     = (Get-Date)
    }
    if ($resultStatus -eq 'Fail') {
        $resultParams['Blocking'] = $true
    }

    return New-VcfCheckResult @resultParams -DisplayName $displayName
}
function Get-VcfCheckCheckSetResultViaRest {

    <#
        .SYNOPSIS
        Fetches a check-set run's result directly via REST API.

        .DESCRIPTION
        Issues a GET request to `/v1/system/check-sets/{runId}` via Invoke-RestMethod using the
        bearer token and ServiceUri from Context.SddcManagerConnection.

        This provides a fallback endpoint query when client SDK parameter formatting prevents
        direct cmdlet execution.

        .PARAMETER Context
        The VcfCheck.Context object. Must already be connected to SDDC Manager.

        .PARAMETER RunId
        The check-set run ID as a string.

        .OUTPUTS
        [PSObject] the raw AssessmentOutput JSON payload.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$RunId
    )

    $connection = $Context.SddcManagerConnection
    $uri = "$($connection.ServiceUri.ToString().TrimEnd('/'))/v1/system/check-sets/$RunId"
    $headers = @{
        Authorization = "Bearer $($connection.SessionSecret)"
        Accept        = 'application/json'
    }
    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -SkipCertificateCheck:$Context.AllowInsecureTls -ErrorAction Stop
}
function Get-VcfCheckUiCheckRunRowSet {

    <#
        .SYNOPSIS
        Flattens a check-set run's AssessmentOutput.PhysicalPresentedData entity tree into
        individual classification rows.

        .DESCRIPTION
        Recursively processes nodes within PhysicalPresentedData (EntityRest model). Grouping nodes
        with child entities set the Resource context for descendants, while leaf entities generate
        individual row objects containing Resource, Check, Status, and Error fields for each
        classification entry.

        .PARAMETER Entity
        An EntityRest node representing a level in the PhysicalPresentedData hierarchy.

        .PARAMETER Resource
        Internal - nearest ancestor grouping node's Name passed during recursion.

        .OUTPUTS
        [PSObject[]] array of structured rows: Resource, Check, Status, Error.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$Entity = $null,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Resource = ''
    )

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $Entity) {
        return $rows.ToArray()
    }

    $children = @($Entity.ChildEntities | Where-Object { $_ })
    if ($children.Count -gt 0) {
        foreach ($child in $children) {
            foreach ($childRow in @(Get-VcfCheckUiCheckRunRowSet -Entity $child -Resource $Entity.Name)) {
                $rows.Add($childRow)
            }
        }
        return $rows.ToArray()
    }

    foreach ($classification in @($Entity.Classifications | Where-Object { $_ })) {
        $rows.Add([PSCustomObject]@{
                Resource = $Resource
                Check    = $Entity.Name
                Status   = $classification.Value
                Error    = $classification.Description
            })
    }

    return $rows.ToArray()
}
