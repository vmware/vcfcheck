"use strict";

(function () {
    // ---- Report export: JSON/CSV/HTML built client-side from the loaded report, PDF via print ----
    // Each format has a build*Content() that returns the string/blob and a thin export*() wrapper
    // that downloads it, so exportZip() can reuse the exact same content-generation logic instead
    // of re-deriving it (and risking the bundle drifting from the individual downloads).

    function buildJsonExportContent() {
        return JSON.stringify(VcfCheckUI.currentReport, null, 2);
    }

    function buildCsvExportContent() {
        var rows = [VcfCheckUI.CSV_COLUMNS.join(",")];
        (VcfCheckUI.currentReport.results || []).forEach(function (raw) {
            rows.push(VcfCheckUI.CSV_COLUMNS.map(function (key) { return VcfCheckUI.csvEscape(raw[key]); }).join(","));
        });
        return rows.join("\r\n");
    }

    function resultToHtml(result, index) {
        var showRemediation = ["Fail", "Warning", "Error"].indexOf(result.status) !== -1;
        var isSkipped = result.status === "Skipped";
        var details = [
            ["Target", VcfCheckUI.targetComponentLabel(result.checkId, result.area, result.targetComponent)],
            ["Destination", result.destination],
            ["Detail", result.detail],
            ["Validation Criteria", isSkipped ? null : result.validationCriteria],
            ["Remediation", showRemediation ? result.remediation : null],
            ["Exception", result.exception]
        ].filter(function (pair) { return pair[1]; })
            .map(function (pair) { return "<dt>" + VcfCheckUI.escapeHtml(pair[0]) + "</dt><dd>" + VcfCheckUI.escapeHtml(pair[1]) + "</dd>"; })
            .join("");
        var rowsHtml = VcfCheckUI.rowsToHtml(result.rows);
        if (rowsHtml) {
            details += "<dt>" + VcfCheckUI.escapeHtml("Results") + "</dt><dd>" + rowsHtml + "</dd>";
        }
        var hostDetailsHtml = VcfCheckUI.hostDetailsToHtml(result.hostDetails, result.hostDetailsLabel);
        if (hostDetailsHtml) {
            details += "<dt>" + VcfCheckUI.escapeHtml(result.hostDetailsLabel || "Hosts") + "</dt><dd>" + hostDetailsHtml + "</dd>";
        }
        var domainHtml = result.component
            ? " <span class=\"result-domain result-domain-component\">Component: " + VcfCheckUI.escapeHtml(result.component) + "</span>"
            : result.domain
                ? " <span class=\"result-domain" + VcfCheckUI.domainPillClass(result.domainType) + "\">Domain: " + VcfCheckUI.escapeHtml(result.domain) + "</span>"
                : "";
        var infoOnlyHtml = result.informational ? " <span class=\"result-info-only\">Info-only</span>" : "";
        var anchorId = index != null ? " id=\"check-" + index + "\"" : "";
        var filterAttrs = " data-status=\"" + VcfCheckUI.escapeHtml(result.status) + "\" data-blocking=\"" + (result.blocking ? "true" : "false") + "\" data-area=\"" + VcfCheckUI.escapeHtml(result.area) + "\" data-name=\"" + VcfCheckUI.escapeHtml(result.displayName || result.checkId) + "\"";
        var durationHtml = typeof result.durationMs === "number"
            ? "<div class=\"check-duration-badge\">" + VcfCheckUI.escapeHtml(VcfCheckUI.formatCheckDuration(result.durationMs)) + "</div>"
            : "";
        var skipReasonHtml = result.status === "Skipped" && (result.skipReasonTag || result.detail)
            ? " <span class=\"result-skip-reason\" title=\"" + VcfCheckUI.escapeHtml(result.detail || result.skipReasonTag) + "\">Skipped Reason: " + VcfCheckUI.escapeHtml(result.skipReasonTag || result.detail) + "</span>"
            : "";
        return "<div class=\"result-row\"" + anchorId + filterAttrs + "><div class=\"result-summary\">" +
            "<span class=\"badge " + VcfCheckUI.escapeHtml(result.status) + "\">" + VcfCheckUI.escapeHtml(result.status) + "</span>" +
            "<span class=\"result-name\"><span class=\"result-name-text\" title=\"" + VcfCheckUI.escapeHtml(result.displayName || result.checkId) + "\">" + VcfCheckUI.escapeHtml(result.displayName || result.checkId) + "</span>" +
            " <span class=\"result-area\">(" + VcfCheckUI.escapeHtml(result.area) + ")</span>" + domainHtml + infoOnlyHtml + skipReasonHtml + "</span></div>" +
            "<dl class=\"result-detail open\">" + details + "</dl>" + durationHtml + "</div>";
    }

    // Right-hand nav for the exported HTML file, grouped by Area like the PowerShell-generated
    // static report's sidebar (Format-VcfCheckHtmlNav) - one colored status-dot link per
    // check, pointing at the #check-<index> anchor resultToHtml() stamps on that same row.
    function buildExportNav(results) {
        var groups = [];
        var groupsByArea = {};
        results.forEach(function (result, index) {
            var area = result.area || "Other";
            if (!groupsByArea[area]) {
                groupsByArea[area] = { area: area, entries: [] };
                groups.push(groupsByArea[area]);
            }
            var label = result.displayName || result.checkId;
            if (result.domain) { label += " [" + result.domain + "]"; }
            groupsByArea[area].entries.push({ index: index, label: label, status: result.status });
        });

        var html = "<nav class=\"export-nav\"><a href=\"#top\">&uarr; Summary</a>";
        groups.forEach(function (group) {
            html += "<div class=\"export-nav-group-title\">" + VcfCheckUI.escapeHtml(group.area) + "</div>";
            group.entries.forEach(function (entry) {
                html += "<a class=\"export-nav-link " + VcfCheckUI.escapeHtml(entry.status) + "\" href=\"#check-" + entry.index + "\">" +
                    VcfCheckUI.escapeHtml(entry.label) + "</a>";
            });
        });
        html += "</nav>";
        return html;
    }

    // Builds the summary tiles for the exported HTML file as filter chips (data-filter-key
    // matches the keys read by buildExportFilterScript's inline handler below).
    function buildExportTilesHtml(summary, results) {
        var tilesHtml = VcfCheckUI.STATUS_FILTER_TILES.map(function (entry) {
            var key = entry[0], label = entry[1], isBlocking = entry[2];
            var count = summary && summary[key] != null ? summary[key] : 0;
            return "<div class=\"tile tile-" + key + " filter-tile" + (isBlocking ? " blocking" : "") + "\" data-filter-key=\"" + key + "\">" +
                "<div class=\"filter-check\">&#10003;</div>" +
                "<div class=\"count\">" + count + "</div><div class=\"label\">" + VcfCheckUI.escapeHtml(label) + "</div></div>";
        }).join("");
        var areaTilesHtml = VcfCheckUI.AREA_FILTER_TILES.map(function (entry) {
            var key = entry[0], label = entry[1];
            var count = results.filter(function (r) { return r.area === key; }).length;
            return "<div class=\"tile filter-tile\" data-area-filter-key=\"" + VcfCheckUI.escapeHtml(key) + "\">" +
                "<div class=\"filter-check\">&#10003;</div>" +
                "<div class=\"count\">" + count + "</div><div class=\"label\">" + VcfCheckUI.escapeHtml(label) + "</div></div>";
        }).join("");
        return "<p class=\"tiles-intro\">Click a tile to filter the results below - combine any status and component tiles at once.</p>" +
            "<div class=\"tiles-section\"><p class=\"tiles-section-label\">By status</p>" +
            "<div class=\"tiles\" id=\"tiles\">" + tilesHtml + "</div></div>" +
            "<div class=\"tiles-section\"><p class=\"tiles-section-label\">By component</p>" +
            "<div class=\"tiles area-tiles\" id=\"area-tiles\">" + areaTilesHtml + "</div></div>" +
            "<details class=\"filter-hidden-summary hidden\" id=\"filter-hidden-summary\">" +
            "<summary id=\"filter-hidden-summary-text\"></summary><ul id=\"filter-hidden-summary-list\"></ul></details>";
    }

    // Self-contained filter script for the exported HTML file - it has no access to this file's
    // script scope (a separate downloaded document), so the blocking/fail/warning/error/skipped/
    // pass predicates are duplicated here in literal form rather than shared with VcfCheckUI.isResultVisible.
    function buildExportFilterScript() {
        var areaKeysJson = JSON.stringify(VcfCheckUI.AREA_FILTER_TILES.map(function (entry) { return entry[0]; }));
        return "<script>(function(){" +
            "var filters={blockingFailures:true,fail:true,warning:true,error:true,skipped:true,pass:true};" +
            "var areaFilters={};" + areaKeysJson + ".forEach(function(k){areaFilters[k]=true;});" +
            "function matches(status,blocking,key){" +
            "if(key==='blockingFailures')return status==='Fail'&&blocking;" +
            "if(key==='fail')return status==='Fail';" +
            "if(key==='warning')return status==='Warning';" +
            "if(key==='error')return status==='Error';" +
            "if(key==='skipped')return status==='Skipped';" +
            "if(key==='pass')return status==='Pass';" +
            "return false;}" +
            "function visible(status,blocking,area){" +
            "var statusMatch=Object.keys(filters).some(function(k){return filters[k]&&matches(status,blocking,k);});" +
            "var areaMatch=Object.keys(areaFilters).some(function(k){return areaFilters[k]&&k===area;});" +
            "return statusMatch&&areaMatch;}" +
            "function apply(){" +
            "var rows=document.querySelectorAll('.result-row');var hidden=[];" +
            "rows.forEach(function(row){" +
            "var status=row.getAttribute('data-status');var blocking=row.getAttribute('data-blocking')==='true';" +
            "var area=row.getAttribute('data-area');" +
            "if(visible(status,blocking,area)){row.classList.remove('filter-hidden');}" +
            "else{row.classList.add('filter-hidden');hidden.push(row.getAttribute('data-name')+' ('+status+')');}" +
            "});" +
            "var wrap=document.getElementById('filter-hidden-summary');" +
            "var text=document.getElementById('filter-hidden-summary-text');" +
            "var list=document.getElementById('filter-hidden-summary-list');" +
            "if(hidden.length===0){wrap.classList.add('hidden');text.textContent='';list.innerHTML='';}" +
            "else{wrap.classList.remove('hidden');" +
            "text.textContent=hidden.length+' check'+(hidden.length===1?'':'s')+' hidden by the current filter';" +
            "list.innerHTML='';hidden.forEach(function(h){var li=document.createElement('li');li.textContent=h;list.appendChild(li);});}" +
            "}" +
            "document.querySelectorAll('.filter-tile[data-filter-key]').forEach(function(tile){" +
            "tile.addEventListener('click',function(){" +
            "var key=tile.getAttribute('data-filter-key');filters[key]=!filters[key];" +
            "tile.classList.toggle('filter-off',!filters[key]);" +
            "tile.querySelector('.filter-check').textContent=filters[key]?'\\u2713':'';" +
            "apply();});});" +
            "document.querySelectorAll('.filter-tile[data-area-filter-key]').forEach(function(tile){" +
            "tile.addEventListener('click',function(){" +
            "var key=tile.getAttribute('data-area-filter-key');areaFilters[key]=!areaFilters[key];" +
            "tile.classList.toggle('filter-off',!areaFilters[key]);" +
            "tile.querySelector('.filter-check').textContent=areaFilters[key]?'\\u2713':'';" +
            "apply();});});" +
            "apply();" +
            "})();<\/script>";
    }

    function buildHtmlExportContent() {
        // Built entirely from VcfCheckUI.currentReport's data with every value escaped - deliberately not
        // a serialization of the live DOM, since Detail/Exception/Remediation originate from
        // live infrastructure state and this is exactly the unescaped-interpolation shape
        // documented as the legacy tool's confirmed stored-XSS pattern (Docs/ARCHITECTURE.md).
        var styleText = document.querySelector("style").textContent;
        var isLight = document.body.classList.contains("light");
        var results = VcfCheckUI.sortResultsForDisplay((VcfCheckUI.currentReport.results || []).map(VcfCheckUI.normalizeResult));
        var cardsHtml = results.map(function (result, index) { return resultToHtml(result, index); }).join("");
        return "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\">" +
            "<title>VCF Check - " + VcfCheckUI.escapeHtml(VcfCheckUI.currentReport.runId) + "</title>" +
            "<style>" + styleText + "</style></head>" +
            "<body class=\"" + (isLight ? "light" : "") + "\"><div id=\"top\" class=\"export-layout\"><main>" +
            buildExportTilesHtml(VcfCheckUI.currentReport.summary, results) +
            "<div id=\"results\">" + cardsHtml + "</div>" +
            "</main>" + buildExportNav(results) + "</div>" +
            buildExportFilterScript() + "</body></html>";
    }

    function exportHtml() {
        if (!VcfCheckUI.currentReport) return;
        VcfCheckUI.downloadBlob(buildHtmlExportContent(), "text/html", "vcf-check-" + VcfCheckUI.formatTimestampForFilename() + ".html");
    }

    function exportPdf() {
        window.print();
    }

    function exportZip() {
        if (!VcfCheckUI.currentReport) return;
        var timestamp = VcfCheckUI.formatTimestampForFilename();
        var files = [
            { name: "vcf-check-" + timestamp + ".json", content: buildJsonExportContent() },
            { name: "vcf-check-" + timestamp + ".csv", content: buildCsvExportContent() },
            { name: "vcf-check-" + timestamp + ".html", content: buildHtmlExportContent() }
        ];
        if (VcfCheckUI.lastSavedSizingEstimate) {
            files.push({ name: "resource-estimation.json", content: JSON.stringify(VcfCheckUI.lastSavedSizingEstimate, null, 2) });
        }
        var zipBlob = VcfCheckUI.buildZipBlob(files);
        VcfCheckUI.downloadBlob(zipBlob, "application/zip", "vcf-check-" + timestamp + ".zip");
    }

    document.getElementById("export-html-button").addEventListener("click", exportHtml);
    document.getElementById("export-pdf-button").addEventListener("click", exportPdf);
    document.getElementById("export-zip-button").addEventListener("click", exportZip);


})();
