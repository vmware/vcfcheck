"use strict";

(function () {
    // ---- Live log detail filter (persisted server-side via /api/settings) ----
    // The server always writes every severity to the log file (Write-LogMessage's own console
    // threshold only affects a terminal session, never the file), and the Live Log/Credential
    // Check log panels tail that file byte-for-byte - so without a client-side filter, DEBUG
    // lines always show regardless of any server-side LogLevel configuration. Raw, unfiltered
    // text is kept per box so switching the filter re-renders instantly without re-fetching.

    VcfCheckUI.LOG_LEVEL_ORDER = { DEBUG: 0, INFO: 1, WARNING: 2, ERROR: 3 };
    VcfCheckUI.logViewLevel = "INFO";
    VcfCheckUI.liveLogRawText = "";
    VcfCheckUI.credentialLogRawText = "";

    function filterLogText(rawText, minLevel) {
        var minOrder = VcfCheckUI.LOG_LEVEL_ORDER[minLevel];
        if (minOrder === undefined || !rawText) return rawText;

        return rawText.split("\n").filter(function (line) {
            var match = line.match(/^\[[^\]]*\]\s*\[(DEBUG|INFO|WARNING|ERROR)\]/);
            // A line that doesn't start with a recognized "[timestamp] [TYPE]" tag (e.g. a
            // trailing blank line, or a wrapped/multi-line message) is kept rather than
            // dropped - the filter should never risk hiding real content it can't classify.
            if (!match) return true;
            return VcfCheckUI.LOG_LEVEL_ORDER[match[1]] >= minOrder;
        }).join("\n");
    }

    VcfCheckUI.renderFilteredLiveLog = function () {
        var box = document.getElementById("live-log");
        box.textContent = filterLogText(VcfCheckUI.liveLogRawText, VcfCheckUI.logViewLevel);
        box.scrollTop = box.scrollHeight;
    }

    VcfCheckUI.renderFilteredCredentialLog = function () {
        var box = document.getElementById("credential-log");
        box.textContent = filterLogText(VcfCheckUI.credentialLogRawText, VcfCheckUI.logViewLevel);
        box.scrollTop = box.scrollHeight;
    }

    function saveLogViewLevelPreference(level) {
        fetch("/api/settings", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ logViewLevel: level })
        }).catch(function (error) {
            console.warn("Failed to save live log detail preference:", error);
        });
    }

    document.getElementById("log-view-level-select").addEventListener("change", function () {
        VcfCheckUI.logViewLevel = this.value;
        saveLogViewLevelPreference(VcfCheckUI.logViewLevel);
        VcfCheckUI.renderFilteredLiveLog();
        VcfCheckUI.renderFilteredCredentialLog();
    });

    function saveTcpTimeoutPreference(seconds) {
        fetch("/api/settings", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ tcpTimeoutSeconds: seconds })
        }).catch(function (error) {
            console.warn("Failed to save TCP connection timeout preference:", error);
        });
    }

    document.getElementById("tcp-timeout-input").addEventListener("change", function () {
        var seconds = parseInt(this.value, 10);
        if (!Number.isInteger(seconds) || seconds < 1 || seconds > 300) {
            this.value = 30;
            return;
        }
        saveTcpTimeoutPreference(seconds);
    });

    function saveHealthSummaryMaxPollAttemptsPreference(attempts) {
        fetch("/api/settings", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ healthSummaryMaxPollAttempts: attempts })
        }).catch(function (error) {
            console.warn("Failed to save SDDC Manager Health Summary poll budget preference:", error);
        });
    }

    document.getElementById("health-summary-max-poll-attempts-select").addEventListener("change", function () {
        saveHealthSummaryMaxPollAttemptsPreference(parseInt(this.value, 10));
    });

    function savePreUpgradeCheckSetMaxPollAttemptsPreference(attempts) {
        fetch("/api/settings", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ preUpgradeCheckSetMaxPollAttempts: attempts })
        }).catch(function (error) {
            console.warn("Failed to save SDDC Manager Pre-Upgrade Check-Set poll budget preference:", error);
        });
    }

    document.getElementById("pre-upgrade-check-set-max-poll-attempts-select").addEventListener("change", function () {
        savePreUpgradeCheckSetMaxPollAttemptsPreference(parseInt(this.value, 10));
    });

    function saveVcfDestinationReleasePreference(version) {
        fetch("/api/settings", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ vcfDestinationRelease: version })
        }).catch(function (error) {
            console.warn("Failed to save VCF destination release preference:", error);
        });
    }

    document.getElementById("vcf-destination-release-input").addEventListener("change", function () {
        saveVcfDestinationReleasePreference(this.value.trim());
    });

    VcfCheckUI.loadVcfDestinationReleaseOptions = function (savedValue) {
        var hint = document.getElementById("vcf-destination-release-hint");
        var select = document.getElementById("vcf-destination-release-input");
        fetch("/api/vcf-destination-releases").then(function (response) {
            return response.json();
        }).then(function (data) {
            var versions = data.versions || [];
            select.innerHTML = "";
            versions.forEach(function (version) {
                var option = document.createElement("option");
                option.value = version;
                option.textContent = version;
                select.appendChild(option);
            });
            hint.textContent = data.available
                ? ""
                : "The shipped Interop Matrix data is missing or unreadable - only 'latest' is available.";

            // Zero-touch default: a user should never have to pick a value themselves the first
            // time - versions[0] is always 'latest' (the server always offers it first,
            // regardless of whether the live release list could be fetched, since it's resolved
            // locally at check time rather than depending on this list) - so auto-fill and
            // persist it to settings.json immediately, the same as if the user had picked it and
            // moved on. Only when nothing has ever been chosen/saved before - never overwrites
            // an explicit prior choice.
            if (savedValue && versions.indexOf(savedValue) !== -1) {
                select.value = savedValue;
            } else if (versions.length > 0) {
                select.value = versions[0];
                saveVcfDestinationReleasePreference(select.value);
            }
        }).catch(function (error) {
            console.warn("Failed to load VCF destination release options:", error);
            hint.textContent = "Could not reach Broadcom's Interop Matrix - showing 'latest' only.";
            select.innerHTML = "";
            var fallbackVersions = savedValue && savedValue !== "latest" ? ["latest", savedValue] : ["latest"];
            fallbackVersions.forEach(function (version) {
                var option = document.createElement("option");
                option.value = version;
                option.textContent = version;
                select.appendChild(option);
            });
            select.value = savedValue || "latest";
        });
    }

})();
