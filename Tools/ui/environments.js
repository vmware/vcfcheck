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
                var rootBadge = VcfCheckUI.el("span", "env-badge", "Root checks");
                rootBadge.setAttribute("data-tooltip", "This environment can run checks that require the SDDC Manager appliance root/OS password, not just the admin login.");
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
            mainCol.appendChild(VcfCheckUI.el("dt", null, "Root-credential checks"));
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

    function integrationTypeDisplayName(type) {
        return type === "AriaOperations" ? "Aria Operations" : type;
    }
    VcfCheckUI.integrationTypeDisplayName = integrationTypeDisplayName;

    function renderIntegrationsEditor() {
        var container = document.getElementById("env-form-integrations-list");
        container.innerHTML = "";

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
                nameInput.placeholder = "e.g. Standalone Prod Aria Ops";
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
            endpoints: [{ name: "", fqdn: "", username: "" }]
        });
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
        var body = {
            name: document.getElementById("env-form-name").value.trim(),
            sddcManagerFqdn: document.getElementById("env-form-fqdn").value.trim(),
            sddcManagerUser: document.getElementById("env-form-username").value.trim(),
            enableRootCredentialChecks: document.getElementById("env-form-root-checks").checked,
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
