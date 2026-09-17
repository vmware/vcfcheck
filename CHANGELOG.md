# VCF Check

## 2.0.0.1008

### Release Date : 2026-09-17


* Feature: Aria Automation integration and initial checks.
  * New Check: Aria Automation Appliance Health Check
  * New Check: Aria Automation Cloud Account Health Check
  * New Check: Aria Automation Licensing Check
  * New Check: Aria Automation Project Zone Configuration Check
  * New Check: Aria Automation Version Check
  * New Check: Aria Automation vRO Integration Health Check
  * New Check: Aria Automation NTP Status Check
  * New Check: Aria Automation DNS Configuration Check
  * New Check: Aria Automation Appliance Disk Space Check
  * New Check: Aria Automation FIPS Status Check
  * New Check: Aria Automation Orchestrator Extensions Check
  * New Check: Aria Automation Orchestrator Properties Check
  * New Check: Aria Automation SSH Server Status Check
* Feature: Aria Operations for logs integration and initial checks.
  * New Check: Aria Operations for Logs Certificate Expiration Check
  * New Check: Aria Operations for Logs Licensing Check
  * New Check: Aria Operations for Logs Log Forwarder Status Check
  * New Check: Aria Operations for Logs Version Check
  * New Check: Aria Operations for Logs vIDM Status Check
  * New Check: Aria Operations for Logs vSphere Integration Status Check
  * New Check: Aria Operations for Logs SSH Server Status Check
* Aria Operations check added.
  * New Check: Aria Operations SSH Server Status Check
* Feature: Optional log scrubbing upon export.
* Feature: Save default health checks.
* Change: Rename "Root checks" to "GuestOS Checks" for clarity.
* Change: Keep LiveLog after the scan has completed (but leave it in a collapsed state).
* Enhancement: If inventory-runtime-dependent checks `SDDC Manager Health Summary` and `SDDC Manager Pre-Upgrade` timeout; provide tailored call to action (how to increase timeout value as needed).
* Bug Fix: `Initialize-VcfCheck` should check for VCF.PowerCLI before checking VCF.PowerCLI configuration.
* Bug Fix: Scan-time Aria Operations connector password check improvements.
* Bug Fix: Credential Check phase reporting lagged.
* Bug Fix: filter out HCX mobility agent from all ESX checks
* Bug Fix: only query ESX hosts that have ConnectionState -in @('Connected', 'Maintenance')
* Bug Fix: fixed several checks where one malformed entry aborts the entire loop.
* Bug Fix: terminating check run failures due to bugs/unexpected input weren't exposed in UI (only in logs).
* Bug Fix: When re-running checks in the same browser session, the session timer didn't reset.

## 2.0.0.1007

### Release Date : 2026-09-11

* Bug Fix: Resolve polling issue caused by stalled task in `SDDC Manager Health Summary` check.
* Bug Fix: Numerous improvements to `vSAN Health Check` (functionality, UI, and bug fixes).
* Bug Fix: Improve edge-case error handling in `NSX Manager and Edge Password Expiration`.

## 2.0.0.1006

### Release Date : 2026-09-10

* New platform: Powershell Engine with Python UI
* Aria Operations checks added as a category
