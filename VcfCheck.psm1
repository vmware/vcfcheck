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
# PowerShell Module: VcfCheck
# Lightweight VCF upgrade-readiness engine.
#
# Private implementation files (dot-sourced below):
#   Private/Logging.ps1             - Write-LogMessage, log initialization
#   Private/SecureStringHelpers.ps1 - SecureString <-> plaintext conversion primitives
#   Private/Models.ps1              - New-VcfCheckResult, New-VcfCheckContext
#   Private/Settings.ps1            - settings.json CRUD, credential resolution, Initialize-VcfCheck
#   Private/Environments.ps1        - environments.json CRUD (multi-environment support)
#   Private/EsxCpuCompatibilityHelpers.ps1 - Shipped Broadcom Compatibility Guide CPU series lookup (offline)
#   Private/Connections.ps1         - SDDC Manager / vCenter / component credential + connection lifecycle
#   Private/ApplianceCommand.ps1    - Invoke-VMScript wrapper for guest-OS commands
#   Private/AriaOpsHelpers.ps1      - Aria Operations credential resolution + Connect-VcfOpsServer wrapper
#   Private/AriaAutomationHelpers.ps1 - Aria Automation credential resolution + hand-written REST auth/API client
#   Private/InventoryHelpers.ps1    - Mockable wrappers around PowerCLI inventory cmdlets
#   Private/IoDeviceCompatibility.ps1 - ESX host network/storage adapter + SCSI device inventory
#   Private/BomHelpers.ps1          - Live VCF release BOM lookup (Invoke-VcfGetReleases) + version-match comparison
#   Private/Catalog.ps1             - Data/CheckCatalog.json loading + strict JSON validation
#   Private/InteropMatrixHelpers.ps1 - Broadcom public Interop Matrix API wrapper (fallback release-existence check)
#   Private/NsxHelpers.ps1          - Mockable wrappers around NSX Policy SDK cmdlets
#   Private/VrslcmHelpers.ps1       - Aria Suite Lifecycle Manager connection + REST helper
#   Private/NsxManagerApiHelpers.ps1 - NSX Manager node/fabric/cluster REST API helper
#   Private/Tools.ps1               - Start-/Stop-/Get-/Restart-VcfCheckServer (Python report viewer lifecycle)
#   Private/Reporting.ps1           - JSON report writing
#   Private/SizingEstimator.ps1     - VCF management domain sizing and upgrade delta estimator
#   Private/Orchestrator.ps1        - Invoke-VcfCheck (top-level entry point)
#   Private/Checks/**/*.ps1         - One Test-Vcf<CheckId> function per check

$privatePath = Join-Path -Path $PSScriptRoot -ChildPath 'Private'
$privateFiles = @(
    'ApplianceCommand.ps1'
    'AriaAutomationHelpers.ps1'
    'AriaOpsHelpers.ps1'
    'BomHelpers.ps1'
    'Catalog.ps1'
    'Connections.ps1'
    'Environments.ps1'
    'EsxCpuCompatibilityHelpers.ps1'
    'InteropMatrixHelpers.ps1'
    'InventoryHelpers.ps1'
    'IoDeviceCompatibility.ps1'
    'Logging.ps1'
    'Models.ps1'
    'NsxHelpers.ps1'
    'NsxManagerApiHelpers.ps1'
    'Orchestrator.ps1'
    'Reporting.ps1'
    'SecureStringHelpers.ps1'
    'Settings.ps1'
    'SizingEstimator.ps1'
    'Tools.ps1'
    'VrslcmHelpers.ps1'
)

foreach ($file in $privateFiles) {
    $filePath = Join-Path -Path $privatePath -ChildPath $file
    if (Test-Path -LiteralPath $filePath) {
        . $filePath
    } else {
        Write-Warning "Private module file not found: $filePath"
    }
}

