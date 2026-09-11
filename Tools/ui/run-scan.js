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
            previousState[row.dataset.environmentId] = {
                checked: true,
                password: row.querySelector(".rs-password") ? row.querySelector(".rs-password").value : "",
                rootPassword: row.querySelector(".rs-root-password") ? row.querySelector(".rs-root-password").value : "",
                integrationPasswords: integrationPasswords
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
                var rootBadge = VcfCheckUI.el("span", "env-badge", "Root checks");
                rootBadge.setAttribute("data-tooltip", "This environment can run checks that require the SDDC Manager appliance root/OS password, not just the admin login.");
                main.appendChild(rootBadge);
            }
            row.appendChild(main);

            var credentialsRow = VcfCheckUI.el("div", "run-scan-env-credentials hidden");
            credentialsRow.appendChild(VcfCheckUI.el("div", "run-scan-env-credentials-heading", "Enter the passwords for " + environment.name));
            var passwordField = VcfCheckUI.buildPasswordField("rs-password-" + environment.id, "Password for User " + environment.sddcManagerUser);
            passwordField.querySelector("input").classList.add("rs-password");
            credentialsRow.appendChild(passwordField);
            if (environment.enableRootCredentialChecks) {
                var rootField = VcfCheckUI.buildPasswordField("rs-root-password-" + environment.id, "SDDC Manager root password");
                rootField.querySelector("input").classList.add("rs-root-password");
                credentialsRow.appendChild(rootField);
            }
            (environment.integrations || []).forEach(function (integration, integrationIndex) {
                var typeLabel = VcfCheckUI.integrationTypeDisplayName(integration.type);
                if (integration.sharedCredentials) {
                    var sharedField = VcfCheckUI.buildPasswordField(
                        "rs-integration-password-" + environment.id + "-" + integrationIndex,
                        "Password for " + typeLabel + " user " + (integration.username || "")
                    );
                    var sharedInput = sharedField.querySelector("input");
                    sharedInput.classList.add("rs-integration-password");
                    sharedInput.dataset.integrationIndex = integrationIndex;
                    sharedInput.dataset.label = typeLabel;
                    credentialsRow.appendChild(sharedField);
                } else {
                    (integration.endpoints || []).forEach(function (endpoint, endpointIndex) {
                        var endpointField = VcfCheckUI.buildPasswordField(
                            "rs-integration-password-" + environment.id + "-" + integrationIndex + "-" + endpointIndex,
                            "Password for " + typeLabel + " (" + (endpoint.name || endpoint.fqdn) + ") user " + (endpoint.username || "")
                        );
                        var endpointInput = endpointField.querySelector("input");
                        endpointInput.classList.add("rs-integration-password");
                        endpointInput.dataset.integrationIndex = integrationIndex;
                        endpointInput.dataset.endpointIndex = endpointIndex;
                        endpointInput.dataset.label = typeLabel + " (" + (endpoint.name || endpoint.fqdn) + ")";
                        credentialsRow.appendChild(endpointField);
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

            items.push({
                environmentId: environmentId,
                password: password,
                rootPassword: rootInput ? rootInput.value : "",
                integrationCredentials: integrationCredentials
            });
        });

        if (missingPassword) {
            throw new Error("Enter a password for \"" + missingPassword + "\" before continuing.");
        }
        return items;
    }


})();
