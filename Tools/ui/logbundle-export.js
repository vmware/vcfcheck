"use strict";

(function () {
    // ---- Log bundle export (server logs + findings), gated on a security-acknowledgement modal ----

    var logbundleWarningResolve = null;

    function showLogbundleWarning() {
        return new Promise(function (resolve) {
            logbundleWarningResolve = resolve;
            document.getElementById("logbundle-modal-overlay").classList.add("open");
        });
    }

    function dismissLogbundleWarning(proceeded) {
        document.getElementById("logbundle-modal-overlay").classList.remove("open");
        VcfCheckUI.postJson("/api/export/logbundle-ack", { proceeded: proceeded }).catch(function () {});
        if (logbundleWarningResolve) {
            var resolve = logbundleWarningResolve;
            logbundleWarningResolve = null;
            resolve(proceeded);
        }
    }

    document.getElementById("logbundle-cancel-button").addEventListener("click", function () {
        dismissLogbundleWarning(false);
    });
    document.getElementById("logbundle-proceed-button").addEventListener("click", function () {
        dismissLogbundleWarning(true);
    });

    function exportLogBundle() {
        var btn = document.getElementById("export-logbundle-button");
        return showLogbundleWarning().then(function (confirmed) {
            if (!confirmed) return;
            btn.disabled = true;
            var originalLabel = btn.textContent;
            btn.textContent = "";
            var spinSpan = document.createElement("span");
            spinSpan.className = "spin";
            spinSpan.textContent = "↻";
            btn.appendChild(spinSpan);
            btn.appendChild(document.createTextNode(" Collecting…"));
            var url = "/api/export/logbundle" + (VcfCheckUI.reportEnvironmentId ? "?environmentId=" + encodeURIComponent(VcfCheckUI.reportEnvironmentId) : "");
            return fetch(url).then(function (resp) {
                if (!resp.ok) {
                    return resp.json().catch(function () { return {}; }).then(function (data) {
                        throw new Error(data.error || (resp.status + " " + resp.statusText));
                    });
                }
                var disposition = resp.headers.get("Content-Disposition") || "";
                var match = disposition.match(/filename="([^"]+)"/);
                var filename = match ? match[1] : "VcfCheck-logbundle.zip";
                return resp.blob().then(function (blob) {
                    var blobUrl = URL.createObjectURL(blob);
                    var a = document.createElement("a");
                    a.href = blobUrl;
                    a.download = filename;
                    a.click();
                    URL.revokeObjectURL(blobUrl);
                    btn.textContent = "✓ Downloaded";
                });
            }).catch(function (err) {
                VcfCheckUI.showErrorNotification(err.message || "Failed to collect logs.");
                btn.textContent = "✗ Failed";
            }).finally(function () {
                btn.disabled = false;
                setTimeout(function () { btn.textContent = originalLabel; }, 3000);
            });
        });
    }

    document.getElementById("export-logbundle-button").addEventListener("click", exportLogBundle);

    document.getElementById("documentation-button").addEventListener("click", function () {
        window.open("/docs", "_blank", "noopener");
    });

    document.getElementById("report-issue-button").addEventListener("click", function () {
        window.open("https://github.com/vmware/vcfcheck/issues", "_blank", "noopener");
    });


})();
