function Test-VcfSampleCheck {

    <#
        .SYNOPSIS
        Engine-skeleton smoke-test check - always passes, touches no external system.

        .DESCRIPTION
        Exists to exercise Invoke-VcfCheck end to end (resolve check -> run -> result ->
        report) without requiring a live SDDC Manager connection to be meaningful. Not part of
        any real check-set; run explicitly via -CheckId sample.

        .PARAMETER Context
        The VcfCheck.Context object (unused by this check, but required by the check contract).

        .OUTPUTS
        [PSObject] a VcfCheck.Result with Status Pass.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$Context,
        [Parameter(Mandatory = $false)] [String]$DisplayName = ''
    )

    $startedAt = Get-Date

    return New-VcfCheckResult -CheckId 'sample' `
        -Status Pass -Detail 'Engine skeleton executed successfully.' `
        -StartedAt $startedAt -CompletedAt (Get-Date) -DisplayName $DisplayName
}
