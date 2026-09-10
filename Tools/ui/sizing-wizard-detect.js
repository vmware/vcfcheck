"use strict";

(function () {
    // ---- Upgrade Resource Estimator: more/platform services step, gates, option loading, environment select, and connect/detect ----

    VcfCheckUI._sizing.humanizeSizingTierLabel = function (sizeKey) {
        return VcfCheckUI._sizing.SIZING_TIER_LABELS[sizeKey.toLowerCase().replace(/-/g, "")] || sizeKey.charAt(0).toUpperCase() + sizeKey.slice(1);
    }

    VcfCheckUI._sizing.getSizingPlatformDomainEntries = function () {
        var managementSnapshot = VcfCheckUI._sizing.sizingDetectedData.managementDomainVCenter || null;
        var entries = [{
            domainKey: "m01",
            displayName: "Management Domain" + (managementSnapshot && managementSnapshot.domainName ? " (" + managementSnapshot.domainName + ")" : ""),
            supervisorPresent: !!(managementSnapshot && managementSnapshot.supervisorPresent)
        }];
        (VcfCheckUI._sizing.sizingDetectedData.workloadDomainVCenters || []).forEach(function (snapshot) {
            entries.push({
                domainKey: "w-" + snapshot.domainName,
                displayName: "Workload Domain (" + snapshot.domainName + ")",
                supervisorPresent: !!snapshot.supervisorPresent
            });
        });
        return entries;
    }

    VcfCheckUI._sizing.buildSizingTierSelect = function (sizeOptions, includeExclude) {
        var select = document.createElement("select");
        (includeExclude ? ["exclude"].concat(sizeOptions) : sizeOptions).forEach(function (sizeKey) {
            var option = document.createElement("option");
            option.value = sizeKey;
            option.textContent = sizeKey === "exclude" ? "Exclude" : VcfCheckUI._sizing.humanizeSizingTierLabel(sizeKey);
            select.appendChild(option);
        });
        return select;
    }

    VcfCheckUI._sizing.buildSizingIncludeExcludeSelect = function () {
        var select = document.createElement("select");
        [["exclude", "Exclude"], ["include", "Include"]].forEach(function (pair) {
            var option = document.createElement("option");
            option.value = pair[0];
            option.textContent = pair[1];
            select.appendChild(option);
        });
        return select;
    }

    VcfCheckUI._sizing.buildSizingField = function (labelText, select) {
        var field = document.createElement("div");
        field.className = "field";
        var label = document.createElement("label");
        label.textContent = labelText;
        field.appendChild(label);
        field.appendChild(select);
        return field;
    }

    // AVI Load Balancer and Security Services Platform, and Supervisor are each deployed
    // per domain (not once for the whole environment), so this renders one card per domain
    // detected by the Scan button rather than a single flat checkbox list - AVI LB always
    // deploys as a 3-node cluster (workbook "Management Domain Sizing" J14/J20), and
    // Security Services Platform's per-size totals already cover its worker/controller
    // nodes as a single figure, with the SSPI installer VM sized and added separately
    // (workbook rows G15/G21 vs. G16 - SSPI is a distinct line item summed alongside SSP,
    // not folded into it).
    VcfCheckUI._sizing.sizingMorePlatformRows = {};
    VcfCheckUI._sizing.sizingMoreGenericRows = {};

    VcfCheckUI._sizing.renderSizingMoreBreakdown = function () {
        var breakdownBox = document.getElementById("sizing-more-breakdown");
        if (!breakdownBox) {
            return;
        }
        var rows = [].concat.apply([], Object.keys(VcfCheckUI._sizing.sizingMorePlatformRows).map(function (key) {
            return VcfCheckUI._sizing.sizingMorePlatformRows[key];
        })).concat(Object.keys(VcfCheckUI._sizing.sizingMoreGenericRows).map(function (key) {
            return VcfCheckUI._sizing.sizingMoreGenericRows[key];
        }));

        VcfCheckUI._sizing.renderSizingBreakdownBox(breakdownBox, rows, ["", "vCPU", "RAM (GB)", "Disk (GB)"]);
    }

    VcfCheckUI._sizing.renderSizingPlatformServicesStep = function () {
        var container = document.getElementById("sizing-platform-list");
        if (!container) {
            return;
        }
        container.innerHTML = "";
        VcfCheckUI._sizing.sizingMorePlatformRows = {};

        var aviRef = VcfCheckUI._sizing.sizingReferenceData.aviLoadBalancer || {};
        var sspRef = VcfCheckUI._sizing.sizingReferenceData.securityServicesPlatform || {};
        var supervisorRef = VcfCheckUI._sizing.sizingReferenceData.supervisor || {};

        VcfCheckUI._sizing.getSizingPlatformDomainEntries().forEach(function (domain) {
            var card = document.createElement("div");
            card.className = "sizing-vcenter-block";
            card.style.marginBottom = "20px";

            var heading = document.createElement("p");
            heading.className = "chk-count";
            heading.style.marginTop = "0";
            var headingStrong = document.createElement("strong");
            headingStrong.textContent = domain.displayName;
            heading.appendChild(headingStrong);
            card.appendChild(heading);

            var aviRow = document.createElement("div");
            aviRow.className = "launcher-row";
            aviRow.style.flexWrap = "wrap";
            var aviSelect = VcfCheckUI._sizing.buildSizingIncludeExcludeSelect();
            var aviSizeSelect = VcfCheckUI._sizing.buildSizingTierSelect(VcfCheckUI._sizing.SIZING_AVI_LB_SIZE_OPTIONS, false);
            aviRow.appendChild(VcfCheckUI._sizing.buildSizingField("AVI Load Balancer", aviSelect));
            aviRow.appendChild(VcfCheckUI._sizing.buildSizingField("AVI Load Balancer Size", aviSizeSelect));
            card.appendChild(aviRow);

            var sspRow = document.createElement("div");
            sspRow.className = "launcher-row";
            sspRow.style.flexWrap = "wrap";
            var sspSelect = VcfCheckUI._sizing.buildSizingIncludeExcludeSelect();
            var sspSizeSelect = VcfCheckUI._sizing.buildSizingTierSelect(VcfCheckUI._sizing.SIZING_SSP_SIZE_OPTIONS, false);
            sspRow.appendChild(VcfCheckUI._sizing.buildSizingField("Security Services Platform", sspSelect));
            sspRow.appendChild(VcfCheckUI._sizing.buildSizingField("Security Services Platform Size", sspSizeSelect));
            card.appendChild(sspRow);

            var supervisorRow = document.createElement("div");
            supervisorRow.className = "launcher-row";
            supervisorRow.style.flexWrap = "wrap";
            var supervisorModeSelect = VcfCheckUI._sizing.buildSizingIncludeExcludeSelect();
            var supervisorAvailabilitySelect = document.createElement("select");
            [["simple", "Simple"], ["highavailability", "High Availability"]].forEach(function (pair) {
                var option = document.createElement("option");
                option.value = pair[0];
                option.textContent = pair[1];
                supervisorAvailabilitySelect.appendChild(option);
            });
            var supervisorSizeSelect = VcfCheckUI._sizing.buildSizingTierSelect(VcfCheckUI._sizing.SIZING_SUPERVISOR_SIZE_OPTIONS, false);
            supervisorRow.appendChild(VcfCheckUI._sizing.buildSizingField("Supervisor", supervisorModeSelect));
            supervisorRow.appendChild(VcfCheckUI._sizing.buildSizingField("Availability Model", supervisorAvailabilitySelect));
            supervisorRow.appendChild(VcfCheckUI._sizing.buildSizingField("Supervisor Size", supervisorSizeSelect));
            card.appendChild(supervisorRow);

            if (domain.supervisorPresent) {
                var supervisorNote = document.createElement("p");
                supervisorNote.className = "chk-count";
                supervisorNote.style.marginTop = "8px";
                supervisorNote.textContent = "Supervisor is already deployed on this domain - it upgrades in place with no net-new resource footprint. Only choose a mode above if you also plan to resize it as part of this upgrade.";
                card.appendChild(supervisorNote);
            } else {
                supervisorModeSelect.value = "exclude";
            }

            function applyDomainSelection() {
                var domainRows = [];

                var aviKey = "aviLoadBalancer-" + domain.domainKey;
                aviSizeSelect.closest(".field").classList.toggle("hidden", aviSelect.value === "exclude");
                if (aviSelect.value === "exclude") {
                    VcfCheckUI._sizing.clearSizingSelection(aviKey);
                } else {
                    var aviSize = aviSizeSelect.value;
                    var aviVCpu = ((aviRef.cpuCores || {})[aviSize] || 0) * 3;
                    var aviMemoryGb = ((aviRef.memoryGb || {})[aviSize] || 0) * 3;
                    var aviStorageGb = ((aviRef.storageGb || {})[aviSize] || 0) * 3;
                    VcfCheckUI._sizing.setSizingSelection(aviKey, "AVI Load Balancer (" + domain.displayName + ")", aviVCpu, aviMemoryGb, aviStorageGb, false, undefined, undefined, undefined,
                        VcfCheckUI._sizing.humanizeSizingTierLabel(aviSize) + " size, 3-node cluster");
                    domainRows.push(["AVI Load Balancer (" + domain.displayName + ")", aviVCpu, aviMemoryGb, aviStorageGb]);
                }

                var sspKey = "securityServicesPlatform-" + domain.domainKey;
                sspSizeSelect.closest(".field").classList.toggle("hidden", sspSelect.value === "exclude");
                if (sspSelect.value === "exclude") {
                    VcfCheckUI._sizing.clearSizingSelection(sspKey);
                } else {
                    var sspSize = sspSizeSelect.value;
                    var sspVCpu = (sspRef.cpuCores || {})[sspSize] || 0;
                    var sspMemoryGb = (sspRef.memoryGb || {})[sspSize] || 0;
                    var sspStorageGb = (sspRef.storageGb || {})[sspSize] || 0;
                    var sspiVCpu = (sspRef.sspiCpuCores || {})[sspSize] || 0;
                    var sspiMemoryGb = (sspRef.sspiMemoryGb || {})[sspSize] || 0;
                    var sspiStorageGb = (sspRef.sspiStorageGb || {})[sspSize] || 0;
                    VcfCheckUI._sizing.setSizingSelection(sspKey, "Security Services Platform (" + domain.displayName + ")", sspVCpu + sspiVCpu, sspMemoryGb + sspiMemoryGb, sspStorageGb + sspiStorageGb, false, undefined, undefined, undefined,
                        VcfCheckUI._sizing.humanizeSizingTierLabel(sspSize) + " size");
                    domainRows.push(["Security Services Platform (" + domain.displayName + ")", sspVCpu + sspiVCpu, sspMemoryGb + sspiMemoryGb, sspStorageGb + sspiStorageGb]);
                }

                var supervisorKey = "supervisor-" + domain.domainKey;
                var supervisorExcluded = supervisorModeSelect.value === "exclude";
                supervisorAvailabilitySelect.closest(".field").classList.toggle("hidden", supervisorExcluded);
                supervisorSizeSelect.closest(".field").classList.toggle("hidden", supervisorExcluded);
                if (supervisorExcluded) {
                    VcfCheckUI._sizing.clearSizingSelection(supervisorKey);
                } else {
                    var nodeCount = supervisorAvailabilitySelect.value === "highavailability" ? 3 : 1;
                    var supervisorSize = supervisorSizeSelect.value;
                    var supervisorVCpu = ((supervisorRef.cpuCores || {})[supervisorSize] || 0) * nodeCount;
                    var supervisorMemoryGb = ((supervisorRef.memoryGb || {})[supervisorSize] || 0) * nodeCount;
                    var supervisorStorageGb = ((supervisorRef.storageGb || {})[supervisorSize] || 0) * nodeCount;
                    VcfCheckUI._sizing.setSizingSelection(supervisorKey, "Supervisor (" + domain.displayName + ")", supervisorVCpu, supervisorMemoryGb, supervisorStorageGb, false, undefined, undefined, undefined,
                        VcfCheckUI._sizing.humanizeSizingTierLabel(supervisorSize) + " size, " + VcfCheckUI._sizing.humanizeSizingAvailabilityLabel(supervisorAvailabilitySelect.value) + " availability (" + nodeCount + " node" + (nodeCount > 1 ? "s" : "") + ")");
                    domainRows.push(["Supervisor (" + domain.displayName + ")", supervisorVCpu, supervisorMemoryGb, supervisorStorageGb]);
                }

                VcfCheckUI._sizing.sizingMorePlatformRows[domain.domainKey] = domainRows;
                VcfCheckUI._sizing.renderSizingMoreBreakdown();
            }

            aviSelect.onchange = applyDomainSelection;
            aviSizeSelect.onchange = applyDomainSelection;
            sspSelect.onchange = applyDomainSelection;
            sspSizeSelect.onchange = applyDomainSelection;
            supervisorModeSelect.onchange = applyDomainSelection;
            supervisorAvailabilitySelect.onchange = applyDomainSelection;
            supervisorSizeSelect.onchange = applyDomainSelection;
            applyDomainSelection();

            container.appendChild(card);
        });
    }

    VcfCheckUI._sizing.updateSizingGateState = function () {
        var detectRow = document.getElementById("sizing-detect-row");
        var notEvaluatedBox = document.getElementById("sizing-not-evaluated");
        var rowsContainer = document.getElementById("sizing-form-rows");
        var detectButton = document.getElementById("sizing-detect-button");
        document.getElementById("sizingNextButton").disabled = !VcfCheckUI._sizing.sizingEnvironmentEvaluated;

        if (VcfCheckUI.environments.length === 0) {
            detectButton.disabled = true;
            notEvaluatedBox.textContent = "Add an Environment above before estimating upgrade resources - the estimator needs to evaluate what's actually deployed (workload domains, Supervisor, etc.) first.";
            rowsContainer.innerHTML = "";
            return;
        }

        detectButton.disabled = VcfCheckUI._sizing.sizingEnvironmentEvaluated;
        detectRow.classList.remove("hidden");
        if (!VcfCheckUI._sizing.sizingEnvironmentEvaluated) {
            notEvaluatedBox.textContent = "Select the Environment to upgrade and click Scan to connect to its vCenter Server instances and read back the host count, VM count, and Supervisor/services state used to size the upgrade.";
            rowsContainer.innerHTML = "";
            return;
        }

        notEvaluatedBox.textContent = "";
    }

    VcfCheckUI._sizing.humanizeSizingComponentKey = function (key) {
        var displayName = (VcfCheckUI._sizing.sizingComponentsByKey[key] || {}).displayName;
        if (displayName) {
            return displayName;
        }
        return key.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, function (c) { return c.toUpperCase(); });
    }

    VcfCheckUI._sizing.humanizeSizingSizeKey = function (sizeKey) {
        return VcfCheckUI._sizing.humanizeSizingTierLabel(sizeKey.replace(/_/g, "-"));
    }

    VcfCheckUI._sizing.loadSizingOptions = function () {
        var rowsContainer = document.getElementById("sizing-form-rows");
        return fetch("/api/sizing/options").then(function (response) {
            return response.json();
        }).then(function (data) {
            var components = data.components || {};
            var reference = data.reference || {};
            VcfCheckUI._sizing.sizingComponentsByKey = components;
            VcfCheckUI._sizing.sizingReferenceData = reference;
            rowsContainer.innerHTML = "";
            Object.keys(components).sort().forEach(function (componentKey) {
                var componentInfo = components[componentKey];
                if (componentInfo.treatment === "excluded" || componentInfo.derivedFrom || VcfCheckUI._sizing.SIZING_FLEET_COMPONENT_KEYS.indexOf(componentKey) !== -1 || VcfCheckUI._sizing.SIZING_COMPONENT_KEYS_HANDLED_ELSEWHERE.indexOf(componentKey) !== -1) {
                    return;
                }
                var row = document.createElement("div");
                row.className = "launcher-row";
                row.style.alignItems = "center";

                var checkbox = document.createElement("input");
                checkbox.type = "checkbox";
                checkbox.className = "sizing-include-checkbox";
                checkbox.dataset.componentKey = componentKey;
                checkbox.addEventListener("change", VcfCheckUI._sizing.scheduleSizingComponentEstimate);

                var label = document.createElement("label");
                label.style.flex = "1";
                label.textContent = VcfCheckUI._sizing.humanizeSizingComponentKey(componentKey);
                label.prepend(checkbox);

                row.appendChild(label);

                if (componentInfo.treatment === "temporaryDouble") {
                    var temporaryDoubleIcon = document.createElement("span");
                    temporaryDoubleIcon.className = "result-info-icon";
                    temporaryDoubleIcon.setAttribute("data-tooltip", "Sized twice: the existing vCenter keeps running alongside a temporary replacement during the upgrade, so both are counted until the old one is decommissioned.");
                    VcfCheckUI.setInlineSvg(temporaryDoubleIcon, VcfCheckUI._INFO_ICON);
                    row.appendChild(temporaryDoubleIcon);
                }

                if (componentInfo.referenceDataMissing) {
                    checkbox.disabled = true;
                    var missingNote = document.createElement("span");
                    missingNote.className = "chk-count";
                    missingNote.textContent = "No sizing data available yet";
                    row.appendChild(missingNote);
                } else {
                    var referenceKey = componentInfo.referenceKey || componentKey;
                    var sizeOptions = Object.keys((reference[referenceKey] || {}).cpuCores || {});
                    var isDerivedFromLiveInventory = componentInfo.sizeConstraint === "derivedFromLiveInventoryCount";
                    if (sizeOptions.length === 0) {
                        checkbox.disabled = true;
                    } else if (isDerivedFromLiveInventory) {
                        // No installer screen exists ahead of the real upgrade wizard to read the
                        // tier off of, so this estimator prompts for the counts itself (manually,
                        // or prefilled by the Scan button above) and derives the tier - see
                        // Get-VcfCheckVCenterSizeTier / brownfield-upgrade-treatment.json's notes
                        // on managementDomainVcenter/workloadDomainVcenter.
                        var hostCountInput = document.createElement("input");
                        hostCountInput.type = "number";
                        hostCountInput.min = "0";
                        hostCountInput.className = "sizing-hostcount-input";
                        hostCountInput.dataset.componentKey = componentKey;
                        hostCountInput.placeholder = "Host count (suggested)";
                        hostCountInput.title = "A suggestion based on live detection - adjust if you expect to grow.";
                        hostCountInput.style.width = "150px";
                        hostCountInput.addEventListener("input", VcfCheckUI._sizing.scheduleSizingComponentEstimate);
                        row.appendChild(hostCountInput);

                        var vmCountInput = document.createElement("input");
                        vmCountInput.type = "number";
                        vmCountInput.min = "0";
                        vmCountInput.className = "sizing-vmcount-input";
                        vmCountInput.dataset.componentKey = componentKey;
                        vmCountInput.placeholder = "VM count (suggested)";
                        vmCountInput.title = "A suggestion based on live detection - adjust if you expect to grow.";
                        vmCountInput.style.width = "150px";
                        vmCountInput.addEventListener("input", VcfCheckUI._sizing.scheduleSizingComponentEstimate);
                        row.appendChild(vmCountInput);

                        var select = document.createElement("select");
                        select.className = "sizing-size-select";
                        select.dataset.componentKey = componentKey;
                        select.classList.add("hidden");
                        select.addEventListener("change", VcfCheckUI._sizing.scheduleSizingComponentEstimate);
                        sizeOptions.forEach(function (sizeKey, sizeIndex) {
                            var option = document.createElement("option");
                            option.value = sizeKey;
                            option.dataset.sizeIndex = String(sizeIndex);
                            option.textContent = VcfCheckUI._sizing.humanizeSizingSizeKey(sizeKey);
                            select.appendChild(option);
                        });
                        row.appendChild(select);

                        var customSizedLabel = document.createElement("label");
                        var customSizedCheckbox = document.createElement("input");
                        customSizedCheckbox.type = "checkbox";
                        customSizedCheckbox.className = "sizing-customsized-checkbox";
                        customSizedCheckbox.dataset.componentKey = componentKey;
                        customSizedCheckbox.title = "Choose a size yourself instead of deriving it from the host/VM counts.";
                        customSizedCheckbox.addEventListener("change", function () {
                            select.classList.toggle("hidden", !customSizedCheckbox.checked);
                            VcfCheckUI._sizing.scheduleSizingComponentEstimate();
                        });
                        customSizedLabel.appendChild(customSizedCheckbox);
                        customSizedLabel.appendChild(document.createTextNode(" Custom sized"));
                        row.appendChild(customSizedLabel);
                    } else if (sizeOptions.length === 1) {
                        var fixedSizeLabel = document.createElement("span");
                        fixedSizeLabel.className = "sizing-size-fixed";
                        fixedSizeLabel.dataset.componentKey = componentKey;
                        fixedSizeLabel.dataset.sizeKey = sizeOptions[0];
                        fixedSizeLabel.textContent = VcfCheckUI._sizing.humanizeSizingSizeKey(sizeOptions[0]);
                        row.appendChild(fixedSizeLabel);
                    } else {
                        var select = document.createElement("select");
                        select.className = "sizing-size-select";
                        select.dataset.componentKey = componentKey;
                        select.addEventListener("change", VcfCheckUI._sizing.scheduleSizingComponentEstimate);
                        sizeOptions.forEach(function (sizeKey) {
                            var option = document.createElement("option");
                            option.value = sizeKey;
                            option.textContent = VcfCheckUI._sizing.humanizeSizingSizeKey(sizeKey);
                            select.appendChild(option);
                        });
                        row.appendChild(select);
                    }
                }

                if (componentInfo.detection) {
                    row.dataset.detectionCheckId = componentInfo.detection.checkId || "";
                    checkbox.classList.add("sizing-detection-checkbox");
                }

                rowsContainer.appendChild(row);
            });
        }).catch(function (error) {
            rowsContainer.innerHTML = "";
            var errorDiv = document.createElement("div");
            errorDiv.className = "chk-count";
            errorDiv.textContent = "Could not load sizing options: " + error;
            rowsContainer.appendChild(errorDiv);
        });
    }

    VcfCheckUI._sizing.sizingComponentEstimateDebounce = null;

    VcfCheckUI._sizing.scheduleSizingComponentEstimate = function () {
        if (VcfCheckUI._sizing.sizingComponentEstimateDebounce) {
            clearTimeout(VcfCheckUI._sizing.sizingComponentEstimateDebounce);
        }
        VcfCheckUI._sizing.sizingComponentEstimateDebounce = setTimeout(VcfCheckUI._sizing.refreshSizingComponentEstimate, 300);
    }

    // Mirrors the per-domain applyDomainSelection pattern in VcfCheckUI._sizing.renderSizingPlatformServicesStep,
    // but the vCPU/RAM/disk for host/VM-count-derived components can only be computed server-side,
    // so this calls /api/sizing/estimate and feeds the result into the shared running-total sidebar
    // instead of computing sizes locally.
    VcfCheckUI._sizing.refreshSizingComponentEstimate = function () {
        var errorBox = document.getElementById("sizing-error");
        errorBox.textContent = "";

        var allComponentKeys = [];
        var selections = [];
        document.querySelectorAll(".sizing-include-checkbox").forEach(function (checkbox) {
            var componentKey = checkbox.dataset.componentKey;
            allComponentKeys.push(componentKey);
            if (!checkbox.checked) {
                return;
            }
            var customSizedCheckbox = document.querySelector(".sizing-customsized-checkbox[data-component-key=\"" + componentKey + "\"]");
            if (customSizedCheckbox && !customSizedCheckbox.checked) {
                var hostCountInput = document.querySelector(".sizing-hostcount-input[data-component-key=\"" + componentKey + "\"]");
                var vmCountInput = document.querySelector(".sizing-vmcount-input[data-component-key=\"" + componentKey + "\"]");
                selections.push({
                    ComponentKey: componentKey,
                    HostCount: parseInt(hostCountInput.value, 10) || 0,
                    VirtualMachineCount: parseInt(vmCountInput.value, 10) || 0
                });
                return;
            }
            var select = document.querySelector(".sizing-size-select[data-component-key=\"" + componentKey + "\"]");
            var fixedSizeLabel = document.querySelector(".sizing-size-fixed[data-component-key=\"" + componentKey + "\"]");
            var sizeKey = select ? select.value : (fixedSizeLabel ? fixedSizeLabel.dataset.sizeKey : "");
            selections.push({ ComponentKey: componentKey, SizeKey: sizeKey });
        });

        var includedKeys = selections.map(function (selection) { return selection.ComponentKey; });
        allComponentKeys.forEach(function (componentKey) {
            if (includedKeys.indexOf(componentKey) === -1) {
                VcfCheckUI._sizing.clearSizingSelection(componentKey);
                delete VcfCheckUI._sizing.sizingMoreGenericRows[componentKey];
            }
        });
        VcfCheckUI._sizing.renderSizingMoreBreakdown();

        if (selections.length === 0) {
            return;
        }

        fetch("/api/sizing/estimate", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ selections: selections })
        }).then(function (response) {
            return response.json().then(function (data) {
                if (!response.ok) {
                    throw new Error(data.error || "Sizing estimate failed");
                }
                return data;
            });
        }).then(function (estimate) {
            (estimate.Components || []).forEach(function (row) {
                var displayName = VcfCheckUI._sizing.humanizeSizingComponentKey(row.ComponentKey);
                var selection = selections.filter(function (s) { return s.ComponentKey === row.ComponentKey; })[0];
                VcfCheckUI._sizing.setSizingSelection(row.ComponentKey, displayName, row.VCpu, row.MemoryGb, row.StorageGb, false, undefined, undefined, undefined,
                    selection && selection.SizeKey ? VcfCheckUI._sizing.humanizeSizingSizeKey(selection.SizeKey) + " size" : "");
                VcfCheckUI._sizing.sizingMoreGenericRows[row.ComponentKey] = [displayName, row.VCpu, row.MemoryGb, row.StorageGb];
            });
            VcfCheckUI._sizing.renderSizingMoreBreakdown();
        }).catch(function (error) {
            errorBox.textContent = error.message || String(error);
        });
    }

    VcfCheckUI.renderSizingEnvironmentSelect = function () {
        var select = document.getElementById("sizing-detect-environment");
        var previousValue = select.value;
        select.innerHTML = "";
        VcfCheckUI.environments.slice().sort(function (a, b) {
            return a.name.localeCompare(b.name);
        }).forEach(function (environment) {
            var option = document.createElement("option");
            option.value = environment.id;
            option.textContent = environment.name;
            select.appendChild(option);
        });
        if (previousValue) {
            select.value = previousValue;
        }
        if (select.value !== previousValue) {
            VcfCheckUI._sizing.sizingEnvironmentEvaluated = false;
            VcfCheckUI._sizing.sizingMaxStepReached = 0;
        }
        VcfCheckUI._sizing.updateSizingGateState();
        VcfCheckUI._sizing.updateSizingDetectPasswordLabel();
    }

    VcfCheckUI._sizing.sizingDetectPasswordField = VcfCheckUI.buildPasswordField("sizing-detect-password", "Password");
    VcfCheckUI._sizing.sizingDetectPasswordField.style.minWidth = "160px";
    document.getElementById("sizing-detect-password-wrap").appendChild(VcfCheckUI._sizing.sizingDetectPasswordField);

    VcfCheckUI._sizing.updateSizingDetectPasswordLabel = function () {
        var environmentId = document.getElementById("sizing-detect-environment").value;
        var environment = VcfCheckUI.environments.filter(function (e) { return e.id === environmentId; })[0];
        var label = VcfCheckUI._sizing.sizingDetectPasswordField.querySelector("label");
        if (label) {
            label.textContent = environment ? "Password for User " + environment.sddcManagerUser : "Password";
        }
    }

    // The detected current tier is only a floor driven by today's live host/VM count, not a hard
    // minimum - the destination vCenter size is a free choice, so this only pre-selects the
    // detected tier as a sensible default rather than disabling anything smaller.
    VcfCheckUI._sizing.applyDetectedVCenterSizeTier = function (data) {
        if (!data.currentSizeTier) {
            return;
        }
        document.querySelectorAll(".sizing-size-select[data-component-key]").forEach(function (select) {
            if (!select.classList.contains("sizing-size-select") || select.closest === undefined) {
                return;
            }
            var isVCenterSelect = document.querySelector(".sizing-hostcount-input[data-component-key=\"" + select.dataset.componentKey + "\"]");
            if (!isVCenterSelect) {
                return;
            }
            var currentTierOption = select.querySelector("option[value=\"" + data.currentSizeTier.toLowerCase() + "\"]");
            if (currentTierOption) {
                select.value = currentTierOption.value;
            }
        });
    }

    VcfCheckUI._sizing.detectSizingValues = function () {
        var errorBox = document.getElementById("sizing-detect-error");
        var environmentId = document.getElementById("sizing-detect-environment").value;
        var password = document.getElementById("sizing-detect-password").value;
        errorBox.textContent = "";

        if (!environmentId) {
            errorBox.textContent = "Add an Environment first to use live auto-detection.";
            return;
        }
        if (!password) {
            errorBox.textContent = "Enter the Environment's password to auto-detect.";
            return;
        }

        var detectButton = document.getElementById("sizing-detect-button");
        var statusBox = document.getElementById("sizing-detect-status");
        detectButton.disabled = true;
        detectButton.classList.add("running");
        statusBox.classList.add("hidden");
        var detectStartTime = Date.now();
        var detectTimer = setInterval(function () {
            var runningSeconds = ((Date.now() - detectStartTime) / 1000).toFixed(1);
            detectButton.textContent = "Scanning... (" + runningSeconds + "s)";
        }, 100);

        fetch("/api/sizing/detect", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ environmentId: environmentId, password: password })
        }).then(function (response) {
            return response.json().then(function (data) {
                if (!response.ok) {
                    throw new Error(data.error || "Sizing detection failed");
                }
                return data;
            });
        }).then(function (data) {
            VcfCheckUI._sizing.sizingEnvironmentEvaluated = true;
            VcfCheckUI._sizing.sizingEnvironmentId = environmentId;
            VcfCheckUI._sizing.sizingDetectedData = data;
            VcfCheckUI._sizing.updateSizingGateState();
            VcfCheckUI._sizing.renderSizingStepper();
            var managementSnapshot = data.managementDomainVCenter || {};
            VcfCheckUI._sizing.loadSizingOptions().then(function () {
                document.querySelectorAll(".sizing-hostcount-input").forEach(function (input) {
                    input.value = managementSnapshot.hostCount;
                });
                document.querySelectorAll(".sizing-vmcount-input").forEach(function (input) {
                    input.value = managementSnapshot.virtualMachineCount;
                });
                document.querySelectorAll(".sizing-detection-checkbox").forEach(function (checkbox) {
                    checkbox.checked = !!managementSnapshot.supervisorPresent;
                });
                VcfCheckUI._sizing.applyDetectedVCenterSizeTier(managementSnapshot);
                VcfCheckUI._sizing.scheduleSizingComponentEstimate();
            });
            var elapsedSeconds = ((Date.now() - detectStartTime) / 1000).toFixed(1);
            statusBox.textContent = "Scan completed in " + elapsedSeconds + "s";
            statusBox.classList.remove("hidden");
        }).catch(function (error) {
            errorBox.textContent = error.message || String(error);
        }).finally(function () {
            clearInterval(detectTimer);
            detectButton.classList.remove("running");
            detectButton.textContent = "Scan";
            if (!VcfCheckUI._sizing.sizingEnvironmentEvaluated) {
                detectButton.disabled = false;
            }
        });
    }

    document.getElementById("sizing-card-header").addEventListener("click", function () {
        document.getElementById("sizing-card").classList.toggle("collapsed");
    });
    document.getElementById("sizingCancelButton").addEventListener("click", function () {
        var message = VcfCheckUI._sizing.sizingHasUnsavedEstimate()
            ? "You haven't saved this resource estimate. Are you sure you want to cancel without saving?"
            : "Cancel this estimate? Your progress will be lost.";
        if (window.confirm(message)) {
            VcfCheckUI._sizing.resetSizingWizard();
        }
    });
    window.addEventListener("beforeunload", function (event) {
        if (!VcfCheckUI._sizing.sizingHasUnsavedEstimate()) {
            return;
        }
        event.preventDefault();
        event.returnValue = "";
    });
    document.getElementById("sizing-detect-button").addEventListener("click", VcfCheckUI._sizing.detectSizingValues);
    document.getElementById("sizing-detect-environment").addEventListener("change", function () {
        VcfCheckUI._sizing.sizingEnvironmentEvaluated = false;
        VcfCheckUI._sizing.sizingMaxStepReached = 0;
        document.getElementById("sizing-detect-button").disabled = false;
        document.getElementById("sizing-detect-status").classList.add("hidden");
        VcfCheckUI._sizing.updateSizingGateState();
        VcfCheckUI._sizing.renderSizingStepper();
        VcfCheckUI._sizing.updateSizingDetectPasswordLabel();
    });
    document.getElementById("sizingNextButton").addEventListener("click", function () {
        VcfCheckUI._sizing.showSizingStep(Math.min(VcfCheckUI._sizing.sizingStepIndex + 1, VcfCheckUI._sizing.SIZING_STEPS.length - 1));
    });
    document.getElementById("sizingBackButton").addEventListener("click", function () {
        VcfCheckUI._sizing.showSizingStep(Math.max(VcfCheckUI._sizing.sizingStepIndex - 1, 0));
    });
    VcfCheckUI._sizing.updateSizingGateState();
    VcfCheckUI._sizing.renderSizingStepper();
    VcfCheckUI._sizing.showSizingStep(0);


})();
