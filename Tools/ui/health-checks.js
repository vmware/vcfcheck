"use strict";

(function () {
    // ---- Health checks card (component/check picker) - unchanged from the single-environment UI ----

    var ARIA_SUBAREA_ORDER = ["Aria Operations for Logs", "Aria Operations", "Aria Automation", "Aria Suite Lifecycle Manager"];

    VcfCheckUI.loadChecks = function () {
        return VcfCheckUI.fetchJson("/api/checks").then(function (data) {
            VcfCheckUI.checksByArea = data.areas || {};
            VcfCheckUI.rootCredentialCheckIds = data.rootCredentialCheckIds || [];
            applySavedCheckDefaults();
            renderComponentCheckboxes();
        });
    }

    function totalCheckCount() {
        var count = 0;
        Object.keys(VcfCheckUI.checksByArea).forEach(function (area) {
            count += (VcfCheckUI.checksByArea[area] || []).length;
        });
        return count;
    }

    // Applies a saved "Save Defaults" selection (VcfCheckUI.savedDefaultCheckIds/savedDefaultAreaIds,
    // populated by loadSettings from /api/settings) to checkSelectionState before the first render, so
    // the UI opens with the user's customized subset instead of every check. Absent entirely (null) means
    // no defaults have ever been saved, so the full catalog stays selected as before. The hint is only
    // shown when the saved selection actually excludes checks, since selecting every check is equivalent
    // to having no saved override.
    function applySavedCheckDefaults() {
        var hint = document.getElementById("checks-card-custom-defaults-hint");
        if (!Array.isArray(VcfCheckUI.savedDefaultCheckIds)) {
            hint.classList.add("hidden");
            return;
        }

        var savedCheckIds = {};
        VcfCheckUI.savedDefaultCheckIds.forEach(function (checkId) { savedCheckIds[checkId] = true; });
        var checkCount = 0;
        var selectedCount = 0;
        Object.keys(VcfCheckUI.checksByArea).forEach(function (area) {
            (VcfCheckUI.checksByArea[area] || []).forEach(function (check) {
                var isSelected = !!savedCheckIds[check.id];
                VcfCheckUI.checkSelectionState[check.id] = isSelected;
                checkCount++;
                if (isSelected) selectedCount++;
            });
        });

        var isFullCatalog = selectedCount >= checkCount;
        hint.classList.toggle("hidden", isFullCatalog);
        if (!isFullCatalog) {
            console.info("[VcfCheck] Loaded a customized default health check selection (" + selectedCount + " of " + checkCount + " checks) instead of the full catalog.");
        }
    }

    VcfCheckUI.checkedValues = function (containerId, scopeSelector) {
        var container = document.getElementById(containerId);
        return Array.prototype.slice.call(container.querySelectorAll((scopeSelector || "") + "input[type=checkbox]:checked"))
            .map(function (input) { return input.value; });
    }

    function renderComponentCheckboxes() {
        var container = document.getElementById("component-checkboxes");
        container.innerHTML = "";
        Object.keys(VcfCheckUI.checksByArea).sort().forEach(function (area) {
            var item = VcfCheckUI.el("label", "checkbox-group-item");
            var input = document.createElement("input");
            input.type = "checkbox";
            input.value = area;
            input.checked = Array.isArray(VcfCheckUI.savedDefaultAreaIds) ? VcfCheckUI.savedDefaultAreaIds.indexOf(area) !== -1 : true;
            input.addEventListener("change", VcfCheckUI.renderCheckCheckboxes);
            item.appendChild(input);
            item.appendChild(document.createTextNode(area));
            container.appendChild(item);
        });
        VcfCheckUI.renderCheckCheckboxes();
    }

    document.getElementById("select-all-areas-button").addEventListener("click", function () {
        setAreaCheckboxesChecked(true);
    });
    document.getElementById("select-no-areas-button").addEventListener("click", function () {
        setAreaCheckboxesChecked(false);
    });

    function setAreaCheckboxesChecked(checked) {
        Array.prototype.slice.call(document.getElementById("component-checkboxes").querySelectorAll("input[type=checkbox]"))
            .forEach(function (input) { input.checked = checked; });
        if (checked) clearCheckFilters();
        VcfCheckUI.renderCheckCheckboxes();
    }

    function clearCheckFilters() {
        document.getElementById("check-search-input").value = "";
        ["select-blocking-chip", "filter-root-chip"].forEach(function (id) {
            var chip = document.getElementById(id);
            chip.classList.remove("active");
            chip.setAttribute("aria-pressed", "false");
        });
        blockingOnlySelectionState = null;
    }

    // Domain filter: unlike Component (static, loaded once from /api/checks), the domain list is
    // only known once a live SDDC Manager connection succeeds - populated from the Discover
    // Workload Domains flow's response (see the credential-check-panel wiring below), not at page load.
    VcfCheckUI.knownDomains = []; // [{name, type}], accumulated (union by name) across tested environments

    VcfCheckUI.renderDomainCheckboxes = function (domains) {
        VcfCheckUI.knownDomains = domains || [];
        var container = document.getElementById("domain-checkboxes");
        var actionsDiv = document.getElementById("domain-actions");
        container.innerHTML = "";
        if (VcfCheckUI.knownDomains.length === 0) {
            container.appendChild(VcfCheckUI.el("div", "checkbox-group-empty", "All domains are scanned by default. To choose specific ones, click <b>Discover Workload Domains</b> below to authenticate and load the list."));
            actionsDiv.style.display = "none";
            return;
        }
        actionsDiv.style.display = "inline";
        VcfCheckUI.knownDomains.slice().sort(function (a, b) { return a.name.localeCompare(b.name); }).forEach(function (domain) {
            var item = VcfCheckUI.el("label", "checkbox-group-item");
            var input = document.createElement("input");
            input.type = "checkbox";
            input.value = domain.name;
            input.checked = true;
            item.appendChild(input);
            item.appendChild(document.createTextNode(domain.name + (domain.type ? " (" + domain.type + ")" : "")));
            container.appendChild(item);
        });
    }

    document.getElementById("select-all-domains-button").addEventListener("click", function () {
        setDomainCheckboxesChecked(true);
    });
    document.getElementById("select-no-domains-button").addEventListener("click", function () {
        setDomainCheckboxesChecked(false);
    });

    function setDomainCheckboxesChecked(checked) {
        Array.prototype.slice.call(document.getElementById("domain-checkboxes").querySelectorAll("input[type=checkbox]"))
            .forEach(function (input) { input.checked = checked; });
    }

    function anyEnvironmentAllowsRootChecks() {
        return VcfCheckUI.environments.some(function (environment) { return !!(environment && environment.enableRootCredentialChecks); });
    }

    VcfCheckUI.checkSelectionState = VcfCheckUI.checkSelectionState || {};
    var blockingOnlySelectionState = null; // checkbox states captured when "Select Blocking Only Checks" is turned on, restored when turned off

    function captureCheckSelectionState() {
        Array.prototype.slice.call(
            document.getElementById("check-checkboxes").querySelectorAll(".chk-area-items input[type=checkbox]")
        ).forEach(function (input) {
            VcfCheckUI.checkSelectionState[input.value] = input.checked;
        });
    }

    VcfCheckUI.renderCheckCheckboxes = function () {
        var selectedAreas = VcfCheckUI.checkedValues("component-checkboxes");
        var container = document.getElementById("check-checkboxes");
        var allowRootChecks = anyEnvironmentAllowsRootChecks();
        var hasRootChecks = selectedAreas.some(function (area) {
            return (VcfCheckUI.checksByArea[area] || []).some(function (check) {
                return VcfCheckUI.rootCredentialCheckIds.indexOf(check.id) !== -1;
            });
        });
        var rootChecksExcluded = !allowRootChecks && hasRootChecks;
        document.getElementById("chk-root-hint").classList.toggle("hidden", !rootChecksExcluded);
        document.getElementById("checks-card-root-hint").classList.toggle("hidden", !rootChecksExcluded);
        captureCheckSelectionState();
        container.innerHTML = "";

        if (selectedAreas.length === 0) {
            container.appendChild(VcfCheckUI.el("div", "checkbox-group-empty", "No components selected."));
            updateChecksCardSummary();
            return;
        }

        selectedAreas.slice().sort().forEach(function (area) {
            var checks = VcfCheckUI.checksByArea[area] || [];
            if (checks.length === 0) return;

            var group = VcfCheckUI.el("div", "chk-area-group");
            group.dataset.area = area;
            if (VcfCheckUI.collapsedCheckAreas[area]) {
                group.classList.add("collapsed");
            }

            var header = VcfCheckUI.el("div", "chk-area-header");
            header.appendChild(VcfCheckUI.el("span", "chk-area-toggle", "▼"));
            var selectAllLabel = VcfCheckUI.el("label", "checkbox-group-item");
            var selectAllInput = document.createElement("input");
            selectAllInput.type = "checkbox";
            selectAllInput.className = "area-select-all";
            selectAllInput.addEventListener("change", function (event) {
                event.stopPropagation();
                setChecksInAreaChecked(area, selectAllInput.checked);
            });
            selectAllLabel.addEventListener("click", function (event) {
                event.stopPropagation();
            });
            selectAllLabel.appendChild(selectAllInput);
            selectAllLabel.appendChild(document.createTextNode(area));
            header.appendChild(selectAllLabel);
            header.appendChild(VcfCheckUI.el("span", "chk-area-header-count"));
            header.addEventListener("click", function () {
                var collapsed = group.classList.toggle("collapsed");
                if (collapsed) {
                    VcfCheckUI.collapsedCheckAreas[area] = true;
                } else {
                    delete VcfCheckUI.collapsedCheckAreas[area];
                }
            });
            group.appendChild(header);

            var items = VcfCheckUI.el("div", "chk-area-items");
            var isAriaSuiteArea = area === "Aria Suite";
            var lastAriaSubgroup = null;
            checks.slice().sort(function (a, b) {
                if (isAriaSuiteArea) {
                    var subAreaOrder = ARIA_SUBAREA_ORDER.indexOf(a.subArea || "") - ARIA_SUBAREA_ORDER.indexOf(b.subArea || "");
                    if (subAreaOrder !== 0) return subAreaOrder;
                }
                return (a.displayName || a.id).localeCompare(b.displayName || b.id, undefined, { sensitivity: "base" });
            }).forEach(function (check) {
                if (isAriaSuiteArea) {
                    var ariaSubgroup = check.subArea || "Aria Suite Lifecycle Manager";
                    if (ariaSubgroup !== lastAriaSubgroup) {
                        items.appendChild(VcfCheckUI.el("div", "chk-subgroup-divider", ariaSubgroup + " Checks"));
                        lastAriaSubgroup = ariaSubgroup;
                    }
                }
                var requiresRoot = VcfCheckUI.rootCredentialCheckIds.indexOf(check.id) !== -1;
                var row = VcfCheckUI.el("div", "chk-item-row");
                var item = VcfCheckUI.el("label", "checkbox-group-item");
                var input = document.createElement("input");
                input.type = "checkbox";
                input.value = check.id;
                var previouslySelected = VcfCheckUI.checkSelectionState[check.id];
                input.checked = previouslySelected !== undefined ? previouslySelected : (allowRootChecks || !requiresRoot);
                input.dataset.area = area;
                input.dataset.blocking = check.blocking ? "1" : "0";
                input.dataset.requiresRoot = requiresRoot ? "1" : "0";
                input.dataset.searchText = (check.displayName || check.id).toLowerCase() + " " + area.toLowerCase();
                input.addEventListener("change", function () {
                    VcfCheckUI.checkSelectionState[input.value] = input.checked;
                    updateChecksCardSummary();
                });
                item.appendChild(input);
                item.appendChild(document.createTextNode(check.displayName || check.id));
                if (check.blocking) {
                    var blockingTag = VcfCheckUI.el("span", "chk-tag chk-tag-blocking", "B");
                    blockingTag.title = "Blocking: a failure blocks the VCF upgrade from proceeding until resolved.";
                    item.appendChild(blockingTag);
                }
                if (requiresRoot) {
                    var rootTag = VcfCheckUI.el("span", "chk-tag chk-tag-root", "G");
                    rootTag.title = "GuestOS: executed through Invoke-VMScript using VMware Tools and user-provided credentials, not the SSO administrative user login and not SSH.";
                    item.appendChild(rootTag);
                }
                row.appendChild(item);
                if (check.description) {
                    var descriptionSpan = VcfCheckUI.el("span", "chk-item-description", check.description);
                    descriptionSpan.title = check.description;
                    row.appendChild(descriptionSpan);
                }
                items.appendChild(row);
            });
            selectAllInput.checked = Array.prototype.slice.call(items.querySelectorAll("input[type=checkbox]"))
                .every(function (input) { return input.checked; });
            group.appendChild(items);
            container.appendChild(group);
        });

        applyCheckFilter();
        updateChecksCardSummary();
    }

    function setChecksInAreaChecked(area, checked) {
        Array.prototype.slice.call(
            document.getElementById("check-checkboxes").querySelectorAll('.chk-area-items input[data-area="' + area + '"]')
        ).forEach(function (input) {
            input.checked = checked;
            VcfCheckUI.checkSelectionState[input.value] = checked;
        });
        updateChecksCardSummary();
    }

    function updateChecksCardSummary() {
        var container = document.getElementById("check-checkboxes");
        var allInputs = Array.prototype.slice.call(container.querySelectorAll(".chk-area-items input[type=checkbox]"));
        var selected = allInputs.filter(function (input) { return input.checked; }).length;
        document.getElementById("checks-card-summary").textContent = selected + "/" + allInputs.length + " selected";

        Array.prototype.slice.call(container.querySelectorAll(".chk-area-group")).forEach(function (group) {
            var groupInputs = Array.prototype.slice.call(group.querySelectorAll(".chk-area-items input[type=checkbox]"));
            var groupSelected = groupInputs.filter(function (input) { return input.checked; }).length;
            var countSpan = group.querySelector(".chk-area-header-count");
            if (countSpan) countSpan.textContent = groupSelected + "/" + groupInputs.length + " selected";
            var selectAllInput = group.querySelector(".area-select-all");
            if (selectAllInput) selectAllInput.checked = groupInputs.length > 0 && groupSelected === groupInputs.length;
        });
    }

    function applyCheckFilter() {
        var term = document.getElementById("check-search-input").value.trim().toLowerCase();
        var rootOnly = document.getElementById("filter-root-chip").classList.contains("active");
        var blockingOnly = document.getElementById("select-blocking-chip").classList.contains("active");
        var container = document.getElementById("check-checkboxes");
        var shown = 0;

        Array.prototype.slice.call(container.querySelectorAll(".chk-area-group")).forEach(function (group) {
            var groupHasVisibleRow = false;
            Array.prototype.slice.call(group.querySelectorAll(".chk-area-items .chk-item-row")).forEach(function (item) {
                var input = item.querySelector("input[type=checkbox]");
                var matchesTerm = !term || input.dataset.searchText.indexOf(term) !== -1;
                var matchesRoot = !rootOnly || input.dataset.requiresRoot === "1";
                var matchesBlocking = !blockingOnly || input.dataset.blocking === "1";
                var visible = matchesTerm && matchesRoot && matchesBlocking;
                item.classList.toggle("hidden", !visible);
                if (visible) {
                    groupHasVisibleRow = true;
                    shown++;
                }
            });
            group.classList.toggle("hidden", !groupHasVisibleRow);
        });

        document.getElementById("check-filter-count").textContent = shown + " shown";
    }

    function toggleFilterChip(chip) {
        var active = !chip.classList.contains("active");
        chip.classList.toggle("active", active);
        chip.setAttribute("aria-pressed", String(active));
        applyCheckFilter();
    }

    document.getElementById("checks-card-header").addEventListener("click", function () {
        document.getElementById("checks-card").classList.toggle("collapsed");
    });
    document.getElementById("check-search-input").addEventListener("input", applyCheckFilter);
    document.getElementById("filter-root-chip").addEventListener("click", function () { toggleFilterChip(this); });

    function toggleSelectBlockingOnly(chip) {
        var activating = !chip.classList.contains("active");
        chip.classList.toggle("active", activating);
        chip.setAttribute("aria-pressed", String(activating));

        var allowRootChecks = anyEnvironmentAllowsRootChecks();
        var checkboxes = Array.prototype.slice.call(
            document.getElementById("check-checkboxes").querySelectorAll(".chk-area-items input[type=checkbox]")
        );

        if (activating) {
            blockingOnlySelectionState = {};
            checkboxes.forEach(function (input) { blockingOnlySelectionState[input.value] = input.checked; });
            checkboxes.forEach(function (input) {
                var checked = input.dataset.blocking === "1" && (allowRootChecks || input.dataset.requiresRoot !== "1");
                input.checked = checked;
                VcfCheckUI.checkSelectionState[input.value] = checked;
            });
        } else {
            checkboxes.forEach(function (input) {
                var checked = blockingOnlySelectionState ? !!blockingOnlySelectionState[input.value] : input.checked;
                input.checked = checked;
                VcfCheckUI.checkSelectionState[input.value] = checked;
            });
            blockingOnlySelectionState = null;
        }
        applyCheckFilter();
        updateChecksCardSummary();
    }
    document.getElementById("select-blocking-chip").addEventListener("click", function () { toggleSelectBlockingOnly(this); });

    function clearFiltersAndSelectAll() {
        setAreaCheckboxesChecked(true);
        var allowRootChecks = anyEnvironmentAllowsRootChecks();
        Array.prototype.slice.call(
            document.getElementById("check-checkboxes").querySelectorAll(".chk-area-items input[type=checkbox]")
        ).forEach(function (input) {
            var checked = allowRootChecks || input.dataset.requiresRoot !== "1";
            input.checked = checked;
            VcfCheckUI.checkSelectionState[input.value] = checked;
        });
        applyCheckFilter();
        updateChecksCardSummary();
    }
    document.getElementById("clear-filters-button").addEventListener("click", clearFiltersAndSelectAll);

    function saveCheckDefaults() {
        var button = document.getElementById("save-check-defaults-button");
        var selectedAreaIds = VcfCheckUI.checkedValues("component-checkboxes");
        var selectedCheckIds = Object.keys(VcfCheckUI.checkSelectionState).filter(function (checkId) {
            return VcfCheckUI.checkSelectionState[checkId];
        });

        VcfCheckUI.postJson("/api/settings", { defaultCheckIds: selectedCheckIds, defaultAreaIds: selectedAreaIds }).then(function () {
            VcfCheckUI.savedDefaultCheckIds = selectedCheckIds;
            VcfCheckUI.savedDefaultAreaIds = selectedAreaIds;
            document.getElementById("checks-card-custom-defaults-hint").classList.toggle("hidden", selectedCheckIds.length >= totalCheckCount());
            var originalText = button.textContent;
            button.textContent = "Saved!";
            button.disabled = true;
            setTimeout(function () {
                button.textContent = originalText;
                button.disabled = false;
            }, 2000);
        }).catch(function (err) {
            VcfCheckUI.showErrorNotification(err.message || "Failed to save default health check selection.");
        });
    }
    document.getElementById("save-check-defaults-button").addEventListener("click", saveCheckDefaults);

    function restoreCheckDefaults() {
        if (!Array.isArray(VcfCheckUI.savedDefaultCheckIds)) {
            VcfCheckUI.showErrorNotification("No saved default health check selection to restore.");
            return;
        }
        applySavedCheckDefaults();
        Array.prototype.slice.call(document.getElementById("component-checkboxes").querySelectorAll("input[type=checkbox]")).forEach(function (input) {
            input.checked = Array.isArray(VcfCheckUI.savedDefaultAreaIds) ? VcfCheckUI.savedDefaultAreaIds.indexOf(input.value) !== -1 : true;
        });
        VcfCheckUI.renderCheckCheckboxes();
        applyCheckFilter();
        updateChecksCardSummary();
    }
    document.getElementById("restore-check-defaults-button").addEventListener("click", restoreCheckDefaults);

})();
