"use strict";

(function () {
    // ---- Environments: Settings & Environments card (list/add/edit/delete) ----

    document.getElementById("environments-card-header").addEventListener("click", function () {
        document.getElementById("environments-card").classList.toggle("collapsed");
    });

    document.getElementById("live-log-header").addEventListener("click", function (event) {
        if (event.target.closest("#live-log-copy-button")) {
            return;
        }
        document.getElementById("live-log-wrap").classList.toggle("collapsed");
    });

    document.getElementById("live-log-copy-button").addEventListener("click", function (event) {
        event.stopPropagation();
        var button = this;
        navigator.clipboard.writeText(VcfCheckUI.liveLogRawText).then(function () {
            var original = button.textContent;
            button.textContent = "Copied";
            setTimeout(function () { button.textContent = original; }, 1800);
        });
    });

    VcfCheckUI.loadEnvironments = function () {
        return VcfCheckUI.fetchJson("/api/environments").then(function (data) {
            VcfCheckUI.environments = data.environments || [];
            renderEnvironmentList();
            VcfCheckUI.renderRunScanEnvironmentList();
            VcfCheckUI.renderSizingEnvironmentSelect();
            updateEnvironmentsEmptyState();
        });
    }

    VcfCheckUI.applyInitialEnvironmentsCardState = function () {
        document.getElementById("environments-card").classList.toggle("collapsed", VcfCheckUI.environments.length > 0);
    }

    function updateEnvironmentsEmptyState() {
        var isEmpty = VcfCheckUI.environments.length === 0;
        document.getElementById("environments-card-hint").textContent = isEmpty
            ? "Start here: add at least one VCF 5.2.x environment, then configure optional scan settings"
            : "Expand to add or modify environments, or configure optional scan settings";
        document.getElementById("add-environment-button").classList.toggle("hidden", isEmpty);
        document.getElementById("environment-search-row").classList.toggle("hidden", isEmpty);
        // With no environments yet, the Add form is shown in place of the button that would
        // otherwise open it, and there's no other environment view to "cancel" back to.
        document.getElementById("env-form-cancel-button").classList.toggle("hidden", isEmpty);
        if (isEmpty) {
            openEnvironmentForm(null);
        } else if (!VcfCheckUI.editingEnvironmentId) {
            closeEnvironmentForm();
        }
    }

    function environmentMatchesSearch(environment, term) {
        if (!term) return true;
        var haystack = (environment.name + " " + environment.sddcManagerFqdn).toLowerCase();
        return haystack.indexOf(term) !== -1;
    }

    function renderEnvironmentList() {
        var container = document.getElementById("environment-list");
        var term = document.getElementById("environment-search-input").value.trim().toLowerCase();
        container.innerHTML = "";

        var visible = VcfCheckUI.environments.filter(function (env) { return environmentMatchesSearch(env, term); });
        if (visible.length === 0) {
            container.appendChild(VcfCheckUI.el("div", VcfCheckUI.environments.length === 0 ? "empty-state-callout" : "checkbox-group-empty", VcfCheckUI.environments.length === 0 ? "↓ Add at least one VCF 5.2.x environment below to get started." : "No environments match your search."));
            return;
        }

        visible.slice().sort(function (a, b) { return a.name.localeCompare(b.name); }).forEach(function (environment) {
            var row = VcfCheckUI.el("div", "env-row");
            var header = VcfCheckUI.el("div", "env-row-header");

            var chevron = document.createElement("button");
            chevron.type = "button";
            chevron.className = "env-chevron";
            chevron.textContent = "▶";
            header.appendChild(chevron);

            header.appendChild(VcfCheckUI.el("span", "env-name", environment.name));
            if (environment.enableRootCredentialChecks) {
                var rootBadge = VcfCheckUI.el("span", "env-badge", "GuestOS checks enabled");
                rootBadge.setAttribute("data-tooltip", "These checks rely on VMware Tools and user-provided credentials to collect internal system details not exposed by the native vSphere API. They do not utilize SSH.");
                header.appendChild(rootBadge);
            }

            var actions = VcfCheckUI.el("div", "env-row-actions");
            var editButton = document.createElement("button");
            editButton.type = "button";
            editButton.className = "env-edit-btn";
            editButton.textContent = "Edit";
            editButton.addEventListener("click", function () { openEnvironmentForm(environment); });
            var deleteButton = document.createElement("button");
            deleteButton.type = "button";
            deleteButton.className = "danger";
            deleteButton.textContent = "Delete";
            deleteButton.addEventListener("click", function () { deleteEnvironment(environment); });
            actions.appendChild(editButton);
            actions.appendChild(deleteButton);
            header.appendChild(actions);

            var detail = VcfCheckUI.el("div", "env-row-detail");
            var columns = VcfCheckUI.el("div", "env-row-detail-columns");

            var mainCol = VcfCheckUI.el("dl", "env-row-detail-col");
            mainCol.appendChild(VcfCheckUI.el("dt", null, "SDDC Manager FQDN"));
            mainCol.appendChild(VcfCheckUI.el("dd", null, environment.sddcManagerFqdn));
            mainCol.appendChild(VcfCheckUI.el("dt", null, "Username"));
            mainCol.appendChild(VcfCheckUI.el("dd", null, environment.sddcManagerUser));
            var guestOsChecksDt = VcfCheckUI.el("dt", null, "GuestOS-based checks");
            var guestOsChecksInfoIcon = VcfCheckUI.el("span", "result-info-icon");
            VcfCheckUI.setInlineSvg(guestOsChecksInfoIcon, VcfCheckUI._INFO_ICON);
            guestOsChecksInfoIcon.setAttribute("tabindex", "0");
            guestOsChecksInfoIcon.setAttribute("data-tooltip", "These checks rely on VMware Tools and user-provided credentials to collect internal system details not exposed by the native vSphere API. They do not utilize SSH.");
            guestOsChecksDt.appendChild(guestOsChecksInfoIcon);
            mainCol.appendChild(guestOsChecksDt);
            mainCol.appendChild(VcfCheckUI.el("dd", null, environment.enableRootCredentialChecks ? "Enabled" : "Disabled"));
            columns.appendChild(mainCol);

            var integrations = environment.integrations || [];
            if (integrations.length > 0) {
                var componentsCol = VcfCheckUI.el("dl", "env-row-detail-col");
                var componentsDt = VcfCheckUI.el("dt", null, "Aria Components");
                var componentsInfoIcon = VcfCheckUI.el("span", "result-info-icon");
                VcfCheckUI.setInlineSvg(componentsInfoIcon, VcfCheckUI._INFO_ICON);
                componentsInfoIcon.setAttribute("tabindex", "0");
                componentsInfoIcon.setAttribute("data-tooltip", "Checked directly against each component's own API, independent of vRSLCM - whether or not that component is managed by vRSLCM, or vRSLCM is deployed at all.");
                componentsDt.appendChild(componentsInfoIcon);
                componentsCol.appendChild(componentsDt);
                integrations.forEach(function (integration) {
                    var typeLabel = integrationTypeDisplayName(integration.type);
                    (integration.endpoints || []).forEach(function (endpoint) {
                        var label = typeLabel + (endpoint.name ? " – " + endpoint.name : "") + " (" + endpoint.fqdn + ")";
                        componentsCol.appendChild(VcfCheckUI.el("dd", null, label));
                    });
                });
                columns.appendChild(componentsCol);
            }

            detail.appendChild(columns);

            chevron.addEventListener("click", function () {
                chevron.classList.toggle("open");
                detail.classList.toggle("open");
            });

            row.appendChild(header);
            row.appendChild(detail);
            container.appendChild(row);
        });
    }

    document.getElementById("environment-search-input").addEventListener("input", renderEnvironmentList);
    document.getElementById("clear-environment-search-button").addEventListener("click", function () {
        document.getElementById("environment-search-input").value = "";
        renderEnvironmentList();
    });

    // In-memory working copy of the environment being added/edited's Integrations list - kept
    // separate from VcfCheckUI.environments (the saved/rendered list) so edits in the form don't
    // take effect until Save. Re-rendered from scratch on every change (add/remove
    // integration/endpoint, toggle sharedCredentials) rather than patched incrementally - the
    // nested structure (integration -> endpoints) makes incremental DOM patching error-prone for
    // little benefit at this list size.
    var formIntegrations = [];

    // Aria guestOS checks piggyback on the environment-wide "Enable Component
    // GuestOS-based checks" checkbox (env-form-root-checks) rather than a separate per-component
    // opt-in - GuestOS checks are all-or-nothing for the environment. These three hold the single
    // shared-vCenter choice presented once above the component list; on Save their values are
    // copied onto every integration's own enableGuestOsChecks/ariaVCenterSharedAcrossEndpoints/
    // ariaVCenterFqdn/ariaVCenterUsername fields, which is what Get-VcfCheckEnvironmentAria*Endpoints
    // (AriaOpsHelpers.ps1 / AriaAutomationHelpers.ps1 / AriaOpsForLogsHelpers.ps1) still reads.
    var formAriaVCenterShared = true;
    var formAriaVCenterFqdn = "";
    var formAriaVCenterUsername = "";

    var INTEGRATION_TYPE_DISPLAY_NAMES = {
        AriaOperations: "Aria Operations",
        AriaAutomation: "Aria Automation",
        AriaOpsForLogs: "Aria Operations for Logs"
    };

    function integrationTypeDisplayName(type) {
        return INTEGRATION_TYPE_DISPLAY_NAMES[type] || type;
    }
    VcfCheckUI.integrationTypeDisplayName = integrationTypeDisplayName;

    // TEST-EXTRACT-ARIAGUESTOSVMNAMESERROR-START
    var VM_NAME_COUNT_RULES = {
        AriaAutomation: {
            allowedCounts: [1, 3],
            tooltip: "Enter the name(s), as they exist in the vCenter inventory, of the one or three VMs that make up the Aria Automation deployment."
        },
        AriaOperations: {
            min: 1,
            max: 16,
            tooltip: "Enter the name(s), as they exist in the vCenter inventory, of the one to 16 VMs that make up the Aria Operations deployment."
        },
        AriaOpsForLogs: {
            min: 1,
            max: 18,
            tooltip: "Enter the name(s), as they exist in the vCenter inventory, of the one to 18 VMs that make up the Aria Operations for Logs deployment."
        }
    };

    // A blank VM Name(s) field is not merely a validation nicety - the guestOS checks never guess a
    // VM name from the appliance's FQDN (see e.g. Test-VcfAriaOpsSshServerStatus.ps1's "VM name(s)
    // not configured" Skip result), since a wrong guess could silently check only one node of a
    // multi-node deployment and misreport a false Pass. Left blank, the checks are simply skipped
    // with no feedback until the user notices a missing result, so count 0 is treated as an error
    // here rather than skipped like other counts.
    function vmNameCountError(integrationType, vmNames) {
        var rule = VM_NAME_COUNT_RULES[integrationType];
        if (!rule) {
            return "";
        }
        var count = vmNames.length;
        if (count === 0) {
            return "Enter at least one VM name - left blank, guestOS checks for this component will be skipped rather than guessed at.";
        }
        if (rule.allowedCounts) {
            if (rule.allowedCounts.indexOf(count) === -1) {
                return "Enter " + rule.allowedCounts.join(" or ") + " VM name(s), separated by commas.";
            }
            return "";
        }
        if (count < rule.min || count > rule.max) {
            return "Enter between " + rule.min + " and " + rule.max + " VM name(s), separated by commas.";
        }
        return "";
    }

    // Returns an error message, or "" when every endpoint with guestOS checks enabled has a valid
    // VM Name(s) count. Called from the Save handler alongside ariaGuestOsVCenterError so a blank
    // or malformed VM Name(s) field blocks Save the same way a blank vCenter FQDN/username does,
    // instead of only showing an inline hint a user could miss.
    function ariaGuestOsVmNamesError(guestOsEnabled, integrations) {
        if (!guestOsEnabled) return "";
        for (var i = 0; i < (integrations || []).length; i++) {
            var integration = integrations[i];
            var endpoints = integration.endpoints || [];
            for (var j = 0; j < endpoints.length; j++) {
                var endpoint = endpoints[j];
                var error = vmNameCountError(integration.type, endpoint.vmNames || []);
                if (error) {
                    return (endpoint.name || integration.type) + ": " + error;
                }
            }
        }
        return "";
    }
    // TEST-EXTRACT-ARIAGUESTOSVMNAMESERROR-END

    // TEST-EXTRACT-ARIAGUESTOSVCENTERERROR-START
    // Returns an error message, or "" when the guestOS-check vCenter configuration is complete
    // enough to save. A missing FQDN/username here does not fail server-side validation (see
    // _validate_integrations's docstring in vcfcheck_server/environments.py) - it only causes that
    // component's guestOS checks to be silently skipped at scan time, which is confusing UX (the
    // Run Scan screen renders a credential row labeled "Aria Components vCenter ()"). Blocking the
    // save here catches the gap before it reaches Run Scan instead of after.
    function ariaGuestOsVCenterError(guestOsEnabled, shared, sharedFqdn, sharedUsername, integrations) {
        if (!guestOsEnabled) return "";
        if ((integrations || []).length === 0) return "";
        if (shared) {
            if (!String(sharedFqdn || "").trim() || !String(sharedUsername || "").trim()) {
                return "Enter the Aria Components vCenter FQDN and username, or disable \"Component GuestOS-based checks\".";
            }
            return "";
        }
        for (var i = 0; i < (integrations || []).length; i++) {
            var endpoints = integrations[i].endpoints || [];
            for (var j = 0; j < endpoints.length; j++) {
                var endpoint = endpoints[j];
                if (!String(endpoint.vCenterFqdn || "").trim() || !String(endpoint.vCenterUsername || "").trim()) {
                    return "Enter the vCenter FQDN and username for \"" + (endpoint.name || integrations[i].type) + "\", or disable \"Component GuestOS-based checks\".";
                }
            }
        }
        return "";
    }
    // TEST-EXTRACT-ARIAGUESTOSVCENTERERROR-END

    function renderAriaGuestOsControls() {
        var container = document.getElementById("env-form-aria-guestos-controls");
        container.innerHTML = "";

        var guestOsEnabled = document.getElementById("env-form-root-checks").checked;
        if (!guestOsEnabled) {
            container.appendChild(VcfCheckUI.el("div", "chk-count", "Enable \"Component GuestOS-based checks\" above to also run guestOS checks against Aria components' vCenters."));
            return;
        }
        if (formIntegrations.length === 0) {
            container.appendChild(VcfCheckUI.el("div", "chk-count", "Add an Aria component below to configure the vCenter used for its guestOS checks."));
            return;
        }

        var sharedRow = VcfCheckUI.el("div", "checkbox-row");
        sharedRow.style.marginBottom = "10px";
        var sharedCheckbox = document.createElement("input");
        sharedCheckbox.type = "checkbox";
        sharedCheckbox.checked = formAriaVCenterShared;
        sharedCheckbox.addEventListener("change", function () {
            formAriaVCenterShared = sharedCheckbox.checked;
            renderAriaGuestOsControls();
            renderIntegrationsEditor();
        });
        var sharedLabel = document.createElement("label");
        sharedLabel.textContent = "All Aria components share the same vCenter";
        sharedLabel.style.color = "var(--text)";
        sharedLabel.style.fontSize = "13px";
        sharedRow.appendChild(sharedCheckbox);
        sharedRow.appendChild(sharedLabel);
        container.appendChild(sharedRow);

        if (formAriaVCenterShared) {
            var sharedVCenterRow = VcfCheckUI.el("div", "launcher-row integration-endpoint-row");

            var sharedFqdnField = VcfCheckUI.el("div", "field");
            var sharedFqdnLabel = document.createElement("label");
            sharedFqdnLabel.textContent = "vCenter FQDN";
            sharedFqdnLabel.textContent += " *";
            var sharedFqdnInput = document.createElement("input");
            sharedFqdnInput.type = "text";
            sharedFqdnInput.spellcheck = false;
            sharedFqdnInput.autocapitalize = "none";
            sharedFqdnInput.value = formAriaVCenterFqdn;
            sharedFqdnInput.classList.toggle("field-input-invalid", !formAriaVCenterFqdn.trim());
            sharedFqdnInput.addEventListener("input", VcfCheckUI.validateFqdnInput);
            sharedFqdnInput.addEventListener("input", function () {
                formAriaVCenterFqdn = sharedFqdnInput.value;
                sharedFqdnInput.classList.toggle("field-input-invalid", !formAriaVCenterFqdn.trim());
            });
            sharedFqdnField.appendChild(sharedFqdnLabel);
            sharedFqdnField.appendChild(sharedFqdnInput);
            sharedVCenterRow.appendChild(sharedFqdnField);

            var sharedUsernameField = VcfCheckUI.el("div", "field");
            var sharedUsernameLabel = document.createElement("label");
            sharedUsernameLabel.textContent = "vCenter Username *";
            var sharedUsernameInput = document.createElement("input");
            sharedUsernameInput.type = "text";
            sharedUsernameInput.value = formAriaVCenterUsername;
            sharedUsernameInput.classList.toggle("field-input-invalid", !formAriaVCenterUsername.trim());
            sharedUsernameInput.addEventListener("input", function () {
                formAriaVCenterUsername = sharedUsernameInput.value;
                sharedUsernameInput.classList.toggle("field-input-invalid", !formAriaVCenterUsername.trim());
            });
            sharedUsernameField.appendChild(sharedUsernameLabel);
            sharedUsernameField.appendChild(sharedUsernameInput);
            sharedVCenterRow.appendChild(sharedUsernameField);

            container.appendChild(sharedVCenterRow);
            container.appendChild(VcfCheckUI.el("div", "chk-count",
                "Both fields are required - GuestOS checks against Aria components silently skip without a vCenter to connect to."));
        }
    }

    function renderIntegrationsEditor() {
        var container = document.getElementById("env-form-integrations-list");
        container.innerHTML = "";

        var guestOsEnabled = document.getElementById("env-form-root-checks").checked;

        formIntegrations.forEach(function (integration, integrationIndex) {
            var typeDisplayName = integrationTypeDisplayName(integration.type);
            var card = VcfCheckUI.el("div", "env-row");
            var header = VcfCheckUI.el("div", "env-row-header");
            header.appendChild(VcfCheckUI.el("span", "env-name", typeDisplayName));

            var removeIntegrationButton = document.createElement("button");
            removeIntegrationButton.type = "button";
            removeIntegrationButton.className = "danger";
            removeIntegrationButton.textContent = "Remove";
            removeIntegrationButton.addEventListener("click", function () {
                formIntegrations.splice(integrationIndex, 1);
                renderAriaGuestOsControls();
                renderIntegrationsEditor();
            });
            var actions = VcfCheckUI.el("div", "env-row-actions");
            actions.appendChild(removeIntegrationButton);
            header.appendChild(actions);
            card.appendChild(header);

            var body = VcfCheckUI.el("div", "env-row-detail open");

            integration.endpoints.forEach(function (endpoint, endpointIndex) {
                var endpointRow = VcfCheckUI.el("div", "launcher-row integration-endpoint-row");

                var nameField = VcfCheckUI.el("div", "field");
                var nameLabel = document.createElement("label");
                nameLabel.textContent = "Name";
                var nameInput = document.createElement("input");
                nameInput.type = "text";
                nameInput.placeholder = "e.g. Production " + typeDisplayName;
                nameInput.value = endpoint.name || "";
                nameInput.addEventListener("input", function () { endpoint.name = nameInput.value; });
                nameField.appendChild(nameLabel);
                nameField.appendChild(nameInput);
                endpointRow.appendChild(nameField);

                var fqdnField = VcfCheckUI.el("div", "field");
                var fqdnLabel = document.createElement("label");
                fqdnLabel.textContent = typeDisplayName + " FQDN";
                var fqdnInput = document.createElement("input");
                fqdnInput.type = "text";
                fqdnInput.spellcheck = false;
                fqdnInput.autocapitalize = "none";
                fqdnInput.value = endpoint.fqdn || "";
                fqdnInput.addEventListener("input", VcfCheckUI.validateFqdnInput);
                fqdnInput.addEventListener("input", function () { endpoint.fqdn = fqdnInput.value; });
                fqdnField.appendChild(fqdnLabel);
                fqdnField.appendChild(fqdnInput);
                endpointRow.appendChild(fqdnField);

                var usernameField = VcfCheckUI.el("div", "field");
                var usernameLabel = document.createElement("label");
                usernameLabel.textContent = "Username";
                var usernameInput = document.createElement("input");
                usernameInput.type = "text";
                usernameInput.value = endpoint.username || "";
                usernameInput.addEventListener("input", function () { endpoint.username = usernameInput.value; });
                usernameField.appendChild(usernameLabel);
                usernameField.appendChild(usernameInput);
                endpointRow.appendChild(usernameField);

                if (guestOsEnabled) {
                    var vmNameRule = VM_NAME_COUNT_RULES[integration.type];
                    var vmNamesField = VcfCheckUI.el("div", "field");
                    var vmNamesLabel = document.createElement("label");
                    vmNamesLabel.textContent = "VM Name(s) *";
                    if (vmNameRule) {
                        var vmNamesInfoIcon = VcfCheckUI.el("span", "result-info-icon");
                        VcfCheckUI.setInlineSvg(vmNamesInfoIcon, VcfCheckUI._INFO_ICON);
                        vmNamesInfoIcon.setAttribute("tabindex", "0");
                        vmNamesInfoIcon.setAttribute("data-tooltip", vmNameRule.tooltip);
                        vmNamesLabel.appendChild(vmNamesInfoIcon);
                    }
                    var vmNamesInput = document.createElement("input");
                    vmNamesInput.type = "text";
                    vmNamesInput.placeholder = "e.g. vm-node-a, vm-node-b, vm-node-c";
                    vmNamesInput.value = (endpoint.vmNames || []).join(", ");
                    var vmNamesHint = VcfCheckUI.el("div", "chk-count field-hint-error");
                    vmNamesHint.textContent = vmNameCountError(integration.type, endpoint.vmNames || []);
                    vmNamesInput.addEventListener("input", function () {
                        endpoint.vmNames = vmNamesInput.value.split(",").map(function (name) { return name.trim(); }).filter(Boolean);
                        var error = vmNameCountError(integration.type, endpoint.vmNames);
                        vmNamesHint.textContent = error;
                        vmNamesInput.classList.toggle("field-input-invalid", Boolean(error));
                    });
                    vmNamesInput.classList.toggle("field-input-invalid", Boolean(vmNamesHint.textContent));
                    vmNamesField.appendChild(vmNamesLabel);
                    vmNamesField.appendChild(vmNamesInput);
                    vmNamesField.appendChild(vmNamesHint);
                    endpointRow.appendChild(vmNamesField);
                }

                if (guestOsEnabled && !formAriaVCenterShared) {
                    var endpointVCenterFqdnField = VcfCheckUI.el("div", "field");
                    var endpointVCenterFqdnLabel = document.createElement("label");
                    endpointVCenterFqdnLabel.textContent = "vCenter FQDN *";
                    var endpointVCenterFqdnInput = document.createElement("input");
                    endpointVCenterFqdnInput.type = "text";
                    endpointVCenterFqdnInput.spellcheck = false;
                    endpointVCenterFqdnInput.autocapitalize = "none";
                    endpointVCenterFqdnInput.value = endpoint.vCenterFqdn || "";
                    endpointVCenterFqdnInput.classList.toggle("field-input-invalid", !(endpoint.vCenterFqdn || "").trim());
                    endpointVCenterFqdnInput.addEventListener("input", VcfCheckUI.validateFqdnInput);
                    endpointVCenterFqdnInput.addEventListener("input", function () {
                        endpoint.vCenterFqdn = endpointVCenterFqdnInput.value;
                        endpointVCenterFqdnInput.classList.toggle("field-input-invalid", !endpoint.vCenterFqdn.trim());
                    });
                    endpointVCenterFqdnField.appendChild(endpointVCenterFqdnLabel);
                    endpointVCenterFqdnField.appendChild(endpointVCenterFqdnInput);
                    endpointRow.appendChild(endpointVCenterFqdnField);

                    var endpointVCenterUsernameField = VcfCheckUI.el("div", "field");
                    var endpointVCenterUsernameLabel = document.createElement("label");
                    endpointVCenterUsernameLabel.textContent = "vCenter Username *";
                    var endpointVCenterUsernameInput = document.createElement("input");
                    endpointVCenterUsernameInput.type = "text";
                    endpointVCenterUsernameInput.value = endpoint.vCenterUsername || "";
                    endpointVCenterUsernameInput.classList.toggle("field-input-invalid", !(endpoint.vCenterUsername || "").trim());
                    endpointVCenterUsernameInput.addEventListener("input", function () {
                        endpoint.vCenterUsername = endpointVCenterUsernameInput.value;
                        endpointVCenterUsernameInput.classList.toggle("field-input-invalid", !endpoint.vCenterUsername.trim());
                    });
                    endpointVCenterUsernameField.appendChild(endpointVCenterUsernameLabel);
                    endpointVCenterUsernameField.appendChild(endpointVCenterUsernameInput);
                    endpointRow.appendChild(endpointVCenterUsernameField);
                }

                if (integration.endpoints.length > 1) {
                    var removeEndpointButton = document.createElement("button");
                    removeEndpointButton.type = "button";
                    removeEndpointButton.className = "danger";
                    removeEndpointButton.textContent = "Remove component";
                    removeEndpointButton.addEventListener("click", function () {
                        integration.endpoints.splice(endpointIndex, 1);
                        renderIntegrationsEditor();
                    });
                    var endpointActions = VcfCheckUI.el("div", "env-row-actions");
                    endpointActions.appendChild(removeEndpointButton);
                    endpointRow.appendChild(endpointActions);
                }

                body.appendChild(endpointRow);
            });

            card.appendChild(body);
            container.appendChild(card);
        });
    }

    document.getElementById("env-form-add-integration-button").addEventListener("click", function () {
        var type = document.getElementById("env-form-integration-type-select").value;
        formIntegrations.push({
            type: type,
            endpoints: [{ name: "", fqdn: "", username: "", vmNames: [], vCenterFqdn: "", vCenterUsername: "" }]
        });
        renderIntegrationsEditor();
    });

    document.getElementById("env-form-root-checks").addEventListener("change", function () {
        renderAriaGuestOsControls();
        renderIntegrationsEditor();
    });

    function setEnvironmentFormError(message) {
        var errorEl = document.getElementById("env-form-error");
        if (message) {
            errorEl.textContent = message;
            errorEl.style.display = "block";
        } else {
            errorEl.textContent = "";
            errorEl.style.display = "none";
        }
    }

    function openEnvironmentForm(environment) {
        VcfCheckUI.editingEnvironmentId = environment ? environment.id : null;
        document.getElementById("environment-form-title").textContent = environment ? "Edit Environment" : "Add Environment";
        document.getElementById("env-form-id").value = environment ? environment.id : "";
        document.getElementById("env-form-name").value = environment ? environment.name : "";
        document.getElementById("env-form-fqdn").value = environment ? environment.sddcManagerFqdn : "";
        document.getElementById("env-form-username").value = environment ? environment.sddcManagerUser : "";
        document.getElementById("env-form-root-checks").checked = environment ? !!environment.enableRootCredentialChecks : true;
        formIntegrations = environment && environment.integrations ? JSON.parse(JSON.stringify(environment.integrations)) : [];
        formIntegrations.forEach(function (integration) {
            if (integration.sharedCredentials) {
                integration.endpoints.forEach(function (endpoint) {
                    if (!endpoint.username) endpoint.username = integration.username || "";
                });
            }
            delete integration.sharedCredentials;
            delete integration.username;
        });

        var ariaSourceIntegration = formIntegrations.filter(function (integration) { return integration.enableGuestOsChecks; })[0];
        formAriaVCenterShared = ariaSourceIntegration ? ariaSourceIntegration.ariaVCenterSharedAcrossEndpoints !== false : true;
        formAriaVCenterFqdn = (ariaSourceIntegration && ariaSourceIntegration.ariaVCenterFqdn) || "";
        formAriaVCenterUsername = (ariaSourceIntegration && ariaSourceIntegration.ariaVCenterUsername) || "";

        renderAriaGuestOsControls();
        renderIntegrationsEditor();
        setEnvironmentFormError(null);
        Array.from(document.querySelectorAll(".env-edit-btn")).forEach(function (btn) {
            btn.disabled = true;
            btn.style.opacity = "0.5";
            btn.style.cursor = "not-allowed";
        });
        document.getElementById("environment-form-wrap").classList.remove("hidden");
    }

    function closeEnvironmentForm() {
        VcfCheckUI.editingEnvironmentId = null;
        formIntegrations = [];
        Array.from(document.querySelectorAll(".env-edit-btn")).forEach(function (btn) {
            btn.disabled = false;
            btn.style.opacity = "1";
            btn.style.cursor = "pointer";
        });
        document.getElementById("environment-form-wrap").classList.add("hidden");
    }

    document.getElementById("add-environment-button").addEventListener("click", function () { openEnvironmentForm(null); });
    document.getElementById("env-form-cancel-button").addEventListener("click", closeEnvironmentForm);

    document.getElementById("env-form-save-button").addEventListener("click", function () {
        var guestOsEnabled = document.getElementById("env-form-root-checks").checked;

        var guestOsVCenterError = ariaGuestOsVCenterError(
            guestOsEnabled, formAriaVCenterShared, formAriaVCenterFqdn, formAriaVCenterUsername, formIntegrations);
        if (guestOsVCenterError) {
            setEnvironmentFormError(guestOsVCenterError);
            return;
        }

        var guestOsVmNamesError = ariaGuestOsVmNamesError(guestOsEnabled, formIntegrations);
        if (guestOsVmNamesError) {
            setEnvironmentFormError(guestOsVmNamesError);
            return;
        }

        formIntegrations.forEach(function (integration) {
            integration.enableGuestOsChecks = guestOsEnabled;
            integration.ariaVCenterSharedAcrossEndpoints = formAriaVCenterShared;
            integration.ariaVCenterFqdn = formAriaVCenterFqdn;
            integration.ariaVCenterUsername = formAriaVCenterUsername;
        });

        var body = {
            name: document.getElementById("env-form-name").value.trim(),
            sddcManagerFqdn: document.getElementById("env-form-fqdn").value.trim(),
            sddcManagerUser: document.getElementById("env-form-username").value.trim(),
            enableRootCredentialChecks: guestOsEnabled,
            integrations: formIntegrations
        };

        var request = VcfCheckUI.editingEnvironmentId
            ? VcfCheckUI.postJson("/api/environments/" + VcfCheckUI.editingEnvironmentId, body, "PUT")
            : VcfCheckUI.postJson("/api/environments", body, "POST");

        request.then(function () {
            closeEnvironmentForm();
            return VcfCheckUI.loadEnvironments();
        }).catch(function (err) {
            setEnvironmentFormError(err.message);
        });
    });

    function deleteEnvironment(environment) {
        if (!window.confirm("Delete environment \"" + environment.name + "\"? This cannot be undone.")) return;
        VcfCheckUI.deleteJson("/api/environments/" + environment.id).then(function () {
            VcfCheckUI.loadEnvironments();
        }).catch(function (err) {
            window.alert("Could not delete environment: " + err.message);
        });
    }


})();
