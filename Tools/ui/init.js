"use strict";

(function () {
    // ---- Initial load ----

    VcfCheckUI.setInlineSvg(document.getElementById("chk-legend-info-icon"), VcfCheckUI._INFO_ICON);
    VcfCheckUI.setInlineSvg(document.getElementById("health-summary-poll-info-icon"), VcfCheckUI._INFO_ICON);
    VcfCheckUI.setInlineSvg(document.getElementById("pre-upgrade-poll-info-icon"), VcfCheckUI._INFO_ICON);
    VcfCheckUI.setInlineSvg(document.getElementById("vcf-destination-release-info-icon"), VcfCheckUI._INFO_ICON);
    VcfCheckUI.setInlineSvg(document.getElementById("powercli-tls-status-info-icon"), VcfCheckUI._INFO_ICON);
    VcfCheckUI.setInlineSvg(document.getElementById("env-form-integrations-info-icon"), VcfCheckUI._INFO_ICON);

    VcfCheckUI.loadSettings().then(function () {
        VcfCheckUI.loadVersion();
        return VcfCheckUI.loadEnvironments();
    }).then(function () {
        VcfCheckUI.applyInitialEnvironmentsCardState();
        return VcfCheckUI.loadChecks();
    }).then(function () {
        VcfCheckUI.clearReport();
        // If a run is already active from before this page load (e.g. a refresh mid-scan),
        // pick it back up rather than showing an idle form.
        VcfCheckUI.fetchJson("/api/run/status").then(function (status) {
            if (status.running) {
                VcfCheckUI.isRunning = true;
                VcfCheckUI.setRunningState(true);
                VcfCheckUI.lastQueue = status.queue || [];
                VcfCheckUI.renderQueueStrip(VcfCheckUI.lastQueue);
                // Rebase the elapsed clock on the server's own run start time, not "now" -
                // otherwise a mid-scan page refresh makes an hours-old run look like it just began.
                VcfCheckUI.runStartTime = status.startedAt ? new Date(status.startedAt).getTime() : Date.now();
                VcfCheckUI.finalRunTime = null;
                VcfCheckUI.resumePolling();
            }
        });
    }).catch(function () {
        VcfCheckUI.applyTheme(true);
        VcfCheckUI.clearReport();
    });

})();
