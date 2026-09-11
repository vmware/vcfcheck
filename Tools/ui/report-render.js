"use strict";

(function () {
    // ---- Report rendering (tiles + result rows) ----

    VcfCheckUI.renderTiles = function (summary) {
        var tiles = document.getElementById("tiles");
        tiles.innerHTML = "";
        // "blockingFailures" is a subset of "fail" (both count Status=Fail rows), so it's
        // excluded here to avoid double-counting. A domain-scoped check still produces one
        // result row per domain it ran against (New-VcfCheckPerDomainResults), so this total
        // is a row count and can exceed the "N/M checks" run-progress counter, which counts
        // distinct checks instead.
        var totalResults = (summary.pass || 0) + (summary.warning || 0) + (summary.fail || 0) + (summary.error || 0) + (summary.skipped || 0);
        var totalLabel = document.getElementById("tiles-total-count");
        if (totalLabel) {
            totalLabel.textContent = "(" + totalResults + " result" + (totalResults === 1 ? "" : "s") + ")";
            totalLabel.title = "Counts individual check results, not distinct checks. A check that runs against multiple domains or vCenters produces one result per domain, so this can exceed the \"checks\" count shown while a scan is running.";
        }
        VcfCheckUI.STATUS_FILTER_TILES.forEach(function (entry) {
            var key = entry[0], label = entry[1], isBlocking = entry[2];
            var tile = VcfCheckUI.el("div", "tile tile-" + key + " filter-tile" + (isBlocking ? " blocking" : "") + (VcfCheckUI.statusFilters[key] ? "" : " filter-off"));
            tile.appendChild(VcfCheckUI.el("div", "filter-check", VcfCheckUI.statusFilters[key] ? "✓" : ""));
            tile.appendChild(VcfCheckUI.el("div", "count", String(summary[key] != null ? summary[key] : 0)));
            tile.appendChild(VcfCheckUI.el("div", "label", label));
            tile.title = VcfCheckUI.statusFilters[key] ? "Click to hide " + label + " checks" : "Click to show " + label + " checks";
            tile.addEventListener("click", function () {
                VcfCheckUI.statusFilters[key] = !VcfCheckUI.statusFilters[key];
                VcfCheckUI.renderTiles(summary);
                VcfCheckUI.renderResults(VcfCheckUI.currentNormalizedResults);
            });
            tiles.appendChild(tile);
        });
    }

    VcfCheckUI.renderAreaTiles = function (results) {
        var tiles = document.getElementById("area-tiles");
        tiles.innerHTML = "";
        VcfCheckUI.AREA_FILTER_TILES.forEach(function (entry) {
            var key = entry[0], label = entry[1];
            var count = results.filter(function (r) { return r.area === key; }).length;
            var tile = VcfCheckUI.el("div", "tile filter-tile" + (VcfCheckUI.areaFilters[key] ? "" : " filter-off"));
            tile.appendChild(VcfCheckUI.el("div", "filter-check", VcfCheckUI.areaFilters[key] ? "✓" : ""));
            tile.appendChild(VcfCheckUI.el("div", "count", String(count)));
            tile.appendChild(VcfCheckUI.el("div", "label", label));
            tile.title = VcfCheckUI.areaFilters[key] ? "Click to hide " + label + " checks" : "Click to show " + label + " checks";
            tile.addEventListener("click", function () {
                VcfCheckUI.areaFilters[key] = !VcfCheckUI.areaFilters[key];
                VcfCheckUI.renderAreaTiles(VcfCheckUI.currentNormalizedResults);
                VcfCheckUI.renderResults(VcfCheckUI.currentNormalizedResults);
            });
            tiles.appendChild(tile);
        });
    }

    VcfCheckUI.domainPillClass = function (domainType) {
        if (domainType === "MANAGEMENT") { return " result-domain-management"; }
        if (domainType) { return " result-domain-workload"; }
        return "";
    }

    // ESX/vSAN-area checks are executed per-vCenter and their TargetComponent is always a
    // vCenter FQDN, not an ESXi host or vSAN cluster - see New-VcfCheckPerDomainResults in
    // Connections.ps1.
    var TARGET_TYPE_LABELS = {
        "ESX": "vCenter",
        "vSAN": "vCenter",
        "vCenter": "vCenter",
        "Tanzu": "vCenter",
        "NSX": "NSX Manager",
        "SDDC Manager": "SDDC Manager",
        "Aria Suite": "Aria Suite Lifecycle Manager"
    };

    // A couple of SDDC-Manager-area checks route through the same per-vCenter merge helpers as
    // the ESX/vSAN checks above, so their TargetComponent is a vCenter FQDN too, despite the
    // "SDDC Manager" area - the Area-based table alone would mislabel these as targeting SDDC
    // Manager itself.
    // The "Aria Suite" area also covers aria_ops_* checks, whose TargetComponent is an Aria
    // Operations FQDN, not vRSLCM's - the TARGET_TYPE_LABELS "Aria Suite" entry alone would
    // mislabel every one of them as targeting Aria Suite Lifecycle Manager.
    var TARGET_TYPE_OVERRIDES_BY_CHECK_ID = {
        "sddc_check_vlcm_vum": "vCenter",
        "sddc_cluster_resource_utilization": "vCenter",
        "sddc_check_cores_and_vsan_tib": "vCenter",
        "aria_ops_adapter_collection_status": "Aria Operations",
        "aria_ops_collector_status": "Aria Operations",
        "aria_ops_collector_type": "Aria Operations",
        "aria_ops_critical_alerts": "Aria Operations",
        "aria_ops_certificate_expiration": "Aria Operations",
        "aria_ops_license": "Aria Operations",
        "aria_ops_lifecycle_status": "Aria Operations",
        "aria_ops_sizing_overview": "Aria Operations"
    };

    VcfCheckUI.targetComponentLabel = function (checkId, area, targetComponent) {
        if (!targetComponent) return targetComponent;
        var typeLabel = TARGET_TYPE_OVERRIDES_BY_CHECK_ID[checkId] || TARGET_TYPE_LABELS[area];
        return typeLabel ? typeLabel + ": " + targetComponent : targetComponent;
    }

    function checkDescriptionFor(area, displayName) {
        var checks = VcfCheckUI.checksByArea[area];
        if (!checks) return "";
        for (var i = 0; i < checks.length; i++) {
            if (checks[i].displayName === displayName) return checks[i].description || "";
        }
        return "";
    }

    function renderResultRow(result) {
        var resultKey = [result.checkId, result.area, result.component, result.domain, result.targetComponent].join("|");
        var row = VcfCheckUI.el("div", "result-row");
        var summaryRow = VcfCheckUI.el("div", "result-summary");

        var checkDescription = checkDescriptionFor(result.area, result.displayName);
        if (checkDescription) {
            var infoIcon = VcfCheckUI.el("span", "result-info-icon");
            VcfCheckUI.setInlineSvg(infoIcon, VcfCheckUI._INFO_ICON);
            infoIcon.setAttribute("data-tooltip", checkDescription);
            infoIcon.setAttribute("tabindex", "0");
            summaryRow.appendChild(infoIcon);
        }

        var badge = VcfCheckUI.el("span", "badge " + result.status, result.status);
        summaryRow.appendChild(badge);
        if (result.blocking && result.status === "Fail") {
            summaryRow.appendChild(VcfCheckUI.el("span", "blocking-tag", "Must resolve before VCF upgrade"));
        }

        var nameWrap = VcfCheckUI.el("span", "result-name");
        var nameText = VcfCheckUI.el("span", "result-name-text");
        nameText.appendChild(document.createTextNode(result.displayName || result.checkId));
        nameText.title = result.displayName || result.checkId;
        nameWrap.appendChild(nameText);
        var areaSpan = VcfCheckUI.el("span", "result-area");
        areaSpan.textContent = "(" + result.area + ")";
        nameWrap.appendChild(areaSpan);
        if (result.component) {
            var componentBadge = VcfCheckUI.el("span", "result-domain result-domain-component");
            componentBadge.textContent = "Component: " + result.component;
            nameWrap.appendChild(componentBadge);
        } else if (result.domain) {
            var domainBadge = VcfCheckUI.el("span", "result-domain" + VcfCheckUI.domainPillClass(result.domainType));
            domainBadge.textContent = "Domain: " + result.domain;
            nameWrap.appendChild(domainBadge);
        }
        if (result.informational) {
            nameWrap.appendChild(VcfCheckUI.el("span", "result-info-only", "Info-only"));
        }
        if (result.status === "Skipped" && (result.skipReasonTag || result.detail)) {
            var skipReasonText = result.skipReasonTag || result.detail;
            var skipReasonPill = VcfCheckUI.el("span", "result-skip-reason", "Skipped Reason: " + skipReasonText);
            skipReasonPill.title = result.detail || skipReasonText;
            nameWrap.appendChild(skipReasonPill);
        }
        summaryRow.appendChild(nameWrap);

        var showRemediation = ["Fail", "Warning", "Error"].indexOf(result.status) !== -1;
        var isSkipped = result.status === "Skipped";
        var detail = VcfCheckUI.el("dl", "result-detail");
        [
            ["Target", VcfCheckUI.targetComponentLabel(result.checkId, result.area, result.targetComponent)],
            ["Destination", result.destination],
            ["Information", isSkipped ? null : result.information],
            ["Detail", result.detail],
            ["Validation Criteria", isSkipped ? null : result.validationCriteria],
            ["Remediation", showRemediation ? result.remediation : null],
            ["Exception", result.exception]
        ].forEach(function (pair) {
            var label = pair[0], value = pair[1];
            if (!value) return;
            detail.appendChild(VcfCheckUI.el("dt", null, label));
            var dd = VcfCheckUI.el("dd");
            // Render text with hyperlinks for fields that might contain URLs
            if (["Information", "Detail", "Validation Criteria", "Remediation"].indexOf(label) !== -1) {
                dd.appendChild(VcfCheckUI.renderTextWithLinks(value));
            } else {
                dd.textContent = value;
            }
            detail.appendChild(dd);
        });
        var rowsTable = VcfCheckUI.renderRowsTable(result.rows);
        if (rowsTable) {
            detail.appendChild(VcfCheckUI.el("dt", null, "Results"));
            var rowsDd = VcfCheckUI.el("dd");
            rowsDd.appendChild(rowsTable);
            detail.appendChild(rowsDd);
        }
        var hostDetailCards = VcfCheckUI.renderHostDetailCards(result.hostDetails, resultKey, result.hostDetailsLabel);
        if (hostDetailCards) {
            var hostDetailsDd = VcfCheckUI.el("dd");
            hostDetailsDd.appendChild(hostDetailCards);
            detail.appendChild(hostDetailsDd);
        }

        if (typeof result.durationMs === "number") {
            detail.appendChild(VcfCheckUI.el("div", "check-duration-badge", VcfCheckUI.formatCheckDuration(result.durationMs)));
        }

        var chevron = VcfCheckUI.el("span", "result-chevron", "▼");
        summaryRow.appendChild(chevron);

        detail.dataset.resultKey = resultKey;
        if (VcfCheckUI.expandedResultKeys[resultKey] || VcfCheckUI.allTilesExpanded) {
            detail.classList.add("open");
            chevron.classList.add("open");
        }

        summaryRow.addEventListener("click", function () {
            detail.classList.toggle("open");
            chevron.classList.toggle("open");
            if (detail.classList.contains("open")) {
                VcfCheckUI.expandedResultKeys[resultKey] = true;
            } else {
                delete VcfCheckUI.expandedResultKeys[resultKey];
            }
        });

        row.appendChild(summaryRow);
        row.appendChild(detail);
        return row;
    }

    function renderDomainScopeSummary(results) {
        var summary = document.getElementById("domain-scope-summary");
        var names = [];
        var seen = {};
        results.forEach(function (result) {
            if (result.domain && !seen[result.domain]) {
                seen[result.domain] = true;
                names.push(result.domain);
            }
        });
        if (names.length === 0) {
            summary.classList.add("hidden");
            summary.textContent = "";
            return;
        }
        names.sort();
        summary.textContent = "Showing results for: " + names.join(", ");
        summary.classList.remove("hidden");
    }

    VcfCheckUI.sortResultsForDisplay = function (results) {
        return results.slice().sort(function (a, b) {
            var orderA = VcfCheckUI.STATUS_ORDER[a.status] != null ? VcfCheckUI.STATUS_ORDER[a.status] : 99;
            var orderB = VcfCheckUI.STATUS_ORDER[b.status] != null ? VcfCheckUI.STATUS_ORDER[b.status] : 99;
            if (orderA !== orderB) return orderA - orderB;
            if (a.blocking !== b.blocking) return a.blocking ? -1 : 1;
            // Sort by area within the same status and blocking flag
            var areaOrderA = VcfCheckUI.AREA_ORDER[a.area] != null ? VcfCheckUI.AREA_ORDER[a.area] : 99;
            var areaOrderB = VcfCheckUI.AREA_ORDER[b.area] != null ? VcfCheckUI.AREA_ORDER[b.area] : 99;
            return areaOrderA - areaOrderB;
        });
    }

    function renderFilterHiddenSummary(hiddenResults) {
        var wrap = document.getElementById("filter-hidden-summary");
        var text = document.getElementById("filter-hidden-summary-text");
        var list = document.getElementById("filter-hidden-summary-list");
        if (hiddenResults.length === 0) {
            wrap.classList.add("hidden");
            text.textContent = "";
            list.innerHTML = "";
            return;
        }
        text.textContent = hiddenResults.length + " check" + (hiddenResults.length === 1 ? "" : "s") + " hidden by the current filter";
        list.innerHTML = "";
        hiddenResults.forEach(function (result) {
            var item = document.createElement("li");
            item.textContent = (result.displayName || result.checkId) + " (" + result.status + ")";
            list.appendChild(item);
        });
        wrap.classList.remove("hidden");
    }

    var SKIP_GROUP_KEY = "__skipped-group__";

    function renderSkipGroupRow(skippedResults) {
        var row = VcfCheckUI.el("div", "result-row skip-group");
        var summaryRow = VcfCheckUI.el("div", "result-summary");

        var badge = VcfCheckUI.el("span", "badge Skipped", "Skipped");
        summaryRow.appendChild(badge);

        var nameWrap = VcfCheckUI.el("span", "result-name");
        var nameText = VcfCheckUI.el("span", "result-name-text",
            "Checks skipped because optional components were not found : no action required");
        nameWrap.appendChild(nameText);
        summaryRow.appendChild(nameWrap);

        var count = VcfCheckUI.el("span", "skip-group-count",
            skippedResults.length + " check" + (skippedResults.length === 1 ? "" : "s"));
        summaryRow.appendChild(count);

        var chevron = VcfCheckUI.el("span", "result-chevron", "▼");
        summaryRow.appendChild(chevron);

        var body = VcfCheckUI.el("div", "skip-group-body");
        skippedResults.forEach(function (result) {
            body.appendChild(renderResultRow(result));
        });

        body.dataset.resultKey = SKIP_GROUP_KEY;
        if (VcfCheckUI.expandedResultKeys[SKIP_GROUP_KEY] || VcfCheckUI.allTilesExpanded) {
            body.classList.add("open");
            chevron.classList.add("open");
        }

        summaryRow.addEventListener("click", function () {
            body.classList.toggle("open");
            chevron.classList.toggle("open");
            if (body.classList.contains("open")) {
                VcfCheckUI.expandedResultKeys[SKIP_GROUP_KEY] = true;
            } else {
                delete VcfCheckUI.expandedResultKeys[SKIP_GROUP_KEY];
            }
        });

        row.appendChild(summaryRow);
        row.appendChild(body);
        return row;
    }

    VcfCheckUI.renderResults = function (results) {
        renderDomainScopeSummary(results);
        VcfCheckUI.currentNormalizedResults = results;
        var sorted = VcfCheckUI.sortResultsForDisplay(results);
        var visible = sorted.filter(VcfCheckUI.isResultVisible);
        var hidden = sorted.filter(function (result) { return !VcfCheckUI.isResultVisible(result); });
        var container = document.getElementById("results");
        container.innerHTML = "";
        var skipped = visible.filter(function (result) { return result.status === "Skipped"; });
        var nonSkipped = visible.filter(function (result) { return result.status !== "Skipped"; });
        nonSkipped.forEach(function (result) {
            container.appendChild(renderResultRow(result));
        });
        if (skipped.length > 0) {
            container.appendChild(renderSkipGroupRow(skipped));
        }
        renderFilterHiddenSummary(hidden);
    }

    function setTileRowOpen(row, open) {
        var chevron = row.querySelector(":scope > .result-summary > .result-chevron");
        var content = row.querySelector(":scope > .result-detail") || row.querySelector(":scope > .skip-group-body");
        if (!content) return;
        content.classList.toggle("open", open);
        if (chevron) chevron.classList.toggle("open", open);
        var key = content.dataset.resultKey;
        if (!key) return;
        if (open) {
            VcfCheckUI.expandedResultKeys[key] = true;
        } else {
            delete VcfCheckUI.expandedResultKeys[key];
        }
    }

    function updateToggleAllTilesButton() {
        document.getElementById("toggle-all-tiles-button").textContent = VcfCheckUI.allTilesExpanded ? "Collapse all" : "Expand all";
    }

    function toggleAllTiles() {
        VcfCheckUI.allTilesExpanded = !VcfCheckUI.allTilesExpanded;
        document.querySelectorAll("#results .result-row").forEach(function (row) {
            setTileRowOpen(row, VcfCheckUI.allTilesExpanded);
        });
        updateToggleAllTilesButton();
    }

    document.getElementById("toggle-all-tiles-button").addEventListener("click", toggleAllTiles);

    VcfCheckUI.normalizeResult = function (raw) {
        // PowerShell's ConvertTo-Json preserves the PascalCase property names from
        // New-VcfCheckResult; normalize to the camelCase keys this UI expects.
        return {
            checkId: raw.CheckId,
            area: raw.Area,
            displayName: raw.DisplayName,
            status: raw.Status,
            blocking: !!raw.Blocking,
            informational: !!raw.Informational,
            targetComponent: raw.TargetComponent,
            destination: raw.Destination,
            domain: raw.Domain,
            domainType: raw.DomainType,
            component: raw.Component,
            information: raw.Information,
            detail: raw.Detail,
            skipReasonTag: raw.SkipReasonTag,
            validationCriteria: raw.ValidationCriteria,
            remediation: raw.Remediation,
            exception: raw.Exception,
            rows: raw.Rows || [],
            hostDetails: raw.HostDetails || [],
            hostDetailsLabel: raw.HostDetailsLabel || "Hosts",
            durationMs: raw.DurationMs
        };
    }

    VcfCheckUI.setExportButtonsEnabled = function (enabled) {
        VcfCheckUI.EXPORT_BUTTON_IDS.forEach(function (id) {
            document.getElementById(id).disabled = !enabled;
        });
        document.getElementById("export-actions").classList.toggle("hidden", !enabled);
    }

    VcfCheckUI.renderReport = function (report) {
        var results = (report.results || []).map(VcfCheckUI.normalizeResult);
        VcfCheckUI.renderTiles(report.summary);
        VcfCheckUI.renderAreaTiles(results);
        VcfCheckUI.renderResults(results);
        VcfCheckUI.currentReport = report;
        VcfCheckUI.setExportButtonsEnabled(!VcfCheckUI.isRunning);
        var totalRunTimeElement = document.getElementById("total-run-time");
        if (VcfCheckUI.finalRunTime) {
            totalRunTimeElement.textContent = "Total run time: " + VcfCheckUI.finalRunTime;
            totalRunTimeElement.classList.remove("hidden");
        } else {
            totalRunTimeElement.classList.add("hidden");
        }
        document.getElementById("tiles-hint").classList.remove("hidden");
        document.getElementById("area-tiles-hint").classList.remove("hidden");
        document.getElementById("area-tiles-label").classList.remove("hidden");
        document.getElementById("toggle-all-tiles-button").classList.remove("hidden");
    }

    VcfCheckUI.clearReport = function () {
        VcfCheckUI.currentReport = null;
        VcfCheckUI.expandedResultKeys = {};
        VcfCheckUI.expandedHostKeys = {};
        VcfCheckUI.allTilesExpanded = false;
        VcfCheckUI.setExportButtonsEnabled(false);
        document.getElementById("tiles").innerHTML = "";
        document.getElementById("area-tiles").innerHTML = "";
        document.getElementById("results").innerHTML = "";
        document.getElementById("tiles-total-count").textContent = "";
        document.getElementById("tiles-hint").classList.add("hidden");
        document.getElementById("total-run-time").classList.add("hidden");
        document.getElementById("area-tiles-hint").classList.add("hidden");
        document.getElementById("area-tiles-label").classList.add("hidden");
        document.getElementById("toggle-all-tiles-button").classList.add("hidden");
        updateToggleAllTilesButton();
        renderDomainScopeSummary([]);
        VcfCheckUI.currentNormalizedResults = [];
        renderFilterHiddenSummary([]);
    }

    VcfCheckUI.clearReportForNewScan = function () {
        VcfCheckUI.currentReport = null;
        VcfCheckUI.expandedResultKeys = {};
        VcfCheckUI.expandedHostKeys = {};
        VcfCheckUI.allTilesExpanded = false;
        VcfCheckUI.setExportButtonsEnabled(false);
        document.getElementById("tiles").innerHTML = "";
        document.getElementById("area-tiles").innerHTML = "";
        document.getElementById("results").innerHTML = "";
        document.getElementById("tiles-total-count").textContent = "";
        document.getElementById("tiles-hint").classList.add("hidden");
        document.getElementById("total-run-time").classList.add("hidden");
        document.getElementById("area-tiles-hint").classList.add("hidden");
        document.getElementById("area-tiles-label").classList.add("hidden");
        document.getElementById("toggle-all-tiles-button").classList.add("hidden");
        updateToggleAllTilesButton();
        renderDomainScopeSummary([]);
        VcfCheckUI.currentNormalizedResults = [];
        renderFilterHiddenSummary([]);
    }

    // TEST-EXTRACT-LOADRUN-START (see Tests/vcf-check-ui.load-run.test.js - keep this marker
    // and the matching END marker in sync with any change to loadRun's signature or logic).
    VcfCheckUI.loadRun = function (environmentId, expectedRunId, isRunning) {
        var query = environmentId ? ("?environmentId=" + encodeURIComponent(environmentId)) : "";
        return VcfCheckUI.fetchJson("/api/runs/latest" + query, true).then(function (report) {
            // While a run is active, latest.json can still hold the PREVIOUS run's report until
            // this run writes its own first partial result - rendering it unconditionally shows
            // stale pass/fail counts under a "0/N checks complete" status. Comparing runId (set
            // server-side before the subprocess for this run is even started - see
            // _start_next_queue_item) catches that case the same way _completed_check_count
            // already does server-side.
            //
            // isRunning covers the narrow window before expectedRunId itself exists: the queue
            // item is accepted and "running" but the server hasn't assigned its runId yet, so
            // expectedRunId is still falsy and the runId comparison below can't fire at all -
            // without this, the previous run's full report (blocking failures, skipped count,
            // everything) renders as if it belonged to the run that was just started.
            if (isRunning && !expectedRunId) {
                VcfCheckUI.clearReportForNewScan();
                return;
            }
            if (expectedRunId && report.runId !== expectedRunId) {
                VcfCheckUI.clearReportForNewScan();
                return;
            }
            VcfCheckUI.renderReport(report);
        }).catch(function () {
            if (expectedRunId) {
                VcfCheckUI.clearReportForNewScan();
            } else {
                VcfCheckUI.clearReport();
            }
        });
    }
    // TEST-EXTRACT-LOADRUN-END

    VcfCheckUI.renderReportEnvironmentSelect = function () {
        var wrap = document.getElementById("report-environment-select-wrap");
        var select = document.getElementById("report-environment-select");
        var scannable = VcfCheckUI.environments.filter(function (env) { return true; });

        if (VcfCheckUI.lastQueue.length <= 1) {
            wrap.classList.add("hidden");
            return;
        }

        wrap.classList.remove("hidden");
        select.innerHTML = "";
        VcfCheckUI.lastQueue.forEach(function (item) {
            var option = document.createElement("option");
            option.value = item.environmentId || "";
            option.textContent = item.name + " (" + item.status + ")";
            select.appendChild(option);
        });
        if (VcfCheckUI.reportEnvironmentId) {
            select.value = VcfCheckUI.reportEnvironmentId;
        }
    }

    document.getElementById("report-environment-select").addEventListener("change", function () {
        VcfCheckUI.reportEnvironmentId = this.value || null;
        VcfCheckUI.loadRun(VcfCheckUI.reportEnvironmentId);
    });


})();
