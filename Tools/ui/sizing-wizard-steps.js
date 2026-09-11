"use strict";

(function () {
    // ---- Upgrade Resource Estimator: vCenter, runtime, management services, and fleet component steps ----

    VcfCheckUI._sizing.getSizingVCenterEntries = function () {
        var managementSnapshot = VcfCheckUI._sizing.sizingDetectedData.managementDomainVCenter || null;
        var managementDisplayName = "Management Domain vCenter" +
            (managementSnapshot && managementSnapshot.domainName ? " (" + managementSnapshot.domainName + ")" : "");
        var entries = [{
            componentKey: "managementDomainVcenter",
            displayName: managementDisplayName,
            snapshot: managementSnapshot
        }];
        (VcfCheckUI._sizing.sizingDetectedData.workloadDomainVCenters || []).forEach(function (snapshot, i) {
            entries.push({
                componentKey: "workloadDomainVcenter-" + i,
                displayName: "Workload Domain vCenter (" + snapshot.domainName + ")",
                snapshot: snapshot
            });
        });
        return entries;
    }

    VcfCheckUI._sizing.SIZING_VCENTER_STORAGE_PRESETS = ["Default", "LStorage", "XLStorage"];

    VcfCheckUI._sizing.collapsedSizingDomains = {}; // componentKey -> false, for a domain the user expanded (default collapsed)

    VcfCheckUI._sizing.humanizeSizingStoragePreset = function (presetSuffix) {
        return { Default: "Standard Storage", LStorage: "Large Storage", XLStorage: "Extra Large Storage" }[presetSuffix] || presetSuffix;
    }

    VcfCheckUI._sizing.renderSizingVCenterStep = function () {
        var listBox = document.getElementById("sizing-vcenter-list");
        var vcenterRef = VcfCheckUI._sizing.sizingReferenceData.vcenter || {};
        var sizeKeys = Object.keys(vcenterRef.cpuCores || {});
        listBox.innerHTML = "";
        VcfCheckUI._sizing.syncConcurrentVCenterSelects();

        VcfCheckUI._sizing.getSizingVCenterEntries().forEach(function (entry) {
            var snapshot = entry.snapshot;
            var group = VcfCheckUI.el("div", "chk-area-group sizing-vcenter-block");
            if (VcfCheckUI._sizing.collapsedSizingDomains[entry.componentKey] !== false) {
                group.classList.add("collapsed");
            }

            var header = VcfCheckUI.el("div", "chk-area-header");
            header.appendChild(VcfCheckUI.el("span", "chk-area-toggle", "▼"));
            header.appendChild(VcfCheckUI.el("span", null, entry.displayName));
            header.addEventListener("click", function () {
                var collapsed = group.classList.toggle("collapsed");
                VcfCheckUI._sizing.collapsedSizingDomains[entry.componentKey] = !collapsed;
            });
            group.appendChild(header);

            var block = VcfCheckUI.el("div", "chk-area-items");
            group.appendChild(block);

            var summaryBox = document.createElement("div");
            summaryBox.style.marginBottom = "10px";
            if (snapshot) {
                var summaryLis = [];

                var detectedLi = document.createElement("li");
                detectedLi.appendChild(document.createTextNode("Detected "));
                var detectedStrong = document.createElement("strong");
                detectedStrong.textContent = snapshot.vcenterFqdn;
                detectedLi.appendChild(detectedStrong);
                detectedLi.appendChild(document.createTextNode("."));
                summaryLis.push(detectedLi);

                if (snapshot.actualSizeTier) {
                    var sizedLi = document.createElement("li");
                    sizedLi.appendChild(document.createTextNode("Currently t-shirt sized "));
                    var sizedStrong = document.createElement("strong");
                    sizedStrong.textContent = VcfCheckUI._sizing.humanizeSizingSizeKey(snapshot.actualSizeTier);
                    sizedLi.appendChild(sizedStrong);
                    if (snapshot.actualStorageSizeKey) {
                        sizedLi.appendChild(document.createTextNode(" with "));
                        var storageStrong = document.createElement("strong");
                        storageStrong.textContent = VcfCheckUI._sizing.humanizeSizingStoragePreset(snapshot.actualStorageSizeKey);
                        sizedLi.appendChild(storageStrong);
                        sizedLi.appendChild(document.createTextNode(" storage."));
                    } else {
                        sizedLi.appendChild(document.createTextNode("."));
                    }
                    summaryLis.push(sizedLi);

                    if (!snapshot.actualStorageSizeKey) {
                        var disjointLi = document.createElement("li");
                        disjointLi.appendChild(document.createTextNode(
                            "Its disk (" + snapshot.actualStorageGb + " GB) doesn't match any of the fixed storage presets the VCSA deployment wizard supports for " +
                            VcfCheckUI._sizing.humanizeSizingSizeKey(snapshot.actualSizeTier) + " - it was customized to a disjoint size (see "
                        ));
                        var kbLink = document.createElement("a");
                        kbLink.href = "https://knowledge.broadcom.com/external/article/326287";
                        kbLink.target = "_blank";
                        kbLink.rel = "noopener";
                        kbLink.textContent = "KB326287";
                        disjointLi.appendChild(kbLink);
                        disjointLi.appendChild(document.createTextNode(")."));
                        summaryLis.push(disjointLi);
                    }
                } else if (snapshot.actualCpuCores) {
                    var nonStandardLi = document.createElement("li");
                    nonStandardLi.textContent = "Currently non-standard sized (" + snapshot.actualCpuCores + " vCPU / " + snapshot.actualMemoryGb + " GB RAM) - does not match a known t-shirt size.";
                    summaryLis.push(nonStandardLi);
                }
                if (snapshot.currentSizeTier) {
                    var servingLi = document.createElement("li");
                    servingLi.appendChild(document.createTextNode(
                        "Serving " + snapshot.hostCount + " hosts / " + snapshot.virtualMachineCount + " VMs today, which sizes it for at least "
                    ));
                    var servingStrong = document.createElement("strong");
                    servingStrong.textContent = VcfCheckUI._sizing.humanizeSizingSizeKey(snapshot.currentSizeTier);
                    servingLi.appendChild(servingStrong);
                    servingLi.appendChild(document.createTextNode("."));
                    summaryLis.push(servingLi);
                }

                var summaryList = document.createElement("ul");
                summaryList.className = "chk-count";
                summaryList.style.margin = "0";
                summaryList.style.paddingLeft = "20px";
                summaryLis.forEach(function (li) {
                    summaryList.appendChild(li);
                });
                summaryBox.appendChild(summaryList);
            }
            block.appendChild(summaryBox);

            var field = document.createElement("div");
            field.className = "field";
            var label = document.createElement("label");
            label.textContent = "Target vCenter size";
            var select = document.createElement("select");
            var floorTier = snapshot ? (snapshot.recommendedSizeTier || snapshot.currentSizeTier || "").toLowerCase() : "";
            sizeKeys.forEach(function (sizeKey) {
                var option = document.createElement("option");
                option.value = sizeKey;
                option.textContent = VcfCheckUI._sizing.humanizeSizingSizeKey(sizeKey) + (sizeKey === floorTier ? " (current size)" : "");
                select.appendChild(option);
            });
            if (floorTier) {
                select.value = floorTier;
            }
            field.appendChild(label);
            field.appendChild(select);

            var storageField = document.createElement("div");
            storageField.className = "field";
            var storageLabel = document.createElement("label");
            storageLabel.textContent = "Target storage size";
            var storageSelect = document.createElement("select");
            storageField.appendChild(storageLabel);
            storageField.appendChild(storageSelect);

            // If the detected appliance already lines up with a known t-shirt size and a known
            // storage preset, the target pickers would just re-select the same "(current size)"
            // option - so keep them tucked behind an "Advanced options" toggle instead of showing
            // two dropdowns with nothing useful to change. When the appliance is non-standard
            // sized or has a disjoint disk, the picker is the only way to specify a target, so
            // show it directly.
            var isAligned = !!(snapshot && snapshot.actualSizeTier && snapshot.actualStorageSizeKey);
            if (isAligned) {
                var advancedToggle = document.createElement("a");
                advancedToggle.href = "#";
                advancedToggle.className = "sizing-advanced-toggle";
                advancedToggle.textContent = "Advanced options";
                advancedToggle.style.display = "inline-block";
                advancedToggle.style.marginBottom = "10px";
                field.style.display = "none";
                storageField.style.display = "none";
                advancedToggle.addEventListener("click", function (event) {
                    event.preventDefault();
                    var showing = field.style.display === "none";
                    field.style.display = showing ? "" : "none";
                    storageField.style.display = showing ? "" : "none";
                    advancedToggle.style.display = showing ? "none" : "inline-block";
                });
                block.appendChild(advancedToggle);
            }
            block.appendChild(field);
            block.appendChild(storageField);

            var impactBox = document.createElement("div");
            impactBox.className = "chk-count";
            impactBox.style.marginTop = "8px";
            block.appendChild(impactBox);

            listBox.appendChild(group);

            var hasCurrentSpecs = !!(snapshot && snapshot.actualCpuCores);
            var actualStorageGb = hasCurrentSpecs ? snapshot.actualStorageGb : null;

            // The VCSA deployment wizard only offers a fixed disk per t-shirt size
            // (Default/Large Storage/Extra Large Storage) - it cannot shrink below the appliance's
            // current disk, so presets smaller than the actual disk are disabled rather than
            // just floored to "current size" the way the t-shirt size picker is.
            function refreshStorageSelect() {
                var sizeKey = select.value;
                var storageDict = vcenterRef.storageGb || {};
                var preserveValue = storageSelect.value;
                storageSelect.innerHTML = "";
                var firstEnabledValue = null;
                VcfCheckUI._sizing.SIZING_VCENTER_STORAGE_PRESETS.forEach(function (presetSuffix) {
                    var presetGb = storageDict[sizeKey + presetSuffix] || 0;
                    var option = document.createElement("option");
                    option.value = presetSuffix;
                    option.textContent = VcfCheckUI._sizing.humanizeSizingStoragePreset(presetSuffix) + " (" + presetGb + " GB)" +
                        (snapshot && presetSuffix === snapshot.actualStorageSizeKey ? " (current size)" : "");
                    if (actualStorageGb && presetGb < actualStorageGb) {
                        option.disabled = true;
                    } else if (firstEnabledValue === null) {
                        firstEnabledValue = presetSuffix;
                    }
                    storageSelect.appendChild(option);
                });
                if (preserveValue && !storageSelect.querySelector("option[value=\"" + preserveValue + "\"]").disabled) {
                    storageSelect.value = preserveValue;
                } else if (snapshot && snapshot.actualStorageSizeKey && !storageSelect.querySelector("option[value=\"" + snapshot.actualStorageSizeKey + "\"]").disabled) {
                    storageSelect.value = snapshot.actualStorageSizeKey;
                } else if (firstEnabledValue) {
                    storageSelect.value = firstEnabledValue;
                }
            }

            function applyVCenterSelection() {
                refreshStorageSelect();
                var sizeKey = select.value;
                var storagePreset = storageSelect.value;
                var vCpu = vcenterRef.cpuCores[sizeKey] || 0;
                var memoryGb = vcenterRef.memoryGb[sizeKey] || 0;
                var storageGb = (vcenterRef.storageGb || {})[sizeKey + storagePreset] || 0;
                if (hasCurrentSpecs) {
                    var deltaVCpu = vCpu - snapshot.actualCpuCores;
                    var deltaMemoryGb = memoryGb - snapshot.actualMemoryGb;
                    var deltaStorageGb = storageGb - snapshot.actualStorageGb;
                    impactBox.textContent = "Selecting " + VcfCheckUI._sizing.humanizeSizingSizeKey(sizeKey) + " with " + VcfCheckUI._sizing.humanizeSizingStoragePreset(storagePreset) + " storage requires " +
                        vCpu + " vCPU, " + memoryGb + " GB RAM, " + storageGb + " GB disk for the new appliance - " +
                        "a net change of " + VcfCheckUI._sizing.formatSizingNumber(deltaVCpu, true) + " vCPU, " + VcfCheckUI._sizing.formatSizingNumber(deltaMemoryGb, true) + " GB RAM, " + VcfCheckUI._sizing.formatSizingNumber(deltaStorageGb, true) + " GB disk " +
                        "over the current appliance once the old one is powered off." +
                        (deltaVCpu === 0 && deltaMemoryGb === 0 && deltaStorageGb !== 0 && sizeKey === snapshot.actualSizeTier ?
                            " This disk change is not a resize choice - it's because vCenter 9's standard disk size for " + VcfCheckUI._sizing.humanizeSizingSizeKey(sizeKey) + " differs from vCenter 8's." :
                            "");
                    VcfCheckUI._sizing.setSizingSelection(entry.componentKey, entry.displayName, deltaVCpu, deltaMemoryGb, deltaStorageGb, true, vCpu, memoryGb, storageGb,
                        VcfCheckUI._sizing.humanizeSizingSizeKey(sizeKey) + " size, " + VcfCheckUI._sizing.humanizeSizingStoragePreset(storagePreset) + " storage");
                } else {
                    impactBox.textContent = "Selecting " + VcfCheckUI._sizing.humanizeSizingSizeKey(sizeKey) + " with " + VcfCheckUI._sizing.humanizeSizingStoragePreset(storagePreset) + " storage requires " +
                        vCpu + " vCPU, " + memoryGb + " GB RAM, " + storageGb + " GB disk for the new appliance. " +
                        "The current appliance's actual specs could not be determined, so this is the full footprint rather than a net change.";
                    VcfCheckUI._sizing.setSizingSelection(entry.componentKey, entry.displayName, vCpu, memoryGb, storageGb, false, undefined, undefined, undefined,
                        VcfCheckUI._sizing.humanizeSizingSizeKey(sizeKey) + " size, " + VcfCheckUI._sizing.humanizeSizingStoragePreset(storagePreset) + " storage");
                }
            }
            select.onchange = applyVCenterSelection;
            storageSelect.onchange = applyVCenterSelection;
            applyVCenterSelection();
        });
    }

    VcfCheckUI._sizing.sizingApplyRuntimeSelectionFn = null;

    // Mirrors the planning workbook's VCFMS worker pool formula: the pool's node count is
    // driven by whichever of RAM or CPU demand (add-ons plus a fixed Day-0 baseline load,
    // each with its own buffer multiplier) needs more nodes at the base per-node size - it is
    // never an upsize to a bigger node tier. A flat "+1" node is added except for two combos
    // the workbook special-cases (see below), each of which needs its own bookkeeping.
    VcfCheckUI._sizing.computeSizingWorkerNodeCount = function (dayZeroRef, comboKey, cpuPerNode, ramPerNode, addonCpu, addonRam, hasAddons) {
        var day0Cpu = (dayZeroRef.cpuCores || {})[comboKey] || 0;
        var day0Ram = (dayZeroRef.memoryGb || {})[comboKey] || 0;
        var cpuReq = Math.ceil((addonCpu + day0Cpu) * (dayZeroRef.cpuBufferMultiplier || 1));
        var ramReq = Math.ceil((addonRam + day0Ram) * (dayZeroRef.ramBufferMultiplier || 1));

        var ramNodesExtra = (comboKey === "additionalinstancesimplesmall" || comboKey === "firstinstancehighavailabilitymedium") ? 0 : 1;
        var cpuNodesExtra;
        if (comboKey === "additionalinstancesimplesmall") {
            cpuNodesExtra = 0;
        } else if (!hasAddons && comboKey === "additionalinstancehighavailabilitymedium") {
            cpuNodesExtra = 0;
        } else if (hasAddons && comboKey === "firstinstancehighavailabilitymedium") {
            cpuNodesExtra = 0;
        } else {
            cpuNodesExtra = 1;
        }

        var ramNodes = Math.ceil(ramReq / ramPerNode) + ramNodesExtra;
        var cpuNodes = Math.ceil(cpuReq / cpuPerNode) + cpuNodesExtra;
        return Math.max(ramNodes, cpuNodes);
    }

    VcfCheckUI._sizing.renderSizingRuntimeStep = function () {
        var instanceSelect = document.getElementById("sizing-runtime-instance");
        var availabilitySelect = document.getElementById("sizing-runtime-availability");
        var sizeSelect = document.getElementById("sizing-runtime-size");
        var hintBox = document.getElementById("sizing-runtime-hint");
        var breakdownBox = document.getElementById("sizing-runtime-breakdown");
        var controlRef = VcfCheckUI._sizing.sizingReferenceData.vcfServicesRuntimeControlNode || {};
        var workerRef = VcfCheckUI._sizing.sizingReferenceData.vcfServicesRuntimeWorkerNode || {};

        function applyAvailabilityConstraint() {
            // Simple availability only has a Small size row in the workbook - Medium/Large
            // don't exist for it, so they must be disabled rather than silently defaulted.
            var isSimple = availabilitySelect.value === "simple";
            Array.from(sizeSelect.options).forEach(function (option) {
                option.disabled = isSimple && option.value !== "small";
            });
            if (isSimple) {
                sizeSelect.value = "small";
                hintBox.textContent = "Simple availability only supports Small - Medium and Large require High Availability.";
            } else {
                hintBox.textContent = "";
            }
        }

        function applyRuntimeSelection() {
            applyAvailabilityConstraint();
            var instance = instanceSelect.value;
            var availability = availabilitySelect.value;
            var size = sizeSelect.value;

            var controlSizeKey = (availability === "highavailability" && size === "small") ? "smallha" : size;
            var controlNodeCount = (controlRef.nodeCount || {})[availability] || 1;
            var controlVCpu = (controlRef.cpuCores[controlSizeKey] || 0) * controlNodeCount;
            var controlMemoryGb = (controlRef.memoryGb[controlSizeKey] || 0) * controlNodeCount;
            var controlStorageGb = (controlRef.storageGb[controlSizeKey] || 0) * controlNodeCount;
            var runtimeConfigSummary = VcfCheckUI._sizing.humanizeSizingInstanceLabel(instance) + ", " + VcfCheckUI._sizing.humanizeSizingAvailabilityLabel(availability) + " availability, " + VcfCheckUI._sizing.humanizeSizingSizeKey(size) + " size";
            VcfCheckUI._sizing.setSizingSelection("vcfServicesRuntimeControlNodes", "VCF Services Runtime Control Nodes", controlVCpu, controlMemoryGb, controlStorageGb, false, undefined, undefined, undefined, runtimeConfigSummary);

            var workerKey = instance + availability + size;
            var vodapKey = availability + size;
            var cpuPerNode = workerRef.cpuCores[workerKey] || 0;
            var ramPerNode = workerRef.memoryGb[workerKey] || 0;
            var baseWorkerStorageGb = workerRef.storageGb[workerKey] || 0;

            // Log Management and Real-time Metrics run inside the worker pool rather than as
            // their own appliances - they add to the pool's RAM/CPU demand, which can push the
            // pool's node count up (see VcfCheckUI._sizing.computeSizingWorkerNodeCount), and add flat disk on top.
            var logsSelect = document.getElementById("sizing-mgmt-logs");
            var realtimeSelect = document.getElementById("sizing-mgmt-realtime");
            var logsRef = VcfCheckUI._sizing.sizingReferenceData.opsLogs || {};
            var realtimeRef = VcfCheckUI._sizing.sizingReferenceData.opsDataPlatform || {};
            var dayZeroRef = VcfCheckUI._sizing.sizingReferenceData.vcfmsDayZeroBaseline || {};
            var logsReplicasInput = document.getElementById("sizing-mgmt-logs-replicas");
            var logsIncluded = logsSelect && logsSelect.value !== "exclude";
            var logsSize = logsIncluded ? logsSelect.value : null;
            var logsReplicas = logsIncluded ?
                (parseInt(logsReplicasInput && logsReplicasInput.value, 10) || (logsRef.minInstances || {})[logsSize] || 1) : 0;
            var logsCpu = logsIncluded ? logsReplicas * (logsRef.cpuCores[logsSize] || 0) : 0;
            var logsRam = logsIncluded ? logsReplicas * (logsRef.memoryGb[logsSize] || 0) : 0;
            var logsStorageGb = logsIncluded ? logsReplicas * (logsRef.storageGb[logsSize] || 0) : 0;

            var realtimeIncluded = realtimeSelect && realtimeSelect.value === "include";
            var realtimeCpu = realtimeIncluded ? (realtimeRef.cpuCores[vodapKey] || 0) : 0;
            var realtimeRam = realtimeIncluded ? (realtimeRef.memoryGb[vodapKey] || 0) : 0;
            var realtimeStorageGb = realtimeIncluded ? (realtimeRef.storageGb || 0) : 0;

            // Software Depot and Identity Broker (Additional Instance only) also add their
            // Day-N CPU/RAM/disk demand into the shared worker pool, on top of - not instead
            // of - their own standalone appliance footprint reported by applyMgmtServicesSelection.
            var isAdditionalInstance = instance === "additionalinstance";
            var depotSelect = document.getElementById("sizing-mgmt-depot");
            var idBrokerSelect = document.getElementById("sizing-mgmt-idbroker");
            var depotRef = VcfCheckUI._sizing.sizingReferenceData.fleetDepot || {};
            var idBrokerRef = VcfCheckUI._sizing.sizingReferenceData.identityBroker || {};
            var idBrokerSizeKey = (availability === "highavailability" && size === "small") ? "small_ha" : size;
            var depotIncluded = isAdditionalInstance && depotSelect && depotSelect.value === "include";
            var idBrokerIncluded = isAdditionalInstance && idBrokerSelect && idBrokerSelect.value === "include";
            var depotDayNCpu = depotIncluded ? (depotRef.cpuCores[size] || 0) : 0;
            var depotDayNRam = depotIncluded ? (depotRef.memoryGb[size] || 0) : 0;
            var depotDayNStorageGb = depotIncluded ? (depotRef.storageGb[size] || 0) : 0;
            var idBrokerDayNCpu = idBrokerIncluded ? (idBrokerRef.cpuCores[idBrokerSizeKey] || 0) : 0;
            var idBrokerDayNRam = idBrokerIncluded ? (idBrokerRef.memoryGb[idBrokerSizeKey] || 0) : 0;
            var idBrokerDayNStorageGb = idBrokerIncluded ? (idBrokerRef.storageGb[idBrokerSizeKey] || 0) : 0;

            var workerNodeCount = VcfCheckUI._sizing.computeSizingWorkerNodeCount(dayZeroRef, workerKey, cpuPerNode, ramPerNode,
                logsCpu + realtimeCpu + depotDayNCpu + idBrokerDayNCpu,
                logsRam + realtimeRam + depotDayNRam + idBrokerDayNRam,
                logsIncluded || realtimeIncluded);

            var workerVCpu = workerNodeCount * cpuPerNode;
            var workerMemoryGb = workerNodeCount * ramPerNode;
            var workerStorageGb = baseWorkerStorageGb + logsStorageGb + realtimeStorageGb + depotDayNStorageGb + idBrokerDayNStorageGb;

            // Contribution of Log Management / Real-time Metrics is reported back to the
            // VCF Management Services step so it can show a breakdown even though these
            // resources are folded into the shared worker pool total above.
            VcfCheckUI._sizing.sizingLogMgmtContribution = logsIncluded ? { vCpu: logsCpu, memoryGb: logsRam, storageGb: logsStorageGb } : null;
            VcfCheckUI._sizing.sizingRealtimeContribution = realtimeIncluded ? { vCpu: realtimeCpu, memoryGb: realtimeRam, storageGb: realtimeStorageGb } : null;

            var workerPoolServices = [];
            if (logsIncluded) {
                workerPoolServices.push({ name: "Log Management", vCpu: logsCpu, memoryGb: logsRam, storageGb: logsStorageGb,
                    configSummary: "Size: " + VcfCheckUI._sizing.humanizeSizingTierLabel(logsSize) + ", Replicas: " + logsReplicas });
            }
            if (realtimeIncluded) {
                workerPoolServices.push({ name: "Real-time Metrics", vCpu: realtimeCpu, memoryGb: realtimeRam, storageGb: realtimeStorageGb,
                    configSummary: "Size: " + VcfCheckUI._sizing.humanizeSizingTierLabel(size) });
            }
            if (depotIncluded) {
                workerPoolServices.push({ name: "Software Depot (worker pool contribution)", vCpu: depotDayNCpu, memoryGb: depotDayNRam, storageGb: depotDayNStorageGb,
                    configSummary: "Size: " + VcfCheckUI._sizing.humanizeSizingTierLabel(size) });
            }
            if (idBrokerIncluded) {
                workerPoolServices.push({ name: "Identity Broker (worker pool contribution)", vCpu: idBrokerDayNCpu, memoryGb: idBrokerDayNRam, storageGb: idBrokerDayNStorageGb,
                    configSummary: "Size: " + VcfCheckUI._sizing.humanizeSizingTierLabel(idBrokerSizeKey) });
            }
            VcfCheckUI._sizing.setSizingSelection("vcfServicesRuntimeWorkerNodes", "VCF Services Runtime Worker Nodes", workerVCpu, workerMemoryGb, workerStorageGb, false, undefined, undefined, undefined, runtimeConfigSummary, workerPoolServices);

            VcfCheckUI._sizing.renderSizingBreakdownBox(breakdownBox, [
                ["Control Nodes", controlNodeCount, controlVCpu, controlMemoryGb, controlStorageGb],
                ["Worker Nodes" + ((logsIncluded || realtimeIncluded || depotIncluded || idBrokerIncluded) ? " (sized for included add-on services)" : ""), workerNodeCount, workerVCpu, workerMemoryGb, workerStorageGb]
            ], ["", "Nodes", "vCPU", "RAM (GB)", "Disk (GB)"]);
        }

        instanceSelect.onchange = applyRuntimeSelection;
        availabilitySelect.onchange = applyRuntimeSelection;
        sizeSelect.onchange = applyRuntimeSelection;
        VcfCheckUI._sizing.sizingApplyRuntimeSelectionFn = applyRuntimeSelection;
        applyRuntimeSelection();
    }

    VcfCheckUI._sizing.SIZING_LOG_MANAGEMENT_MIN_REPLICAS = { small: 1, medium: 3, large: 3 };
    VcfCheckUI._sizing.SIZING_LOG_MANAGEMENT_MAX_REPLICAS = { small: 19, medium: 19, large: 19 };

    VcfCheckUI._sizing.clearSizingSelection = function (componentKey) {
        delete VcfCheckUI._sizing.sizingSelections[componentKey];
        VcfCheckUI._sizing.updateSizingRunningTotal();
    }

    VcfCheckUI._sizing.sizingMgmtLastDepotValue = "include";
    VcfCheckUI._sizing.sizingMgmtLastIdBrokerValue = "include";
    VcfCheckUI._sizing.sizingLogMgmtContribution = null;
    VcfCheckUI._sizing.sizingRealtimeContribution = null;

    VcfCheckUI._sizing.renderSizingMgmtServicesStep = function () {
        var logsSelect = document.getElementById("sizing-mgmt-logs");
        var logsReplicasField = document.getElementById("sizing-mgmt-logs-replicas-field");
        var logsReplicasInput = document.getElementById("sizing-mgmt-logs-replicas");
        var realtimeSelect = document.getElementById("sizing-mgmt-realtime");
        var depotSelect = document.getElementById("sizing-mgmt-depot");
        var idBrokerSelect = document.getElementById("sizing-mgmt-idbroker");
        var hintBox = document.getElementById("sizing-mgmt-hint");
        var breakdownBox = document.getElementById("sizing-mgmt-breakdown");
        var logsHelpBox = document.getElementById("sizing-mgmt-logs-help");

        var logsRef = VcfCheckUI._sizing.sizingReferenceData.opsLogs || {};
        var realtimeRef = VcfCheckUI._sizing.sizingReferenceData.opsDataPlatform || {};
        var depotRef = VcfCheckUI._sizing.sizingReferenceData.fleetDepot || {};
        var idBrokerRef = VcfCheckUI._sizing.sizingReferenceData.identityBroker || {};

        var runtimeInstance = (document.getElementById("sizing-runtime-instance") || {}).value || "firstinstance";
        var runtimeAvailability = (document.getElementById("sizing-runtime-availability") || {}).value || "simple";
        var runtimeSize = (document.getElementById("sizing-runtime-size") || {}).value || "small";
        var isAdditionalInstance = runtimeInstance === "additionalinstance";

        depotSelect.disabled = !isAdditionalInstance;
        if (!isAdditionalInstance) {
            if (depotSelect.value !== "exclude") {
                VcfCheckUI._sizing.sizingMgmtLastDepotValue = depotSelect.value;
            }
            depotSelect.value = "exclude";
        } else if (depotSelect.value === "exclude" && VcfCheckUI._sizing.sizingMgmtLastDepotValue !== "exclude") {
            depotSelect.value = VcfCheckUI._sizing.sizingMgmtLastDepotValue;
        }

        idBrokerSelect.disabled = !isAdditionalInstance;
        if (!isAdditionalInstance) {
            if (idBrokerSelect.value !== "exclude") {
                VcfCheckUI._sizing.sizingMgmtLastIdBrokerValue = idBrokerSelect.value;
            }
            idBrokerSelect.value = "exclude";
        } else if (idBrokerSelect.value === "exclude" && VcfCheckUI._sizing.sizingMgmtLastIdBrokerValue !== "exclude") {
            idBrokerSelect.value = VcfCheckUI._sizing.sizingMgmtLastIdBrokerValue;
        }

        function applyMgmtServicesSelection() {
            // Log Management and Real-time Metrics run inside the shared VCF services runtime
            // worker pool rather than as their own appliances, so their vCPU/RAM/disk are already
            // folded into the worker pool total (see applyRuntimeSelection). The rows below still
            // show their individual contribution for visibility, sourced from that same function.
            var rows = [];
            var includedRows = [];
            var logsSize = logsSelect.value;
            logsReplicasField.classList.toggle("hidden", logsSize === "exclude");
            logsHelpBox.classList.toggle("hidden", logsSize === "exclude");
            VcfCheckUI._sizing.clearSizingSelection("logManagement");
            VcfCheckUI._sizing.clearSizingSelection("realTimeMetrics");
            if (logsSize !== "exclude") {
                var minReplicas = VcfCheckUI._sizing.SIZING_LOG_MANAGEMENT_MIN_REPLICAS[logsSize] || 1;
                var maxReplicas = VcfCheckUI._sizing.SIZING_LOG_MANAGEMENT_MAX_REPLICAS[logsSize] || 19;
                logsReplicasInput.min = minReplicas;
                logsReplicasInput.max = maxReplicas;
                var currentReplicas = parseInt(logsReplicasInput.value, 10);
                if (currentReplicas < minReplicas) {
                    logsReplicasInput.value = minReplicas;
                } else if (currentReplicas > maxReplicas) {
                    logsReplicasInput.value = maxReplicas;
                }
            }

            if (typeof VcfCheckUI._sizing.sizingApplyRuntimeSelectionFn === "function") {
                VcfCheckUI._sizing.sizingApplyRuntimeSelectionFn();
            }

            if (logsSize !== "exclude" && VcfCheckUI._sizing.sizingLogMgmtContribution) {
                rows.push(["Log Management", VcfCheckUI._sizing.sizingLogMgmtContribution.vCpu, VcfCheckUI._sizing.sizingLogMgmtContribution.memoryGb, VcfCheckUI._sizing.sizingLogMgmtContribution.storageGb]);
                includedRows.push("Log Management");
            }

            if (realtimeSelect.value === "include" && VcfCheckUI._sizing.sizingRealtimeContribution) {
                rows.push(["Real-time Metrics", VcfCheckUI._sizing.sizingRealtimeContribution.vCpu, VcfCheckUI._sizing.sizingRealtimeContribution.memoryGb, VcfCheckUI._sizing.sizingRealtimeContribution.storageGb]);
                includedRows.push("Real-time Metrics");
            }

            if (isAdditionalInstance && depotSelect.value === "include") {
                var depotVCpu = depotRef.cpuCores[runtimeSize] || 0;
                var depotMemoryGb = depotRef.memoryGb[runtimeSize] || 0;
                var depotStorageGb = depotRef.storageGb[runtimeSize] || 0;
                VcfCheckUI._sizing.setSizingSelection("softwareDepot", "Software Depot (Additional Instance)", depotVCpu, depotMemoryGb, depotStorageGb, false, undefined, undefined, undefined,
                    VcfCheckUI._sizing.humanizeSizingSizeKey(runtimeSize) + " size");
                rows.push(["Software Depot", depotVCpu, depotMemoryGb, depotStorageGb]);
            } else {
                VcfCheckUI._sizing.clearSizingSelection("softwareDepot");
            }

            if (isAdditionalInstance && idBrokerSelect.value === "include") {
                var idBrokerSizeKey = (runtimeAvailability === "highavailability" && runtimeSize === "small") ? "small_ha" : runtimeSize;
                var idBrokerVCpu = idBrokerRef.cpuCores[idBrokerSizeKey] || 0;
                var idBrokerMemoryGb = idBrokerRef.memoryGb[idBrokerSizeKey] || 0;
                var idBrokerStorageGb = idBrokerRef.storageGb[idBrokerSizeKey] || 0;
                VcfCheckUI._sizing.setSizingSelection("identityBroker", "Identity Broker (Additional Instance)", idBrokerVCpu, idBrokerMemoryGb, idBrokerStorageGb, false, undefined, undefined, undefined,
                    VcfCheckUI._sizing.humanizeSizingSizeKey(runtimeSize) + " size, " + VcfCheckUI._sizing.humanizeSizingAvailabilityLabel(runtimeAvailability) + " availability");
                rows.push(["Identity Broker", idBrokerVCpu, idBrokerMemoryGb, idBrokerStorageGb]);
            } else {
                VcfCheckUI._sizing.clearSizingSelection("identityBroker");
            }

            hintBox.textContent = isAdditionalInstance ? "" :
                "Software Depot and Identity Broker are only offered as separate deployments for an Additional Instance - the First Instance's depot and broker are already sized as part of VCF Services Runtime.";

            var includedNote = includedRows.length === 0 ? "" :
                includedRows.join(" and ") + " included in runtime worker pool below";

            VcfCheckUI._sizing.renderSizingBreakdownBox(breakdownBox, rows, ["", "vCPU", "RAM (GB)", "Disk (GB)"], includedNote);
        }

        logsSelect.onchange = applyMgmtServicesSelection;
        logsReplicasInput.onchange = applyMgmtServicesSelection;
        realtimeSelect.onchange = applyMgmtServicesSelection;
        depotSelect.onchange = applyMgmtServicesSelection;
        idBrokerSelect.onchange = applyMgmtServicesSelection;
        applyMgmtServicesSelection();
    }

    VcfCheckUI._sizing.SIZING_FLEET_COMPONENT_KEYS = ["vcfOperations", "vcfOperationsCollector", "vdefendAndAviLicensingHub", "vcfAutomation", "vcfOperationsForNetworks", "vcfOperationsForNetworksCollector"];
    // Rendered by their own dedicated step (vCenter, VCF Management Services, or the
    // per-domain AVI LB/SSP/Supervisor cards) rather than the generic "More Components"
    // checkbox list - listing them here again would just duplicate that UI.
    VcfCheckUI._sizing.SIZING_COMPONENT_KEYS_HANDLED_ELSEWHERE = ["managementDomainVcenter", "workloadDomainVcenter", "managementDomainSupervisor", "managementDomainAviLoadBalancer", "workloadDomainAviLoadBalancer", "managementDomainSecurityServicesPlatform", "workloadDomainSecurityServicesPlatform", "licenseServer", "logManagement"];
    VcfCheckUI._sizing.sizingFleetLastVcfOpsValue = "include";
    VcfCheckUI._sizing.sizingFleetLastCloudProxyValue = "include";

    VcfCheckUI._sizing.renderSizingFleetStep = function () {
        var vcfOpsSelect = document.getElementById("sizing-fleet-vcfops");
        var vcfOpsSizeSelect = document.getElementById("sizing-fleet-vcfops-size");
        var cloudProxySelect = document.getElementById("sizing-fleet-cloudproxy");
        var cloudProxySizeSelect = document.getElementById("sizing-fleet-cloudproxy-size");
        var automationSelect = document.getElementById("sizing-fleet-automation");
        var automationSizeSelect = document.getElementById("sizing-fleet-automation-size");
        var opsNetworksSelect = document.getElementById("sizing-fleet-opsnetworks");
        var opsNetworksSizeSelect = document.getElementById("sizing-fleet-opsnetworks-size");
        var licenseHubSelect = document.getElementById("sizing-fleet-licensehub");
        var hintBox = document.getElementById("sizing-fleet-hint");
        var breakdownBox = document.getElementById("sizing-fleet-breakdown");

        var vcfOpsRef = VcfCheckUI._sizing.sizingReferenceData.vcfOperations || {};
        var cloudProxyRef = VcfCheckUI._sizing.sizingReferenceData.vcfOperationsCollector || {};
        var automationRef = VcfCheckUI._sizing.sizingReferenceData.vcfAutomation || {};
        var opsNetworksRef = VcfCheckUI._sizing.sizingReferenceData.vrni || {};
        var opsNetworksCollectorRef = VcfCheckUI._sizing.sizingReferenceData.vrniCollector || {};
        var licenseHubRef = VcfCheckUI._sizing.sizingReferenceData.vdefendAndAviLicensingHub || {};

        var runtimeInstance = (document.getElementById("sizing-runtime-instance") || {}).value || "firstinstance";
        var isAdditionalInstance = runtimeInstance === "additionalinstance";

        vcfOpsSelect.disabled = isAdditionalInstance;
        if (isAdditionalInstance) {
            if (vcfOpsSelect.value !== "exclude") {
                VcfCheckUI._sizing.sizingFleetLastVcfOpsValue = vcfOpsSelect.value;
            }
            vcfOpsSelect.value = "exclude";
        } else if (vcfOpsSelect.value === "exclude" && VcfCheckUI._sizing.sizingFleetLastVcfOpsValue !== "exclude") {
            vcfOpsSelect.value = VcfCheckUI._sizing.sizingFleetLastVcfOpsValue;
        }

        var vcfOpsPresent = vcfOpsSelect.value === "include" || vcfOpsSelect.value === "existing";

        cloudProxySelect.disabled = !vcfOpsPresent;
        if (!vcfOpsPresent) {
            if (cloudProxySelect.value !== "exclude") {
                VcfCheckUI._sizing.sizingFleetLastCloudProxyValue = cloudProxySelect.value;
            }
            cloudProxySelect.value = "exclude";
        } else if (cloudProxySelect.value === "exclude" && VcfCheckUI._sizing.sizingFleetLastCloudProxyValue !== "exclude") {
            cloudProxySelect.value = VcfCheckUI._sizing.sizingFleetLastCloudProxyValue;
        }

        function applyFleetSelection() {
            var rows = [];

            vcfOpsSizeSelect.closest(".field").classList.toggle("hidden", vcfOpsSelect.value !== "include");
            if (vcfOpsSelect.value === "include") {
                var vcfOpsSize = vcfOpsSizeSelect.value;
                var vcfOpsVCpu = (vcfOpsRef.cpuCores || {})[vcfOpsSize] || 0;
                var vcfOpsMemoryGb = (vcfOpsRef.memoryGb || {})[vcfOpsSize] || 0;
                var vcfOpsStorageGb = (vcfOpsRef.storageGb || {})[vcfOpsSize] || 0;
                VcfCheckUI._sizing.setSizingSelection("vcfOperations", "VCF Operations", vcfOpsVCpu, vcfOpsMemoryGb, vcfOpsStorageGb, false, undefined, undefined, undefined,
                    VcfCheckUI._sizing.humanizeSizingSizeKey(vcfOpsSize) + " size");
                rows.push(["VCF Operations", vcfOpsVCpu, vcfOpsMemoryGb, vcfOpsStorageGb]);
            } else {
                VcfCheckUI._sizing.clearSizingSelection("vcfOperations");
            }

            cloudProxySizeSelect.closest(".field").classList.toggle("hidden", cloudProxySelect.value !== "include");
            if (cloudProxySelect.value === "include") {
                var cloudProxySize = cloudProxySizeSelect.value;
                var cloudProxyVCpu = (cloudProxyRef.cpuCores || {})[cloudProxySize] || 0;
                var cloudProxyMemoryGb = (cloudProxyRef.memoryGb || {})[cloudProxySize] || 0;
                var cloudProxyStorageGb = (cloudProxyRef.storageGb || {})[cloudProxySize] || 0;
                VcfCheckUI._sizing.setSizingSelection("vcfOperationsCollector", "Cloud Proxy", cloudProxyVCpu, cloudProxyMemoryGb, cloudProxyStorageGb, false, undefined, undefined, undefined,
                    VcfCheckUI._sizing.humanizeSizingSizeKey(cloudProxySize) + " size");
                rows.push(["Cloud Proxy", cloudProxyVCpu, cloudProxyMemoryGb, cloudProxyStorageGb]);
            } else {
                VcfCheckUI._sizing.clearSizingSelection("vcfOperationsCollector");
            }

            if (licenseHubSelect.value === "include") {
                var licenseHubSizeKey = Object.keys(licenseHubRef.cpuCores || {})[0];
                var licenseHubVCpu = (licenseHubRef.cpuCores || {})[licenseHubSizeKey] || 0;
                var licenseHubMemoryGb = (licenseHubRef.memoryGb || {})[licenseHubSizeKey] || 0;
                var licenseHubStorageGb = (licenseHubRef.storageGb || {})[licenseHubSizeKey] || 0;
                VcfCheckUI._sizing.setSizingSelection("vdefendAndAviLicensingHub", "License Server", licenseHubVCpu, licenseHubMemoryGb, licenseHubStorageGb, false, undefined, undefined, undefined,
                    VcfCheckUI._sizing.humanizeSizingSizeKey(licenseHubSizeKey) + " size");
                rows.push(["License Server", licenseHubVCpu, licenseHubMemoryGb, licenseHubStorageGb]);
            } else {
                VcfCheckUI._sizing.clearSizingSelection("vdefendAndAviLicensingHub");
            }

            automationSizeSelect.closest(".field").classList.toggle("hidden", automationSelect.value !== "include");
            if (automationSelect.value === "include") {
                var automationSize = automationSizeSelect.value;
                var automationVCpu = (automationRef.cpuCores || {})[automationSize] || 0;
                var automationMemoryGb = (automationRef.memoryGb || {})[automationSize] || 0;
                var automationStorageGb = (automationRef.storageGb || {})[automationSize] || 0;
                VcfCheckUI._sizing.setSizingSelection("vcfAutomation", "VCF Automation", automationVCpu, automationMemoryGb, automationStorageGb, false, undefined, undefined, undefined,
                    VcfCheckUI._sizing.humanizeSizingSizeKey(automationSize) + " size");
                rows.push(["VCF Automation", automationVCpu, automationMemoryGb, automationStorageGb]);
            } else {
                VcfCheckUI._sizing.clearSizingSelection("vcfAutomation");
            }

            opsNetworksSizeSelect.closest(".field").classList.toggle("hidden", opsNetworksSelect.value !== "include");
            if (opsNetworksSelect.value === "include") {
                var opsNetworksSize = opsNetworksSizeSelect.value;
                var opsNetworksVCpu = (opsNetworksRef.cpuCores || {})[opsNetworksSize] || 0;
                var opsNetworksMemoryGb = (opsNetworksRef.memoryGb || {})[opsNetworksSize] || 0;
                var opsNetworksStorageGb = (opsNetworksRef.storageGb || {})[opsNetworksSize] || 0;
                var opsNetworksCollectorVCpu = (opsNetworksCollectorRef.cpuCores || {})[opsNetworksSize] || 0;
                var opsNetworksCollectorMemoryGb = (opsNetworksCollectorRef.memoryGb || {})[opsNetworksSize] || 0;
                var opsNetworksCollectorStorageGb = (opsNetworksCollectorRef.storageGb || {})[opsNetworksSize] || 0;
                VcfCheckUI._sizing.setSizingSelection("vcfOperationsForNetworks", "VCF Operations for networks", opsNetworksVCpu, opsNetworksMemoryGb, opsNetworksStorageGb, false, undefined, undefined, undefined,
                    VcfCheckUI._sizing.humanizeSizingSizeKey(opsNetworksSize) + " size");
                VcfCheckUI._sizing.setSizingSelection("vcfOperationsForNetworksCollector", "VCF Operations for networks collector", opsNetworksCollectorVCpu, opsNetworksCollectorMemoryGb, opsNetworksCollectorStorageGb, false, undefined, undefined, undefined,
                    VcfCheckUI._sizing.humanizeSizingSizeKey(opsNetworksSize) + " size");
                rows.push(["VCF Operations for networks", opsNetworksVCpu, opsNetworksMemoryGb, opsNetworksStorageGb]);
                rows.push(["VCF Operations for networks collector", opsNetworksCollectorVCpu, opsNetworksCollectorMemoryGb, opsNetworksCollectorStorageGb]);
            } else {
                VcfCheckUI._sizing.clearSizingSelection("vcfOperationsForNetworks");
                VcfCheckUI._sizing.clearSizingSelection("vcfOperationsForNetworksCollector");
            }

            hintBox.textContent = isAdditionalInstance ?
                "VCF Operations is Excluded because the VCF Instance Profile on the Services Runtime step is set to Additional Instance - a new VCF Operations instance cannot be created for an Additional Instance, it must already exist elsewhere. Go back to Services Runtime and change Instance Model to First Instance to unlock this." : "";

            VcfCheckUI._sizing.renderSizingBreakdownBox(breakdownBox, rows, ["", "vCPU", "RAM (GB)", "Disk (GB)"]);
        }

        vcfOpsSelect.onchange = applyFleetSelection;
        vcfOpsSizeSelect.onchange = applyFleetSelection;
        cloudProxySelect.onchange = applyFleetSelection;
        cloudProxySizeSelect.onchange = applyFleetSelection;
        automationSelect.onchange = applyFleetSelection;
        automationSizeSelect.onchange = applyFleetSelection;
        opsNetworksSelect.onchange = applyFleetSelection;
        opsNetworksSizeSelect.onchange = applyFleetSelection;
        licenseHubSelect.onchange = applyFleetSelection;
        applyFleetSelection();
    }

    VcfCheckUI._sizing.SIZING_AVI_LB_SIZE_OPTIONS = ["small", "large", "xlarge"];
    VcfCheckUI._sizing.SIZING_SSP_SIZE_OPTIONS = ["medium", "large", "xlarge"];
    VcfCheckUI._sizing.SIZING_SUPERVISOR_SIZE_OPTIONS = ["tiny", "small", "medium", "large", "xlarge"];

    VcfCheckUI._sizing.SIZING_TIER_LABELS = {
        tiny: "Tiny",
        xsmall: "Extra Small",
        small: "Small",
        medium: "Medium",
        large: "Large",
        xlarge: "Extra Large"
    };


})();
