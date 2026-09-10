"use strict";

(function () {
    // ---- Theme: dark/light toggle, persisted server-side via /api/settings ----

    var _ICON_SUN = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>';
    var _ICON_MOON = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 9 0 0 0 21 12.79z"/></svg>';

    VcfCheckUI.applyTheme = function (isLight) {
        document.body.classList.toggle("light", isLight);
        localStorage.setItem("vcfCheckTheme", isLight ? "light" : "dark");
        var btn = document.getElementById("theme-toggle");
        VcfCheckUI.setInlineSvg(btn, isLight ? _ICON_MOON : _ICON_SUN);
        btn.appendChild(document.createTextNode(isLight ? " Dark" : " Light"));
        btn.title = isLight ? 'Switch to dark mode' : 'Switch to light mode';
    }

    function saveThemePreference(theme) {
        fetch("/api/settings", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ theme: theme })
        }).then(function (response) {
            if (!response.ok) {
                console.warn("Failed to save theme preference: HTTP " + response.status);
            }
        }).catch(function (error) {
            console.warn("Failed to save theme preference:", error);
        });
    }

    function toggleTheme() {
        var isLight = !document.body.classList.contains("light");
        VcfCheckUI.applyTheme(isLight);
        saveThemePreference(isLight ? "light" : "dark");
    }

    document.getElementById("theme-toggle").addEventListener("click", toggleTheme);

    VcfCheckUI.loadVersion = function () {
        return VcfCheckUI.fetchJson("/api/version").then(function (data) {
            document.getElementById("version-badge").textContent = "v" + (data.version || "unknown");
        }).catch(function () { /* badge just stays empty if the server can't resolve a version */ });
    }

    VcfCheckUI.loadSettings = function () {
        return VcfCheckUI.fetchJson("/api/settings").then(function (data) {
            VcfCheckUI.applyTheme(data.theme === "light");
            VcfCheckUI.logViewLevel = ["DEBUG", "WARNING"].indexOf(data.logViewLevel) !== -1 ? data.logViewLevel : "INFO";
            document.getElementById("log-view-level-select").value = VcfCheckUI.logViewLevel;

            var tcpTimeoutSeconds = parseInt(data.tcpTimeoutSeconds, 10);
            if (!Number.isInteger(tcpTimeoutSeconds) || tcpTimeoutSeconds < 1 || tcpTimeoutSeconds > 300) {
                tcpTimeoutSeconds = 30;
            }
            document.getElementById("tcp-timeout-input").value = tcpTimeoutSeconds;

            VcfCheckUI.loadVcfDestinationReleaseOptions(data.vcfDestinationRelease || "");

            var healthSummaryMaxPollAttempts = [12, 24, 48, 60].indexOf(data.healthSummaryMaxPollAttempts) !== -1 ? data.healthSummaryMaxPollAttempts : 24;
            document.getElementById("health-summary-max-poll-attempts-select").value = healthSummaryMaxPollAttempts;

            var preUpgradeCheckSetMaxPollAttempts = [20, 40, 60, 80].indexOf(data.preUpgradeCheckSetMaxPollAttempts) !== -1 ? data.preUpgradeCheckSetMaxPollAttempts : 40;
            document.getElementById("pre-upgrade-check-set-max-poll-attempts-select").value = preUpgradeCheckSetMaxPollAttempts;

            document.getElementById("sizing-section").style.display = data.sizingEstimatorEnabled ? "" : "none";

            VcfCheckUI.loadPowerCliTlsStatus();
        });
    }

    VcfCheckUI.loadPowerCliTlsStatus = function () {
        var valueEl = document.getElementById("powercli-tls-status-value");
        return VcfCheckUI.fetchJson("/api/powercli-tls-status").then(function (data) {
            if (data.invalidCertificateAction === null || data.invalidCertificateAction === undefined) {
                valueEl.textContent = "Unknown";
                valueEl.style.color = "";
                return;
            }
            if (data.allowInsecureTls) {
                valueEl.textContent = "Allowed (" + data.invalidCertificateAction + ")";
                valueEl.style.color = "var(--warning-text)";
            } else {
                valueEl.textContent = "Blocked (" + data.invalidCertificateAction + ")";
                valueEl.style.color = "";
            }
        }).catch(function () {
            valueEl.textContent = "Unknown";
            valueEl.style.color = "";
        });
    }

})();
