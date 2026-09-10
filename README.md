[![License](https://img.shields.io/badge/License-Broadcom-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-2.0.0.1006-orange.svg)](CHANGELOG.md)
[![Downloads](https://img.shields.io/github/downloads/vmware/vcfcheck/total?label=Release%20Downloads)

# VCF Check

A lightweight PowerShell module that runs pre-upgrade health checks against VMware Cloud
Foundation (VCF) 5.2 and later environments, paired with a bundled local Python web-based user
interface. These checks are used to ascertain if any remediation is required before launching a
VCF 9.x upgrade.

VCF Check does not support VCF releases earlier than 5.2. When it connects to SDDC Manager, it
checks the reported VCF version and stops the run with an explanatory error if the environment
is older than 5.2.

## Installation

### Prerequisites

* [PowerShell 7.4+](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell)
* [VCF.PowerCLI 9.0+](https://developer.broadcom.com/powercli) — if VMware.PowerCLI is already installed, uninstall it first (`Uninstall-Module VMware.PowerCLI -AllVersions`); the two modules conflict and cannot coexist.
* Python 3.13+ (see [Installing Python](#installing-python) below)
* macOS/Linux/Windows system with HTTPS network access to SDDC Manager, vCenter, and vRSLCM (if installed)
* An SSO account on SDDC Manager with ADMIN-level access.
* Modern web browser (to access the web interface of pre-check utility). Chrome-based recommended (Firefox, Safari should work; IE will not).

#### Installing Python

Python 3 is included by default on macOS and most Linux distributions. On Windows, install it using one of the following:

* **winget (preferred):**

  ```Powershell
  winget install --id Python.Python.3.13 -e
  ```

* **Microsoft Store:** search for "Python 3.13" (Windows 10/11 only, not Windows Server).
* **Official installer:** download from the [Python Windows downloads page](https://www.python.org/downloads/windows/) and select the installer matching your system architecture.

### Offline Zip

1. Copy `VcfCheck-<version>.zip` to the script execution system.
2. Expand it into a `VcfCheck` folder under one of your `$env:PSModulePath` locations, for example, your user module path:

   ```powershell
   $userModulePath = ($env:PSModulePath -split [IO.Path]::PathSeparator)[0]
   $destination = Join-Path -Path $userModulePath -ChildPath 'VcfCheck'
   Expand-Archive -Path './VcfCheck-<version>.zip' -DestinationPath $destination -Force
   ```

   On Linux, `Expand-Archive` may not be recognized as the PowerShell module that installs it, `Microsoft.PowerShell.Archive` module,
   may not be installed by default on all distributions. If the command above fails, either install it first:

   ```powershell
   Install-Module -Name Microsoft.PowerShell.Archive -Scope AllUsers
   ```

   or extract the archive with `unzip` instead:

   ```bash
   unzip VcfCheck-<version>.zip -d /path/to/Modules/VcfCheck
   ```

   The archive's top-level folder is already named after the module version, so this produces
   `<...>/Modules/VcfCheck/<version>/VcfCheck.psd1`, matching the layout PowerShell
   expects for versioned modules.
3. If this PowerShell session was already open before you ran the steps above, start a new
   session before continuing. A running session caches the module autoload table at startup,
   so it will not see a module dropped into `$env:PSModulePath` afterward, and
   `Get-Module -ListAvailable` will report nothing until the session is restarted.
4. Verify and import:

   ```powershell
   Get-Module -ListAvailable VcfCheck
   Import-Module VcfCheck
   ```

### PowerShell Gallery

  ```Powershell
  Install-Module -Name VcfCheck -Scope CurrentUser
  ```

## Quick Start

```powershell
Initialize-VcfCheck                        # (One time) sets up your configuration files and environment.

Start-VcfCheckServer                       # Launches the web-based configuration utility.
Stop-VcfCheckServer                        # Stops the web-based configuration utility.
```

HTML and JSON reports are automatically saved to `$env:VcfCheckBaseDirectory/Findings/<environment name>`.

If port 8766 is already in use by a leftover process, `Start-VcfCheckServer` throws instead of binding to it. Run `Start-VcfCheckServer -Force` to stop whatever is holding the port first and then start normally. Use `-Background` to run detached (stop it later with `Stop-VcfCheckServer`) and `-Port <n>` to use a different port.

## Using VCF Check

* After launching `Start-VcfCheckServer` from a PowerShell terminal, the `VCF Check` web page will appear at `http://127.0.0.1:<unused_port>`. For security, the web server will not bind to a public port and thus may only be accessed from your local system.

### Creating an Environment

#### Creating your first environment

1. Navigate to Settings & Environments -> Environments -> `Add Environment`.
2. Enter a friendly name for your VCF environment in the `Name` field.
3. Enter the SDDC Manager Fully Qualified Domain Name (FQDN) or IP address in the "SDDC Manager FQDN" field. (e.g., `sddcm.example.com` or `192.168.1.100`).
4. Enter your SSO username in the "Username" field (example: `administrator@vsphere.local`). Please note: This user must have ADMIN-level permissions to SDDC Manager.
5. The checkbox `Enable SDDC Manager root-credential checks (VMware Tools guest operations)` should remain checked unless one or more of the following conditions are met:

   * SDDC Manager and vCenter do not and cannot run VMware Tools for security or policy reasons.
   * You do not have `root` shell credentials for the SDDC Manager.
   * You have specific organization policies against the use of `Invoke-VMScript` to run shell operations on virtual appliances.

To view checks that require `root` credentials, expand "Health checks" and click on the filter "Needs Root Credentials".

#### Adding Aria Components (optional)

Under `Aria Components (optional)`, you may register endpoints such as Aria Operations for API-level checks (adapter status, certificate expiration, licensing, collector health, and so on).

* These checks connect directly to each component's own API. They do not go through, and do not require, vRealize Suite Lifecycle Manager (vRSLCM).
* Add an endpoint here regardless of whether that component happens to be managed by vRSLCM, or whether vRSLCM is deployed in the environment at all - VCF Check has no dependency on vRSLCM to run these checks.
* If you don't add a component here, its checks are simply skipped for that environment.

#### Creating a subsequent environment

1. Click the `Settings & Environments` pane to expand it.
2. Click `Add Environment`.
3. Complete steps 3-5 from the `First environment` setup steps.

#### Modifying an environment

1. Click the `Settings & Environments` pane to expand it.
2. Click `Edit` to the right of the environment name in question to modify it, or `Delete` to remove it.
3. If you are editing the environment, you may modify its friendly name, `SDDC Manager FQDN`, `Username`, or toggle `Root-Credential` checks.
4. Click `Save` to complete your changes.

#### Updating display settings (optional)

* Under `Settings & Environments` there is a section called `Advanced Settings`.
* `Live log detail` controls the level of detail displayed during a health check run. The default `INFO` is typically sufficient, but you may turn it down to `WARNING` (to display less information) or up to `DEBUG` (to display more information) as the situation dictates. All of this data (unfiltered) is available in `$env:VcfCheckBaseDirectory/Logs` with date-stamped files for later analysis.
  * **Note** : If you update the log level during a check run, the changes take effect immediately.
* `TCP connection timeout (seconds)` controls the timeout value for connections to endpoints (like SDDC Manager, vCenter, and vRSLCM).
* `VCF destination release` controls the compatibility checks for `Aria Suite Component Version Check` and `VCF Bill of Materials Upgrade Readiness Check`. If you are planning to upgrade to a version less than the latest version of VCF 9.x, you may change the selected release here.
* `SDDC Manager Health Summary poll budget` and `SDDC Manager Pre-Upgrade Check-Set poll budget` control how long the `SDDC Manager Health Summary` and `SDDC Manager Pre-Upgrade Check-Set Assessment` checks, respectively, will keep polling SDDC Manager before giving up - both can take several minutes on a live environment since SDDC Manager runs a multi-step task in the background for each. The `SDDC Manager Health Summary` check also abandons polling on its own once SDDC Manager stops making progress, so raising its budget only helps a genuinely slow (not stuck) run.
* Whether connections to all endpoints (via SDK or REST) accept untrusted/self-signed certificates is controlled by PowerCLI's own `Set-PowerCLIConfiguration -InvalidCertificateAction` setting - there is no separate VcfCheck-specific toggle. Run `Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore` for lab environments with self-signed certificates, or leave it at its default (`Fail`/`Warn`) for production. Check the current value with `Get-PowerCLIConfiguration`. The `Insecure TLS Settings` line in this Settings panel is a read-only reflection of that PowerCLI setting, not a control - change it via `Set-PowerCLIConfiguration`, then reload the page to see the update.

## Run Scan

### Select Environment(s)

1. Click one or more environments you wish to check.
2. Enter your credentials for your SSO user and the root user (if `root` checks are enabled).

### Discover Workload Domains (Optional)

* By default, `Run Check` scans every workload domain in the selected environment(s). Click `Discover Workload Domains` to customize which ones are scanned instead.
* This step performs the following:
  * Validates SDDC Manager and vCenter TCP/443 reachability.
  * Validates vRSLCM (if deployed) TCP/443 reachability.
  * Validates SSO user credentials for SDDC Manager.
  * Validates root credentials for SDDC Manager through a multi-step authentication and VM identification process.
  * Loads the list of workload domains for the selected environment(s) into the `Domain` selector.
* Once the domains load, deselect any you do not wish to scan. Your selection carries forward into `Run Check`.

* The four-stage checks will be displayed under `Credential Check` with any errors surfaced to the right of the check name.  A `Live Log` will appear beneath with additional detail.

### Health Checks

* Click on `Health Check` to view or customize the list of checks run against your environments.  By default, all are selected.

* Each check is accompanied by a short description (longer descriptions are available in this document).  These descriptions also accompany the completed checks.

* Checks may be excluded / included individually or by Component category.
  * To disable an entire Component category, deselect the component under `Components` or above the list of checks.
* Checks for which failure is known to block a VCF 9.x upgrade are prefaced with a **[B]**.
* Checks that require `root` credentials to SDDC Manager are prefaced with an **[R]**.

### Run Check

* The check workflow validates connectivity and credentials for the selected environment(s) automatically before proceeding with the checks themselves - the same validation `Discover Workload Domains` performs (see `Discover Workload Domains (Optional)` for details), so running it first is optional.
* A Progress Bar will appear, showing how many checks out of the total have completed, the time elapsed, and details on the running check.
* You may scroll down to see details on the checks that have completed; a floating "mini progress bar" will keep you apprised of the overall scan progress.
* You may apply post-check filters in real time, filtering out statuses or components at will. These will be dynamically applied to your view and will not impact the underlying data.
* The check results will dynamically reorder themselves with higher priority issues (blocking failures for example) rising to the top.
* One check result will appear per workload domain.
* Click the `i` icon to view a description of the check.
* You may view more details on any check by clicking on it. Once expanded, you'll see the following:
  * The target (such as vCenter: vcenter.example.com).
  * (Optional) Information: extra information about the check.
  * Validation Criteria: what the check is looking for.
  * Results / Details: status of the check results.
  * (Conditional) Remediation: if the check does not pass, how to resolve the condition.
* Checks skipped due to missing optional components can be reviewed in detail by clicking on the summary bar to view individual skipped checks and why they were skipped.
* `Info-only` badge.  This badge indicates that there is no check criteria. The data is presented as informational only.

### Export (Reports)

* Once your report is complete, it becomes available for export.
* Scroll up to the top of the screen and in the top right corner choose one of the following:
  * HTML: Filterable static HTML page (Downloads to your default download directory)
  * ZIP: a zip file containing the HTML file and a JSON version of the data (Downloads to your default download directory)
  * PDF: a PDF version of the report, available to print or save as a PDF.

* Note: Each time you run a check, a copy of the JSON and HTML is automatically saved to your `$env:VcfCheckBaseDirectory/Findings/<environment name>` folder as a backup in case you close your browser in error.
  * While a run is in progress, these files are named after an internal run ID (e.g. `VCF52-df248dbfd49b-findings.json`), so every check that finishes overwrites the same pair of files instead of creating a new one.
  * Once the run completes, both files are renamed to use the completion timestamp instead (e.g. `VCF52-20260910-204036-findings.json`), giving a human-friendly, sortable name for looking the run up later.
  * If a run is interrupted (browser closed, PowerShell process killed, etc.) before it completes, the rename never happens - the JSON and HTML files for that run are left named with the run ID rather than a timestamp.
  * `latest.json` in the same folder always holds a copy of the most recent run's data, under that fixed name, regardless of whether the run completed or was interrupted.

### Collect Logs

* If you need technical support, you may click on `Collect Logs` in the upper-right corner of the screen at any time.
* This log bundle contains:
  * `$env:VcfCheckBaseDirectory/Findings/*`
  * `$env:VcfCheckBaseDirectory/Logs/*`
  * `$env:VcfCheckBaseDirectory/Config/*`
* Notes
  * No passwords are stored in this data.
  * You will be prompted to accept a warning that this data does contain FQDNs and other details about your environment.
  * If you need to sanitize FQDN or other details about your environment, manually collect the data from the aforementioned directories and transform accordingly.

### Dark / Light mode

* The UI supports Dark and Light mode.  Light mode is the default.

## Check Details

* 74 checks total

## General Notes

* Expirations dates for password and certificates are presented in YYYY-MM-DD in the HTML.  For further granularity, please review the JSON export.

### Aria

* **Number of checks:**  12

#### Aria Lifecycle Manager Disk Space Report

* **Purpose:** Verifies that the vRealize Suite Lifecycle Manager (vRSLCM) root volume has at least 3 GB of free space available for upgrades.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * A vRSLCM upgrade is only necessary in the rare instance that an Aria appliance requires it prior to upgrading to VCF 9.x.

#### Aria Operations Adapter Collection Status Check

* **Purpose:** Enumerates every configured Aria Operations adapter instance and inspects the monitored resources tied to it, flagging any adapter instance where none of its resources report a `DATARECEIVING`/`OLDDATARECEIVING` status — the condition that indicates Aria Operations has silently stopped collecting data from that source. Adapter instances with no associated resources are reported separately (`Unknown`) rather than counted as a failure, since an adapter with nothing configured to monitor isn't itself broken.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Skipped if Aria Operations isn't deployed in the environment.
  * Reports each adapter instance's Name, AdapterKindKey, ResourceCount, and Status.

#### Aria Operations Certificate Expiration Check

* **Purpose:** Scans every certificate registered with Aria Operations (Administration > Certificates), flagging any that are already expired or expiring within the configurable warning threshold (default 30 days).
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Skipped if Aria Operations isn't deployed in the environment.
  * A certificate whose expiration date can't be parsed is also flagged as a Warning rather than silently passed.

#### Aria Operations Collector Status Check

* **Purpose:** Connects directly to Aria Operations (independent of vRSLCM) and verifies that every registered collector — the primary appliance as well as any remote collectors or collector groups — reports an `UP` State, since a collector that has gone `DOWN` stops delivering the metrics/alerts that operators rely on both before and after the upgrade. Reports each collector's Name, HostName, State, and LastHeartbeat for drill-down.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Skipped if Aria Operations isn't deployed in the environment.
  * Connects to a standalone Aria Operations endpoint declared on the environment (`Integrations`), not through vRSLCM.

#### Aria Operations Collector Type Inventory

* **Purpose:** Reports the deployment Type (`INTERNAL`, `REMOTE`, `CLOUD_PROXY`, `AAP`, `OTHER`) of every Aria Operations collector for reviewer visibility.
* **Blocks upgrade?** No
* **Informational only check?** Yes
* **Notes:**
  * Skipped if Aria Operations isn't deployed in the environment.
  * No failure condition; reports each collector's Name, HostName, and Type for drill-down.

#### Aria Operations Licensing Check

* **Purpose:** Reports Aria Operations' license entitlement — expiration date, capacity, usage, edition, license type, and statuses — flagging a non-permanent license that is already expired or expiring within the configurable warning threshold (default 30 days).
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Skipped if Aria Operations isn't deployed in the environment.
  * A `PERMANENT` license is never flagged, even though Aria Operations still reports a numeric expiration date for it.

#### Aria Operations Lifecycle Status Check

* **Purpose:** Validates Aria Operations' own reported version against Broadcom's public Interop Matrix upgrade-path status for the selected VCF destination release, falling back to a minimum-version floor comparison when the Interop Matrix has no resolvable verdict for the installed/destination pair.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * Skipped if Aria Operations isn't deployed in the environment.

#### Aria Operations Open Alerts

* **Purpose:** Queries Aria Operations for any active alert at `CRITICAL` or `IMMEDIATE` criticality, surfacing unresolved issues on monitored resources so they can be triaged before proceeding with the upgrade rather than being discovered afterward.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Skipped if Aria Operations isn't deployed in the environment.
  * Reports each matching alert's definition name, resource name (resolved from the resource ID, falling back to the raw ID if lookup fails), criticality, status, and start time.

#### Aria Operations Sizing Overview

* **Purpose:** Reports Aria Operations' own self-monitored CPU, memory, disk, network, and object-count metrics for reviewer visibility, and warns if any self-monitoring resource reports no sizing-related metrics.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Skipped if Aria Operations isn't deployed in the environment.
  * No exact `StatKey` names are hardcoded — metrics are pulled from Aria Operations' self-monitoring adapter with no `-StatKey` filter, then filtered by name pattern (CPU/memory/disk/network/storage/object/latency/capacity) since no live instance was available to confirm the exact key set.
  * Lists each self-monitoring resource with a Pass/Warning status. `Warning` (and an overall `Warning` result) if any resource reports zero sizing-related metrics; `Pass` otherwise.

#### Aria Suite Appliance Disk Space Report

* **Purpose:** Monitors disk space utilization on `/`, `/storage/db`, `/storage/core`, and `/storage/log` across all deployed Aria Suite appliances (Operations, Operations for Logs, Automation, and Workspace ONE Access). Generates a warning as usage approaches capacity thresholds and blocks operations if any mount reaches 100%.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * Only checks Aria components deployed using vRSLCM.

#### Aria Suite Component Root Password Expiry

* **Purpose:** Checks root account password expiration for Aria Suite appliances:
  * **Pass:** Password expires in more than 30 days (or is set to never expire).
  * **Warn:** Password expires within 30 days.
  * **Fail:** Password is already expired.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Only checks Aria components deployed using vRSLCM.

#### Aria Suite Component Version Check

* **Purpose:** Verifies that Aria Suite Lifecycle Manager and its registered products are compatible with the target VCF 9.x version.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * Uses an offline copy of the Broadcom Interoperability Matrix as a data source.
  * Only checks Aria components deployed using vRSLCM.

#### Aria Suite Lifecycle Manager Certificate Expiration Check

* **Purpose:** Scans all certificates in the Aria Suite Lifecycle Manager locker—including Lifecycle Manager and registered products (VRLI, vROps, vRA, and WSA)—flagging any that are expired or expiring within 30 days.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Only checks Aria components deployed using vRSLCM.

### ESX

* **Number of checks:** 4

#### ESX execInstalledOnly Enforcement

* **Purpose:** This check reports the status of VMkernel.Boot.execInstalledOnly across all ESX hosts in a workload domain. This vSphere security setting ensures only digitally signed, installed executables can run.
* **Blocks upgrade?** No
* **Informational only check?** Yes
* **Notes:**
  * Rolls up host-level results per cluster when non-unique.

#### ESX Hardware Summary and CPU Compatibility Check

* **Purpose:** This check details the BIOS version, hardware vendor/model, CPU, vSAN storage, network adapters, HBAs, and SCSI devices for every host in a workload domain, and flags any host CPU that is not found on Broadcom's server/CPU Hardware Compatibility Guide, or is deprecated/discontinued per Broadcom's CPU support removal timeline, for the target ESX release.
* **Blocks upgrade?** Yes, if any host's CPU is unlisted on the Hardware Compatibility Guide or discontinued. A deprecated CPU reports a non-blocking warning.
* **Informational only check?** No
* **Notes:**
  * CPU compatibility is checked against a shipped, offline snapshot of <https://compatibilityguide.broadcom.com>; CPU deprecation/discontinuation status is checked against a shipped, offline snapshot of <https://knowledge.broadcom.com/external/article/318697>.

#### ESX Image Profile

* **Purpose:** Generates cluster-level reports on host ESX builds, applied image profiles, and vLCM details (add-ons, components, firmware, and drivers) to catch image mismatches prior to upgrading to VCF 9.x.
* **Blocks upgrade?** No
* **Informational only check?** Yes
* **Notes:**
  * Rolls up host-level results per cluster when non-unique.

#### ESX Lockdown mode

* **Purpose:** Lockdown mode restricts ESX host management exclusively to vCenter, disabling direct root and local API access. This check verifies that every host with Lockdown mode enabled includes its VCF service account (`svc-vcf-<host_shortname>`) in its Exception Users list. Without this exception, SDDC Manager cannot connect to the host to perform upgrades.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * Rolls up host-level results per cluster when non-unique.
  * Does not show `svc-vcf-<host_shortname>` status when Lockdown mode is disabled.

### SDDC Manager

* **Number of checks:** 15

#### Hotfix SDDC Manager Async-Patch Upgrade History

* **Purpose:** This check verifies SDDC Manager's appliance logs for any record of an out-of-band async-patch having been applied, flagging it so it can be reviewed with Broadcom support before proceeding with the upgrade.
* **Blocks upgrade?** No
* **Informational only check?** No

#### Hotfix Version Alias Coverage

* **Purpose:** Flags any vCenter, ESX host, or NSX Manager whose installed build doesn't match the current release's BOM version and isn't covered by a registered SDDC Manager version alias — the condition that trips LCM's upgrade-path validation mid-upgrade.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * Rolls up host-level results per cluster when non-unique.

#### Management Domain Resource Utilization

* **Purpose:** Validates that you have sufficient resources in your primary cluster in the Management (MGMT) workload domain for a VCF 9.1.1 upgrade.
* **Blocks upgrade?** No
* **Informational only check?** No

#### SDDC Manager Appliance Disk Space

* **Purpose:** This check reports the free/used disk space per filesystem on the SDDC Manager appliance.
* **Blocks upgrade?** No
* **Informational only check?** Yes
* **Notes:**
  * This check uses `Invoke-VMScript` to inspect the file system on the SDDC Manager appliance.

#### SDDC Manager Depot Account Status

* **Purpose:** Verifies both the online and offline software depot accounts are configured and actively connected. If one is improperly configured, it relays the reason why.
* **Blocks upgrade?** Yes
* **Informational only check?** No

#### SDDC Manager Failed Tasks

* **Purpose:** Checks SDDC Manager's most recent tasks for any with a `Failed` status, rolling up repeated occurrences by task name (with counts and timestamps) and their failing sub-tasks, so operators can spot and resolve underlying issues before upgrading.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Failed tasks are not necessarily blocking; they simply require review before proceeding.
  * The check rolls up repeated occurrences of failed tasks to improve the signal-to-noise ratio.

#### SDDC Manager Health Summary

* **Purpose:** Polls SDDC Manager's own built-in health-summary for 11 categories (DNS, NTP, certificates, passwords, services, storage, connectivity, compute, hardware compatibility, general, version) and reports its pass/fail verdict.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Unlike previous versions of this check, it does not process an SOS bundle, and thus data is derived from SDDC Manager's status endpoint only.
  * Sub-task details are included.
  * If the check detects a prior task is running (OPERATION_IN_PROGRESS), it will self-heal, and poll that task, rather than start a superfluous new task.

#### SDDC Manager LCM Manifest Polling

* **Purpose:** Verifies that SDDC Manager's LCM manifest polling setting (lcm.core.enableManifestPolling) is enabled, which is required for LCM to display all available download bundles.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * This check uses `Invoke-VMScript` to inspect configuration files on the SDDC Manager VM using its root credentials.

#### SDDC Manager Platform Lock Table

* **Purpose:** Checks whether SDDC Manager's internal platform.lock database table is empty — a non-empty table means an LCM operation is (or was) in progress or became stuck, which blocks further platform operations.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * This check uses `Invoke-VMScript` to run `psql` commands on the SDDC Manager VM using its root credentials.

#### SDDC Manager Pre-Upgrade Check-Set Assessment

* **Purpose:** Runs SDDC Manager's own pre-upgrade check-set assessment and reports any failing or warning checks per resource.
* **Blocks upgrade?** No
* **Informational only check?** No

#### SDDC Manager VxRail Manager Table

* **Purpose:** Queries VxRail-based SDDC Manager's internal platform.vx_manager table for any row reporting an ERROR status.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * This check is skipped in VSRN environments.
  * This check uses `Invoke-VMScript` to run `psql` commands on the SDDC Manager VM using its root credentials.

#### vCenter Core and TiB Report

* **Purpose:** This informational check reports total CPU core counts and vSAN storage capacity (in TiB) per vCenter and domain, to assist with license estimation for VCF 9.x.
* **Blocks upgrade?** No
* **Informational only check?** Yes
* **Notes:**
  * This data is not linked to your actual license utilization, but is simply a reflection of your capacity in licensing terms. There is no connection to the Broadcom license portal.

#### VCF Bill of Materials Upgrade Readiness Check

* **Purpose:** Verifies each VCF component's Bill of Materials version is compatible and current before an upgrade, flagging any BOM mismatches that could block the process.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * Utilizes offline copies of the interoperability matrix for vCenter, ESX, NSX, and SDDC Manager to ascertain upgrade blockers (including [back in time](https://knowledge.broadcom.com/external/article/448135/upgrade-failure-for-vcenter-80-u3j-esxi.html) issues).

#### VCF License Key Expiration

* **Purpose:**  Fails on any already-expired VCF-managed license key and warns on keys expiring within the configured threshold (default 30 days), listing every key's status and days remaining.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * This data is based on what's known to the local SDDC Manager, rather than the Broadcom licensing portal.

#### vSphere Lifecycle Management (vLCM) Enablement

* **Purpose:** Checks each cluster to see if it's managed by vLCM baselines (VUM) or vLCM Images. vLCM Image management is required to complete an upgrade to ESX 9.0 or later.
* **Blocks upgrade?** No
* **Informational only check?** No

### vCenter

* **Number of checks:** 28

#### Datastore Free Space

* **Purpose:** Reports free space on every datastore and warns when one is inaccessible or nearing capacity (80% for vSAN, 90% for others), so storage headroom can be confirmed before upgrading.
* **Blocks upgrade?** No
* **Informational only check?** No

#### Distributed Virtual Switch Version

* **Purpose:**  Flags distributed virtual switches below version 7.0, since vCenter Server 9.0 requires that minimum for compatibility.
* **Blocks upgrade?** Yes
* **Informational only check?** No

#### DRS Affinity/Anti-Affinity Rules

* **Purpose:** Displays DRS affinity/anti-affinity rules and whether or not they are enabled/disabled, mandatory/best-effort.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * Only mandatory rules have the potential to impact an upgrade and should be evaluated.

#### ESX Host Memory Utilization

* **Purpose:** Reports each ESX host's memory usage against RED (≥95%)/YELLOW (≥80%)/GREEN thresholds, flagging any host approaching capacity before the upgrade proceeds.
* **Blocks upgrade?** No
* **Informational only check?** No

#### ESX Host Power State

* **Purpose:** Verifies that every ESX host managed by the vCenter is powered on and connected, flagging any host that is powered off or disconnected before an upgrade proceeds.
* **Blocks upgrade?** Yes
* **Informational only check?** No

#### HCX Plugin Detection

* **Purpose:** Detects the HCX plugin across every vCenter attached to SDDC Manager and, when found, parses its version to warn — with a specific remediation citing the VCF 9.1 HCX compatibility KB — only when it's below the HCX 9.1 minimum required for VCF 9.1 (passing silently if already compliant).
* **Blocks upgrade?** No
* **Informational only check?** Yes
* **Notes:**
  * This check will be skipped with no call to action if the plugins are not detected.

#### IPFIX/NetFlow Configuration Consistency

* **Purpose:** Flags distributed virtual switches on any attached vCenter that have inconsistent IPFIX/NetFlow configuration (enabled on some, disabled on others).
* **Blocks upgrade?** No
* **Informational only check?** No

#### Legacy Plugin Detection

* **Purpose:** Flags EOL services (Site Recovery Manager, Dell RecoveryPoint) with a Warning and upgrade-transition guidance before you proceed to VCF 9.x.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * This check will be skipped with no call to action if the plugins are not detected.

#### Management Appliance Snapshot Size

* **Purpose:** Flags SDDC Manager, vCenter, and vRSLCM VMs running on oversized snapshots (>5GB warning, >50GB blocking) that should be cleared before upgrade.
* **Blocks upgrade?** Yes
* **Informational only check?** No

#### Multiwriter-Enabled Virtual Disks

* **Purpose:** Flags VMs across every attached vCenter with a multiwriter-enabled virtual disk, since it can block Storage vMotion and host-evacuation steps during the upgrade.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vCenter and ESX Certificate Expiration

* **Purpose:** Checks the vCenter machine SSL certificate and managed ESX host certificates for expiration across all vCenter domains, flagging any that are already expired or expiring within the configurable warning threshold (default 30 days).
* **Blocks upgrade?** Yes
* **Informational only check?** No

#### vCenter Appliance Disk Space, Inode, and Heap Dump Check

* **Purpose:** Verifies every filesystem on the vCenter appliance is below 80% disk space and inode utilization and that no .hprof (Java heap dump) files are present.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * This check uses `Invoke-VMScript` to check disk-space, inode data, and search for heap files on the appropriate vCenter VM using its root credentials.

#### vCenter Appliance Health Endpoints

* **Purpose:** Checks each vCenter Appliance VAMI health endpoint's actual traffic-light value (mapping red→Fail, yellow/orange/gray→Warning) and, for any non-green item, surfaces VAMI's own descriptive message/resolution text as the row detail and remediation.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vCenter Appliance Outbound Proxy Configuration

* **Purpose:** Flags any vCenter with an outbound proxy configured as a Warning and points to KB guidance to verify its health before starting the upgrade.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vCenter Appliance Root Password Expiration

* **Purpose:** Alerts when the vCenter appliance root account password is about to expire or automatic rotation is disabled, either of which could lock out access mid-upgrade.
* **Blocks upgrade?** Yes
* **Informational only check?** No

#### vCenter Appliance Sizing Check

* **Purpose:** Verifies that each vCenter appliance in the environment is appropriately sized for its live host and VM inventory, and that its disk configuration matches a supported VCSA preset.
* **Blocks upgrade?** Yes
* **Informational only check?** No

#### vCenter Appliance Storage Usage Detail

* **Purpose:** Shows per-partition storage usage across every vCenter appliance attached to SDDC Manager, for capacity planning.
* **Blocks upgrade?** No
* **Informational only check?** Yes

#### vCenter Enhanced Linked Mode (ELM) Compatibility

* **Purpose:** Flags vCenters participating in Enhanced Linked Mode (ELM) and verifies vmdir replication health, since VCF 9.x SSO does not support ELM.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vCenter Lookup Service SSL Trust Mismatch

* **Purpose:** Verifies every :443 service registered with vCenter's Lookup Service presents the SSL certificate the Lookup Service has on file for it, flagging live cert/trust drift before an upgrade.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vCenter Service Status

* **Purpose:** Flags any vCenter appliance service reporting an unknown state.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vCenter SSO Administrator Password Expiry

* **Purpose:** Verifies SSO administrator (PSC/SYSTEM) credential(s) are neither expired nor due to expire within 30 days.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * Checks whether the password(s) will expire within 30 days.

#### vCenter Trusted Root CRL Accumulation Check

* **Purpose:** Checks whether the vCenter appliance's TRUSTED_ROOT_CRLS VECS store has accumulated an excessive number of certificate revocation list entries (≥1000), which can crash the appliance's certificate-management service and disrupt upgrades.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vCenter VMAFD Machine ID

* **Purpose:** Verifies the vCenter appliance's identity service (VMAFD) hasn't become corrupted, as a bad machine ID can block a VCF upgrade.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vCenter VMDir Database File Size

* **Purpose:** Checks the vCenter appliance's vmdir database file for corruption (zero-byte) and for approaching or exceeding the default 1024 MB VMDIR size limit that causes license/SSO-user storage errors.
* **Blocks upgrade?** Yes
* **Informational only check?** No
* **Notes:**
  * This check uses `Invoke-VMScript` to check the file size of this database file on the vCenter VM using its root credentials.

#### vCenter VMDir Health State

* **Purpose:** Verifies the vCenter appliance's local VMDir replication state is "Normal" via retry on transient errors and remediation guidance for abnormal states.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * This check uses `Invoke-VMScript` to check the replication status using the commands `vdcrepadmin` and `dir-cli` on the vCenter VM using its root credentials.

#### vSphere Supervisor Cluster Detection

* **Purpose:** Reports whether any vSphere Supervisor (Workload Management) cluster is enabled, warning when a Supervisor-enabled cluster is still vLCM baseline (VUM) managed since it can't transition to vLCM images until its vCenter is upgraded to 9.0.
* **Blocks upgrade?** No
* **Informational only check?** Yes
* **Notes:**
  * This check will be skipped with no call to action if no vSphere Supervisors are enabled on any cluster in this vCenter.

#### vSphere Supervisor Cluster Kubernetes Versions

* **Purpose:** Reports the current Kubernetes version of each vSphere Supervisor cluster.
* **Blocks upgrade?** No
* **Informational only check?** Yes
* **Notes:**
  * This check will be skipped with no call to action if no vSphere Supervisors are enabled on any cluster in this vCenter.

#### vSphere Supervisor Namespaces

* **Purpose:** Reports every vSphere Namespace on Supervisor-enabled vCenters, its backing cluster, and config status.
* **Blocks upgrade?** No
* **Informational only check?** Yes
* **Notes:**
  * This check will be skipped with no call to action if no vSphere Supervisors are enabled on any cluster in this vCenter.

### NSX

* **Number of checks:** 10

#### NSX Application Platform (NAPP) Registration

* **Purpose:** Verifies every NSX Application Platform (NAPP) cluster registered with NSX Manager is connected, flagging NAPP for migration to Security Services Platform (SSP) since it is no longer supported.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * This check will be skipped with no call to action if NSX Application Platform is not detected.

#### NSX Compute Manager Registration Status

* **Purpose:** Verifies that every vCenter registered as an NSX Manager compute manager remains registered and connected, flagging any that have lost registration or connectivity.
* **Blocks upgrade?** No
* **Informational only check?** No

#### NSX Federation Configuration

* **Purpose:** Flags whether NSX Federation is configured on the management NSX Manager, warning that federated environments require extra steps when upgrading NSX in VCF 9.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * This check will be skipped with no call to action if NSX Federation is not detected.

#### NSX Latency Profile (pNIC Latency Stats)

* **Purpose:** Verifies that no NSX latency-monitoring profile has pNIC latency stats enabled on an NSX Manager older than 4.2.1.2, since that combination is a known upgrade blocker (KB 376769).
* **Blocks upgrade?** Yes
* **Informational only check?** No

#### NSX Manager and Edge Password Expiration

* **Purpose:** Checks the admin/audit/root account password expiration on NSX Manager and every NSX Edge transport node, flagging accounts that are already expired or expiring within 30 days.
* **Blocks upgrade?** No
* **Informational only check?** No

#### NSX Manager API Rate Limits

* **Purpose:** Checks that NSX Manager's API limits match the default values.
* **Blocks upgrade?** No
* **Informational only check?** No

#### NSX Manager Backup History

* **Purpose:** Confirms NSX Manager has a recent successful backup before upgrading.
* **Blocks upgrade?** No
* **Informational only check?** No

#### NSX Manager Node Install/Upgrade Service

* **Purpose:** Verifies that NSX Manager's node install/upgrade service is enabled and bound to a literal IPv4 address (not a hostname/FQDN).
* **Blocks upgrade?** No
* **Informational only check?** No

#### NSX Manager Open Alarms

* **Purpose:** Queries the NSX Manager Alarm/Event Framework for open alarms and flags any at CRITICAL/HIGH severity, so unresolved issues (e.g. remote logging not configured) surface before an upgrade instead of passing silently.
* **Blocks upgrade?** No
* **Informational only check?** No

#### NSX Transport Node Disk Space

* **Purpose:** Checks disk space utilization on every NSX transport node filesystem, warning when usage exceeds the threshold (95% for vsantraces, 75% for others).
* **Blocks upgrade?** No
* **Informational only check?** No

### vSAN

* **Number of checks:** 5

#### vSAN Cluster Health

* **Purpose:** Confirms every vSAN-enabled cluster reports overall green Skyline Health, with a full per-cluster, worst-first breakdown of every health sub-test (network, limits, disk balance/health, encryption, HCL, daemon liveness, and more) for drill-down without leaving the report.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vSAN Disk Format Compatibility

* **Purpose:** Verifies every vSAN-enabled cluster's on-disk format meets the minimum version required for a vSphere 9.x upgrade.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vSAN Disk Group Mount Status

* **Purpose:** Verifies every vSAN disk group across all workload domains is mounted, with per-disk tier, format, and cluster-level dedup/compression/encryption detail.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vSAN Inaccessible Objects

* **Purpose:** Flags vSAN objects with unhealthy or policy-noncompliant status across every vCenter attached to SDDC Manager, pointing to the affected cluster and a KB for remediation.
* **Blocks upgrade?** No
* **Informational only check?** No

#### vSAN Witness Host Version

* **Purpose:** Confirms a stretched cluster's witness host is running the same ESX build as its data hosts, flagging any missing witness or version mismatch.
* **Blocks upgrade?** No
* **Informational only check?** No
* **Notes:**
  * This check will be skipped with no call to action if a stretched cluster is not detected.
