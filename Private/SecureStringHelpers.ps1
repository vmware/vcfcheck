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
#region SecureString helpers
#
# These are the ONLY two functions permitted to touch a plaintext password in memory

function ConvertFrom-SecureStringViaBstr {

    <#
        .SYNOPSIS
        Converts a SecureString to a plain-text string using BSTR marshalling, then zeros the BSTR immediately.

        .DESCRIPTION
        Allocates a BSTR via Marshal.SecureStringToBSTR, reads the plain text, and guarantees
        Marshal.ZeroFreeBSTR in a finally block so the plain-text window on the heap is as short as
        possible. This is the only mechanism in this module that overwrites the underlying memory
        rather than merely dropping a reference to it. Intended only for immediate use (e.g. building
        a guest-ops credential or a Basic auth header) - never store the return value in a variable
        that outlives a single statement.

        .PARAMETER SecureString
        The SecureString to convert.

        .OUTPUTS
        String - the plain-text value of the SecureString.

        .EXAMPLE
        $plain = ConvertFrom-SecureStringViaBstr -SecureString $credential.Password
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [SecureString]$SecureString
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}
function ConvertTo-SecureStringForCredential {

    <#
        .SYNOPSIS
        Builds a SecureString from a plain-text string for PSCredential construction.

        .DESCRIPTION
        Wraps ConvertTo-SecureString -AsPlainText -Force so callers do not need to suppress
        PSAvoidUsingConvertToSecureStringWithPlainText at every call site. This is the single
        sanctioned conversion point in the module - the source plaintext (e.g. a credential
        retrieved via Invoke-VcfGetCredentials) should be discarded via Remove-Variable
        immediately after calling this function.

        .PARAMETER PlainText
        The plain-text string to convert. Empty string is permitted (PSCredential allows blank passwords).

        .OUTPUTS
        SecureString

        .EXAMPLE
        $securePassword = ConvertTo-SecureStringForCredential -PlainText $vcenterCredentialResponse.Password
        Remove-Variable -Name vcenterCredentialResponse -Force
    #>

    [CmdletBinding()]
    [OutputType([SecureString])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '')]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$PlainText
    )

    # ConvertTo-SecureString's own -String parameter rejects an empty string outright
    # (ValidateNotNullOrEmpty), so the empty-password case has to be built directly.
    if ($PlainText.Length -eq 0) {
        return [System.Security.SecureString]::new()
    }

    return ConvertTo-SecureString -String $PlainText -AsPlainText -Force
}

#endregion SecureString helpers