# Check implementation files - one function per precheck, discovered by convention
# (loaded here; active checks are controlled by Data/CheckCatalog.json).
$checksPath = Join-Path -Path $privatePath -ChildPath 'Checks'
if (Test-Path -LiteralPath $checksPath) {
    Get-ChildItem -Path $checksPath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

# Module constants - set once at load time, never mutate.
$Script:VcfCheckModuleLoaded = $true
$Script:VcfCheckVersion      = '2.0.0.1007'

# Environment variable that stores the active base directory (set by Initialize-VcfCheck).
$Script:VCF_CHECK_ENV_VAR     = 'VcfCheckBaseDirectory'
$Script:VCF_CHECK_DEFAULT_DIR = 'VcfCheck'

# Subdirectory names under the user base directory.
$Script:CHECK_CONFIG_DIR_NAME   = 'Config'
$Script:CHECK_DATA_DIR_NAME     = 'Data'
$Script:CHECK_DOCS_DIR_NAME     = 'Docs'
$Script:CHECK_FINDINGS_DIR_NAME = 'Findings'
$Script:CHECK_LOGS_DIR_NAME     = 'Logs'
$Script:CHECK_RUN_DIR_NAME      = 'Run'
$Script:CHECK_TOOLS_DIR_NAME    = 'Tools'

# File names within their respective subdirectories.
$Script:CHECK_SETTINGS_FILE_NAME     = 'settings.json'
$Script:CHECK_ENVIRONMENTS_FILE_NAME = 'environments.json'

# Tool files copied to the user's Tools subdirectory on Initialize-VcfCheck.
$Script:CHECK_TOOL_FILE_NAMES = @(
    'Invoke-VcfCheckLauncher.ps1'
    'Invoke-VcfCheckSizingDetect.ps1'
    'Invoke-VcfCheckSizingEstimate.ps1'
    'Invoke-VcfCheckSizingWorker.ps1'
    'Invoke-VcfCheckValidateCredentials.ps1'
    'Invoke-VcfCheckVrslcmLockerDiagnostic.ps1'
    'Manage-VcfCheckServer.py'
    'Start-VcfCheckServer.py'
    'vcf-check-ui.html'
    'vcfcheck_server\__init__.py'
    'vcfcheck_server\check_catalog.py'
    'vcfcheck_server\environments.py'
    'vcfcheck_server\json_utils.py'
    'vcfcheck_server\logs.py'
    'vcfcheck_server\paths.py'
    'vcfcheck_server\sizing.py'
    'vcfcheck_server\vcf_release.py'
    'ui\common.js'
    'ui\environments.js'
    'ui\export.js'
    'ui\filters.js'
    'ui\fqdn-validation.js'
    'ui\health-checks.js'
    'ui\init.js'
    'ui\live-log-filter.js'
    'ui\logbundle-export.js'
    'ui\password-toggle.js'
    'ui\report-render.js'
    'ui\run-actions-polling.js'
    'ui\run-scan.js'
    'ui\sizing-wizard-core.js'
    'ui\sizing-wizard-detect.js'
    'ui\sizing-wizard-steps.js'
    'ui\state.js'
    'ui\theme.js'
    'ui\zip-writer.js'
)

# Multiple simultaneous vCenter connections are required so Invoke-VMScript can address VMs
# by bare name and -Server parameter across connected vCenter instances.
try {
    if (Get-Module -Name 'VMware.VimAutomation.Core' -ErrorAction SilentlyContinue) {
        $currentMode = (Get-PowerCLIConfiguration -Scope Session -ErrorAction SilentlyContinue).DefaultVIServerMode
        if ($currentMode -ne 'Multiple') {
            Write-Warning "VcfCheck requires PowerCLI's DefaultVIServerMode to be 'Multiple' so it can address VMs across more than one connected vCenter. Run: Set-PowerCLIConfiguration -Scope Session -DefaultVIServerMode Multiple -Confirm:`$false"
        }
    }
} catch {
    Write-Warning "Could not check PowerCLI DefaultVIServerMode: $($_.Exception.Message)"
}
