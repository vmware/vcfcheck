"use strict";

(function () {
    // ---- Upgrade Resource Estimator: shared state, wizard navigation, totals/breakdown, refine step, save/export ----

    VcfCheckUI._sizing.sizingComponentsByKey = {};
    VcfCheckUI._sizing.sizingEnvironmentEvaluated = false;
    VcfCheckUI._sizing.sizingReferenceData = {};
    VcfCheckUI._sizing.sizingDetectedData = {};
    VcfCheckUI._sizing.sizingSelections = {};
    VcfCheckUI._sizing.SIZING_STEPS = ["connect", "vcenter", "runtime", "mgmtservices", "fleet", "more", "refine"];
    VcfCheckUI._sizing.SIZING_STEP_LABELS = ["Connect", "vCenter", "Services Runtime", "VCF Management Services", "VCF Fleet Components", "More Components", "Refinement"];
    VcfCheckUI._sizing.sizingStepIndex = 0;
    VcfCheckUI._sizing.sizingMaxStepReached = 0;
    VcfCheckUI._sizing.sizingCpuOvercommitRatio = 1;
    VcfCheckUI._sizing.sizingMemOvercommitRatio = 1;
    VcfCheckUI._sizing.sizingConcurrentVCenters = 1;
    VcfCheckUI._sizing.sizingEnvironmentId = "";
    VcfCheckUI._sizing.sizingEstimateDirty = false;

    VcfCheckUI._sizing.renderSizingStepper = function () {
        var stepperEl = document.getElementById("sizingStepper");
        stepperEl.innerHTML = "";
        VcfCheckUI._sizing.SIZING_STEPS.forEach(function (step, i) {
            var done = i < VcfCheckUI._sizing.sizingStepIndex;
            var active = i === VcfCheckUI._sizing.sizingStepIndex;
            var reachable = i <= VcfCheckUI._sizing.sizingMaxStepReached && (i === 0 || VcfCheckUI._sizing.sizingEnvironmentEvaluated);
            var dotCls = done ? "s-dot done" : active ? "s-dot active" : "s-dot";
            if (reachable && !active) {
                dotCls += " reachable";
            }
            var lblCls = active ? "s-label active" : "s-label";

            var stepEl = document.createElement("div");
            stepEl.className = "s-step";
            stepEl.dataset.stepIndex = String(i);

            var dot = document.createElement("div");
            dot.className = dotCls;
            dot.textContent = done ? "✓" : String(i + 1);
            stepEl.appendChild(dot);

            var lbl = document.createElement("div");
            lbl.className = lblCls;
            lbl.textContent = VcfCheckUI._sizing.SIZING_STEP_LABELS[i];
            stepEl.appendChild(lbl);

            stepperEl.appendChild(stepEl);

            if (i < VcfCheckUI._sizing.SIZING_STEPS.length - 1) {
                var connector = document.createElement("div");
                connector.className = "s-connector";
                var line = document.createElement("div");
                line.className = "s-line" + (done ? " done" : "");
                connector.appendChild(line);
                stepperEl.appendChild(connector);
            }
        });
        stepperEl.querySelectorAll(".s-dot.reachable").forEach(function (dot) {
            dot.addEventListener("click", function () {
                var step = dot.closest(".s-step");
                var targetIndex = parseInt(step.dataset.stepIndex, 10);
                VcfCheckUI._sizing.showSizingStep(targetIndex);
            });
        });
    }

    VcfCheckUI._sizing.resetSizingWizard = function () {
        VcfCheckUI._sizing.sizingEnvironmentEvaluated = false;
        VcfCheckUI._sizing.sizingReferenceData = {};
        VcfCheckUI._sizing.sizingDetectedData = {};
        VcfCheckUI._sizing.sizingSelections = {};
        VcfCheckUI._sizing.sizingStepIndex = 0;
        VcfCheckUI._sizing.sizingMaxStepReached = 0;
        VcfCheckUI._sizing.sizingCpuOvercommitRatio = 1;
        VcfCheckUI._sizing.sizingMemOvercommitRatio = 1;
        VcfCheckUI._sizing.sizingConcurrentVCenters = 1;
        VcfCheckUI._sizing.sizingEnvironmentId = "";
        VcfCheckUI._sizing.sizingEstimateDirty = false;
        document.getElementById("sizing-detect-environment").selectedIndex = 0;
        var passwordField = document.getElementById("sizing-detect-password");
        if (passwordField) {
            passwordField.value = "";
        }
        document.querySelectorAll(".sizing-step-panel select").forEach(function (select) {
            if (select.id === "sizing-detect-environment") {
                return;
            }
            var defaultOption = Array.prototype.find.call(select.options, function (opt) { return opt.defaultSelected; });
            select.selectedIndex = defaultOption ? defaultOption.index : 0;
        });
        document.querySelectorAll(".sizing-step-panel input[type=number]").forEach(function (input) {
            input.value = input.defaultValue;
        });
        document.getElementById("sizing-detect-button").disabled = false;
        document.getElementById("sizing-detect-error").textContent = "";
        document.getElementById("sizing-detect-status").classList.add("hidden");
        VcfCheckUI._sizing.updateSizingGateState();
        VcfCheckUI._sizing.showSizingStep(0);
    }

    VcfCheckUI._sizing.showSizingStep = function (index) {
        if (index > 0 && !VcfCheckUI._sizing.sizingEnvironmentEvaluated) {
            // Scanning an Environment is required before anything past Connect.
            index = 0;
        }
        VcfCheckUI._sizing.sizingStepIndex = index;
        VcfCheckUI._sizing.sizingMaxStepReached = Math.max(VcfCheckUI._sizing.sizingMaxStepReached, index);
        document.querySelectorAll(".sizing-step-panel").forEach(function (panel, i) {
            panel.classList.toggle("active", i === index);
        });
        VcfCheckUI._sizing.renderSizingStepper();
        document.getElementById("sizingSidebar").classList.toggle("hidden", index === 0);
        document.getElementById("sizingBackButton").classList.toggle("hidden", index === 0);
        document.getElementById("sizingNextButton").classList.toggle("hidden", index === VcfCheckUI._sizing.SIZING_STEPS.length - 1);
        document.getElementById("sizingNextButton").disabled = !VcfCheckUI._sizing.sizingEnvironmentEvaluated;
        document.getElementById("sizingSaveButton").classList.toggle("hidden", index !== VcfCheckUI._sizing.SIZING_STEPS.length - 1);
        document.getElementById("sizingDownloadButton").classList.toggle("hidden", index !== VcfCheckUI._sizing.SIZING_STEPS.length - 1);
        if (index === 1) {
            VcfCheckUI._sizing.renderSizingVCenterStep();
        } else if (index === 2) {
            VcfCheckUI._sizing.renderSizingRuntimeStep();
        } else if (index === 3) {
            VcfCheckUI._sizing.renderSizingMgmtServicesStep();
        } else if (index === 4) {
            VcfCheckUI._sizing.renderSizingFleetStep();
        } else if (index === 5) {
            VcfCheckUI._sizing.renderSizingPlatformServicesStep();
            VcfCheckUI._sizing.loadSizingOptions();
        } else if (index === 6) {
            VcfCheckUI._sizing.renderSizingRefineStep();
        }
    }

    // True only on the Refinement step (the final step, where Save lives) with changes made
    // since the last successful save - everywhere else, leaving is non-destructive.
    VcfCheckUI._sizing.sizingHasUnsavedEstimate = function () {
        return VcfCheckUI._sizing.sizingStepIndex === VcfCheckUI._sizing.SIZING_STEPS.length - 1 && VcfCheckUI._sizing.sizingEstimateDirty && Object.keys(VcfCheckUI._sizing.sizingSelections).length > 0;
    }

    VcfCheckUI._sizing.humanizeSizingLabel = function (text) {
        return text.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, function (c) { return c.toUpperCase(); });
    }

    // VcfCheckUI._sizing.humanizeSizingLabel() only splits words at a lowercase->uppercase boundary, so raw select
    // values that are already all-lowercase (e.g. "firstinstance", "highavailability") pass
    // through with no space inserted. These two values have no camelCase boundary to exploit,
    // so they need an explicit lookup instead.
    VcfCheckUI._sizing.SIZING_INSTANCE_LABELS = { firstinstance: "First Instance", additionalinstance: "Additional Instance" };
    VcfCheckUI._sizing.SIZING_AVAILABILITY_LABELS = { simple: "Simple", highavailability: "High Availability" };

    VcfCheckUI._sizing.humanizeSizingInstanceLabel = function (instance) {
        return VcfCheckUI._sizing.SIZING_INSTANCE_LABELS[instance] || VcfCheckUI._sizing.humanizeSizingLabel(instance);
    }

    VcfCheckUI._sizing.humanizeSizingAvailabilityLabel = function (availability) {
        return VcfCheckUI._sizing.SIZING_AVAILABILITY_LABELS[availability] || VcfCheckUI._sizing.humanizeSizingLabel(availability);
    }

    VcfCheckUI._sizing.setSizingSelection = function (componentKey, displayName, vCpu, memoryGb, storageGb, isDelta, peakVCpu, peakMemoryGb, peakStorageGb, configSummary, services) {
        VcfCheckUI._sizing.sizingSelections[componentKey] = {
            displayName: displayName,
            vCpu: vCpu,
            memoryGb: memoryGb,
            storageGb: storageGb,
            isDelta: !!isDelta,
            // Human-readable recipe of the wizard selections that produced this row (e.g.
            // "Small size, Standard storage") so the saved report can be used to reproduce the
            // configuration without re-deriving it from raw vCPU/RAM/disk numbers.
            configSummary: configSummary || "",
            // For a "net change" row, the old appliance is still running (and already accounted
            // for in the environment's current capacity) while the new one is deployed alongside
            // it, so the temporary swing capacity needed is the new appliance's full footprint,
            // not the smaller net change. Non-delta rows have no swing period, so peak == steady state.
            peakVCpu: isDelta ? peakVCpu : vCpu,
            peakMemoryGb: isDelta ? peakMemoryGb : memoryGb,
            peakStorageGb: isDelta ? peakStorageGb : storageGb,
            // Services that run inside this component's footprint rather than as their own
            // appliance (e.g. Log Management inside the Services Runtime Worker Nodes pool) -
            // already counted in the vCpu/memoryGb/storageGb above, listed here only so the
            // report can surface them in its own "Service Configuration" section.
            services: services || []
        };
        VcfCheckUI._sizing.sizingEstimateDirty = true;
        VcfCheckUI._sizing.updateSizingRunningTotal();
    }

    VcfCheckUI._sizing.formatSizingNumber = function (value, isDelta) {
        if (isDelta && value > 0) {
            return "+" + value;
        }
        return String(value);
    }

    VcfCheckUI._sizing.isSizingVCenterComponentKey = function (key) {
        return key === "managementDomainVcenter" || key.indexOf("workloadDomainVcenter-") === 0;
    }

    // Shared by VcfCheckUI._sizing.updateSizingRunningTotal() (rendering) and VcfCheckUI._sizing.saveSizingEstimate() (the JSON file
    // written on Save), so the two never drift apart.
    VcfCheckUI._sizing.computeSizingTotals = function () {
        var totalVCpu = 0, totalMemoryGb = 0, totalStorageGb = 0;
        var nonVCenterPeakVCpu = 0, nonVCenterPeakMemoryGb = 0, nonVCenterPeakStorageGb = 0;
        var vCenterPeaks = [];
        var anyDelta = false;
        var rows = Object.keys(VcfCheckUI._sizing.sizingSelections).map(function (key) {
            var s = VcfCheckUI._sizing.sizingSelections[key];
            totalVCpu += s.vCpu;
            totalMemoryGb += s.memoryGb;
            totalStorageGb += s.storageGb;
            if (s.isDelta && VcfCheckUI._sizing.isSizingVCenterComponentKey(key)) {
                vCenterPeaks.push({ displayName: s.displayName, peakVCpu: s.peakVCpu, peakMemoryGb: s.peakMemoryGb, peakStorageGb: s.peakStorageGb });
            } else {
                nonVCenterPeakVCpu += s.peakVCpu;
                nonVCenterPeakMemoryGb += s.peakMemoryGb;
                nonVCenterPeakStorageGb += s.peakStorageGb;
            }
            anyDelta = anyDelta || s.isDelta;
            return { componentKey: key, displayName: s.displayName, vCpu: s.vCpu, memoryGb: s.memoryGb, storageGb: s.storageGb, isDelta: s.isDelta, configSummary: s.configSummary, services: s.services || [] };
        });

        // Flattened across all components, so the report can render a single "Service
        // Configuration" section for services that don't have a 1:1 relationship with a
        // component (e.g. Log Management running inside the Worker Nodes pool) without the
        // reader having to infer that from the component rows' vCPU/RAM/disk totals.
        var services = [];
        rows.forEach(function (row) {
            row.services.forEach(function (service) {
                services.push({
                    name: service.name,
                    hostComponent: row.displayName,
                    vCpu: service.vCpu,
                    memoryGb: service.memoryGb,
                    storageGb: service.storageGb,
                    configSummary: service.configSummary || ""
                });
            });
        });

        // vCenter swing space only needs to cover as many vCenters as are upgraded at once,
        // not every vCenter's peak added together - the rest queue behind the concurrency limit.
        // Worst case is the N largest appliances running concurrently, so sum the top
        // `concurrentVCenters` peaks per metric rather than averaging across all of them.
        var concurrentVCenters = Math.min(VcfCheckUI._sizing.sizingConcurrentVCenters, vCenterPeaks.length) || vCenterPeaks.length;
        var sumTopPeaks = function (metric) {
            return vCenterPeaks.map(function (p) { return p[metric]; })
                .sort(function (a, b) { return b - a; })
                .slice(0, concurrentVCenters)
                .reduce(function (sum, v) { return sum + v; }, 0);
        };
        var vCenterPeakShareVCpu = sumTopPeaks("peakVCpu");
        var vCenterPeakShareMemoryGb = sumTopPeaks("peakMemoryGb");
        var vCenterPeakShareStorageGb = sumTopPeaks("peakStorageGb");
        return {
            rows: rows,
            services: services,
            anyDelta: anyDelta,
            totalVCpu: totalVCpu,
            totalMemoryGb: totalMemoryGb,
            totalStorageGb: totalStorageGb,
            concurrentVCenters: concurrentVCenters,
            vCenterCount: vCenterPeaks.length,
            vCenterPeaks: vCenterPeaks,
            peakTotalVCpu: nonVCenterPeakVCpu + vCenterPeakShareVCpu,
            peakTotalMemoryGb: nonVCenterPeakMemoryGb + vCenterPeakShareMemoryGb,
            peakTotalStorageGb: nonVCenterPeakStorageGb + vCenterPeakShareStorageGb,
            physicalVCpu: totalVCpu / VcfCheckUI._sizing.sizingCpuOvercommitRatio,
            physicalMemoryGb: totalMemoryGb / VcfCheckUI._sizing.sizingMemOvercommitRatio
        };
    }

    VcfCheckUI._sizing.buildSizingRowsTable = function (headers, rows) {
        var table = document.createElement("table");
        table.className = "rows-table";
        var thead = document.createElement("thead");
        var headRow = document.createElement("tr");
        headers.forEach(function (headerText) {
            var th = document.createElement("th");
            th.textContent = headerText;
            headRow.appendChild(th);
        });
        thead.appendChild(headRow);
        table.appendChild(thead);
        var tbody = document.createElement("tbody");
        rows.forEach(function (cells) {
            var tr = document.createElement("tr");
            cells.forEach(function (cellValue) {
                var td = document.createElement("td");
                td.textContent = cellValue;
                tr.appendChild(td);
            });
            tbody.appendChild(tr);
        });
        table.appendChild(tbody);
        return table;
    }

    VcfCheckUI._sizing.renderSizingBreakdownBox = function (box, rows, headers, includedNoteText) {
        box.innerHTML = "";
        if (rows.length === 0) {
            return;
        }
        if (includedNoteText) {
            var note = document.createElement("p");
            note.className = "chk-count included-in-pool-note";
            note.textContent = includedNoteText;
            box.appendChild(note);
        }
        box.appendChild(VcfCheckUI._sizing.buildSizingRowsTable(headers, rows));
    }

    VcfCheckUI._sizing.sizingRowCell = function (text, opts) {
        var td = document.createElement("td");
        if (opts && opts.numeric) {
            td.className = "num";
        }
        if (opts && opts.title) {
            td.title = opts.title;
        }
        td.textContent = text;
        return td;
    }

    VcfCheckUI._sizing.sizingRow = function (cells, rowClass) {
        var tr = document.createElement("tr");
        if (rowClass) {
            tr.className = rowClass;
        }
        cells.forEach(function (cell) {
            tr.appendChild(cell);
        });
        return tr;
    }

    VcfCheckUI._sizing.updateSizingRunningTotal = function () {
        var box = document.getElementById("sizing-running-total");
        var noteBox = document.getElementById("sizing-running-total-note");
        var totals = VcfCheckUI._sizing.computeSizingTotals();

        box.innerHTML = "";
        totals.rows.forEach(function (row) {
            var label = row.displayName + (row.isDelta ? " (net change)" : "");
            box.appendChild(VcfCheckUI._sizing.sizingRow([
                VcfCheckUI._sizing.sizingRowCell(label, { title: row.configSummary || "" }),
                VcfCheckUI._sizing.sizingRowCell(VcfCheckUI._sizing.formatSizingNumber(row.vCpu, row.isDelta), { numeric: true }),
                VcfCheckUI._sizing.sizingRowCell(VcfCheckUI._sizing.formatSizingNumber(row.memoryGb, row.isDelta), { numeric: true }),
                VcfCheckUI._sizing.sizingRowCell(VcfCheckUI._sizing.formatSizingNumber(row.storageGb, row.isDelta), { numeric: true })
            ]));
        });
        box.appendChild(VcfCheckUI._sizing.sizingRow([
            VcfCheckUI._sizing.sizingRowCell("Total (steady state)"),
            VcfCheckUI._sizing.sizingRowCell(VcfCheckUI._sizing.formatSizingNumber(totals.totalVCpu, totals.anyDelta), { numeric: true }),
            VcfCheckUI._sizing.sizingRowCell(VcfCheckUI._sizing.formatSizingNumber(totals.totalMemoryGb, totals.anyDelta), { numeric: true }),
            VcfCheckUI._sizing.sizingRowCell(VcfCheckUI._sizing.formatSizingNumber(totals.totalStorageGb, totals.anyDelta), { numeric: true })
        ], "sizing-totals-row"));
        if (totals.anyDelta) {
            totals.vCenterPeaks.forEach(function (peak) {
                box.appendChild(VcfCheckUI._sizing.sizingRow([
                    VcfCheckUI._sizing.sizingRowCell(peak.displayName + " peak swing capacity (old + new side by side)"),
                    VcfCheckUI._sizing.sizingRowCell(String(Math.round(peak.peakVCpu)), { numeric: true }),
                    VcfCheckUI._sizing.sizingRowCell(String(Math.round(peak.peakMemoryGb)), { numeric: true }),
                    VcfCheckUI._sizing.sizingRowCell(String(Math.round(peak.peakStorageGb)), { numeric: true })
                ], "sizing-peak-row"));
            });
            var peakLabel = totals.vCenterCount > 0 && totals.concurrentVCenters === totals.vCenterCount ?
                "Total peak swing capacity (upgrading all " + totals.vCenterCount + " vCenter" + (totals.vCenterCount === 1 ? "" : "s") + " at once)" :
                "Total peak swing capacity (upgrading " + totals.concurrentVCenters + " of " + totals.vCenterCount + " vCenters at once - see Refinement step)";
            box.appendChild(VcfCheckUI._sizing.sizingRow([
                VcfCheckUI._sizing.sizingRowCell(peakLabel),
                VcfCheckUI._sizing.sizingRowCell(String(Math.round(totals.peakTotalVCpu)), { numeric: true }),
                VcfCheckUI._sizing.sizingRowCell(String(Math.round(totals.peakTotalMemoryGb)), { numeric: true }),
                VcfCheckUI._sizing.sizingRowCell(String(Math.round(totals.peakTotalStorageGb)), { numeric: true })
            ], "sizing-totals-row sizing-peak-row"));
        }
        // Omitted at the 1:1 default since it would just duplicate the steady-state row above;
        // shown only once overcommitment makes the physical footprint genuinely different.
        if (VcfCheckUI._sizing.sizingCpuOvercommitRatio !== 1 || VcfCheckUI._sizing.sizingMemOvercommitRatio !== 1) {
            box.appendChild(VcfCheckUI._sizing.sizingRow([
                VcfCheckUI._sizing.sizingRowCell("Physical resources needed (at " + VcfCheckUI._sizing.sizingCpuOvercommitRatio + ":1 CPU, " + VcfCheckUI._sizing.sizingMemOvercommitRatio + ":1 memory)"),
                VcfCheckUI._sizing.sizingRowCell(String(Math.ceil(totals.physicalVCpu)), { numeric: true }),
                VcfCheckUI._sizing.sizingRowCell(String(Math.ceil(totals.physicalMemoryGb)), { numeric: true }),
                VcfCheckUI._sizing.sizingRowCell(VcfCheckUI._sizing.formatSizingNumber(totals.totalStorageGb, totals.anyDelta), { numeric: true })
            ], "sizing-totals-row sizing-peak-row"));
        }
        if (noteBox) {
            var notes = [];
            if (totals.anyDelta) {
                notes.push("\"Net change\" rows are the delta versus what's running today. \"Peak swing capacity\" is the extra vCPU/RAM/disk needed while old and new appliances run side by side; the total scales to how many vCenters you upgrade at once (set on the Refinement step).");
            }
            notes.push("\"Physical resources needed\" applies the overcommitment ratios from the Refinement step (default 1:1) to estimate physical host CPU cores and RAM required.");
            noteBox.textContent = notes.join(" ");
        }
        VcfCheckUI._sizing.renderSizingServiceConfigTable(totals.services);
    }

    VcfCheckUI._sizing.renderSizingServiceConfigTable = function (services) {
        var box = document.getElementById("sizing-running-total-services");
        if (!box) {
            return;
        }
        var section = box.closest(".sizing-service-config-section");
        if (section) {
            section.classList.toggle("hidden", services.length === 0);
        }
        box.innerHTML = "";
        services.forEach(function (service) {
            box.appendChild(VcfCheckUI._sizing.sizingRow([
                VcfCheckUI._sizing.sizingRowCell(service.name),
                VcfCheckUI._sizing.sizingRowCell(service.hostComponent),
                VcfCheckUI._sizing.sizingRowCell(service.vCpu, { numeric: true }),
                VcfCheckUI._sizing.sizingRowCell(service.memoryGb, { numeric: true }),
                VcfCheckUI._sizing.sizingRowCell(service.storageGb, { numeric: true })
            ]));
        });
    }

    // Holds the most recently saved estimate's payload so exportZip() can bundle the same JSON
    // that was written server-side into Findings/<slug>/, without a second round trip.
    VcfCheckUI.lastSavedSizingEstimate = null;

    VcfCheckUI._sizing.buildSizingEstimatePayload = function () {
        var totals = VcfCheckUI._sizing.computeSizingTotals();
        return {
            savedAt: new Date().toISOString(),
            environmentId: VcfCheckUI._sizing.sizingEnvironmentId,
            cpuOvercommitRatio: VcfCheckUI._sizing.sizingCpuOvercommitRatio,
            memOvercommitRatio: VcfCheckUI._sizing.sizingMemOvercommitRatio,
            concurrentVCenters: VcfCheckUI._sizing.sizingConcurrentVCenters,
            components: totals.rows,
            services: totals.services,
            totals: {
                vCpu: totals.totalVCpu,
                memoryGb: totals.totalMemoryGb,
                storageGb: totals.totalStorageGb,
                peakVCpu: totals.peakTotalVCpu,
                peakMemoryGb: totals.peakTotalMemoryGb,
                peakStorageGb: totals.peakTotalStorageGb,
                physicalVCpu: totals.physicalVCpu,
                physicalMemoryGb: totals.physicalMemoryGb
            }
        };
    }

    VcfCheckUI._sizing.saveSizingEstimate = function () {
        var btn = document.getElementById("sizingSaveButton");
        var payload = VcfCheckUI._sizing.buildSizingEstimatePayload();
        btn.disabled = true;
        var originalLabel = btn.textContent;
        btn.textContent = "Saving…";
        VcfCheckUI.postJson("/api/sizing/save-estimate", { environmentId: VcfCheckUI._sizing.sizingEnvironmentId, estimate: payload }).then(function () {
            VcfCheckUI.lastSavedSizingEstimate = payload;
            VcfCheckUI._sizing.sizingEstimateDirty = false;
            document.getElementById("sizing-card").classList.add("collapsed");
        }).catch(function (err) {
            VcfCheckUI.showErrorNotification(err.message || "Failed to save the resource estimate.");
            btn.textContent = "✗ Failed";
        }).finally(function () {
            btn.disabled = false;
            setTimeout(function () { btn.textContent = originalLabel; }, 3000);
        });
    }

    VcfCheckUI._sizing.buildSizingEstimateHtmlDocument = function () {
        var payload = VcfCheckUI._sizing.buildSizingEstimatePayload();
        var totalsTable = document.querySelector("#sizingSidebar .sizing-totals-table").outerHTML;
        var serviceSection = document.querySelector(".sizing-service-config-section");
        var serviceTable = (serviceSection && !serviceSection.classList.contains("hidden")) ? serviceSection.outerHTML : "";
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Management Resources Upgrade Estimate</title>" +
            "<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;} table{border-collapse:collapse;width:100%;} " +
            "th,td{padding:6px 10px;text-align:right;border-bottom:1px solid #ddd;} th:first-child,td:first-child{text-align:left;}</style></head><body>" +
            "<h2>Management Resources Upgrade Estimate</h2>" +
            "<p>Environment: " + VcfCheckUI.escapeHtml(VcfCheckUI._sizing.sizingEnvironmentId || "") + "<br>Saved at: " + VcfCheckUI.escapeHtml(payload.savedAt) + "</p>" +
            totalsTable + serviceTable + "</body></html>";
    }

    VcfCheckUI._sizing.downloadSizingEstimateHtml = function () {
        var blob = new Blob([VcfCheckUI._sizing.buildSizingEstimateHtmlDocument()], { type: "text/html" });
        var url = URL.createObjectURL(blob);
        var link = document.createElement("a");
        link.href = url;
        link.download = "resource-estimation-" + (VcfCheckUI._sizing.sizingEnvironmentId || "estimate") + ".html";
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(url);
    }

    document.getElementById("sizingSaveButton").addEventListener("click", VcfCheckUI._sizing.saveSizingEstimate);
    document.getElementById("sizingDownloadButton").addEventListener("click", VcfCheckUI._sizing.downloadSizingEstimateHtml);

    VcfCheckUI._sizing.renderSizingRefineStep = function () {
        var cpuInput = document.getElementById("sizing-refine-cpu-ratio");
        var memInput = document.getElementById("sizing-refine-mem-ratio");
        var vcenterInput = document.getElementById("sizing-refine-concurrent-vcenters");
        var hintBox = document.getElementById("sizing-refine-hint");
        var totalVCenters = VcfCheckUI._sizing.getSizingVCenterEntries().length;
        var vcenterOptionCount = Math.max(totalVCenters, 1);
        if (parseInt(vcenterInput.dataset.optionCount, 10) !== vcenterOptionCount) {
            vcenterInput.dataset.optionCount = String(vcenterOptionCount);
            vcenterInput.innerHTML = "";
            for (var vcenterOptionIndex = 1; vcenterOptionIndex <= vcenterOptionCount; vcenterOptionIndex++) {
                var vcenterOption = document.createElement("option");
                vcenterOption.value = String(vcenterOptionIndex);
                vcenterOption.textContent = String(vcenterOptionIndex);
                vcenterInput.appendChild(vcenterOption);
            }
        }
        if (VcfCheckUI._sizing.sizingConcurrentVCenters > vcenterOptionCount) {
            VcfCheckUI._sizing.sizingConcurrentVCenters = vcenterOptionCount;
        }
        vcenterInput.value = String(VcfCheckUI._sizing.sizingConcurrentVCenters);
        hintBox.textContent = totalVCenters + " vCenter(s) detected. Overcommitment ratios default to 1:1 (no overcommit) - set them to match your cluster's actual CPU/memory overcommitment (see the linked guidance above) to see the physical host resources required.";
        if (!cpuInput.dataset.wired) {
            cpuInput.dataset.wired = "1";
            memInput.dataset.wired = "1";
            vcenterInput.dataset.wired = "1";
            cpuInput.addEventListener("input", function () {
                VcfCheckUI._sizing.sizingCpuOvercommitRatio = parseFloat(cpuInput.value) || 1;
                VcfCheckUI._sizing.sizingEstimateDirty = true;
                VcfCheckUI._sizing.updateSizingRunningTotal();
            });
            memInput.addEventListener("input", function () {
                VcfCheckUI._sizing.sizingMemOvercommitRatio = parseFloat(memInput.value) || 1;
                VcfCheckUI._sizing.sizingEstimateDirty = true;
                VcfCheckUI._sizing.updateSizingRunningTotal();
            });
            vcenterInput.addEventListener("change", function () {
                VcfCheckUI._sizing.sizingConcurrentVCenters = parseInt(vcenterInput.value, 10) || 1;
                VcfCheckUI._sizing.sizingEstimateDirty = true;
                VcfCheckUI._sizing.updateSizingRunningTotal();
            });
        }
    }


})();
