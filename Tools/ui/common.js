"use strict";

(function () {
    VcfCheckUI.reportEnvironmentId = null;
    VcfCheckUI.expandedResultKeys = {};
    VcfCheckUI.expandedHostKeys = {};
    VcfCheckUI.allTilesExpanded = false;
    VcfCheckUI.runStartTime = null;
    VcfCheckUI.runElapsedTimer = null;
    VcfCheckUI.finalRunTime = null;

    VcfCheckUI.showErrorNotification = function (message) {
        // Log to browser console for debugging
        console.error("[VcfCheck Error]", message);

        // Create or update error banner
        var errorBanner = document.getElementById("vcf-error-banner");
        if (!errorBanner) {
            errorBanner = document.createElement("div");
            errorBanner.id = "vcf-error-banner";
            errorBanner.className = "error-banner hidden";
            var mainContainer = document.querySelector("main") || document.body;
            mainContainer.insertBefore(errorBanner, mainContainer.firstChild);
        }

        errorBanner.textContent = "";

        // Extract and display log file path if present. message may originate from a server
        // error response, so it's built with textContent/createElement below, never assigned
        // as markup.
        var logPathParts = message.indexOf("Check the server log at:") !== -1
            ? message.split("Check the server log at:")
            : null;

        if (logPathParts && logPathParts.length > 1) {
            errorBanner.appendChild(VcfCheckUI.el("strong", null, "⚠️ Server Error"));
            errorBanner.appendChild(document.createElement("br"));
            errorBanner.appendChild(document.createTextNode("Check the server log file for details:"));
            errorBanner.appendChild(document.createElement("br"));
            var codeEl = VcfCheckUI.el("code", null, logPathParts[1].trim());
            errorBanner.appendChild(codeEl);
        } else {
            errorBanner.appendChild(VcfCheckUI.el("strong", null, "⚠️ Error:"));
            errorBanner.appendChild(document.createTextNode(" " + message));
        }

        errorBanner.classList.remove("hidden");

        // Auto-hide after 15 seconds (longer for log file messages)
        setTimeout(function() {
            errorBanner.classList.add("hidden");
        }, 15000);
    }

    VcfCheckUI.formatElapsedTime = function (milliseconds) {
        var totalSeconds = Math.floor(milliseconds / 1000);
        var hours = Math.floor(totalSeconds / 3600);
        var minutes = Math.floor((totalSeconds % 3600) / 60);
        var seconds = totalSeconds % 60;
        if (hours > 0) {
            return hours + "h " + minutes + "m " + seconds + "s";
        } else if (minutes > 0) {
            return minutes + "m " + seconds + "s";
        } else {
            return seconds + "s";
        }
    }

    VcfCheckUI.formatCheckDuration = function (milliseconds) {
        if (milliseconds < 1000) {
            return Math.round(milliseconds) + " ms to execute";
        }
        return (Math.round(milliseconds / 100) / 10) + " seconds to execute";
    }

    VcfCheckUI.el = function (tag, className, text) {
        var node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined && text !== null) node.textContent = text;
        return node;
    }

    // Replaces an element's content with a fixed, compile-time SVG icon constant (never
    // user-controlled data) via DOMParser rather than assigning markup as a string, so
    // no HTML-assignment site anywhere in this file needs auditing for untrusted content.
    VcfCheckUI.setInlineSvg = function (target, svgMarkup) {
        target.textContent = "";
        var parsed = new DOMParser().parseFromString(svgMarkup, "image/svg+xml").documentElement;
        target.appendChild(document.importNode(parsed, true));
    }

    VcfCheckUI.renderTextWithLinks = function (text) {
        // Parse text and convert markdown links [text](url) and https:// URLs into clickable links.
        // Returns a document fragment containing text nodes and anchor elements.
        if (!text) return document.createDocumentFragment();

        var fragment = document.createDocumentFragment();
        var lastIndex = 0;
        var markdownRegex = /\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g;
        var urlRegex = /(https:\/\/[^\s]+)/g;

        // First pass: handle markdown links
        var workingText = text;
        var markdownMatches = [];
        var match;

        while ((match = markdownRegex.exec(text)) !== null) {
            markdownMatches.push({
                start: match.index,
                end: match.index + match[0].length,
                text: match[1],
                url: match[2],
                isMarkdown: true
            });
        }

        // Second pass: handle plain URLs, skipping regions covered by markdown links
        urlRegex.lastIndex = 0;
        while ((match = urlRegex.exec(text)) !== null) {
            // Skip if this URL is part of a markdown link
            var inMarkdown = markdownMatches.some(function(md) {
                return match.index >= md.start && match.index < md.end;
            });
            if (!inMarkdown) {
                markdownMatches.push({
                    start: match.index,
                    end: match.index + match[0].length,
                    text: match[1],
                    url: match[1],
                    isMarkdown: false
                });
            }
        }

        // Sort matches by position
        markdownMatches.sort(function(a, b) { return a.start - b.start; });

        // Build fragment with matches
        lastIndex = 0;
        for (var i = 0; i < markdownMatches.length; i++) {
            var m = markdownMatches[i];

            // Add text before this match
            if (m.start > lastIndex) {
                fragment.appendChild(document.createTextNode(text.substring(lastIndex, m.start)));
            }

            // Add the link
            var link = document.createElement("a");
            link.href = m.url;
            link.target = "_blank";
            link.rel = "noopener noreferrer";
            link.textContent = m.text;
            fragment.appendChild(link);

            lastIndex = m.end;
        }

        // Add remaining text
        if (lastIndex < text.length) {
            fragment.appendChild(document.createTextNode(text.substring(lastIndex)));
        }

        // If no links were found, just return a text node
        if (fragment.childNodes.length === 0) {
            fragment.appendChild(document.createTextNode(text));
        }

        return fragment;
    }

    // A fetch() call rejects with a bare TypeError ("Failed to fetch"/"NetworkError...") when the
    // request never got a response at all - the local VcfCheck server isn't running, crashed,
    // or the browser blocked the request outright. That is a categorically different situation
    // from a target environment being unreachable (Connect-VcfCheckSddcManager's own TCP
    // pre-flight already turns THAT into a clean, specific Error-status check result - see
    // Docs/ARCHITECTURE.md - so it never surfaces as a fetch-level failure). Rewriting the raw
    // TypeError into a message that names the actual failure (this browser tab lost contact with
    // the local server) avoids the misleading impression that the SDDC Manager target itself is
    // what's unreachable.
    VcfCheckUI.toFriendlyFetchError = function (err) {
        if (err instanceof TypeError) {
            return new Error(
                "Could not reach the VcfCheck server at " + window.location.origin +
                ". Check that Start-VcfCheckServer is still running, then reload this page and try again."
            );
        }
        return err;
    }

    VcfCheckUI.fetchJson = function (url, suppressErrorBanner) {
        return fetch(url).then(function (resp) {
            if (!resp.ok) {
                var errorMsg = resp.status + " " + resp.statusText + " from " + url;
                console.error("[VcfCheck API Error]", errorMsg);
                throw new Error(errorMsg);
            }
            return resp.json().catch(function(parseErr) {
                console.error("[VcfCheck JSON Parse Error]", "Failed to parse response from " + url, parseErr);
                throw new Error("Invalid JSON response from " + url);
            });
        }).catch(function (err) {
            var friendlyErr = VcfCheckUI.toFriendlyFetchError(err);
            console.error("[VcfCheck Fetch Error]", friendlyErr.message);
            if (!suppressErrorBanner) {
                VcfCheckUI.showErrorNotification(friendlyErr.message);
            }
            throw friendlyErr;
        });
    }

    VcfCheckUI.postJson = function (url, body, methodOrOptions) {
        var options = {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body)
        };
        // Support both method string (backward compat) and options object
        if (typeof methodOrOptions === "string") {
            options.method = methodOrOptions;
        } else if (typeof methodOrOptions === "object" && methodOrOptions) {
            Object.assign(options, methodOrOptions);
        }
        return fetch(url, options).then(function (resp) {
            return resp.json().then(function (data) {
                if (!resp.ok) throw new Error(data.error || (resp.status + " " + resp.statusText));
                return data;
            });
        }).catch(function (err) { throw VcfCheckUI.toFriendlyFetchError(err); });
    }

    VcfCheckUI.deleteJson = function (url) {
        return fetch(url, { method: "DELETE" }).then(function (resp) {
            return resp.json().then(function (data) {
                if (!resp.ok) throw new Error(data.error || (resp.status + " " + resp.statusText));
                return data;
            });
        }).catch(function (err) { throw VcfCheckUI.toFriendlyFetchError(err); });
    }

    VcfCheckUI.csvEscape = function (value) {
        var str = value === undefined || value === null ? "" : String(value);
        if (/["\r\n,]/.test(str)) {
            return '"' + str.replace(/"/g, '""') + '"';
        }
        return str;
    }

    VcfCheckUI.escapeHtml = function (value) {
        var str = value === undefined || value === null ? "" : String(value);
        return str
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
    }

    // Same convention as the static HTML report's Format-VcfCheckHtmlRowsTable: a Rows cell
    // whose trimmed value case-insensitively matches a known status word gets the matching
    // color class, reusing the --pass/--warning/--fail/--error/--skipped variables.
    VcfCheckUI.ROW_STATUS_CLASSES = {
        PASS: "cell-pass", GREEN: "cell-pass",
        WARNING: "cell-warning", YELLOW: "cell-warning",
        FAIL: "cell-fail", RED: "cell-fail",
        ERROR: "cell-error",
        SKIPPED: "cell-skipped"
    };

    VcfCheckUI.rowStatusClass = function (value) {
        if (value === undefined || value === null) return null;
        return VcfCheckUI.ROW_STATUS_CLASSES[String(value).trim().toUpperCase()] || null;
    }

    // Column headers come from the first row's own key order - every subsequent row reads that
    // same fixed key list (a row missing one of those keys renders an empty cell) rather than
    // shifting columns per row, matching the static HTML report's Format-VcfCheckHtmlRowsTable.
    //
    // rows[0] is expected to be an object - if a row is a bare string instead (confirmed live:
    // a PowerShell ConvertTo-Json -Depth cutoff had stringified nested adapter/device objects to
    // "@{Name=vmnic0; ...}" text), Object.keys() on a string returns one numeric-index key per
    // character ("0","1",...), rendering the string exploded across dozens of single-character
    // columns instead of as text. Guard here so a row that isn't a plain object degrades to a
    // single "Value" column instead.
    VcfCheckUI.rowsTableColumns = function (rows) {
        if (!rows || !rows.length) return [];
        var first = rows[0];
        if (first === null || typeof first !== "object") return ["Value"];
        return Object.keys(first);
    }

    // Companion to VcfCheckUI.rowsTableColumns' "Value" fallback above - a non-object row has no such
    // property, so read the row itself rather than indexing into it.
    VcfCheckUI.rowsTableCellValue = function (row, column) {
        if (row === null || typeof row !== "object") return column === "Value" ? row : undefined;
        return row[column];
    }

    // Mirrors Reporting.ps1's ConvertTo-VcfCheckNormalizedExpiryDateText: display-only
    // normalization of expiration-date/Last Backup Date columns to YYYY-MM-DD, leaving
    // non-date text (e.g. "Never", or a stale-backup cell's trailing "more than 48 hours
    // ago." suffix) and the underlying JSON result untouched.
    VcfCheckUI.normalizeExpiryCellValue = function (column, value) {
        if (typeof value !== "string" || !/Expir.*Date|Next Rotation|Last Backup Date/i.test(column)) return value;
        var parsed = new Date(value);
        if (isNaN(parsed.getTime())) return value;
        var month = String(parsed.getUTCMonth() + 1).padStart(2, "0");
        var day = String(parsed.getUTCDate()).padStart(2, "0");
        return parsed.getUTCFullYear() + "-" + month + "-" + day;
    }

    // The SDDC Manager health-summary API returns one semicolon-joined string per SubTask
    // where the same templated message (e.g. "License mismatch found for ESXi <host> with
    // VCF License...") repeats once per affected host. Group those repeats into one line with
    // a host list so 27 near-identical sentences don't render as a single unreadable paragraph.
    var ERROR_GROUP_HOST_PATTERN = /\b[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}\b/g;

    VcfCheckUI.groupErrorMessages = function (value) {
        if (typeof value !== "string" || value.indexOf(";") === -1) return null;
        var items = value.split(/;\s*/).map(function (s) { return s.trim(); }).filter(Boolean);
        if (items.length <= 1) return null;

        var order = [];
        var groups = {};
        items.forEach(function (item) {
            var hosts = item.match(ERROR_GROUP_HOST_PATTERN) || [];
            var template = hosts.length ? item.replace(ERROR_GROUP_HOST_PATTERN, "{host}") : item;
            if (!groups[template]) {
                groups[template] = { template: template, hosts: [], items: [] };
                order.push(template);
            }
            groups[template].items.push(item);
            hosts.forEach(function (host) {
                if (groups[template].hosts.indexOf(host) === -1) groups[template].hosts.push(host);
            });
        });

        return order.map(function (template) { return groups[template]; });
    }

    // A template only repeats when the same message text recurs for multiple hosts; a
    // one-off message (even one that happens to contain a dotted hostname) is shown verbatim
    // rather than having its host text stripped out into a "(1 host): ..." suffix.
    VcfCheckUI.buildErrorGroupLine = function (group) {
        if (group.items.length <= 1) return group.items[0];
        var prefix = group.template.replace("{host}", "").trim() + " (" + group.items.length + " hosts): ";
        return prefix + group.hosts.join(", ");
    }

    VcfCheckUI.renderErrorCell = function (td, value) {
        var groups = VcfCheckUI.groupErrorMessages(value);
        if (!groups) {
            td.textContent = value === undefined || value === null ? "" : value;
            return;
        }
        var list = document.createElement("ul");
        list.className = "error-message-list";
        groups.forEach(function (group) {
            list.appendChild(VcfCheckUI.el("li", null, VcfCheckUI.buildErrorGroupLine(group)));
        });
        td.appendChild(list);
    }

    VcfCheckUI.renderRowsTable = function (rows) {
        if (!rows || !rows.length) return null;
        var columns = VcfCheckUI.rowsTableColumns(rows);
        var table = document.createElement("table");
        table.className = "rows-table";

        var headRow = document.createElement("tr");
        columns.forEach(function (column) {
            headRow.appendChild(VcfCheckUI.el("th", null, column));
        });
        table.appendChild(headRow);

        rows.forEach(function (row) {
            var tr = document.createElement("tr");
            columns.forEach(function (column) {
                var td = document.createElement("td");
                var value = VcfCheckUI.normalizeExpiryCellValue(column, VcfCheckUI.rowsTableCellValue(row, column));
                var statusClass = VcfCheckUI.rowStatusClass(value);
                if (statusClass) td.className = statusClass;
                if (column === "Error") {
                    VcfCheckUI.renderErrorCell(td, value);
                } else {
                    td.textContent = value === undefined || value === null ? "" : value;
                }
                tr.appendChild(td);
            });
            table.appendChild(tr);
        });

        return table;
    }

    VcfCheckUI.rowsToHtml = function (rows) {
        if (!rows || !rows.length) return "";
        var columns = VcfCheckUI.rowsTableColumns(rows);
        var head = "<tr>" + columns.map(function (column) { return "<th>" + VcfCheckUI.escapeHtml(column) + "</th>"; }).join("") + "</tr>";
        var body = rows.map(function (row) {
            return "<tr>" + columns.map(function (column) {
                var value = VcfCheckUI.normalizeExpiryCellValue(column, VcfCheckUI.rowsTableCellValue(row, column));
                var statusClass = VcfCheckUI.rowStatusClass(value);
                var classAttr = statusClass ? " class=\"" + statusClass + "\"" : "";
                if (column === "Error") {
                    var groups = VcfCheckUI.groupErrorMessages(value);
                    if (groups) {
                        var items = groups.map(function (group) { return "<li>" + VcfCheckUI.escapeHtml(VcfCheckUI.buildErrorGroupLine(group)) + "</li>"; }).join("");
                        return "<td" + classAttr + "><ul class=\"error-message-list\">" + items + "</ul></td>";
                    }
                }
                return "<td" + classAttr + ">" + VcfCheckUI.escapeHtml(value) + "</td>";
            }).join("") + "</tr>";
        }).join("");
        return "<table class=\"rows-table\">" + head + body + "</table>";
    }

    // Matches the static HTML report's Format-VcfCheckHtmlHostDetailCard: one collapsible
    // <details> per host, a key/value summary table for scalar fields, and a rows-table per
    // array-valued field (NetworkAdapters, StorageAdapters, ScsiDevices, etc.).
    VcfCheckUI.hostDetailFieldLabel = function (fieldName) {
        if (fieldName === "CpuCompatibility") {
            return "VCF 9.1 CPU Compatibility";
        }
        return fieldName.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/\bCpu\b/g, "CPU");
    }

    // CpuCompatibility's and CpuDeprecationStatus' raw enum values, and CpuCompatibilityMatchedSeries'/
    // CpuDeprecationMatchedSeries' "no match" case, all need friendlier display text than the raw
    // HostDetails value.
    VcfCheckUI.hostDetailFieldValue = function (fieldName, value) {
        if (value === undefined || value === null || value === "") {
            return (fieldName === "CpuCompatibilityMatchedSeries" || fieldName === "CpuDeprecationMatchedSeries") ? "N/A" : "";
        }
        if (fieldName === "CpuCompatibility" && value === "NotListed") {
            return "Not Supported";
        }
        if (fieldName === "CpuDeprecationStatus" && value === "None") {
            return "Not Deprecated";
        }
        return value;
    }

    VcfCheckUI.splitHostDetailFields = function (host) {
        var summaryFields = [];
        var arrayFields = [];
        Object.keys(host).forEach(function (key) {
            if (key === "HostName" || key === "ClusterName") return;
            if (Array.isArray(host[key])) {
                arrayFields.push([key, host[key]]);
            } else {
                summaryFields.push([key, host[key]]);
            }
        });
        return { summaryFields: summaryFields, arrayFields: arrayFields };
    }

    // The label used when a HostDetails entry has no ClusterName (i.e. HostDetails isn't
    // grouping hosts by vSphere cluster at all - e.g. Aria Operations self-monitoring resources).
    VcfCheckUI.UNGROUPED_CLUSTER_LABEL = "Summary";

    VcfCheckUI.pluralizeUnitLabel = function (label, count) {
        var word = label || "Hosts";
        if (word === "Hosts") {
            return count + " host" + (count === 1 ? "" : "s");
        }
        var singular = word.replace(/s$/i, "");
        return count + " " + (count === 1 ? singular : word);
    }

    VcfCheckUI.clusterHostStatusCounts = function (hosts) {
        var counts = {};
        hosts.forEach(function (host) {
            if (!host.Status) return;
            counts[host.Status] = (counts[host.Status] || 0) + 1;
        });
        return counts;
    }

    VcfCheckUI.groupHostDetailsByCluster = function (hostDetails) {
        var clusters = {};
        var order = [];
        hostDetails.forEach(function (host) {
            var clusterName = host.ClusterName || VcfCheckUI.UNGROUPED_CLUSTER_LABEL;
            if (!clusters[clusterName]) {
                clusters[clusterName] = [];
                order.push(clusterName);
            }
            clusters[clusterName].push(host);
        });
        order.sort(function (a, b) { return a.localeCompare(b); });
        return order.map(function (clusterName) {
            var hosts = clusters[clusterName].slice().sort(function (a, b) {
                return String(a.HostName).localeCompare(String(b.HostName));
            });
            return { clusterName: clusterName, hosts: hosts };
        });
    }

    VcfCheckUI.renderHostDetailCard = function (host, hostKey) {
        var fields = VcfCheckUI.splitHostDetailFields(host);
        var details = document.createElement("details");
        details.className = "host-details";
        details.open = !!VcfCheckUI.expandedHostKeys[hostKey];
        details.addEventListener("toggle", function () {
            if (details.open) {
                VcfCheckUI.expandedHostKeys[hostKey] = true;
            } else {
                delete VcfCheckUI.expandedHostKeys[hostKey];
            }
        });
        var summary = VcfCheckUI.el("summary", null, host.HostName);
        if (host.Status) {
            summary.appendChild(VcfCheckUI.el("span", "badge " + host.Status, host.Status));
        }
        var cpuStatus = VcfCheckUI.hostCpuStatus(host);
        if (cpuStatus) {
            summary.appendChild(VcfCheckUI.el("span", "cpu-status-badge " + cpuStatus, VcfCheckUI.CPU_STATUS_LABEL[cpuStatus]));
        }
        details.appendChild(summary);

        var body = VcfCheckUI.el("div", "host-details-body");
        var summaryTable = document.createElement("table");
        summaryTable.className = "host-detail-summary";
        fields.summaryFields.forEach(function (pair) {
            var tr = document.createElement("tr");
            var td = VcfCheckUI.el("td", null, VcfCheckUI.hostDetailFieldValue(pair[0], pair[1]));
            var statusClass = pair[0] === "Status" ? VcfCheckUI.rowStatusClass(pair[1]) : null;
            if (statusClass) td.className = statusClass;
            tr.appendChild(VcfCheckUI.el("th", null, VcfCheckUI.hostDetailFieldLabel(pair[0])));
            tr.appendChild(td);
            summaryTable.appendChild(tr);
        });
        body.appendChild(summaryTable);

        fields.arrayFields.forEach(function (pair) {
            var subTable = VcfCheckUI.renderRowsTable(pair[1]);
            if (subTable) {
                body.appendChild(VcfCheckUI.el("h4", null, VcfCheckUI.hostDetailFieldLabel(pair[0])));
                body.appendChild(subTable);
            }
        });

        details.appendChild(body);
        return details;
    }

    // Classifies a host's CPU as compatible/deprecated/unsupported so counts and badges can
    // surface CPU issues without parsing the check's comma-delimited Detail sentences.
    VcfCheckUI.CPU_STATUS_LABEL = { compatible: "Compatible CPU", deprecated: "Deprecated CPU", unsupported: "Unsupported CPU" };
    VcfCheckUI.hostCpuStatus = function (host) {
        if (host.CpuCompatibility === "NotListed" || host.CpuDeprecationStatus === "Discontinued") {
            return "unsupported";
        }
        if (host.CpuDeprecationStatus === "Deprecated") {
            return "deprecated";
        }
        if (host.CpuCompatibility === "Compatible") {
            return "compatible";
        }
        return null;
    }

    VcfCheckUI.clusterCpuStatusCounts = function (hosts) {
        var counts = { compatible: 0, deprecated: 0, unsupported: 0 };
        hosts.forEach(function (host) {
            var status = VcfCheckUI.hostCpuStatus(host);
            if (status) counts[status]++;
        });
        return counts;
    }

    VcfCheckUI.cpuStatusBadgesHtml = function (counts) {
        return ["compatible", "deprecated", "unsupported"].map(function (status) {
            if (!counts[status]) return "";
            return "<span class=\"cluster-badge " + status + "\">" + counts[status] + " " + status + "</span>";
        }).join("");
    }

    // A host's non-"Pass" Status (Warning/Fail/Error) rolls up onto its cluster group's summary
    // as a badge, worst status wins, so a warning cluster is spottable without expanding it.
    VcfCheckUI.HOST_STATUS_SEVERITY = { Error: 3, Fail: 2, Warning: 1 };
    VcfCheckUI.clusterWorstHostStatus = function (hosts) {
        var worst = null;
        var worstRank = 0;
        hosts.forEach(function (host) {
            var rank = VcfCheckUI.HOST_STATUS_SEVERITY[host.Status] || 0;
            if (rank > worstRank) {
                worstRank = rank;
                worst = host.Status;
            }
        });
        return worst;
    }

    VcfCheckUI.renderHostSummaryBar = function (hostDetails, label) {
        var summaryBar = VcfCheckUI.el("div", "host-summary-bar");
        summaryBar.appendChild(VcfCheckUI.el("span", "host-summary-label", label));
        var cpuCounts = VcfCheckUI.clusterCpuStatusCounts(hostDetails);
        var hasCpuCounts = cpuCounts.compatible + cpuCounts.deprecated + cpuCounts.unsupported > 0;
        summaryBar.appendChild(VcfCheckUI.el("span", "cluster-badge" + (hasCpuCounts ? " neutral" : ""), VcfCheckUI.pluralizeUnitLabel(label, hostDetails.length)));
        ["compatible", "deprecated", "unsupported"].forEach(function (status) {
            if (!cpuCounts[status]) return;
            summaryBar.appendChild(VcfCheckUI.el("span", "cluster-badge " + status, String(cpuCounts[status]) + " " + status));
        });
        return summaryBar;
    }

    VcfCheckUI.renderHostDetailCards = function (hostDetails, resultKey, hostDetailsLabel) {
        if (!hostDetails || !hostDetails.length) return null;
        var wrap = document.createDocumentFragment();
        wrap.appendChild(VcfCheckUI.renderHostSummaryBar(hostDetails, hostDetailsLabel));

        VcfCheckUI.groupHostDetailsByCluster(hostDetails).forEach(function (group) {
            var clusterKey = resultKey + "|cluster|" + group.clusterName;
            var clusterDetails = document.createElement("details");
            clusterDetails.className = "host-cluster-group";
            clusterDetails.open = !!VcfCheckUI.expandedHostKeys[clusterKey];
            clusterDetails.addEventListener("toggle", function () {
                if (clusterDetails.open) {
                    VcfCheckUI.expandedHostKeys[clusterKey] = true;
                } else {
                    delete VcfCheckUI.expandedHostKeys[clusterKey];
                }
            });
            var summary = VcfCheckUI.el("summary", null, group.clusterName);
            var cpuCounts = VcfCheckUI.clusterCpuStatusCounts(group.hosts);
            var hasCpuCounts = cpuCounts.compatible + cpuCounts.deprecated + cpuCounts.unsupported > 0;
            summary.appendChild(document.createTextNode(" "));
            summary.appendChild(VcfCheckUI.el("span", "cluster-badge" + (hasCpuCounts ? " neutral" : ""), VcfCheckUI.pluralizeUnitLabel(hostDetailsLabel, group.hosts.length)));
            ["compatible", "deprecated", "unsupported"].forEach(function (status) {
                if (!cpuCounts[status]) return;
                summary.appendChild(document.createTextNode(" "));
                summary.appendChild(VcfCheckUI.el("span", "cluster-badge " + status, String(cpuCounts[status]) + " " + status));
            });
            var statusCounts = VcfCheckUI.clusterHostStatusCounts(group.hosts);
            ["Pass", "Warning", "Fail", "Error", "Skipped"].forEach(function (status) {
                if (!statusCounts[status]) return;
                summary.appendChild(document.createTextNode(" "));
                summary.appendChild(VcfCheckUI.el("span", "badge " + status, statusCounts[status] + " " + status));
            });
            clusterDetails.appendChild(summary);

            var clusterBody = VcfCheckUI.el("div", "host-cluster-body");
            group.hosts.forEach(function (host) {
                var hostKey = resultKey + "|" + group.clusterName + "|" + host.HostName;
                clusterBody.appendChild(VcfCheckUI.renderHostDetailCard(host, hostKey));
            });
            clusterDetails.appendChild(clusterBody);
            wrap.appendChild(clusterDetails);
        });

        return wrap;
    }

    VcfCheckUI.hostStatusCountsBadgesHtml = function (counts) {
        return ["Pass", "Warning", "Fail", "Error", "Skipped"].map(function (status) {
            if (!counts[status]) return "";
            return " <span class=\"badge " + status + "\">" + counts[status] + " " + status + "</span>";
        }).join("");
    }

    VcfCheckUI.hostDetailCardToHtml = function (host) {
        var fields = VcfCheckUI.splitHostDetailFields(host);
        var summaryRows = fields.summaryFields.map(function (pair) {
            var statusClass = pair[0] === "Status" ? VcfCheckUI.rowStatusClass(pair[1]) : null;
            var classAttr = statusClass ? " class=\"" + statusClass + "\"" : "";
            return "<tr><th>" + VcfCheckUI.escapeHtml(VcfCheckUI.hostDetailFieldLabel(pair[0])) + "</th><td" + classAttr + ">" + VcfCheckUI.escapeHtml(VcfCheckUI.hostDetailFieldValue(pair[0], pair[1])) + "</td></tr>";
        }).join("");
        var arrayHtml = fields.arrayFields.map(function (pair) {
            var subTable = VcfCheckUI.rowsToHtml(pair[1]);
            return subTable ? "<h4>" + VcfCheckUI.escapeHtml(VcfCheckUI.hostDetailFieldLabel(pair[0])) + "</h4>" + subTable : "";
        }).join("");
        var statusBadgeHtml = host.Status ? "<span class=\"badge " + VcfCheckUI.escapeHtml(host.Status) + "\">" + VcfCheckUI.escapeHtml(host.Status) + "</span>" : "";
        var cpuStatus = VcfCheckUI.hostCpuStatus(host);
        var cpuBadgeHtml = cpuStatus ? "<span class=\"cpu-status-badge " + cpuStatus + "\">" + VcfCheckUI.escapeHtml(VcfCheckUI.CPU_STATUS_LABEL[cpuStatus]) + "</span>" : "";
        return "<details class=\"host-details\"><summary>" + VcfCheckUI.escapeHtml(host.HostName) + statusBadgeHtml + cpuBadgeHtml + "</summary>" +
            "<div class=\"host-details-body\"><table class=\"host-detail-summary\">" + summaryRows + "</table>" + arrayHtml + "</div></details>";
    }

    VcfCheckUI.hostDetailsToHtml = function (hostDetails, hostDetailsLabel) {
        if (!hostDetails || !hostDetails.length) return "";
        return VcfCheckUI.groupHostDetailsByCluster(hostDetails).map(function (group) {
            var hostCountLabel = VcfCheckUI.pluralizeUnitLabel(hostDetailsLabel, group.hosts.length);
            var hostsHtml = group.hosts.map(VcfCheckUI.hostDetailCardToHtml).join("");
            var cpuCounts = VcfCheckUI.clusterCpuStatusCounts(group.hosts);
            var hasCpuCounts = cpuCounts.compatible + cpuCounts.deprecated + cpuCounts.unsupported > 0;
            var totalBadgeHtml = "<span class=\"cluster-badge" + (hasCpuCounts ? " neutral" : "") + "\">" + VcfCheckUI.escapeHtml(hostCountLabel) + "</span>";
            var cpuBadgesHtml = VcfCheckUI.cpuStatusBadgesHtml(cpuCounts);
            var statusBadgeHtml = VcfCheckUI.hostStatusCountsBadgesHtml(VcfCheckUI.clusterHostStatusCounts(group.hosts));
            return "<details class=\"host-cluster-group\"><summary>" + VcfCheckUI.escapeHtml(group.clusterName) +
                " " + totalBadgeHtml + cpuBadgesHtml + statusBadgeHtml + "</summary>" +
                "<div class=\"host-cluster-body\">" + hostsHtml + "</div></details>";
        }).join("");
    }


})();
