"use strict";

(function () {
    // ---- Run Scan: environment checkboxes + per-environment credential fields ----

    VcfCheckUI.renderRunScanEnvironmentList = function () {
        var container = document.getElementById("run-scan-environment-list");
        // Preserve whatever is currently checked/typed across a re-render (e.g. after adding a
        // new environment while others are already selected mid-setup).
        var previousState = {};
        Array.prototype.slice.call(container.querySelectorAll(".run-scan-env-row")).forEach(function (row) {
            var checkbox = row.querySelector("input[type=checkbox]");
            if (!checkbox || !checkbox.checked) return;
            var integrationPasswords = {};
            Array.prototype.slice.call(row.querySelectorAll(".rs-integration-password")).forEach(function (input) {
                integrationPasswords[input.id] = input.value;
            });
            var ariaVCenterPasswords = {};
            Array.prototype.slice.call(row.querySelectorAll(".rs-aria-vcenter-user-password, .rs-aria-vcenter-root-password")).forEach(function (input) {
                ariaVCenterPasswords[input.id] = input.value;
            });
            previousState[row.dataset.environmentId] = {
                checked: true,
                password: row.querySelector(".rs-password") ? row.querySelector(".rs-password").value : "",
                rootPassword: row.querySelector(".rs-root-password") ? row.querySelector(".rs-root-password").value : "",
                integrationPasswords: integrationPasswords,
                ariaVCenterPasswords: ariaVCenterPasswords
            };
        });

        document.getElementById("health-check-button").disabled = VcfCheckUI.environments.length === 0;
        VcfCheckUI.refreshDiscoverButtonState();

        container.innerHTML = "";
        if (VcfCheckUI.environments.length === 0) {
            container.appendChild(VcfCheckUI.el("div", "checkbox-group-empty", "No environments configured yet. Add one above."));
            return;
        }

        VcfCheckUI.environments.slice().sort(function (a, b) { return a.name.localeCompare(b.name); }).forEach(function (environment) {
            var row = VcfCheckUI.el("div", "run-scan-env-row");
            row.dataset.environmentId = environment.id;

            var main = VcfCheckUI.el("div", "run-scan-env-row-main");
            var checkbox = document.createElement("input");
            checkbox.type = "checkbox";
            checkbox.value = environment.id;
            main.appendChild(checkbox);
            main.appendChild(VcfCheckUI.el("span", "env-name", environment.name));
            if (environment.enableRootCredentialChecks) {
                var rootBadge = VcfCheckUI.el("span", "env-badge", "GuestOS checks enabled");
                rootBadge.setAttribute("data-tooltip", "These checks rely on VMware Tools and user-provided credentials to collect internal system details not exposed by the native vSphere API. They do not utilize SSH.");
                main.appendChild(rootBadge);
            }
            row.appendChild(main);

            var credentialsRow = VcfCheckUI.el("div", "run-scan-env-credentials hidden");
            credentialsRow.appendChild(VcfCheckUI.el("div", "run-scan-env-credentials-heading", "Enter the passwords for SDDC Manager"));

            var sddcRow = VcfCheckUI.el("div", "run-scan-sddc-row");
            var passwordField = VcfCheckUI.buildPasswordField("rs-password-" + environment.id, "Password for " + environment.sddcManagerUser);
            passwordField.querySelector("input").classList.add("rs-password");
            sddcRow.appendChild(passwordField);
            if (environment.enableRootCredentialChecks) {
                var rootField = VcfCheckUI.buildPasswordField("rs-root-password-" + environment.id, "Password for root user");
                rootField.querySelector("input").classList.add("rs-root-password");
                sddcRow.appendChild(rootField);
            }
            credentialsRow.appendChild(sddcRow);

            if ((environment.integrations || []).length > 0) {
                credentialsRow.appendChild(VcfCheckUI.el("div", "run-scan-aria-heading", "Enter the password for configured Aria Components"));
            }

            // Aria components sharing one vCenter (the common case) log into the exact same FQDN
            // with the exact same SSO account, so render that connection once above the
            // per-component fields instead of once per integration. Each component's own guestOS
            // root password stays a sibling of its service-account field below, since - unlike the
            // vCenter connection - the appliance being targeted differs per component.
            var sharedAriaVCenterGroups = {};
            var unconfiguredAriaVCenterTypes = [];
            (environment.integrations || []).forEach(function (integration, integrationIndex) {
                if (!integration.enableGuestOsChecks || !integration.ariaVCenterSharedAcrossEndpoints) return;
                var fqdn = (integration.ariaVCenterFqdn || "").trim();
                var username = (integration.ariaVCenterUsername || "").trim();
                if (!fqdn || !username) {
                    // Saved without a vCenter FQDN/username (an environment created before this field
                    // was required, or edited outside validation) - the backend silently skips this
                    // component's guestOS checks rather than failing the scan, so surface that here
                    // instead of rendering a credential row with nothing to label it.
                    unconfiguredAriaVCenterTypes.push(VcfCheckUI.integrationTypeDisplayName(integration.type));
                    return;
                }
                var groupKey = fqdn + "|" + username;
                if (!sharedAriaVCenterGroups[groupKey]) {
                    sharedAriaVCenterGroups[groupKey] = {
                        fqdn: fqdn,
                        username: username,
                        integrationIndices: []
                    };
                }
                sharedAriaVCenterGroups[groupKey].integrationIndices.push(integrationIndex);
            });
            if (unconfiguredAriaVCenterTypes.length > 0) {
                credentialsRow.appendChild(VcfCheckUI.el("div", "chk-count field-hint-error",
                    "GuestOS checks against the vCenter for " + unconfiguredAriaVCenterTypes.join(", ") +
                    " will be skipped - no vCenter FQDN/username is configured. Edit this environment to add one."));
            }
            Object.keys(sharedAriaVCenterGroups).forEach(function (groupKey, groupIndex) {
                var group = sharedAriaVCenterGroups[groupKey];
                var vCenterUserRow = VcfCheckUI.buildComponentPasswordField(
                    "rs-integration-aria-vcenter-" + environment.id + "-shared-" + groupIndex + "-user",
                    "Aria Components vCenter (" + group.fqdn + ")",
                    group.username
                );
                var vCenterUserInput = vCenterUserRow.querySelector("input");
                vCenterUserInput.classList.add("rs-aria-vcenter-user-password");
                vCenterUserInput.dataset.integrationIndices = group.integrationIndices.join(",");
                vCenterUserInput.dataset.label = "Aria Components vCenter (" + group.fqdn + ") user";
                credentialsRow.appendChild(vCenterUserRow);
            });

            (environment.integrations || []).forEach(function (integration, integrationIndex) {
                var typeLabel = VcfCheckUI.integrationTypeDisplayName(integration.type);

                function appendRootRow(componentLabel, endpointIndex) {
                    var idSuffix = endpointIndex === null ? String(integrationIndex) : integrationIndex + "-" + endpointIndex;
                    var rootRow = VcfCheckUI.buildComponentPasswordField(
                        "rs-integration-aria-vcenter-" + environment.id + "-" + idSuffix + "-root",
                        componentLabel,
                        "root"
                    );
                    var rootInput = rootRow.querySelector("input");
                    rootInput.classList.add("rs-aria-vcenter-root-password");
                    rootInput.dataset.integrationIndices = String(integrationIndex);
                    if (endpointIndex !== null) rootInput.dataset.endpointIndex = endpointIndex;
                    rootInput.dataset.label = componentLabel + " root";
                    credentialsRow.appendChild(rootRow);
                }

                if (integration.sharedCredentials) {
                    var sharedRow = VcfCheckUI.buildComponentPasswordField(
                        "rs-integration-password-" + environment.id + "-" + integrationIndex,
                        typeLabel,
                        integration.username || ""
                    );
                    var sharedInput = sharedRow.querySelector("input");
                    sharedInput.classList.add("rs-integration-password");
                    sharedInput.dataset.integrationIndex = integrationIndex;
                    sharedInput.dataset.label = typeLabel;
                    credentialsRow.appendChild(sharedRow);
                    if (integration.enableGuestOsChecks) appendRootRow(typeLabel, null);
                } else {
                    (integration.endpoints || []).forEach(function (endpoint, endpointIndex) {
                        var componentLabel = typeLabel + " (" + (endpoint.name || endpoint.fqdn) + ")";
                        var endpointRow = VcfCheckUI.buildComponentPasswordField(
                            "rs-integration-password-" + environment.id + "-" + integrationIndex + "-" + endpointIndex,
                            componentLabel,
                            endpoint.username || ""
                        );
                        var endpointInput = endpointRow.querySelector("input");
                        endpointInput.classList.add("rs-integration-password");
                        endpointInput.dataset.integrationIndex = integrationIndex;
                        endpointInput.dataset.endpointIndex = endpointIndex;
                        endpointInput.dataset.label = componentLabel;
                        credentialsRow.appendChild(endpointRow);
                        if (integration.enableGuestOsChecks) appendRootRow(componentLabel, endpointIndex);
                    });
                }

                if (integration.enableGuestOsChecks && !integration.ariaVCenterSharedAcrossEndpoints) {
                    (integration.endpoints || []).forEach(function (endpoint, endpointIndex) {
                        var endpointVCenterLabel = (endpoint.name || endpoint.fqdn) + " vCenter (" + (endpoint.vCenterFqdn || "") + ")";
                        var endpointVCenterUserRow = VcfCheckUI.buildComponentPasswordField(
                            "rs-integration-aria-vcenter-" + environment.id + "-" + integrationIndex + "-" + endpointIndex + "-user",
                            endpointVCenterLabel,
                            endpoint.vCenterUsername || ""
                        );
                        var endpointVCenterUserInput = endpointVCenterUserRow.querySelector("input");
                        endpointVCenterUserInput.classList.add("rs-aria-vcenter-user-password");
                        endpointVCenterUserInput.dataset.integrationIndices = String(integrationIndex);
                        endpointVCenterUserInput.dataset.endpointIndex = endpointIndex;
                        endpointVCenterUserInput.dataset.label = endpointVCenterLabel + " user";
                        credentialsRow.appendChild(endpointVCenterUserRow);
                    });
                }
            });
            row.appendChild(credentialsRow);

            // A password edit invalidates a prior Discover Workload Domains success even though
            // the environment selection itself hasn't changed - Run Check's skip-the-pre-flight
            // shortcut only holds while both the selection AND the credentials it validated are
            // unchanged.
            credentialsRow.addEventListener("input", function () {
                VcfCheckUI.discoveredDomainsSignature = null;
                VcfCheckUI.refreshDiscoverButtonState();
            });

            checkbox.addEventListener("change", function () {
                credentialsRow.classList.toggle("hidden", !checkbox.checked);
                VcfCheckUI.renderCheckCheckboxes();
                VcfCheckUI.refreshDiscoverButtonState();
            });

            var saved = previousState[environment.id];
            if (saved) {
                checkbox.checked = true;
                credentialsRow.classList.remove("hidden");
                var passwordInput = credentialsRow.querySelector(".rs-password");
                if (passwordInput) passwordInput.value = saved.password;
                var rootInput = credentialsRow.querySelector(".rs-root-password");
                if (rootInput) rootInput.value = saved.rootPassword;
                Array.prototype.slice.call(credentialsRow.querySelectorAll(".rs-integration-password")).forEach(function (input) {
                    if (saved.integrationPasswords && saved.integrationPasswords[input.id] !== undefined) {
                        input.value = saved.integrationPasswords[input.id];
                    }
                });
                Array.prototype.slice.call(credentialsRow.querySelectorAll(".rs-aria-vcenter-user-password, .rs-aria-vcenter-root-password")).forEach(function (input) {
                    if (saved.ariaVCenterPasswords && saved.ariaVCenterPasswords[input.id] !== undefined) {
                        input.value = saved.ariaVCenterPasswords[input.id];
                    }
                });
            }

            container.appendChild(row);
        });

        VcfCheckUI.renderCheckCheckboxes();
        VcfCheckUI.refreshDiscoverButtonState();
    }

    document.getElementById("select-all-envs-button").addEventListener("click", function () {
        Array.prototype.slice.call(document.querySelectorAll("#run-scan-environment-list input[type=checkbox]")).forEach(function (checkbox) {
            checkbox.checked = true;
            checkbox.dispatchEvent(new Event("change"));
        });
    });
    document.getElementById("clear-envs-button").addEventListener("click", function () {
        Array.prototype.slice.call(document.querySelectorAll("#run-scan-environment-list input[type=checkbox]")).forEach(function (checkbox) {
            checkbox.checked = false;
            checkbox.dispatchEvent(new Event("change"));
        });
    });

    VcfCheckUI.getSelectedEnvironmentItems = function () {
        var rows = Array.prototype.slice.call(document.querySelectorAll("#run-scan-environment-list .run-scan-env-row"));
        var items = [];
        var missingPassword = null;

        rows.forEach(function (row) {
            var checkbox = row.querySelector("input[type=checkbox]");
            if (!checkbox.checked) return;
            var environmentId = row.dataset.environmentId;
            var environment = VcfCheckUI.environments.filter(function (env) { return env.id === environmentId; })[0];
            var passwordInput = row.querySelector(".rs-password");
            var rootInput = row.querySelector(".rs-root-password");
            var password = passwordInput ? passwordInput.value : "";
            if (!password) {
                missingPassword = environment ? environment.name : environmentId;
                return;
            }

            var integrationCredentials = [];
            var integrationInputs = Array.prototype.slice.call(row.querySelectorAll(".rs-integration-password"));
            for (var i = 0; i < integrationInputs.length; i++) {
                var integrationInput = integrationInputs[i];
                if (!integrationInput.value) {
                    missingPassword = (environment ? environment.name : environmentId) + " - " + integrationInput.dataset.label;
                    return;
                }
                integrationCredentials.push({
                    integrationIndex: Number(integrationInput.dataset.integrationIndex),
                    endpointIndex: integrationInput.dataset.endpointIndex !== undefined ? Number(integrationInput.dataset.endpointIndex) : null,
                    password: integrationInput.value
                });
            }

            var ariaVCenterCredentials = [];
            var ariaUserInputs = Array.prototype.slice.call(row.querySelectorAll(".rs-aria-vcenter-user-password"));
            for (var u = 0; u < ariaUserInputs.length; u++) {
                var ariaUserInput = ariaUserInputs[u];
                if (!ariaUserInput.value) {
                    missingPassword = (environment ? environment.name : environmentId) + " - " + ariaUserInput.dataset.label;
                    return;
                }
                ariaUserInput.dataset.integrationIndices.split(",").forEach(function (integrationIndex) {
                    ariaVCenterCredentials.push({
                        integrationIndex: Number(integrationIndex),
                        endpointIndex: ariaUserInput.dataset.endpointIndex !== undefined ? Number(ariaUserInput.dataset.endpointIndex) : null,
                        credentialType: "vCenterUser",
                        password: ariaUserInput.value
                    });
                });
            }
            var ariaRootInputs = Array.prototype.slice.call(row.querySelectorAll(".rs-aria-vcenter-root-password"));
            for (var r = 0; r < ariaRootInputs.length; r++) {
                var ariaRootInput = ariaRootInputs[r];
                if (!ariaRootInput.value) {
                    missingPassword = (environment ? environment.name : environmentId) + " - " + ariaRootInput.dataset.label;
                    return;
                }
                ariaRootInput.dataset.integrationIndices.split(",").forEach(function (integrationIndex) {
                    ariaVCenterCredentials.push({
                        integrationIndex: Number(integrationIndex),
                        endpointIndex: ariaRootInput.dataset.endpointIndex !== undefined ? Number(ariaRootInput.dataset.endpointIndex) : null,
                        credentialType: "vCenterRoot",
                        password: ariaRootInput.value
                    });
                });
            }

            items.push({
                environmentId: environmentId,
                password: password,
                rootPassword: rootInput ? rootInput.value : "",
                integrationCredentials: integrationCredentials,
                ariaVCenterCredentials: ariaVCenterCredentials
            });
        });

        if (missingPassword) {
            throw new Error("Enter a password for \"" + missingPassword + "\" before continuing.");
        }
        return items;
    }


})();
