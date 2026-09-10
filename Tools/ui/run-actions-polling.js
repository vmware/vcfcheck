"use strict";

(function () {
    // ---- Run Check / Discover Workload Domains actions + live log/queue polling ----

    function setLauncherError(message) {
        var errorEl = document.getElementById("launcher-error");
        if (message) {
            errorEl.textContent = "";
            var textNode = document.createTextNode(message);
            errorEl.appendChild(textNode);

            // Add Force Clear button if the error is about a stuck run
            if (message.includes("already in progress")) {
                var button = document.createElement("button");
                button.type = "button";
                button.textContent = "Force Clear";
                button.style.marginLeft = "12px";
                button.style.padding = "4px 8px";
                button.style.fontSize = "12px";
                button.style.backgroundColor = "var(--fail)";
                button.style.color = "white";
                button.style.border = "none";
                button.style.borderRadius = "4px";
                button.style.cursor = "pointer";
                button.addEventListener("click", function () {
                    button.disabled = true;
                    button.textContent = "Clearing...";
                    VcfCheckUI.postJson("/api/run/force-clear", {})
                        .then(function () {
                            setLauncherError("Run state cleared. You can now start a new scan.");
                            setTimeout(function () {
                                setLauncherError(null);
                            }, 3000);
                        })
                        .catch(function (err) {
                            button.disabled = false;
                            button.textContent = "Force Clear";
                            setLauncherError("Force clear failed: " + err.message);
                        });
                });
                errorEl.appendChild(document.createTextNode(" "));
                errorEl.appendChild(button);
            }
            errorEl.style.display = "block";
        } else {
            errorEl.textContent = "";
            errorEl.style.display = "none";
        }
    }

    VcfCheckUI.setRunningState = function (running) {
        var button = document.getElementById("health-check-button");
        var statusBox = document.getElementById("launcher-status-box");
        button.classList.toggle("running", running);
        // Single place that owns this label - previously only the click handler's own start/
        // cancel paths set it, so a run that finished on its own (completed OR failed, e.g. an
        // unreachable SDDC Manager) left the button reading "Cancel" indefinitely even though
        // isRunning had already gone false and there was nothing left to cancel.
        button.textContent = running ? "Cancel" : "Run Check";
        if (running) {
            document.getElementById("discover-workload-domains-button").disabled = true;
        } else {
            VcfCheckUI.refreshDiscoverButtonState();
        }
        statusBox.classList.toggle("hidden", !running);
        document.getElementById("sticky-progress-bar").classList.toggle("hidden", !running);
        if (!running) {
            document.getElementById("queue-strip").classList.add("hidden");
            document.getElementById("live-log-wrap").classList.add("hidden");
        }
    }

    VcfCheckUI.renderQueueStrip = function (queue) {
        var strip = document.getElementById("queue-strip");
        strip.innerHTML = "";
        if (!queue || queue.length === 0) {
            strip.classList.add("hidden");
            return;
        }
        strip.classList.remove("hidden");
        queue.forEach(function (item) {
            var row = VcfCheckUI.el("div", "queue-item");
            row.appendChild(VcfCheckUI.el("span", "queue-item-status " + item.status, item.status));
            row.appendChild(VcfCheckUI.el("span", "queue-item-name", item.name));
            row.appendChild(VcfCheckUI.el("span", "queue-item-progress", item.completedChecks + "/" + item.totalChecks + " checks"));
            strip.appendChild(row);
        });
    }

    function appendLiveLog(text) {
        if (!text) return;
        VcfCheckUI.liveLogRawText += text;
        VcfCheckUI.renderFilteredLiveLog();
        // pollLog()'s fetch is async and can resolve after pollOnce has already called
        // setRunningState(false) for this same tick (run just completed) - without this guard,
        // that late response re-shows a stale live-log-wrap that never gets hidden again until
        // the next run's own setRunningState(true), so it sits on screen alongside the next
        // run's credential-check panel.
        if (VcfCheckUI.isRunning) {
            document.getElementById("live-log-wrap").classList.remove("hidden");
        }
    }

    function pollLog() {
        VcfCheckUI.fetchJson("/api/run/log?since=" + VcfCheckUI.logOffset).then(function (data) {
            VcfCheckUI.logOffset = data.offset || VcfCheckUI.logOffset;
            appendLiveLog(data.text);
        }).catch(function () { /* log tail is best-effort - never blocks the status poll */ });
    }

    var currentCheckName = null;
    var currentCheckStartTime = null;

    function pollOnce() {
        VcfCheckUI.fetchJson("/api/run/status").then(function (status) {
            VcfCheckUI.lastQueue = status.queue || [];
            VcfCheckUI.renderQueueStrip(VcfCheckUI.lastQueue);
            pollLog();

            var viewingEnvironmentId = status.currentEnvironmentId || VcfCheckUI.reportEnvironmentId;
            VcfCheckUI.loadRun(viewingEnvironmentId, status.runId, status.running).then(VcfCheckUI.renderReportEnvironmentSelect);

            var completed = VcfCheckUI.lastQueue.reduce(function (sum, item) { return sum + item.completedChecks; }, 0);
            var total = VcfCheckUI.lastQueue.reduce(function (sum, item) { return sum + item.totalChecks; }, 0) || status.totalChecks || completed;
            var statusText;
            if (status.running) {
                var elapsedMs = Date.now() - VcfCheckUI.runStartTime;
                var elapsedTime = VcfCheckUI.formatElapsedTime(elapsedMs);

                // Extract currently running check from log - reads the raw, unfiltered buffer
                // (not the displayed box) since these "[N/M] Running ..." lines are INFO-level
                // and would otherwise be invisible whenever the WARNING display filter is active.
                if (VcfCheckUI.liveLogRawText) {
                    var logLines = VcfCheckUI.liveLogRawText.split('\n');
                    for (var i = logLines.length - 1; i >= 0; i--) {
                        var match = logLines[i].match(/\[\d+\/\d+\]\s+Running\s+(.+?)\.\.\./);
                        if (match) {
                            var newCheckName = match[1];
                            if (newCheckName !== currentCheckName) {
                                currentCheckName = newCheckName;
                                currentCheckStartTime = Date.now();
                            }
                            break;
                        }
                    }
                }

                var progressText = VcfCheckUI.lastQueue.length > 1
                    ? "Progress: " + completed + "/" + total + " checks (" + VcfCheckUI.lastQueue.length + " environments)"
                    : "Progress: " + completed + "/" + total + " checks";
                document.getElementById("launcher-progress-text").textContent = progressText;
                document.getElementById("launcher-elapsed-text").textContent = "Elapsed: " + elapsedTime;

                var progressPercent = total > 0 ? Math.min(100, (completed / total) * 100) : 0;
                document.getElementById("launcher-progress-fill").style.width = progressPercent + "%";

                var currentCheckElement = document.getElementById("launcher-current-check");
                var stickyText = document.getElementById("sticky-progress-bar-text");
                if (currentCheckName) {
                    var checkElapsedMs = Date.now() - currentCheckStartTime;
                    var checkElapsedTime = VcfCheckUI.formatElapsedTime(checkElapsedMs);
                    currentCheckElement.textContent = "Current: " + currentCheckName + " (" + checkElapsedTime + ")";
                    stickyText.textContent = "Running: " + currentCheckName + " (" + checkElapsedTime + ")";
                } else {
                    currentCheckElement.textContent = "";
                    stickyText.textContent = "Running checks...";
                }
                var stickyCountText = completed > total ? completed + " result(s)" : completed + "/" + total;
                document.getElementById("sticky-progress-bar-count").textContent = stickyCountText;

                // Sub-progress (e.g. "Host 3/12") is optional and check-specific - only checks
                // that iterate many items and call Write-VcfCheckSubProgress ever populate it
                // (see status.queue[].subProgress); every other check simply leaves it blank.
                var subProgressElement = document.getElementById("launcher-sub-progress");
                var runningItem = VcfCheckUI.lastQueue.find(function (item) { return item.environmentId === status.currentEnvironmentId; });
                var subProgress = runningItem ? runningItem.subProgress : null;
                if (subProgress && subProgress.total > 0) {
                    // "hosts" (the default for every check written before Unit existed) keeps
                    // the original "Scanning N/Total hosts" wording unchanged; anything else
                    // (e.g. Health Summary's poll attempts) gets a neutral "N/Total <unit>"
                    // instead of a "Scanning ... hosts" claim that isn't actually true for it.
                    var unit = subProgress.unit || "hosts";
                    var subProgressText = unit === "hosts"
                        ? ("Scanning " + subProgress.current + "/" + subProgress.total + " hosts")
                        : (subProgress.current + "/" + subProgress.total + " " + unit);
                    if (subProgress.label) { subProgressText += " (" + subProgress.label + ")"; }
                    subProgressElement.textContent = subProgressText;
                } else {
                    subProgressElement.textContent = "";
                }
            } else {
                if (VcfCheckUI.runStartTime) {
                    VcfCheckUI.finalRunTime = VcfCheckUI.formatElapsedTime(Date.now() - VcfCheckUI.runStartTime);
                }
                var failedItems = VcfCheckUI.lastQueue.filter(function (item) { return item.status === "failed"; });
                if (failedItems.length > 0) {
                    // A "failed" queue item means the launcher subprocess itself crashed/exited
                    // non-zero (e.g. an unhandled file-lock error) partway through - whatever
                    // report exists is only a partial flush from before the crash, not a complete
                    // run. Confirmed live: without this, the headline text said "Run complete"
                    // regardless, and the only failure signal was a small queue-strip chip easy to
                    // miss, so a crashed run looked identical to a clean one at a glance.
                    var failedNames = failedItems.map(function (item) { return item.name; }).join(", ");
                    document.getElementById("launcher-progress-text").textContent = "Run failed - did not complete";
                    VcfCheckUI.showErrorNotification("The scan did not complete for: " + failedNames + ". The results shown below are only a partial report from before the failure - check the server log for details.");
                } else {
                    document.getElementById("launcher-progress-text").textContent = "Run complete";
                }
                document.getElementById("launcher-elapsed-text").textContent = VcfCheckUI.finalRunTime ? ("Total execution time: " + VcfCheckUI.finalRunTime) : "";
                document.getElementById("launcher-progress-fill").style.width = "100%";
                document.getElementById("launcher-current-check").textContent = "";
                document.getElementById("launcher-sub-progress").textContent = "";
            }

            if (!status.running) {
                VcfCheckUI.isRunning = false;
                clearInterval(VcfCheckUI.pollTimer);
                VcfCheckUI.pollTimer = null;
                clearInterval(VcfCheckUI.runElapsedTimer);
                VcfCheckUI.runElapsedTimer = null;
                VcfCheckUI.setRunningState(false);
                VcfCheckUI.reportEnvironmentId = VcfCheckUI.lastQueue.length ? (VcfCheckUI.lastQueue[VcfCheckUI.lastQueue.length - 1].environmentId) : null;
                VcfCheckUI.loadRun(VcfCheckUI.reportEnvironmentId, status.runId).then(VcfCheckUI.renderReportEnvironmentSelect);
            }
        }).catch(function (err) {
            // A transient blip here shouldn't stop polling - the next tick (2s later) retries on
            // its own rather than surfacing every missed poll as a user-facing error.
            console.error("Status poll failed:", err.message);
            VcfCheckUI.showErrorNotification("Server error: " + err.message);
        });
    }

    function startPolling() {
        if (VcfCheckUI.pollTimer) clearInterval(VcfCheckUI.pollTimer);
        VcfCheckUI.runStartTime = Date.now();
        VcfCheckUI.finalRunTime = null;
        VcfCheckUI.pollTimer = setInterval(pollOnce, 2000);
        pollOnce();
    }

    // Reattach the poll loop to a run that is already in progress (e.g. a page-load resume,
    // or a rejected "already in progress" second Run Check click) without touching
    // runStartTime/liveLogRawText/logOffset - those belong to the run that's actually active,
    // and resetting them here would re-base its elapsed clock or blank its live log.
    VcfCheckUI.resumePolling = function () {
        if (VcfCheckUI.pollTimer) return;
        VcfCheckUI.pollTimer = setInterval(pollOnce, 2000);
        pollOnce();
    }

    var credentialCheckRunning = false;
    var credentialCheckCancelRequested = false;
    var credentialCheckAbortController = null;
    var credentialLogOffset = 0;
    var credentialElapsedTimer = null;
    var credentialStartTime = null;

    // Signature of the environment ids Discover Workload Domains last succeeded against - null
    // means "not yet discovered, or the environment selection has moved since". Lets the button
    // gray out once discovery has already run for the current selection, instead of inviting a
    // redundant re-authentication every time the user revisits this section.
    VcfCheckUI.discoveredDomainsSignature = null;

    function environmentSelectionSignature() {
        return Array.prototype.slice.call(document.querySelectorAll("#run-scan-environment-list input[type=checkbox]:checked"))
            .map(function (checkbox) { return checkbox.value; })
            .sort()
            .join(",");
    }

    VcfCheckUI.refreshDiscoverButtonState = function () {
        var testButton = document.getElementById("discover-workload-domains-button");
        if (credentialCheckRunning || VcfCheckUI.isRunning) return;
        var alreadyDiscovered = VcfCheckUI.discoveredDomainsSignature !== null &&
            VcfCheckUI.discoveredDomainsSignature === environmentSelectionSignature();
        testButton.disabled = VcfCheckUI.environments.length === 0 || alreadyDiscovered;
        testButton.title = alreadyDiscovered
            ? "Workload domains already discovered for the selected environment(s). Change the environment selection to re-discover."
            : "Validate credentials and discover SDDC workload domains to customize which ones to run VCF Checks on.";
    }

    var CREDENTIAL_STATUS_LABELS = { pending: "Pending", checking: "Checking…", success: "Authenticated", failed: "Failed" };
    var CREDENTIAL_STATUS_ICONS = { pending: "–", success: "✓", failed: "✗" };

    function fmtElapsedDuration(totalSeconds) {
        var minutes = Math.floor(totalSeconds / 60);
        var seconds = totalSeconds % 60;
        return minutes > 0 ? (minutes + "m " + seconds + "s") : (seconds + "s");
    }

    function startCredentialElapsedTimer() {
        stopCredentialElapsedTimer();
        credentialStartTime = Date.now();
        var badge = document.getElementById("credential-check-elapsed");
        badge.textContent = "0s elapsed";
        credentialElapsedTimer = setInterval(function () {
            badge.textContent = fmtElapsedDuration(Math.round((Date.now() - credentialStartTime) / 1000)) + " elapsed";
        }, 1000);
    }

    function stopCredentialElapsedTimer() {
        if (credentialElapsedTimer) {
            clearInterval(credentialElapsedTimer);
            credentialElapsedTimer = null;
        }
    }

    function hideCredentialCheckPanel() {
        stopCredentialElapsedTimer();
        document.getElementById("credential-check-panel").classList.add("hidden");
        document.getElementById("credential-log-wrap").classList.add("hidden");
    }

    function renderCredentialCheckItems(steps) {
        var container = document.getElementById("credential-check-items");
        container.innerHTML = "";
        steps.forEach(function (step) {
            var hasPhases = step.phases && Array.isArray(step.phases) && step.phases.length > 0;

            if (hasPhases) {
                // Render phase-based view
                var envGroup = VcfCheckUI.el("div", "credential-check-group");
                var envHeader = VcfCheckUI.el("div", "credential-check-env-name", step.label);
                envGroup.appendChild(envHeader);

                var phaseList = VcfCheckUI.el("div", "credential-check-phases");
                step.phases.forEach(function (phase, idx) {
                    var phaseRow = VcfCheckUI.el("div", "credential-check-phase pi-" + phase.status);
                    var iconSpan = VcfCheckUI.el("span", "pi-icon");

                    // Show spinning icon only if phase is pending AND step is still checking
                    var isPhaseComplete = phase.status === "pass" || phase.status === "fail";
                    var isStepComplete = step.status === "success" || step.status === "failed";
                    console.log("Rendering phase " + idx + " '" + phase.name + "': status=" + phase.status + ", isPhaseComplete=" + isPhaseComplete + ", isStepComplete=" + isStepComplete);

                    if (!isPhaseComplete && !isStepComplete) {
                        // Phase is pending and step is still checking
                        console.log("  -> Showing spinner for phase " + idx);
                        iconSpan.appendChild(VcfCheckUI.el("span", "spin", "↻"));
                    } else {
                        var statusMap = { pass: "✓", fail: "✗", skipped: "–", pending: "–" };
                        var icon = statusMap[phase.status] || "–";
                        console.log("  -> Showing icon '" + icon + "' for phase " + idx);
                        iconSpan.textContent = icon;
                        if (phase.status !== "pass" && phase.status !== "fail" && phase.status !== "pending") {
                            console.log("Unexpected phase status: " + phase.status + " (phase=" + phase.name + ")");
                        }
                    }

                    phaseRow.appendChild(iconSpan);
                    phaseRow.appendChild(VcfCheckUI.el("span", "pi-label", phase.name));

                    if (phase.error) {
                        phaseRow.appendChild(VcfCheckUI.el("span", "pi-status", phase.error));
                    }

                    phaseList.appendChild(phaseRow);
                });

                envGroup.appendChild(phaseList);
                container.appendChild(envGroup);
            } else {
                // Render simple row view (fallback for old format or when phases unavailable)
                var row = VcfCheckUI.el("div", "progress-item pi-" + step.status);
                var iconSpan = VcfCheckUI.el("span", "pi-icon");
                if (step.status === "checking") {
                    iconSpan.appendChild(VcfCheckUI.el("span", "spin", "↻"));
                } else {
                    iconSpan.textContent = CREDENTIAL_STATUS_ICONS[step.status] || "–";
                }
                row.appendChild(iconSpan);
                row.appendChild(VcfCheckUI.el("span", "pi-label", step.label));
                var statusText = step.detail || CREDENTIAL_STATUS_LABELS[step.status] || "Validating...";
                row.appendChild(VcfCheckUI.el("span", "pi-status", statusText));
                container.appendChild(row);
            }
        });
    }

    function appendCredentialLog(text) {
        if (!text) return;
        document.getElementById("credential-log-wrap").classList.remove("hidden");
        VcfCheckUI.credentialLogRawText += text;
        VcfCheckUI.renderFilteredCredentialLog();
    }

    function pollCredentialLog() {
        return VcfCheckUI.fetchJson("/api/validate-credentials/log?since=" + credentialLogOffset).then(function (data) {
            credentialLogOffset = data.offset || credentialLogOffset;
            appendCredentialLog(data.text);
        }).catch(function () { /* log tail is best-effort - never blocks the credential check itself */ });
    }

    document.getElementById("credential-log-copy-button").addEventListener("click", function () {
        var button = this;
        // Copies the full, unfiltered transcript regardless of the current display filter -
        // troubleshooting/support wants every DEBUG line even if the on-screen view is trimmed.
        navigator.clipboard.writeText(VcfCheckUI.credentialLogRawText).then(function () {
            var original = button.textContent;
            button.textContent = "Copied";
            setTimeout(function () { button.textContent = original; }, 1800);
        });
    });

    function runCredentialValidation(items) {
        // Shared by the "Discover Workload Domains" button and Run Check's automatic pre-flight (below) -
        // same per-environment phase panel (Network Reachability -> SDDC Manager Authentication
        // -> ...), same live log, same domain-checkbox population, so a connectivity/auth problem
        // reads identically whether the user asked for it explicitly or Run Check caught it for
        // them. Resolves with the finished `steps` array (each with .status "success"/"failed")
        // rather than throwing, so callers can inspect per-environment outcomes themselves.
        var testedDomains = {};

        var steps = items.map(function (item) {
            var environment = VcfCheckUI.environments.filter(function (env) { return env.id === item.environmentId; })[0];
            var rootPasswordProvided = item.rootPassword && item.rootPassword.trim().length > 0;
            var fqdn = environment ? environment.sddcManagerFqdn : item.fqdn || "SDDC Manager";
            var initialPhases = [
                { name: 'SDDC Manager Network Reachability (' + fqdn + ')', status: 'pending', error: null },
                { name: 'SDDC Manager Authentication (' + fqdn + ')', status: 'pending', error: null }
            ];
            if (rootPasswordProvided) {
                initialPhases.push({ name: 'VMware Tools Status on ' + fqdn, status: 'pending', error: null });
                initialPhases.push({ name: 'SDDC Manager Root Authentication (' + fqdn + ')', status: 'pending', error: null });
            }
            (item.integrationCredentials || []).forEach(function (credential) {
                var integration = environment && environment.integrations ? environment.integrations[credential.integrationIndex] : null;
                if (!integration || integration.type !== 'AriaOperations') { return; }
                var endpoints = integration.sharedCredentials ? (integration.endpoints || []) : [integration.endpoints[credential.endpointIndex]];
                endpoints.forEach(function (endpoint) {
                    if (!endpoint) { return; }
                    initialPhases.push({ name: 'Aria Operations Network Reachability (' + endpoint.fqdn + ')', status: 'pending', error: null });
                    initialPhases.push({ name: 'Aria Operations Authentication (' + endpoint.fqdn + ')', status: 'pending', error: null });
                });
            });
            return {
                item: item,
                label: environment ? environment.name : item.environmentId,
                status: "pending",
                detail: null,
                phases: initialPhases,
                fqdn: fqdn
            };
        });

        var testButton = document.getElementById("discover-workload-domains-button");
        var healthButton = document.getElementById("health-check-button");
        credentialCheckRunning = true;
        credentialCheckCancelRequested = false;
        credentialCheckAbortController = new AbortController();
        testButton.disabled = false;
        testButton.classList.add("cancelling");
        healthButton.disabled = true;
        testButton.textContent = "Cancel";

        document.getElementById("credential-check-panel").classList.remove("hidden");
        VcfCheckUI.credentialLogRawText = "";
        VcfCheckUI.renderFilteredCredentialLog();
        renderCredentialCheckItems(steps);
        startCredentialElapsedTimer();

        // Primes credentialLogOffset to the log file's current size (an out-of-range `since`
        // clamps server-side) so only lines this credential check itself produces are shown.
        credentialLogOffset = Number.MAX_SAFE_INTEGER;
        return pollCredentialLog().then(function () {
            return steps.reduce(function (chain, step) {
                return chain.then(function () {
                    // Check if cancel was requested before processing this step
                    if (credentialCheckCancelRequested) {
                        return Promise.reject(new Error("Credential test cancelled by user."));
                    }

                    step.status = "checking";
                    step.detail = null;
                    renderCredentialCheckItems(steps);
                    var logTimer = setInterval(pollCredentialLog, 800);

                    return VcfCheckUI.postJson("/api/validate-credentials", { items: [step.item] }, { signal: credentialCheckAbortController.signal }).then(function (data) {
                        var result = (data.results || [])[0] || {};
                        console.log("Credential check response for " + step.item.fqdn + ":", result);
                        step.status = result.success ? "success" : "failed";

                        (result.domains || []).forEach(function (domain) {
                            if (domain && domain.name) { testedDomains[domain.name] = domain.type || ""; }
                        });

                        // Merge response phases with initial phases (real-time updates)
                        console.log("Before merge - step.phases:", step.phases);
                        if (result.phases && Array.isArray(result.phases)) {
                            console.log("Response has " + result.phases.length + " phases:", result.phases);
                            // Positional merge only holds when both sides agree on phase count -
                            // PowerShell can return phases the client's initialPhases placeholder
                            // list never anticipated (e.g. "Aria Suite Lifecycle Manager
                            // Connectivity", only added server-side when VRSLCM is registered with
                            // SDDC Manager). A straight index-by-index map would silently drop any
                            // such extra phase instead of rendering it, so fall back to the
                            // server's own phases (with their own names) whenever the counts
                            // differ, rather than assuming the client guessed the full set upfront.
                            if (step.phases && Array.isArray(step.phases) && step.phases.length === result.phases.length) {
                                console.log("Merging " + step.phases.length + " initial phases with " + result.phases.length + " result phases");
                                // Update existing phases by position (PowerShell returns phases in same order)
                                // Preserve the FQDN-specific phase names from initial phases, but update status and error
                                step.phases = step.phases.map(function (initialPhase, index) {
                                    var resultPhase = result.phases[index];
                                    console.log("Merging phase " + index + ": initial=" + initialPhase.name + ", result=" + (resultPhase ? resultPhase.name + " (status=" + resultPhase.status + ")" : "undefined"));
                                    if (resultPhase) {
                                        var merged = {
                                            name: initialPhase.name, // Keep the FQDN-specific name from UI
                                            status: resultPhase.status,
                                            error: resultPhase.error || null // Explicitly set error (may be null)
                                        };
                                        console.log("Merged phase " + index + ": " + JSON.stringify(merged));
                                        return merged;
                                    }
                                    return initialPhase;
                                });
                                console.log("After merge - step.phases:", step.phases);
                            } else {
                                // No initial phases, or the server returned a different count than
                                // the client guessed upfront - use result phases directly.
                                step.phases = result.phases;
                            }
                            // Immediately render updated phases
                            console.log("Calling renderCredentialCheckItems with updated step.phases");
                            renderCredentialCheckItems(steps);
                        } else {
                            console.log("No phases in response (phases=" + result.phases + ")");
                        }

                        step.detail = result.success ? null : (result.error || "Credentials could not be validated.");
                        if (result.rootCredentialTested && !step.phases) {
                            step.detail = (step.detail ? step.detail + " " : "") +
                                (result.rootCredentialSuccess
                                    ? "— root credential verified"
                                    : ("— root credential check failed: " + (result.rootCredentialError || "unknown error")));
                        }
                        // Always render immediately after status/phases update
                        renderCredentialCheckItems(steps);
                    }).catch(function (err) {
                        step.status = "failed";
                        step.detail = err.message;
                        renderCredentialCheckItems(steps);
                    }).finally(function () {
                        clearInterval(logTimer);
                        return pollCredentialLog();
                    }).then(function () {
                        renderCredentialCheckItems(steps);
                    });
                });
            }, Promise.resolve());
        }).catch(function (err) {
            // Handle cancellation or other errors
            if (err.message && err.message.includes("cancelled")) {
                // User cancelled - already set error message above
            } else {
                setLauncherError(err.message || "An error occurred during credential validation.");
            }
        }).finally(function () {
            var wasCancelled = credentialCheckCancelRequested;
            stopCredentialElapsedTimer();
            credentialCheckRunning = false;
            credentialCheckCancelRequested = false;
            credentialCheckAbortController = null;
            testButton.classList.remove("cancelling");
            healthButton.disabled = false;
            testButton.textContent = "Discover Workload Domains";
            // Union with whatever was already known - a re-test of a subset of environments
            // (e.g. after fixing one password) shouldn't drop domains from environments not
            // re-tested this round.
            var domainMap = {};
            VcfCheckUI.knownDomains.forEach(function (domain) { domainMap[domain.name] = domain.type; });
            Object.keys(testedDomains).forEach(function (name) { domainMap[name] = testedDomains[name]; });
            VcfCheckUI.renderDomainCheckboxes(Object.keys(domainMap).map(function (name) { return { name: name, type: domainMap[name] }; }));
            if (!wasCancelled && steps.every(function (step) { return step.status === "success"; })) {
                VcfCheckUI.discoveredDomainsSignature = environmentSelectionSignature();
            }
            VcfCheckUI.refreshDiscoverButtonState();
        }).then(function () {
            return steps;
        });
    }

    document.getElementById("discover-workload-domains-button").addEventListener("click", function () {
        // Handle cancel if already running
        if (credentialCheckRunning) {
            credentialCheckCancelRequested = true;
            if (credentialCheckAbortController) {
                credentialCheckAbortController.abort();
            }
            setLauncherError("Credential test cancelled.");
            return;
        }

        if (VcfCheckUI.isRunning) {
            setLauncherError("A check is already running - wait for it to finish (or click Cancel) before testing credentials.");
            return;
        }

        setLauncherError(null);

        var items;
        try {
            items = VcfCheckUI.getSelectedEnvironmentItems();
        } catch (err) {
            setLauncherError(err.message);
            return;
        }
        if (items.length === 0) {
            setLauncherError("Select at least one environment to test.");
            return;
        }

        runCredentialValidation(items);
    });

    document.getElementById("health-check-button").addEventListener("click", function () {
        if (VcfCheckUI.isRunning) {
            var button = document.getElementById("health-check-button");
            button.disabled = true;
            var originalText = button.textContent;
            button.textContent = "Cancelling...";

            VcfCheckUI.postJson("/api/run/cancel", {})
                .then(function () {
                    setLauncherError("Scan cancelled successfully.");
                })
                .catch(function (err) {
                    setLauncherError("Cancel request sent, but got error: " + err.message + ". The scan may still be stopping.");
                })
                .finally(function () {
                    if (VcfCheckUI.pollTimer) {
                        clearInterval(VcfCheckUI.pollTimer);
                        VcfCheckUI.pollTimer = null;
                    }
                    // Wait 2 seconds then check status to see if run actually stopped
                    setTimeout(function () {
                        VcfCheckUI.fetchJson("/api/run/status").then(function (status) {
                            if (!status.running) {
                                VcfCheckUI.isRunning = false;
                                VcfCheckUI.setRunningState(false);
                                button.disabled = false;
                            } else {
                                // Still running - re-enable cancel for another attempt
                                setLauncherError("Run still in progress. Click Cancel again to retry, or restart the server.");
                                button.disabled = false;
                                button.textContent = originalText;
                            }
                        }).catch(function () {
                            // Can't check status - assume it worked and move to idle state
                            VcfCheckUI.isRunning = false;
                            VcfCheckUI.setRunningState(false);
                            button.disabled = false;
                        });
                    }, 2000);
                });
            return;
        }

        if (credentialCheckRunning) {
            setLauncherError("A credential test is already running - wait for it to finish (or click Cancel) before running a check.");
            return;
        }

        setLauncherError(null);
        hideCredentialCheckPanel();

        var items;
        try {
            items = VcfCheckUI.getSelectedEnvironmentItems();
        } catch (err) {
            setLauncherError(err.message);
            return;
        }
        if (items.length === 0) {
            setLauncherError("Select at least one environment to scan.");
            return;
        }

        var checkIds = VcfCheckUI.checkedValues("check-checkboxes", ".chk-area-items ");
        if (checkIds.length === 0) {
            setLauncherError("Select at least one health check.");
            return;
        }

        // Only enforce a non-empty domain selection when domains are actually loaded - an empty
        // selection with none loaded (Discover Workload Domains skipped or failed for every environment)
        // just means "no domain filter", matching -CheckSet/-CheckId's own "empty means all".
        var selectedDomains = VcfCheckUI.checkedValues("domain-checkboxes");
        if (VcfCheckUI.knownDomains.length > 0 && selectedDomains.length === 0) {
            setLauncherError("Select at least one domain.");
            return;
        }

        function startTheRun() {
            VcfCheckUI.isRunning = true;
            VcfCheckUI.setRunningState(true);
            hideCredentialCheckPanel();
            // Clear the previous run's results immediately - otherwise the first status poll
            // (fired right away by startPolling) still fetches /api/runs/latest before this run
            // has written its own first partial report, and briefly re-renders the old run's
            // results as if they belonged to the one just started.
            // Use clearReportForNewScan to avoid showing "No runs found" during active scan.
            VcfCheckUI.clearReportForNewScan();

            VcfCheckUI.postJson("/api/run/start", { items: items, checkIds: checkIds, domains: selectedDomains }).then(function () {
                // Only reset the shared Live Log/offset/elapsed-timer globals once the server
                // has actually accepted this run - resetting them earlier stomps the still-active
                // prior run's in-progress log and elapsed baseline if this request is instead
                // rejected below with "already in progress".
                VcfCheckUI.logOffset = 0;
                // Seed the scan's Live Log with whatever the connectivity/credential pre-flight just
                // logged, instead of blanking it - otherwise that transcript (e.g. the guest-command
                // invocation lines while validating a root credential) is visible in the credential
                // check's own log box for a few seconds and then vanishes the moment that box is
                // hidden below, with no trace of it anywhere. One continuous transcript reads as what
                // it actually is: a single Run Check operation, not two unrelated ones.
                VcfCheckUI.liveLogRawText = VcfCheckUI.credentialLogRawText
                    ? VcfCheckUI.credentialLogRawText + "\n----- Starting scan -----\n"
                    : "";
                VcfCheckUI.renderFilteredLiveLog();
                startPolling();
            }).catch(function (err) {
                // If a run is already in progress, keep isRunning=true so the Cancel button appears.
                // Do NOT touch liveLogRawText/logOffset/runStartTime here or reuse startPolling's
                // reset path - the run that's already in progress owns those globals and this
                // request was rejected, not accepted.
                if (err.message && err.message.includes("already in progress")) {
                    VcfCheckUI.isRunning = true;
                    VcfCheckUI.setRunningState(true);
                    VcfCheckUI.resumePolling();
                    setLauncherError("A run is already in progress. Click Cancel to stop it, or wait for it to complete.");
                } else {
                    VcfCheckUI.isRunning = false;
                    VcfCheckUI.setRunningState(false);
                    setLauncherError(err.message);
                }
            });
        }

        // Skip the redundant pre-flight when Discover Workload Domains already validated
        // reachability/credentials for this exact environment selection - re-running it here
        // would just re-authenticate against the same SDDC Managers a second time in a row.
        if (VcfCheckUI.discoveredDomainsSignature !== null &&
            VcfCheckUI.discoveredDomainsSignature === environmentSelectionSignature()) {
            startTheRun();
            return;
        }

        // Verify reachability/credentials before committing to a scan - a network/auth problem
        // then surfaces as the same friendly per-environment phase panel Discover Workload Domains shows
        // (which distinguishes "unreachable" from "authentication failed"), instead of the scan
        // starting, running for a while, and only then reporting a per-check connection error.
        var healthButton = document.getElementById("health-check-button");
        healthButton.disabled = true;
        healthButton.textContent = "Verifying connectivity...";
        // Hide "No runs found" the moment Run Check is clicked, not just once the
        // connectivity pre-flight succeeds and startTheRun() fires - otherwise it stays
        // visible for the entire "Verifying connectivity..." phase.
        VcfCheckUI.clearReportForNewScan();
        runCredentialValidation(items).then(function (steps) {
            healthButton.disabled = false;
            healthButton.textContent = "Run Check";

            var failed = steps.filter(function (step) { return step.status !== "success"; });
            if (failed.length === 0) {
                // Validation passed - collapse its panel (with its own Live Log) before the scan's
                // own Live Log appears, so the two never show on screen at the same time.
                hideCredentialCheckPanel();
                startTheRun();
                return;
            }

            var failedNames = failed.map(function (step) { return step.label; }).join(", ");
            setLauncherError(
                "Run Check was not started - connectivity/credential check failed for: " + failedNames +
                ". See the details above, fix the issue, then click Run Check again."
            );
        }).catch(function (err) {
            healthButton.disabled = false;
            healthButton.textContent = "Run Check";
            setLauncherError(err.message || "Connectivity/credential check failed before the scan could start.");
        });
    });


})();
