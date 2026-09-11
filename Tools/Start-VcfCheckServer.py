#!/usr/bin/env python3
# Copyright (c) 2026 Broadcom. All Rights Reserved.
# Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
# and/or its subsidiaries.
#
# =============================================================================
#
# SOFTWARE LICENSE AGREEMENT
#
# Copyright (c) CA, Inc. All rights reserved.
#
# You are hereby granted a non-exclusive, worldwide, royalty-free license
# under CA, Inc.'s copyrights to use, copy, modify, and distribute this
# software in source code or binary form for use in connection with CA, Inc.
# products.
#
# This copyright notice shall be included in all copies or substantial
# portions of the software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#
"""Local report viewer and launcher for VcfCheck.

Serves the single-file vcf-check-ui.html SPA plus a small JSON API. Three families of
endpoints exist:

  - Read-only (GET /api/runs, /api/runs/latest, /api/runs/<id>, /api/checks, /api/settings,
    /api/environments, /api/version, /api/run/log, /api/validate-credentials/log): reads
    run-<id>.json / latest.json / Data/CheckCatalog.json / Config/settings.json /
    Config/environments.json / VcfCheck.psd1 / the day's server log / the day's engine log -
    files already written by the PowerShell engine (Private/Reporting.ps1, Private/Logging.ps1),
    this server's own environments.json writes, or this server's logging output. These never touch a subprocess. /api/settings only ever returns fqdn/username/theme
    (the keys settings.json is allowed to carry) - a password is never in that file to begin
    with, so there is nothing to accidentally return. /api/runs/latest and /api/runs/<id> accept
    an optional ?environmentId=<id> query param to scope to a specific saved environment's
    Findings/<id> subdirectory instead of the root Findings/ directory. /api/validate-credentials/log
    tails VcfCheckEngine-<date>.log (the file Invoke-VcfCheckValidateCredentials.ps1 writes
    to via Write-LogMessage) the same way /api/run/log tails the launcher log, for the browser's
    Discover Workload Domains Live Log panel.

  - Environments CRUD (GET/POST /api/environments, PUT/DELETE /api/environments/<id>): plain
    JSON list edits against Config/environments.json - no subprocess needed. A password is never
    a field on an environment object; _validate_environment_body rejects any password-shaped key
    outright. The first read ever performed migrates a legacy single-target settings.json into a
    single environment automatically (_load_environments).

  - Launcher (POST /api/run/start, POST /api/run/cancel, GET /api/run/status, POST
    /api/validate-credentials, POST /api/settings): /api/run/start and /api/validate-credentials spawn
    Invoke-VcfCheckLauncher.ps1 / Invoke-VcfCheckValidateCredentials.ps1 as a real
    PowerShell subprocess. Both accept either the original single-target flat body
    ({fqdn, username, password, rootPassword?}, kept for back-compat) or a multi-environment
    {items: [{environmentId, password, rootPassword?}, ...]} body - /api/run/start processes
    the resulting queue sequentially, one subprocess at a time (see _start_next_queue_item /
    _is_run_active), since this server has no background thread: every queue advance happens
    lazily, driven by whatever request calls _is_run_active next (a status poll or a new
    /api/run/start). Credentials submitted via the POST body are forwarded to the subprocess
    ONLY through its environment (never argv, never a file, never logged) and are never written
    to disk except for the FQDN/username, which are persisted to settings.json using the exact
    2-key schema Get-VcfCheckSettings expects - the password is never written anywhere. This
    mirrors the sibling VCF.Patch.Scanner tool's own Python-to-PowerShell credential hand-off
    (Tools/Start-VCFPatchScannerServer.py). POST /api/settings never touches a subprocess - it
    just persists the browser's theme preference, read-merge-write against whatever
    settings.json already holds.

  - Log bundle export (GET /api/export/logbundle, POST /api/export/logbundle-ack): streams an
    in-memory ZIP of every dated file under Logs/ plus every *.json file under Findings/ (or just
    one environment's Findings/<slug>/ subdirectory when ?environmentId=<id> is given) - same
    "bundle the whole logs directory" convention as the sibling VCF.Patch.Scanner tool's
    /scan/collect-logs, extended here to also include findings since a precheck report is exactly
    the artifact support would need alongside the raw logs. Explicit _reject_cross_origin() check
    before streaming binary, same reasoning as the POST routes below. logbundle-ack just audit-logs the
    browser's accept/cancel decision on the sensitive-data disclaimer shown before the download -
    it never gates the download itself.

stdlib only, no framework, so there is no extra dependency story for a tool meant to be
bundled inside a PowerShell module.
"""

import argparse
import io
import json
import logging
import os
import re
import signal
import subprocess
import sys
import threading
import uuid
import zipfile

try:
    import fcntl
except ImportError:  # Windows has no fcntl - see _acquire_active_run_lock's docstring.
    fcntl = None
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

from vcfcheck_server.check_catalog import (
    _checks_by_area,
    _load_check_catalog,
    _load_check_descriptions,
    _root_credential_check_ids,
)
from vcfcheck_server.environments import (
    _findings_slug_for_environment_id,
    _load_environments,
    _new_environment_id,
    _save_environments,
    _slugify_environment_name,
    _validate_environment_body,
    reject_unsafe_cli_value,
)
from vcfcheck_server.json_utils import _extract_json_object, _load_json_file, _load_latest_findings_json
from vcfcheck_server.logs import (
    _engine_log_path,
    _list_log_files,
    _tail_credential_log,
    _tail_log_file,
)
from vcfcheck_server.paths import (
    _config_dir,
    _docs_dir,
    _findings_dir,
    _findings_dir_for_item,
    _logs_dir,
    _module_version,
    _MODULE_PSD1,
)
from vcfcheck_server.sizing import (
    SizingWorker,
    _describe_sizing_detect_progress,
    _load_sizing_reference_data,
    _load_sizing_treatment_data,
    _render_sizing_estimate_html,
    _sizing_estimator_enabled,
)
from vcfcheck_server.vcf_release import (
    VCF_DESTINATION_RELEASE_FLOOR,
    _families_from_versions,
    _fetch_vcf_destination_release_options,
    _get_vcf_destination_release,
    _INTEROP_MATRIX_SDDC_MANAGER_DATA_FILE,
    _parse_dotted_version,
    _vcf_destination_release_options_cache,
)

MODULE_DIR = Path(__file__).resolve().parent
UI_FILE = MODULE_DIR / "vcf-check-ui.html"
UI_DIR = MODULE_DIR / "ui"

# Explicit allowlist of the SPA's per-feature script modules - deliberately not a generic
# "serve anything under ui/" static route, so adding a file there never becomes a servable
# path without a matching entry here.
_UI_ASSET_FILES = {
    "/ui/state.js": UI_DIR / "state.js",
    "/ui/filters.js": UI_DIR / "filters.js",
    "/ui/live-log-filter.js": UI_DIR / "live-log-filter.js",
    "/ui/common.js": UI_DIR / "common.js",
    "/ui/zip-writer.js": UI_DIR / "zip-writer.js",
    "/ui/password-toggle.js": UI_DIR / "password-toggle.js",
    "/ui/fqdn-validation.js": UI_DIR / "fqdn-validation.js",
    "/ui/report-render.js": UI_DIR / "report-render.js",
    "/ui/theme.js": UI_DIR / "theme.js",
    "/ui/sizing-wizard-core.js": UI_DIR / "sizing-wizard-core.js",
    "/ui/sizing-wizard-steps.js": UI_DIR / "sizing-wizard-steps.js",
    "/ui/sizing-wizard-detect.js": UI_DIR / "sizing-wizard-detect.js",
    "/ui/export.js": UI_DIR / "export.js",
    "/ui/logbundle-export.js": UI_DIR / "logbundle-export.js",
    "/ui/environments.js": UI_DIR / "environments.js",
    "/ui/run-scan.js": UI_DIR / "run-scan.js",
    "/ui/health-checks.js": UI_DIR / "health-checks.js",
    "/ui/run-actions-polling.js": UI_DIR / "run-actions-polling.js",
    "/ui/init.js": UI_DIR / "init.js",
}
LAUNCHER_SCRIPT = MODULE_DIR / "Invoke-VcfCheckLauncher.ps1"
SIZING_ESTIMATE_SCRIPT = MODULE_DIR / "Invoke-VcfCheckSizingEstimate.ps1"
VALIDATE_CREDENTIALS_SCRIPT = MODULE_DIR / "Invoke-VcfCheckValidateCredentials.ps1"
SIZING_DETECT_SCRIPT = MODULE_DIR / "Invoke-VcfCheckSizingDetect.ps1"

# run-<id>.json filenames are constructed from Get-Date -Format 'yyyyMMdd-HHmmss' on the
# PowerShell side (Private/Orchestrator.ps1) - restrict to that shape before touching disk.
RUN_ID_PATTERN = re.compile(r"^[0-9A-Za-z_-]{1,64}$")

# Environment ids are generated by _new_environment_id() below (uuid4 hex[:12]) - restrict to
# that shape before using one to build a filesystem path (Findings/<environmentId>/...).
ENVIRONMENT_ID_PATTERN = re.compile(r"^[0-9a-f]{12}$")

# The /api/environments/<id> route, shared by do_PUT and do_DELETE (both previously duplicated
# this same literal regex) - built from ENVIRONMENT_ID_PATTERN's own character class rather than
# a second copy of it, so the two can never quietly drift out of sync.
ENVIRONMENT_ID_ROUTE_PATTERN = re.compile(
    r"^/api/environments/(" + ENVIRONMENT_ID_PATTERN.pattern.strip("^$") + r")$"
)

# Only these parent-process environment variables are forwarded to the launcher subprocess,
# plus the credential/module-path variables this server adds itself below - a deny-by-default
# allowlist so unrelated parent-shell secrets can never leak into the child's environment.
_SUBPROCESS_ENV_ALLOWLIST = (
    "PATH",
    "PSModulePath",
    "HOME",
    "USERPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
    "ProgramData",
    "TEMP",
    "TMP",
    "SystemRoot",
    "windir",
    "ComSpec",
    "LANG",
    "LC_ALL",
)

logger = logging.getLogger("VcfCheck-Server")

# Every pwsh subprocess this server launches (module lookup, check runs, credential
# validation) must stay invisible - this is a web-UI-driven tool, and on Windows a bare
# subprocess.Popen/run allocates a new console that flashes to the foreground, which is a
# jarring, unexplained window for someone driving the whole thing from a browser. No-op on
# non-Windows platforms, where a new console is never allocated in the first place.
_NO_WINDOW_KWARGS = (
    {"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" else {}
)


_sizing_worker = SizingWorker()


class RunQueue:
    """Owns the launcher-subprocess queue state - previously a bare module-level dict
    (`_run_state`) mutated directly from a dozen call sites, with correctness resting entirely on
    every one of them remembering to hold `_run_lock` (and to hold it the *right* way - some
    functions required the caller to already have it, others acquired it themselves, and getting
    that backwards either deadlocks or races). Wrapping the same dict shape in a class doesn't
    change any behavior; it makes the locking contract explicit and enforced in one place instead
    of implicit in a docstring per function.

    Locking convention: every public method (no leading underscore) acquires self.lock itself and
    is safe to call from any thread. A method with a `_locked` suffix assumes the caller already
    holds self.lock - never call one directly except from another method that already holds it.
    `threading.Lock` is not reentrant, so acquiring it twice on the same thread deadlocks silently
    (no exception - the request just hangs forever), which is exactly the failure mode this
    convention exists to prevent.

    `.lock` and `.state` are exposed as plain public attributes (not name-mangled) so the
    module-level `_run_lock`/`_run_state` names below can keep resolving to these exact same
    objects during the transition off them - existing code/tests that still say
    `with _run_lock:` / `_run_state["process"]` keep working unchanged. Migrating every remaining
    call site to use this class's own methods instead of the module-level aliases is a deliberate,
    separate follow-up - not bundled into this structural extraction.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.state = {
            "process": None,
            "reader_thread": None,
            "run_id": None,
            "total_checks": None,
            "started_at": None,
            # "queue" holds one dict per environment in this batch:
            # {environmentId, name, checkIds, password, rootPassword, status, runId, totalChecks}.
            # status is one of pending|running|success|failed|blocked. Populated by start();
            # drained one item at a time by _start_next_locked, called opportunistically from
            # is_active() (this server has no background thread - every state transition happens
            # lazily, driven by the browser's own /api/run/status poll).
            "queue": [],
            "current_index": None,
            "findings_dir": None,
        }

    def start(self, base_directory: Path, queue_items: list) -> dict:
        """Equivalent of the old _handle_run_start's locked block: sets the queue, resets
        current_index, and pumps the first item - all under one lock acquisition, so the caller
        gets a consistent {"started", "runId", "startedAt"} snapshot instead of having to
        re-acquire the lock itself just to read back what starting the first item produced."""
        with self.lock:
            self.state["queue"] = queue_items
            self.state["current_index"] = None
            started = self._start_next_locked(base_directory)
            block_reasons = [
                f"{item['name']}: {item['blockReason']}" for item in queue_items if item.get("blockReason")
            ]
            return {
                "started": started, "runId": self.state["run_id"], "startedAt": self.state["started_at"],
                "blockReasons": block_reasons,
            }

    def is_active(self, base_directory: Path) -> bool:
        """Reaps a finished subprocess, records its queue item's outcome, and starts the next
        pending queue item if one exists - this server has no background thread, so every queue
        advance happens lazily here, driven by whatever request (a status poll or a new
        /api/run/start) happens to call this next. Reports whether a run is currently active."""
        with self.lock:
            process = self.state["process"]
            if process is not None:
                if process.poll() is None:
                    return True
                self._reap_locked(process)
            return self._start_next_locked(base_directory)

    def snapshot(self, base_directory: Path) -> dict:
        """Everything GET /api/run/status needs, computed under one lock acquisition (avoiding
        the read-then-read race a caller doing several separate .state[...] reads under its own
        `with self.lock:` would otherwise have to get right itself every time)."""
        with self.lock:
            process = self.state["process"]
            current_process_pid = process.pid if process else None
            queue_view = [
                {
                    "environmentId": item["environmentId"],
                    "name": item["name"],
                    "status": item["status"],
                    "totalChecks": item["totalChecks"],
                    "completedChecks": _completed_check_count(base_directory, item, current_process_pid),
                    "subProgress": _load_sub_progress(base_directory, item),
                }
                for item in self.state["queue"]
            ]
            current_index = self.state["current_index"]
            return {
                "runId": self.state["run_id"],
                "totalChecks": self.state["total_checks"],
                "startedAt": self.state["started_at"],
                "queue": queue_view,
                "currentEnvironmentId": queue_view[current_index]["environmentId"] if current_index is not None else None,
            }

    def current_run_id(self):
        with self.lock:
            return self.state["run_id"]

    def has_active_item_for_environment(self, environment_id: str) -> bool:
        with self.lock:
            return any(
                item.get("environmentId") == environment_id and item["status"] in ("pending", "running")
                for item in self.state["queue"]
            )

    def cancel(self) -> None:
        """Terminates the active subprocess and drops the rest of the queue - a browser-side
        cancel actually stops the server-side run instead of only resetting the tab's own
        isRunning flag."""
        with self.lock:
            self._terminate_locked()
            for item in self.state["queue"]:
                if item["status"] in ("pending", "running"):
                    item["status"] = "failed"
            self.state["process"] = None
            self.state["reader_thread"] = None
            self.state["current_index"] = None

    def force_clear(self) -> None:
        """Emergency reset: force-clears the run state without gracefully terminating the
        process. Use this only if the normal cancel doesn't work (e.g. process is hung or
        zombie)."""
        with self.lock:
            process = self.state["process"]
            if process is not None:
                try:
                    if process.poll() is None:
                        process.kill()
                except (OSError, ProcessLookupError):
                    pass
            if self.state["findings_dir"] is not None:
                _clear_active_run_lock(self.state["findings_dir"])
            self.state.update({
                "process": None, "reader_thread": None, "current_index": None, "queue": [],
                "run_id": None, "total_checks": None, "started_at": None, "findings_dir": None,
            })

    def terminate(self) -> None:
        """Terminates the active launcher subprocess, if any. Shared by cancel() and the server's
        own shutdown path (main()'s signal handler / finally block) - without the latter, stopping
        or -Force-restarting the server (Stop-Process only ever signals the server's own PID,
        never its children) orphans the pwsh launcher: reparented to init, it keeps running and
        keeps writing partial reports to the same Findings/<slug>/latest.json a subsequently
        started run also writes to, so the two processes' runIds flip-flop in that file and
        /api/run/status's completedChecks (gated on a runId match, see _completed_check_count)
        intermittently reports 0 while the run is otherwise progressing normally - confirmed live
        as the cause of the browser's progress bar resetting to 0/N. Acquires the lock itself,
        unlike the old module-level _terminate_run_process which required the caller to already
        hold it - callers no longer need their own `with _run_lock:` wrapper around this."""
        with self.lock:
            self._terminate_locked()

    def _terminate_locked(self) -> None:
        process = self.state["process"]
        if process is not None and process.poll() is None:
            logger.warning(
                "Terminating active run %s subprocess (pid %s) as part of server shutdown/cancel.",
                self.state["run_id"], process.pid,
            )
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        findings_dir = self.state["findings_dir"]
        if findings_dir is not None:
            _clear_active_run_lock(findings_dir)
            self.state["findings_dir"] = None

    def _reap_locked(self, process) -> None:
        current_index = self.state["current_index"]
        queue = self.state["queue"]
        if current_index is not None and current_index < len(queue):
            queue[current_index]["status"] = "success" if process.returncode == 0 else "failed"
        self.state["process"] = None
        self.state["reader_thread"] = None
        findings_dir = self.state["findings_dir"]
        if findings_dir is not None:
            _clear_active_run_lock(findings_dir)
            self.state["findings_dir"] = None

    def _start_next_locked(self, base_directory: Path) -> bool:
        """Launches the next pending queue item's subprocess. Assumes self.lock is already held.

        A queue item without an environmentId (the back-compat single-target flat body) omits
        -OutputPath entirely so Invoke-VcfCheck falls back to its own default
        ($env:VcfCheckBaseDirectory\\Findings) exactly as before this feature existed - a real
        multi-environment item (environmentId present) gets its own Findings/<slug-of-name>
        subdirectory (see _slugify_environment_name) so one environment's run never overwrites
        another's latest.json, and so a human browsing Findings/ on disk sees the environment's
        friendly name rather than an opaque id.

        Returns True if an item was started, False if the queue has nothing left to run.
        """
        queue = self.state["queue"]
        next_index = next((i for i, item in enumerate(queue) if item["status"] == "pending"), None)
        if next_index is None:
            self.state["current_index"] = None
            return False

        item = queue[next_index]

        findings_dir = (_findings_dir(base_directory) / item["findingsSlug"]) if item.get("findingsSlug") else _findings_dir(base_directory)
        findings_dir.mkdir(parents=True, exist_ok=True)

        lock_fd, blocking_pid = _acquire_active_run_lock(findings_dir)
        if lock_fd is None:
            item["status"] = "blocked"
            item["blockReason"] = (
                f"another process{f' (pid {blocking_pid})' if blocking_pid else ''} is still holding the "
                f"run lock for this environment - if that run actually finished or crashed, use Force Clear "
                f"and try again"
            )
            logger.warning(
                "Skipping run for %r: another process%s already holds the active-run lock at %s "
                "(likely an orphaned launcher from a previous server crash/restart - it will release "
                "the lock on its own once it exits; only use Force Clear or terminate it directly if "
                "it appears to be stuck).",
                item["name"], f" (pid {blocking_pid})" if blocking_pid else "", _active_run_lock_path(findings_dir),
            )
            return self._start_next_locked(base_directory)

        item["status"] = "running"
        self.state["current_index"] = next_index

        run_id = uuid.uuid4().hex[:12]
        started_at = datetime.now(timezone.utc).isoformat()
        item["runId"] = run_id
        item["runStartedAt"] = started_at

        latest_findings_file = findings_dir / "latest.json"

        logger.info("===== Run %s started %s - %s (%d check(s)) =====", run_id, started_at, item['name'], len(item['checkIds']))
        logger.info("Findings will be written to: %s", latest_findings_file)

        env = _build_launcher_env(base_directory, item["password"], item.get("rootPassword", ""), item.get("ariaOpsCredentials"))
        args = [
            "pwsh", "-NoProfile", "-NonInteractive", "-File", str(LAUNCHER_SCRIPT),
            "-SddcManagerFqdn", item["fqdn"],
            "-SddcManagerUser", item["username"],
            "-CheckId", ",".join(item["checkIds"]),
            "-RunId", run_id,
            "-ConnectivityTimeoutSeconds", str(_get_tcp_timeout_seconds(base_directory)),
            "-HealthSummaryMaxPollAttempts", str(_get_health_summary_max_poll_attempts(base_directory)),
            "-PreUpgradeCheckSetMaxPollAttempts", str(_get_pre_upgrade_check_set_max_poll_attempts(base_directory)),
        ]
        vcf_destination_release = _get_vcf_destination_release(base_directory)
        if vcf_destination_release:
            args.extend(["-VcfDestinationRelease", vcf_destination_release])
        if item.get("domains"):
            # Comma-joined, same rationale as -CheckId above (Popen's argv binding does not
            # greedily consume multiple space-separated tokens into a named array parameter).
            args.extend(["-Domain", ",".join(item["domains"])])
        if item.get("findingsSlug"):
            args.extend(["-EnvironmentName", item["name"]])
            args.extend(["-OutputPath", str(_findings_dir(base_directory) / item["findingsSlug"])])

        try:
            process = subprocess.Popen(
                args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                pass_fds=(lock_fd,) if lock_fd != _NO_LOCK_FD else (),
                **_NO_WINDOW_KWARGS,
            )
        except OSError as exc:
            item["status"] = "failed"
            item["blockReason"] = f"failed to launch PowerShell (pwsh): {exc}"
            logger.error("Could not start VcfCheck run for %r: %s", item["name"], exc)
            _release_active_run_lock(findings_dir, lock_fd)
            return self._start_next_locked(base_directory)

        logger.info("Started run %s for %r (pid %s, %d check(s))", run_id, item["name"], process.pid, len(item["checkIds"]))
        if lock_fd != _NO_LOCK_FD:
            # The launcher subprocess inherited its own copy of lock_fd via pass_fds above, so
            # closing ours here does not release the flock - it stays held for as long as the
            # subprocess itself is alive, which is the whole point (see _acquire_active_run_lock).
            _write_active_run_lock_fd(lock_fd, process.pid, run_id)
            os.close(lock_fd)
        else:
            _write_active_run_lock(findings_dir, process.pid, run_id)

        reader_thread = threading.Thread(target=_stream_pipe_to_logger, args=(process.stdout, run_id), daemon=True)
        reader_thread.start()

        self.state["process"] = process
        self.state["reader_thread"] = reader_thread
        self.state["run_id"] = run_id
        self.state["total_checks"] = item["totalChecks"]
        self.state["started_at"] = started_at
        self.state["findings_dir"] = findings_dir
        return True


_run_queue = RunQueue()

# Compatibility aliases during the transition off direct _run_state/_run_lock access (still used
# by a handful of call sites below and by the existing Python test suite) - these are the exact
# same Lock and dict objects _run_queue uses internally, not copies, so mutating them through
# either name mutates the one real state RunQueue's own methods also see.
_run_lock = _run_queue.lock
_run_state = _run_queue.state


# Sentinel returned by _acquire_active_run_lock in place of a real fd on the Windows fallback
# path (no fcntl there), so callers can tell "acquired, nothing to hold open" apart from "blocked".
_NO_LOCK_FD = -1


def _active_run_lock_path(findings_dir: Path) -> Path:
    return findings_dir / ".active-run.json"


def _read_active_run_lock_payload(findings_dir: Path) -> dict | None:
    try:
        return json.loads(_active_run_lock_path(findings_dir).read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def _write_active_run_lock(findings_dir: Path, pid: int, run_id: str) -> None:
    """Best-effort, non-atomic write used only on the Windows fallback path (see
    _acquire_active_run_lock) - on POSIX the lock content is written to the already-locked fd by
    _write_active_run_lock_fd instead."""
    lock_path = _active_run_lock_path(findings_dir)
    try:
        lock_path.write_text(json.dumps({"pid": pid, "runId": run_id}), encoding="utf-8")
    except OSError as exc:
        logger.warning("Could not write active-run lock at %s: %s", lock_path, exc)


def _write_active_run_lock_fd(fd: int, pid: int, run_id: str) -> None:
    os.ftruncate(fd, 0)
    os.lseek(fd, 0, os.SEEK_SET)
    os.write(fd, json.dumps({"pid": pid, "runId": run_id}).encode("utf-8"))


def _clear_active_run_lock(findings_dir: Path) -> None:
    """Removes the (by now unlocked, since whichever process held it has exited) lock file -
    purely a disk-hygiene step. It does not itself release anything: on POSIX the OS releases the
    underlying flock automatically the moment the last process holding the fd (the launcher
    subprocess, once _acquire_active_run_lock's caller closes its own copy) exits or dies, even if
    this server crashes first - that's the whole point of using flock instead of a pid-liveness
    check here."""
    try:
        _active_run_lock_path(findings_dir).unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        logger.warning("Could not remove active-run lock at %s: %s", _active_run_lock_path(findings_dir), exc)


def _pid_is_alive(pid: int) -> bool:
    """Best-effort liveness check for the Windows fallback path only.

    CONFIRMED BUG, FIXED (2026-08-11, live customer report): os.kill(pid, 0) does not reliably
    raise ProcessLookupError on Windows for a dead pid - Python's implementation there is limited
    to a handful of signals, and passing 0 raises a generic OSError ([WinError 87] "the parameter
    is incorrect") regardless of whether the pid exists. The previous "any other OSError -> assume
    alive" fallback therefore always reported a Windows pid as alive, so a stale lock file left
    over from a crashed/restarted server could never self-heal - it blocked every run until someone
    used Force Clear. Uses the Win32 OpenProcess/GetExitCodeProcess API instead, which actually
    distinguishes a live pid from a dead/nonexistent one.
    """
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259
        handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            return False
        try:
            exit_code = wintypes.DWORD()
            if not ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
                return True  # Can't tell - assume alive rather than allowing a duplicate run.
            return exit_code.value == STILL_ACTIVE
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def _active_run_lock_holder_pid(findings_dir: Path) -> int | None:
    """Windows-fallback-only liveness check: returns the PID recorded in this environment's lock
    file if that PID is still alive, or None if there is no lock or its process has already
    exited (stale lock files are removed here so they don't block runs forever). Racy by
    construction - a check and a subsequent write are two separate, non-atomic filesystem
    operations, so two nearly-simultaneous /api/run/start calls (even within the same process,
    let alone two independent server processes) could both observe None here before either writes
    - see _acquire_active_run_lock, which uses fcntl.flock instead wherever it's available."""
    holder_pid = _read_active_run_lock_payload(findings_dir)
    if holder_pid is None:
        return None
    try:
        pid = int(holder_pid["pid"])
    except (KeyError, TypeError, ValueError):
        return None
    if _pid_is_alive(pid):
        return pid
    _clear_active_run_lock(findings_dir)
    return None


def _acquire_active_run_lock(findings_dir: Path) -> tuple:
    """Attempts to atomically claim the exclusive right to start a run against this environment
    right now. Returns (fd, blocking_pid):

    - On success, `fd` is either an open file descriptor the caller MUST pass to the launcher
      subprocess via Popen's pass_fds and then close its own copy of once the subprocess exists
      (POSIX), or the _NO_LOCK_FD sentinel meaning "acquired, nothing to hold open" (Windows
      fallback). `blocking_pid` is None.
    - On failure, `fd` is None and `blocking_pid` names the pid already recorded for this
      environment, if any (read separately from the flock failure itself - the two are not
      atomic with each other - so this is best-effort and only ever used for a log message, never
      for a decision).

    On POSIX this uses fcntl.flock(LOCK_EX | LOCK_NB) on the lock file, which locks an "open file
    description" rather than a pid: once the caller passes this fd to the launcher subprocess and
    closes its own copy, the lock is held for exactly as long as the launcher is actually alive -
    inherited across fork/exec, and released automatically by the kernel the instant every process
    holding it exits, even if this server crashes, is killed, or is restarted in between. That
    closes the race a pid-liveness check cannot: a check and a write are two separate, non-atomic
    filesystem operations, so two independent server processes (or two /api/run/start requests
    racing a slow subprocess spawn) could both pass a liveness check before either had written its
    pid. Falls back to the racy pid-liveness check (_active_run_lock_holder_pid) when fcntl isn't
    available (Windows) - see that function's docstring for why it's weaker.
    """
    if fcntl is None:
        holder_pid = _active_run_lock_holder_pid(findings_dir)
        if holder_pid is not None:
            return None, holder_pid
        return _NO_LOCK_FD, None

    lock_path = _active_run_lock_path(findings_dir)
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        payload = _read_active_run_lock_payload(findings_dir)
        os.close(fd)
        return None, (payload.get("pid") if payload else None)
    return fd, None


def _release_active_run_lock(findings_dir: Path, fd) -> None:
    """Releases a lock acquired by _acquire_active_run_lock that will never be handed to a
    subprocess (the Popen call itself failed) - as opposed to the normal path, where the fd is
    closed in _start_next_queue_item right after a successful Popen and release happens later,
    automatically, when the subprocess exits."""
    if fd is not None and fd != _NO_LOCK_FD:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)
    _clear_active_run_lock(findings_dir)


def _get_tcp_timeout_seconds(base_directory: Path) -> int:
    settings = _load_json_file(_config_dir(base_directory) / "settings.json") or {}
    return settings.get("TcpTimeoutSeconds") or 30


# Selectable poll-budget presets for the two "very long running" SDDC Manager checks that can
# sit blocking a run for minutes while SDDC Manager works through them - a fixed, validated set
# of choices rather than free numeric entry, so the poll delay/attempt math a user could pick
# stays within ranges that have actually been exercised against a live environment.
HEALTH_SUMMARY_MAX_POLL_ATTEMPTS_CHOICES = (12, 24, 48, 60)
PRE_UPGRADE_CHECK_SET_MAX_POLL_ATTEMPTS_CHOICES = (20, 40, 60, 80)


def _get_health_summary_max_poll_attempts(base_directory: Path) -> int:
    settings = _load_json_file(_config_dir(base_directory) / "settings.json") or {}
    value = settings.get("HealthSummaryMaxPollAttempts")
    return value if value in HEALTH_SUMMARY_MAX_POLL_ATTEMPTS_CHOICES else 24


def _get_pre_upgrade_check_set_max_poll_attempts(base_directory: Path) -> int:
    settings = _load_json_file(_config_dir(base_directory) / "settings.json") or {}
    value = settings.get("PreUpgradeCheckSetMaxPollAttempts")
    return value if value in PRE_UPGRADE_CHECK_SET_MAX_POLL_ATTEMPTS_CHOICES else 40


_PIPE_LINE_LEVEL_RE = re.compile(r'^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[(\w+)\] ')

_PIPE_LINE_LOG_METHODS = {
    'DEBUG': logging.Logger.debug,
    'INFO': logging.Logger.info,
    'WARNING': logging.Logger.warning,
    'ERROR': logging.Logger.error,
}


def _stream_pipe_to_logger(pipe, run_id: str):
    """Thread target: reads lines from a subprocess pipe and logs them through the Python logger.

    Lines tagged INFO/DEBUG by Write-LogMessage are already written verbatim to that run's
    VcfCheckEngine log file, so re-logging them here would duplicate every line across both
    log files. Only WARNING/ERROR-tagged lines (worth surfacing in the server log even though
    the engine log also has them) and untagged lines (the "[N/Total] Running..."/"->"/summary
    progress output, which is Write-Host-only and exists nowhere else) are logged here."""
    try:
        for line in iter(pipe.readline, b''):
            if line:
                try:
                    text = line.decode('utf-8', errors='replace').rstrip('\n\r')
                    if text:
                        match = _PIPE_LINE_LEVEL_RE.match(text)
                        text = _PIPE_LINE_LEVEL_RE.sub('', text)
                        if text:
                            level = match.group(1).upper() if match else None
                            if level in ('INFO', 'DEBUG'):
                                continue
                            log_method = _PIPE_LINE_LOG_METHODS.get(level, logging.Logger.info) if level else logging.Logger.info
                            log_method(logger, text)
                except Exception as e:
                    logger.error("Error processing pipe output: %s", e)
        pipe.close()
    except Exception as e:
        logger.error("Error reading subprocess pipe: %s", e)


def _start_next_queue_item(base_directory: Path) -> bool:
    """Compatibility wrapper around RunQueue._start_next_locked, kept for any external caller
    still using the old module-level function name. Must be called with _run_lock already held -
    same contract as before this became a RunQueue method."""
    return _run_queue._start_next_locked(base_directory)


def _terminate_run_process() -> None:
    """Compatibility wrapper around RunQueue._terminate_locked. Must be called with _run_lock
    already held - same contract as before this became a RunQueue method. Prefer
    _run_queue.terminate() (which acquires the lock itself) in new code."""
    _run_queue._terminate_locked()


def _is_run_active(base_directory: Path) -> bool:
    """Compatibility wrapper around RunQueue.is_active."""
    return _run_queue.is_active(base_directory)


def _list_findings_files(base_directory: Path, environment_id: str) -> list:
    """JSON and HTML findings files to include in the log bundle (JSON run/estimate data plus any
    standalone HTML reports, such as the resource estimator's own report - see
    _render_sizing_estimate_html). Scoped to one environment's own Findings/<slug>/ subdirectory
    when environment_id is given (caller has already validated it against
    ENVIRONMENT_ID_PATTERN); otherwise every matching file under Findings/ (recursively), covering
    both the legacy flat single-environment layout and every saved environment's own
    subdirectory."""
    findings_dir = _findings_dir(base_directory)
    if not findings_dir.is_dir():
        return []
    if environment_id:
        slug = _findings_slug_for_environment_id(base_directory, environment_id)
        if not slug:
            return []
        scoped_dir = findings_dir / slug
        return sorted(list(scoped_dir.glob("*.json")) + list(scoped_dir.glob("*.html")))
    return sorted(list(findings_dir.rglob("*.json")) + list(findings_dir.rglob("*.html")))


def _latest_json_mismatch_grace_expired(item: dict) -> bool:
    """True once item["runStartedAt"] is far enough in the past that a runId mismatch in
    latest.json is no longer explained by "the subprocess just hasn't flushed its first partial
    report yet" - see _LATEST_JSON_MISMATCH_GRACE_SECONDS. Treats a missing/unparseable
    runStartedAt as already-expired (fail toward surfacing the warning, not hiding it)."""
    run_started_at = item.get("runStartedAt")
    if not run_started_at:
        return True
    try:
        started = datetime.fromisoformat(run_started_at)
    except ValueError:
        return True
    elapsed = (datetime.now(timezone.utc) - started).total_seconds()
    return elapsed >= _LATEST_JSON_MISMATCH_GRACE_SECONDS


# A freshly started subprocess needs a moment to connect and flush its first partial report -
# until then, latest.json still legitimately holds this same environment's *previous* run's
# runId. A mismatch inside this window is expected, not evidence of a second writer, so
# _completed_check_count only escalates to a WARNING once a mismatch has outlasted it.
_LATEST_JSON_MISMATCH_GRACE_SECONDS = 15

# /api/run/status is polled every couple of seconds while a run is active - without this,
# _completed_check_count would re-log the same mismatch on every single poll for as long as the
# mismatch persists (confirmed live: dozens of near-identical lines a minute apart, for a run
# that was not actually stuck on anything other than a slow first check). Keyed by runId so a
# later run against the same environment logs its own mismatch again if it hits one.
_logged_latest_json_mismatch_run_ids: set = set()


def _load_sub_progress(base_directory: Path, item: dict):
    """Reads the current check's optional progress.json (Write-VcfCheckSubProgress), if any -
    e.g. {"current": 3, "total": 12, "label": "esx-04.rainpole.io"} while a long-running check
    like ESX Hardware Summary is iterating hosts. Returns None when the current check never
    reports sub-progress, or hasn't yet, or already finished (Clear-VcfCheckSubProgress
    removes the file after every check)."""
    if item["status"] != "running":
        return None
    progress_path = _findings_dir_for_item(base_directory, item) / "progress.json"
    return _load_latest_findings_json(progress_path)


def _completed_check_count(base_directory: Path, item: dict, current_process_pid: int | None = None) -> int:
    """Counts completed checks for a queue item from its partial/final latest.json, scoped to
    this item's own runId - without that check, a stale latest.json left over from this same
    environment's previous run would be miscounted as this run's progress before the new
    subprocess has flushed its first partial report.

    `current_process_pid` is the PID of whatever subprocess this server itself currently has
    running for this queue (or None) - passed in explicitly by the caller (RunQueue.snapshot)
    rather than this function reaching into RunQueue's state itself, so it has no locking contract
    of its own to get wrong. Defaults to None so direct callers (including the existing test
    suite) that don't have - or don't care about - a live process still get the same "no live
    process of ours" behavior as before this became an explicit parameter."""
    if item["status"] == "pending" or not item.get("runId"):
        return 0
    findings_dir = _findings_dir_for_item(base_directory, item)
    payload = _load_latest_findings_json(findings_dir / "latest.json")
    if not payload:
        return 0
    payload_run_id = payload.get("runId")
    if payload_run_id != item["runId"]:
        run_id = item["runId"]
        if payload_run_id and _latest_json_mismatch_grace_expired(item) and run_id not in _logged_latest_json_mismatch_run_ids:
            _logged_latest_json_mismatch_run_ids.add(run_id)
            # A genuine second writer is only possible if some other, still-alive process holds
            # this environment's active-run lock - the lock is an exclusive flock, so our own
            # subprocess could not have started (item["status"] would be "blocked", not
            # "running") while another holder was still alive. Check for that explicitly instead
            # of always blaming "another process": far more often, this run's own subprocess
            # simply hasn't finished (and flushed) its first check yet, and latest.json is just
            # showing the previous run's leftover content - not a race at all.
            holder_pid = _active_run_lock_holder_pid(findings_dir)
            if holder_pid and holder_pid != current_process_pid:
                logger.warning(
                    "latest.json at %s carries runId %r, not the expected %r for %r - PID %s "
                    "still holds this environment's active-run lock (likely an orphaned launcher "
                    "subprocess from a previous run that outlived a server restart). It will "
                    "release the lock on its own once it exits; terminate PID %s directly if it "
                    "appears to be stuck.",
                    findings_dir / "latest.json", payload_run_id, run_id, item["name"], holder_pid, holder_pid,
                )
            else:
                logger.info(
                    "%r: latest.json still has previous runId %r (expected %r) - first check "
                    "still running, no lock conflict.",
                    item["name"], payload_run_id, run_id,
                )
        return 0
    _logged_latest_json_mismatch_run_ids.discard(item["runId"])
    results = payload.get("results")
    if not isinstance(results, list):
        return 0
    # Distinct CheckId, not len(results): a domain-scoped check writes one result row per
    # domain it ran against (New-VcfCheckPerDomainResults), so raw row count runs ahead of
    # totalChecks (a count of unique selected checks) - confirmed live as a progress bar
    # reading e.g. 36/28. Counting distinct CheckId values keeps this monotonic and bounded
    # by totalChecks regardless of how many domains a check fanned out to.
    return len({row.get("CheckId") for row in results if isinstance(row, dict)})


def _tail_launcher_log(base_directory: Path, since: int) -> dict:
    """Tails today's server log from a byte offset, scoped to launcher subprocess output. since<=0
    (the default) scopes to the current run's own header line (`===== Run <run_id> started ...`,
    written by _start_next_queue_item) rather than the whole day's file, so a freshly opened
    live-log panel does not have to scroll through every prior run that happened today."""
    log_path = _logs_dir(base_directory) / f"VcfCheckServer-{datetime.now().strftime('%Y-%m-%d')}.log"
    run_id = _run_queue.current_run_id()
    marker = f"===== Run {run_id} started".encode("utf-8") if run_id else None
    return _tail_log_file(log_path, since, marker=marker)


def _build_launcher_env(base_directory: Path, sddc_password: str, root_password: str, aria_ops_credentials: list = None) -> dict:
    env = {name: os.environ[name] for name in _SUBPROCESS_ENV_ALLOWLIST if name in os.environ}
    env["VcfCheckBaseDirectory"] = str(base_directory)
    env["VCFCHECK_MODULE_PSD1"] = str(_MODULE_PSD1)
    env["VCFCHECK_SDDC_PASSWORD"] = sddc_password
    if root_password:
        env["VCFCHECK_ROOT_PASSWORD"] = root_password
    if aria_ops_credentials:
        env["VCFCHECK_ARIAOPS_CREDENTIALS_JSON"] = json.dumps(aria_ops_credentials)
    return env


def _resolve_aria_ops_credentials(environment: dict, integration_credentials) -> list:
    """Resolves the browser-supplied per-endpoint Aria Operations passwords
    (environment.integrations[].endpoints[] indices) against the environment's stored
    Integrations, into the {Name, Fqdn, Username, Password} list Invoke-VcfCheckValidateCredentials.ps1
    expects on VCFCHECK_ARIAOPS_CREDENTIALS_JSON."""
    resolved = []
    if not isinstance(integration_credentials, list):
        return resolved
    integrations = environment.get("integrations") or []
    for entry in integration_credentials:
        if not isinstance(entry, dict):
            continue
        password = str(entry.get("password", "") or "")
        if not password:
            continue
        integration_index = entry.get("integrationIndex")
        endpoint_index = entry.get("endpointIndex")
        if not isinstance(integration_index, int):
            continue
        if integration_index < 0 or integration_index >= len(integrations):
            continue
        integration = integrations[integration_index] or {}
        if integration.get("type") != "AriaOperations":
            continue
        endpoints = integration.get("endpoints") or []

        # A shared-credential integration sends one password entry with endpointIndex omitted -
        # it applies to every endpoint under that integration, not just one.
        if integration.get("sharedCredentials"):
            target_endpoints = endpoints
        elif isinstance(endpoint_index, int) and 0 <= endpoint_index < len(endpoints):
            target_endpoints = [endpoints[endpoint_index]]
        else:
            continue

        for endpoint in target_endpoints:
            endpoint = endpoint or {}
            username = integration.get("username") if integration.get("sharedCredentials") else endpoint.get("username")
            if not endpoint.get("fqdn") or not username:
                continue
            resolved.append({
                "Name": endpoint.get("name") or endpoint.get("fqdn"),
                "Fqdn": endpoint.get("fqdn"),
                "Username": username,
                "Password": password,
            })
    return resolved


class VcfCheckRequestHandler(BaseHTTPRequestHandler):
    base_directory: Path = Path.home() / "VcfCheck"
    port: int = 8766

    def log_message(self, format_str, *args):  # noqa: A002 - stdlib signature
        logger.debug("%s - %s", self.address_string(), format_str % args)

    def _send_json(self, status: HTTPStatus, payload) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, status: HTTPStatus, content: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def _send_js(self, status: HTTPStatus, content: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/javascript; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def _resolve_findings_dir_for_request(self, environment_id):
        """Resolves the Findings/ directory scoped to an optional ?environmentId= query param.

        Returns (findings_dir, already_sent) - mirrors _read_json_body's "response already sent"
        convention so callers can `if already_sent: return` without duplicating the invalid-id /
        unknown-id checks that were previously copy-pasted across /api/runs/latest, /api/runs/<id>,
        and /api/export/logbundle. When environment_id is falsy, returns the root Findings/
        directory unscoped (already_sent=False, matching every one of those routes' original
        behavior when no environmentId was supplied).
        """
        findings_dir = _findings_dir(self.base_directory)
        if not environment_id:
            return findings_dir, False
        if not ENVIRONMENT_ID_PATTERN.match(environment_id):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Invalid environment id"})
            return None, True
        slug = _findings_slug_for_environment_id(self.base_directory, environment_id)
        if not slug:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": f"No environment found with id {environment_id!r}"})
            return None, True
        return findings_dir / slug, False

    def _same_origin(self) -> bool:
        """Reject a POST whose Origin/Host does not match this loopback server.

        The server binds to 127.0.0.1 only, so this is not a defense against a remote
        attacker - it guards against another origin's page issuing a same-origin-looking
        POST (simple form POSTs are not preflighted, so the loopback bind alone does not
        stop the *request* from being sent, only from being *read* cross-origin).
        """
        allowed_hosts = {f"127.0.0.1:{self.port}", f"localhost:{self.port}"}
        host = self.headers.get("Host", "")
        if host not in allowed_hosts:
            return False
        origin = self.headers.get("Origin")
        if origin is not None:
            origin_host = urlparse(origin).netloc
            if origin_host not in allowed_hosts:
                return False
        return True

    def _reject_cross_origin(self) -> bool:
        """Sends the 403 response and returns True when _same_origin() fails, or returns False
        (no response sent) when the request passes - mirrors _read_json_body's "already sent"
        convention so every state-changing route can `if self._reject_cross_origin(): return`
        instead of re-checking `if not self._same_origin(): ...` and writing the same 403 body
        itself (previously duplicated verbatim across do_POST, do_PUT, do_DELETE, and the GET
        /api/export/logbundle route)."""
        if self._same_origin():
            return False
        self._send_json(HTTPStatus.FORBIDDEN, {"error": "Origin/Host mismatch"})
        return True

    def _run_safely(self, dispatch) -> None:
        """Runs a do_GET/do_POST/do_PUT/do_DELETE dispatch method, turning any unexpected
        exception into a 500 JSON response instead of letting it propagate out of the method.
        An uncaught exception there gets logged by ThreadingHTTPServer's default error handler
        but never sends any HTTP response at all - the browser's fetch() then sees the
        connection drop and reports a bare "Failed to fetch"/"NetworkError" with no indication
        of what actually went wrong server-side. Every route below already returns a proper
        error response for the failure modes it anticipates; this is the backstop for the ones
        it doesn't."""
        try:
            dispatch()
        except Exception as exc:
            logger.exception("Unhandled error handling %s %s", self.command, self.path)
            try:
                logs_dir = _logs_dir(self.base_directory)
                log_file = logs_dir / f"VcfCheckServer-{datetime.now().strftime('%Y-%m-%d')}.log"
                error_msg = f"Internal server error: {exc}. Check the server log at: {log_file}"
                self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": error_msg})
            except Exception:
                pass

    def do_GET(self):  # noqa: N802 - stdlib method name
        self._run_safely(self._dispatch_get)

    # Exact-path GET routes, keyed by path -> handler method name (looked up via getattr, so
    # method definition order below doesn't matter). Replaces the long if/elif chain this used
    # to be - one more branch no longer means one more `if path == "...": ... return` to read
    # past to find the one you actually want. Each handler takes the already-parsed
    # urllib.parse.ParseResult for the request.
    _GET_ROUTES = {
        "/": "_get_index",
        "/index.html": "_get_index",
        "/docs": "_get_docs",
        "/api/runs": "_get_runs_list",
        "/api/runs/latest": "_get_runs_latest",
        "/api/settings": "_get_settings",
        "/api/version": "_get_version",
        "/api/checks": "_get_checks",
        "/api/sizing/options": "_get_sizing_options",
        "/api/run/status": "_get_run_status",
        "/api/run/log": "_get_run_log",
        "/api/validate-credentials/log": "_get_validate_credentials_log",
        "/api/export/logbundle": "_get_logbundle_export",
        "/api/environments": "_get_environments_list",
        "/api/vcf-destination-releases": "_get_vcf_destination_releases",
        "/api/powercli-tls-status": "_get_powercli_tls_status",
        **{path: "_get_ui_asset" for path in _UI_ASSET_FILES},
    }

    # Parameterized GET routes tried, in order, only after _GET_ROUTES has no exact match.
    _GET_PARAM_ROUTES = (
        (re.compile(r"^/api/runs/([0-9A-Za-z_-]+)$"), "_get_run_by_id"),
    )

    def _dispatch_get(self):
        parsed = urlparse(self.path)
        path = parsed.path

        handler_name = self._GET_ROUTES.get(path)
        if handler_name:
            getattr(self, handler_name)(parsed)
            return

        for pattern, handler_name in self._GET_PARAM_ROUTES:
            match = pattern.match(path)
            if match:
                getattr(self, handler_name)(parsed, *match.groups())
                return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def _get_index(self, parsed) -> None:
        if not UI_FILE.is_file():
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "UI file not found"})
            return
        self._send_html(HTTPStatus.OK, UI_FILE.read_bytes())

    def _get_docs(self, parsed) -> None:
        readme_file = _docs_dir(self.base_directory) / "README.html"
        if not readme_file.is_file():
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "Documentation not found"})
            return
        self._send_html(HTTPStatus.OK, readme_file.read_bytes())

    def _get_ui_asset(self, parsed) -> None:
        asset_file = _UI_ASSET_FILES.get(parsed.path)
        if asset_file is None or not asset_file.is_file():
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "UI asset not found"})
            return
        self._send_js(HTTPStatus.OK, asset_file.read_bytes())

    def _get_runs_list(self, parsed) -> None:
        findings_dir = _findings_dir(self.base_directory)
        run_ids = []
        if findings_dir.is_dir():
            for candidate in sorted(findings_dir.glob("run-*.json"), reverse=True):
                run_ids.append(candidate.stem.removeprefix("run-"))
        self._send_json(HTTPStatus.OK, {"runs": run_ids})

    def _get_runs_latest(self, parsed) -> None:
        environment_id = parse_qs(parsed.query).get("environmentId", [None])[0]
        findings_dir, already_sent = self._resolve_findings_dir_for_request(environment_id)
        if already_sent:
            return
        payload = _load_latest_findings_json(findings_dir / "latest.json")
        if payload is None:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "No runs found yet"})
            return
        self._send_json(HTTPStatus.OK, payload)

    def _get_settings(self, parsed) -> None:
        payload = _load_json_file(_config_dir(self.base_directory) / "settings.json") or {}
        self._send_json(
            HTTPStatus.OK,
            {
                "fqdn": payload.get("SddcManagerFqdn"),
                "username": payload.get("SddcManagerUser"),
                "theme": payload.get("Theme") or "light",
                "logViewLevel": payload.get("LogViewLevel") or "INFO",
                "tcpTimeoutSeconds": payload.get("TcpTimeoutSeconds") or 30,
                "vcfDestinationRelease": payload.get("VcfDestinationRelease") or "",
                "healthSummaryMaxPollAttempts": _get_health_summary_max_poll_attempts(self.base_directory),
                "preUpgradeCheckSetMaxPollAttempts": _get_pre_upgrade_check_set_max_poll_attempts(self.base_directory),
                "sizingEstimatorEnabled": _sizing_estimator_enabled(),
            },
        )

    def _get_vcf_destination_releases(self, parsed) -> None:
        versions = _fetch_vcf_destination_release_options()
        families = _families_from_versions(versions) if versions is not None else []
        self._send_json(
            HTTPStatus.OK,
            {"available": versions is not None, "versions": ["latest"] + families},
        )

    def _get_powercli_tls_status(self, parsed) -> None:
        """Reports PowerCLI's own InvalidCertificateAction setting (Get-PowerCLIConfiguration) -
        VcfCheck has no insecure-TLS setting of its own; every connector derives that decision
        from this PowerCLI setting instead (see Resolve-VcfCheckAllowInsecureTls in
        Private/Settings.ps1). This lets the web UI show that live state as a read-only
        indicator rather than a control."""
        args = [
            "pwsh", "-NoProfile", "-NonInteractive", "-Command",
            "(Get-PowerCLIConfiguration -Scope Session).InvalidCertificateAction.ToString()",
        ]
        try:
            completed = subprocess.run(
                args, capture_output=True, text=True, timeout=30, **_NO_WINDOW_KWARGS,
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            logger.warning("Could not read PowerCLI's InvalidCertificateAction: %s", exc)
            self._send_json(HTTPStatus.OK, {"invalidCertificateAction": None, "allowInsecureTls": None})
            return

        invalid_certificate_action = completed.stdout.strip()
        if completed.returncode != 0 or not invalid_certificate_action:
            logger.warning(
                "Could not read PowerCLI's InvalidCertificateAction (exit code %s): %s",
                completed.returncode, completed.stderr.strip(),
            )
            self._send_json(HTTPStatus.OK, {"invalidCertificateAction": None, "allowInsecureTls": None})
            return

        self._send_json(
            HTTPStatus.OK,
            {
                "invalidCertificateAction": invalid_certificate_action,
                "allowInsecureTls": invalid_certificate_action == "Ignore",
            },
        )

    def _get_version(self, parsed) -> None:
        server_script = Path(__file__).resolve()
        self._send_json(
            HTTPStatus.OK,
            {
                "version": _module_version(),
                "serverScriptModifiedAt": datetime.fromtimestamp(
                    server_script.stat().st_mtime
                ).isoformat(timespec="seconds"),
            },
        )

    def _get_checks(self, parsed) -> None:
        catalog = _load_check_catalog(self.base_directory)
        descriptions = _load_check_descriptions(self.base_directory)
        self._send_json(
            HTTPStatus.OK,
            {
                "areas": _checks_by_area(catalog, descriptions),
                "rootCredentialCheckIds": _root_credential_check_ids(catalog),
            },
        )

    def _get_sizing_options(self, parsed) -> None:
        reference_data = _load_sizing_reference_data(self.base_directory)
        treatment_data = _load_sizing_treatment_data(self.base_directory)
        self._send_json(
            HTTPStatus.OK,
            {
                "components": treatment_data.get("components", {}),
                "reference": reference_data,
                "vcenterSizeThresholds": treatment_data.get("vcenterSizeThresholds", {}),
            },
        )

    def _get_run_status(self, parsed) -> None:
        active = _run_queue.is_active(self.base_directory)
        snapshot = _run_queue.snapshot(self.base_directory)
        self._send_json(HTTPStatus.OK, {"running": active, **snapshot})

    def _get_run_log(self, parsed) -> None:
        query = parse_qs(parsed.query)
        try:
            since = int(query.get("since", ["0"])[0])
        except ValueError:
            since = 0
        self._send_json(HTTPStatus.OK, _tail_launcher_log(self.base_directory, since))

    def _get_validate_credentials_log(self, parsed) -> None:
        query = parse_qs(parsed.query)
        try:
            since = int(query.get("since", ["0"])[0])
        except ValueError:
            since = 0
        self._send_json(HTTPStatus.OK, _tail_credential_log(self.base_directory, since))

    def _get_logbundle_export(self, parsed) -> None:
        # Explicit origin check required - success path streams a ZIP archive, not via
        # _send_json(). _reject_cross_origin()'s own docstring frames this guard as being
        # for state-changing routes, but the check itself is Host/Origin-header-based and
        # applies just as well here: a simple cross-origin GET (no preflight) could
        # otherwise be used to trigger a download of another origin's data.
        if self._reject_cross_origin():
            return
        # Format-only validation, not _resolve_findings_dir_for_request: an unknown (but
        # well-formed) environment id here falls through to _list_findings_files returning no
        # files, which the "no logs or findings" 404 below already covers - no separate
        # "unknown environment" 404 needed for a bundle export.
        environment_id = parse_qs(parsed.query).get("environmentId", [None])[0]
        if environment_id and not ENVIRONMENT_ID_PATTERN.match(environment_id):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Invalid environment id"})
            return
        log_files = _list_log_files(self.base_directory)
        findings_files = _list_findings_files(self.base_directory, environment_id)
        if not log_files and not findings_files:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "No logs or findings found to bundle."})
            return
        findings_root = _findings_dir(self.base_directory)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        zip_name = f"VcfCheck-logbundle-{stamp}.zip"
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            for log_file in log_files:
                zf.write(log_file, f"Logs/{log_file.name}")
            for findings_file in findings_files:
                zf.write(findings_file, f"Findings/{findings_file.relative_to(findings_root)}")
        body = buf.getvalue()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", f'attachment; filename="{zip_name}"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _get_environments_list(self, parsed) -> None:
        self._send_json(HTTPStatus.OK, {"environments": _load_environments(self.base_directory)})

    def _get_run_by_id(self, parsed, run_id: str) -> None:
        if not RUN_ID_PATTERN.match(run_id):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Invalid run id"})
            return
        environment_id = parse_qs(parsed.query).get("environmentId", [None])[0]
        findings_dir, already_sent = self._resolve_findings_dir_for_request(environment_id)
        if already_sent:
            return
        payload = _load_json_file(findings_dir / f"run-{run_id}.json")
        if payload is None:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": f"Run '{run_id}' not found"})
            return
        self._send_json(HTTPStatus.OK, payload)

    def _read_json_body(self):
        """Reads and parses this request's body. Returns (body, None) on success, or
        (None, error_response_already_sent=True) after writing a 400 response itself."""
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            content_length = 0
        raw_body = self.rfile.read(content_length) if content_length > 0 else b""

        try:
            body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Request body is not valid JSON"})
            return None, True
        return body, False

    def do_POST(self):  # noqa: N802 - stdlib method name
        self._run_safely(self._dispatch_post)

    def _dispatch_post(self):
        parsed = urlparse(self.path)
        if parsed.path not in (
            "/api/run/start",
            "/api/run/cancel",
            "/api/run/force-clear",
            "/api/validate-credentials",
            "/api/settings",
            "/api/environments",
            "/api/export/logbundle-ack",
            "/api/sizing/estimate",
            "/api/sizing/detect",
            "/api/sizing/save-estimate",
        ):
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
            return

        if self._reject_cross_origin():
            return

        if parsed.path == "/api/run/cancel":
            self._handle_run_cancel()
            return

        if parsed.path == "/api/run/force-clear":
            self._handle_run_force_clear()
            return

        body, already_sent = self._read_json_body()
        if already_sent:
            return

        if parsed.path == "/api/validate-credentials":
            self._handle_validate_credentials(body)
        elif parsed.path == "/api/settings":
            self._handle_settings_update(body)
        elif parsed.path == "/api/environments":
            self._handle_environment_create(body)
        elif parsed.path == "/api/export/logbundle-ack":
            self._handle_logbundle_ack(body)
        elif parsed.path == "/api/sizing/estimate":
            self._handle_sizing_estimate(body)
        elif parsed.path == "/api/sizing/detect":
            self._handle_sizing_detect(body)
        elif parsed.path == "/api/sizing/save-estimate":
            self._handle_sizing_save_estimate(body)
        else:
            self._handle_run_start(body)

    def do_PUT(self):  # noqa: N802 - stdlib method name
        self._run_safely(self._dispatch_put)

    def _dispatch_put(self):
        parsed = urlparse(self.path)
        match = ENVIRONMENT_ID_ROUTE_PATTERN.match(parsed.path)
        if not match:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
            return
        if self._reject_cross_origin():
            return

        body, already_sent = self._read_json_body()
        if already_sent:
            return
        self._handle_environment_update(match.group(1), body)

    def do_DELETE(self):  # noqa: N802 - stdlib method name
        self._run_safely(self._dispatch_delete)

    def _dispatch_delete(self):
        parsed = urlparse(self.path)
        match = ENVIRONMENT_ID_ROUTE_PATTERN.match(parsed.path)
        if not match:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
            return
        if self._reject_cross_origin():
            return

        self._handle_environment_delete(match.group(1))

    def _handle_logbundle_ack(self, body: dict) -> None:
        """Audit-logs the browser's accept/cancel decision on the log bundle's sensitive-data
        disclaimer - mirrors the sibling VCF.Patch.Scanner tool's /scan/collect-logs-ack. The
        actual download is a separate GET (/api/export/logbundle); this only records what the
        user chose, it never gates the download itself (the browser already withheld the GET
        until the user clicked Proceed)."""
        proceeded = bool(body.get("proceeded"))
        client = f"{self.client_address[0]}:{self.client_address[1]}" if self.client_address else "unknown"
        action = "acknowledged and proceeded" if proceeded else "cancelled"
        logger.info("Log bundle export security warning %s by %s", action, client)
        self._send_json(HTTPStatus.OK, {"ok": True})

    def _handle_sizing_estimate(self, body: dict) -> None:
        """Computes the VCF 9.1.1 management domain sizing/upgrade-delta estimate via the
        long-lived _sizing_worker process (Invoke-VcfCheckSizingWorker.ps1), which calls
        Get-VcfCheckManagementDomainSizingEstimate - kept as the single source of truth for
        this arithmetic rather than reimplementing it here. A fresh `pwsh -File` subprocess per
        request (the original implementation) paid the module-import cost - about 1 second - on
        every "Calculate" click even though the estimate itself is pure arithmetic over static
        data; the worker pays that cost once and answers subsequent requests over its stdin/stdout
        pipe instead."""
        selections = body.get("selections")
        if not isinstance(selections, list):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "'selections' must be an array"})
            return

        try:
            estimate = _sizing_worker.request(selections)
        except (RuntimeError, TimeoutError, OSError) as exc:
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": f"Could not run the sizing estimator: {exc}"})
            return
        except json.JSONDecodeError:
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "Sizing estimator returned invalid JSON"})
            return

        if isinstance(estimate, dict) and "error" in estimate and "Components" not in estimate:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": estimate["error"]})
            return

        self._send_json(HTTPStatus.OK, estimate)

    def _handle_sizing_save_estimate(self, body: dict) -> None:
        """Persists the sizing wizard's Refinement-step estimate as a JSON file plus a standalone
        HTML report (_render_sizing_estimate_html) under the requesting Environment's own
        Findings/<slug>/ subdirectory, so both ride along automatically with that environment's
        ZIP export (client-side) and /api/export/logbundle (server-side, which picks up every
        *.json and *.html under Findings/<slug>/ - see _list_findings_files)."""
        environment_id = body.get("environmentId")
        estimate = body.get("estimate")
        if not isinstance(environment_id, str) or not environment_id:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "'environmentId' is required"})
            return
        if not isinstance(estimate, dict):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "'estimate' must be an object"})
            return

        findings_dir, already_sent = self._resolve_findings_dir_for_request(environment_id)
        if already_sent:
            return
        findings_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        json_file_name = f"resource-estimation-{stamp}.json"
        html_file_name = f"resource-estimation-{stamp}.html"
        (findings_dir / json_file_name).write_text(json.dumps(estimate, indent=2), encoding="utf-8")
        (findings_dir / html_file_name).write_text(_render_sizing_estimate_html(estimate), encoding="utf-8")
        self._update_environment_resource_estimate(environment_id, estimate)
        self._send_json(HTTPStatus.OK, {"ok": True, "fileName": json_file_name, "htmlFileName": html_file_name})

    def _update_environment_resource_estimate(self, environment_id: str, estimate: dict) -> None:
        """Records the Refinement step's physical vCPU/memory/disk totals onto the environment's
        own entry in environments.json (managementResourcesForVcf9Upgrade), so a later feature -
        e.g. a management-domain resource-utilization view - can read the environment's most
        recent estimate without re-running the wizard. Created on the first save, overwritten on
        every subsequent one; failure to update it (e.g. environment deleted mid-wizard) is
        logged and swallowed rather than failing the estimate save that already succeeded."""
        totals = estimate.get("totals") or {}
        environments = _load_environments(self.base_directory)
        environment = next((env for env in environments if env.get("id") == environment_id), None)
        if environment is None:
            logger.warning("Could not record resource estimate: unknown environment id %r", environment_id)
            return
        environment["managementResourcesForVcf9Upgrade"] = {
            "CPU": round(float(totals.get("physicalVCpu", 0))),
            "memoryGB": round(float(totals.get("physicalMemoryGb", 0))),
            "diskGB": round(float(totals.get("storageGb", 0))),
            "updatedAt": datetime.now(timezone.utc).isoformat(),
        }
        _save_environments(self.base_directory, environments)

    def _handle_sizing_detect(self, body: dict) -> None:
        """Live auto-detection for the sizing wizard: connects to the given saved Environment's
        SDDC Manager, resolves its management domain vCenter and every workload domain vCenter,
        and returns live host/VM counts plus Supervisor presence for each via
        Invoke-VcfCheckSizingDetect.ps1. A one-shot `pwsh -File`
        subprocess (like /api/validate-credentials, not the persistent /api/sizing/estimate
        worker) - this is an occasional user-triggered action, not a per-keystroke hot path, so
        the ~1s module-import cost is an acceptable trade for not holding a live SDDC
        Manager/vCenter connection open in a long-lived process."""
        environment_id = str(body.get("environmentId", "")).strip()
        password = str(body.get("password", "") or "")
        if not environment_id or not password:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "environmentId and password are required"})
            return

        environment = next((env for env in _load_environments(self.base_directory) if env["id"] == environment_id), None)
        if environment is None:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"Unknown environment id: {environment_id!r}"})
            return

        env = _build_launcher_env(self.base_directory, password, "")
        tcp_timeout_seconds = _get_tcp_timeout_seconds(self.base_directory)

        # Invoke-VcfCheckSizingDetect.ps1 writes its current step to this file (via
        # Write-VcfCheckSizingProgress) as it goes, so if the subprocess below is killed for
        # exceeding subprocess_timeout_seconds, we can still report which check it was stuck on
        # instead of just "timed out" - the killed process never gets to log that itself.
        run_dir = self.base_directory / "Run"
        run_dir.mkdir(parents=True, exist_ok=True)
        progress_file = run_dir / f"sizing-detect-progress-{uuid.uuid4().hex}.json"
        env["VCFCHECK_SIZING_PROGRESS_FILE"] = str(progress_file)

        args = [
            "pwsh", "-NoProfile", "-NonInteractive", "-File", str(SIZING_DETECT_SCRIPT),
            "-SddcManagerFqdn", environment["sddcManagerFqdn"],
            "-SddcManagerUser", environment["sddcManagerUser"],
            "-ConnectivityTimeoutSeconds", str(tcp_timeout_seconds),
        ]

        # +30s buffer over the TCP timeout, same rationale as _run_validate_credentials_script:
        # a user-raised TCP timeout could otherwise exceed this subprocess wait and get killed
        # before the PowerShell-side connect attempt itself gives up.
        subprocess_timeout_seconds = tcp_timeout_seconds + 30
        try:
            completed = subprocess.run(
                args, env=env, capture_output=True, text=True,
                timeout=subprocess_timeout_seconds, **_NO_WINDOW_KWARGS,
            )
        except subprocess.TimeoutExpired:
            stuck_on = _describe_sizing_detect_progress(progress_file)
            logger.error(
                "Sizing detection for %s timed out after %s seconds; last recorded step: %s",
                environment["sddcManagerFqdn"], subprocess_timeout_seconds, stuck_on or "none recorded",
            )
            message = f"Sizing detection timed out after {subprocess_timeout_seconds} seconds"
            message += f" while {stuck_on}." if stuck_on else "."
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": message})
            return
        except OSError as exc:
            logger.error("Could not start sizing detection: %s", exc)
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": f"Could not start pwsh: {exc}"})
            return
        finally:
            progress_file.unlink(missing_ok=True)

        # Never log stdout/stderr - see _run_validate_credentials_script's identical rationale.
        result = _extract_json_object(completed.stdout, "managementDomainVCenter") or _extract_json_object(completed.stdout, "error")
        if result is None:
            logger.warning("Sizing detection for %s produced no parseable result (exit code %s)", environment["sddcManagerFqdn"], completed.returncode)
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "Sizing detection did not return a result. Check the server log for details."})
            return

        if "error" in result:
            logger.info("Sizing detection for %s failed", environment["sddcManagerFqdn"])
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": result["error"]})
            return

        management_snapshot = result.get("managementDomainVCenter") or {}
        workload_snapshots = result.get("workloadDomainVCenters") or []
        logger.info("Sizing detection for %s: managementHostCount=%s managementVirtualMachineCount=%s workloadDomainVCenterCount=%s",
                     environment["sddcManagerFqdn"], management_snapshot.get("hostCount"),
                     management_snapshot.get("virtualMachineCount"), len(workload_snapshots))
        self._send_json(HTTPStatus.OK, {
            "managementDomainVCenter": management_snapshot,
            "workloadDomainVCenters": workload_snapshots,
        })

    def _handle_settings_update(self, body: dict) -> None:
        """Persist browser-only preferences (theme, live log detail level) to settings.json.

        Read-merge-write against whatever settings.json already holds, so this never clobbers
        the FQDN/username _handle_run_start wrote as a side effect of starting a run. Each
        preference is applied independently and only if present in the request body, so the
        browser can save theme and logViewLevel via separate calls without one clobbering the
        other.
        """
        updates = {}

        if "theme" in body:
            theme = body.get("theme")
            if theme not in ("light", "dark"):
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "theme must be 'light' or 'dark'"})
                return
            updates["Theme"] = theme

        if "logViewLevel" in body:
            log_view_level = body.get("logViewLevel")
            if log_view_level not in ("DEBUG", "INFO", "WARNING"):
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "logViewLevel must be 'DEBUG', 'INFO', or 'WARNING'"})
                return
            updates["LogViewLevel"] = log_view_level

        if "tcpTimeoutSeconds" in body:
            tcp_timeout_seconds = body.get("tcpTimeoutSeconds")
            if not isinstance(tcp_timeout_seconds, int) or isinstance(tcp_timeout_seconds, bool) or not (1 <= tcp_timeout_seconds <= 300):
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "tcpTimeoutSeconds must be an integer between 1 and 300"})
                return
            updates["TcpTimeoutSeconds"] = tcp_timeout_seconds

        if "vcfDestinationRelease" in body:
            vcf_destination_release = body.get("vcfDestinationRelease") or ""
            if vcf_destination_release and vcf_destination_release != "latest":
                parsed_release = _parse_dotted_version(vcf_destination_release)
                if parsed_release is None:
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": "vcfDestinationRelease must be 'latest', a release family (e.g. 9.1.0), a full dotted version (e.g. 9.1.0.0300), or empty"})
                    return
                if parsed_release < VCF_DESTINATION_RELEASE_FLOOR[: len(parsed_release)]:
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"vcfDestinationRelease must be {'.'.join(map(str, VCF_DESTINATION_RELEASE_FLOOR))} or newer"})
                    return
                if len(parsed_release) == 4:
                    # Interop Matrix snapshots (Data/Interoperability/*.json) always zero-pad the
                    # 4th segment to 4 digits (e.g. "9.1.0.0400"); Test-VcfSddcBomCheck.ps1 does an
                    # exact-string match against that format, so a differently-padded build number
                    # (e.g. "9.1.0.040") would silently never match.
                    vcf_destination_release = "{}.{}.{}.{:04d}".format(*parsed_release)
            updates["VcfDestinationRelease"] = vcf_destination_release

        if "healthSummaryMaxPollAttempts" in body:
            health_summary_max_poll_attempts = body.get("healthSummaryMaxPollAttempts")
            if health_summary_max_poll_attempts not in HEALTH_SUMMARY_MAX_POLL_ATTEMPTS_CHOICES:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"healthSummaryMaxPollAttempts must be one of {HEALTH_SUMMARY_MAX_POLL_ATTEMPTS_CHOICES}"})
                return
            updates["HealthSummaryMaxPollAttempts"] = health_summary_max_poll_attempts

        if "preUpgradeCheckSetMaxPollAttempts" in body:
            pre_upgrade_check_set_max_poll_attempts = body.get("preUpgradeCheckSetMaxPollAttempts")
            if pre_upgrade_check_set_max_poll_attempts not in PRE_UPGRADE_CHECK_SET_MAX_POLL_ATTEMPTS_CHOICES:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"preUpgradeCheckSetMaxPollAttempts must be one of {PRE_UPGRADE_CHECK_SET_MAX_POLL_ATTEMPTS_CHOICES}"})
                return
            updates["PreUpgradeCheckSetMaxPollAttempts"] = pre_upgrade_check_set_max_poll_attempts

        if not updates:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "No recognized setting provided"})
            return

        config_dir = _config_dir(self.base_directory)
        settings_path = config_dir / "settings.json"
        existing = _load_json_file(settings_path) or {}
        existing.update(updates)

        try:
            config_dir.mkdir(parents=True, exist_ok=True)
            settings_path.write_text(json.dumps(existing, indent=2), encoding="utf-8")
        except OSError as exc:
            logger.warning("Could not write settings.json: %s", exc)
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": f"Could not save settings: {exc}"})
            return

        self._send_json(
            HTTPStatus.OK,
            {
                "theme": existing.get("Theme"),
                "logViewLevel": existing.get("LogViewLevel"),
                "tcpTimeoutSeconds": existing.get("TcpTimeoutSeconds"),
                "vcfDestinationRelease": existing.get("VcfDestinationRelease"),
                "healthSummaryMaxPollAttempts": existing.get("HealthSummaryMaxPollAttempts"),
                "preUpgradeCheckSetMaxPollAttempts": existing.get("PreUpgradeCheckSetMaxPollAttempts"),
            },
        )

    def _handle_environment_create(self, body: dict) -> None:
        environments = _load_environments(self.base_directory)
        error = _validate_environment_body(body, environments)
        if error:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": error})
            return

        now = datetime.now(timezone.utc).isoformat()
        new_environment = {
            "id": _new_environment_id(),
            "name": str(body["name"]).strip(),
            "sddcManagerFqdn": str(body["sddcManagerFqdn"]).strip(),
            "sddcManagerUser": str(body["sddcManagerUser"]).strip(),
            "enableRootCredentialChecks": bool(body.get("enableRootCredentialChecks", False)),
            "integrations": body.get("integrations") or [],
            "createdAt": now,
            "updatedAt": now,
        }
        environments.append(new_environment)
        _save_environments(self.base_directory, environments)
        self._send_json(HTTPStatus.CREATED, new_environment)

    def _handle_environment_update(self, environment_id: str, body: dict) -> None:
        environments = _load_environments(self.base_directory)
        existing = next((env for env in environments if env["id"] == environment_id), None)
        if existing is None:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": f"No environment found with id {environment_id!r}"})
            return

        error = _validate_environment_body(body, environments, exclude_id=environment_id)
        if error:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": error})
            return

        existing["name"] = str(body["name"]).strip()
        existing["sddcManagerFqdn"] = str(body["sddcManagerFqdn"]).strip()
        existing["sddcManagerUser"] = str(body["sddcManagerUser"]).strip()
        existing["enableRootCredentialChecks"] = bool(body.get("enableRootCredentialChecks", False))
        existing["integrations"] = body.get("integrations") or []
        existing["updatedAt"] = datetime.now(timezone.utc).isoformat()

        _save_environments(self.base_directory, environments)
        self._send_json(HTTPStatus.OK, existing)

    def _handle_environment_delete(self, environment_id: str) -> None:
        if _run_queue.has_active_item_for_environment(environment_id):
            self._send_json(HTTPStatus.CONFLICT, {"error": "Cannot delete an environment while a run against it is queued or in progress"})
            return

        environments = _load_environments(self.base_directory)
        remaining = [env for env in environments if env["id"] != environment_id]
        if len(remaining) == len(environments):
            self._send_json(HTTPStatus.NOT_FOUND, {"error": f"No environment found with id {environment_id!r}"})
            return

        _save_environments(self.base_directory, remaining)
        self._send_json(HTTPStatus.OK, {"deleted": environment_id})

    def _run_validate_credentials_script(
        self, fqdn: str, username: str, password: str, root_password: str, aria_ops_credentials: list = None
    ) -> dict:
        """Runs Invoke-VcfCheckValidateCredentials.ps1 once and returns its parsed result (or a
        synthesized failure dict on a timeout/start/parse failure) - shared by both the
        back-compat single-target body and the multi-environment items body in
        _handle_validate_credentials below."""
        env = _build_launcher_env(self.base_directory, password, root_password, aria_ops_credentials)
        tcp_timeout_seconds = _get_tcp_timeout_seconds(self.base_directory)
        args = [
            "pwsh", "-NoProfile", "-NonInteractive", "-File", str(VALIDATE_CREDENTIALS_SCRIPT),
            "-SddcManagerFqdn", fqdn,
            "-SddcManagerUser", username,
            "-ConnectivityTimeoutSeconds", str(tcp_timeout_seconds),
        ]

        # +30s buffer over the TCP timeout for authentication/API calls made once a connection
        # is established - otherwise a user-raised TCP timeout could exceed this subprocess wait
        # and get killed before the PowerShell-side check itself gives up.
        subprocess_timeout_seconds = tcp_timeout_seconds + 30
        try:
            completed = subprocess.run(
                args, env=env, capture_output=True, text=True,
                timeout=subprocess_timeout_seconds, **_NO_WINDOW_KWARGS,
            )
        except subprocess.TimeoutExpired:
            return {
                "success": False, "error": f"Credential validation timed out after {subprocess_timeout_seconds} seconds.",
                "rootCredentialTested": False, "rootCredentialSuccess": None, "rootCredentialError": None,
                "domains": [],
            }
        except OSError as exc:
            logger.error("Could not start credential validation: %s", exc)
            return {
                "success": False, "error": f"Could not start pwsh: {exc}",
                "rootCredentialTested": False, "rootCredentialSuccess": None, "rootCredentialError": None,
                "domains": [],
            }

        # Never log stdout/stderr - they may contain a redacted-but-still-sensitive-adjacent
        # error message; only the pass/fail outcome itself is logged.
        result = _extract_json_object(completed.stdout, "success")
        if result is None:
            logger.warning("Credential validation for %s produced no parseable result (exit code %s)", fqdn, completed.returncode)
            return {
                "success": False, "error": "Credential validation did not return a result. Check the server log for details.",
                "rootCredentialTested": False, "rootCredentialSuccess": None, "rootCredentialError": None,
                "domains": [],
            }

        logger.info("Credential validation for %s: success=%s", fqdn, result.get("success"))
        response = {
            "success": bool(result.get("success")),
            "error": result.get("error"),
            "rootCredentialTested": bool(result.get("rootCredentialTested", False)),
            "rootCredentialSuccess": result.get("rootCredentialSuccess"),
            "rootCredentialError": result.get("rootCredentialError"),
        }
        # Preserve phases array from PowerShell if present (phase-based credential validation)
        if "phases" in result:
            response["phases"] = result.get("phases")
        response["domains"] = result.get("domains", [])
        return response

    def _handle_validate_credentials(self, body: dict) -> None:
        raw_items = body.get("items")
        if isinstance(raw_items, list) and raw_items:
            environments = {env["id"]: env for env in _load_environments(self.base_directory)}
            results = []
            for raw_item in raw_items:
                environment_id = str(raw_item.get("environmentId", "")).strip()
                environment = environments.get(environment_id)
                if not environment:
                    results.append({"environmentId": environment_id, "success": False, "error": f"Unknown environment id: {environment_id!r}"})
                    continue
                password = str(raw_item.get("password", "") or "")
                if not password:
                    results.append({"environmentId": environment_id, "success": False, "error": "A password is required"})
                    continue
                root_password = str(raw_item.get("rootPassword", "") or "")
                aria_ops_credentials = _resolve_aria_ops_credentials(environment, raw_item.get("integrationCredentials"))
                outcome = self._run_validate_credentials_script(
                    environment["sddcManagerFqdn"], environment["sddcManagerUser"], password, root_password, aria_ops_credentials
                )
                outcome["environmentId"] = environment_id
                results.append(outcome)
            self._send_json(HTTPStatus.OK, {"results": results})
            return

        fqdn = str(body.get("fqdn", "")).strip()
        username = str(body.get("username", "")).strip()
        password = str(body.get("password", "") or "")
        root_password = str(body.get("rootPassword", "") or "")

        if not fqdn or not username or not password:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "fqdn, username, and password are required"})
            return
        cli_error = reject_unsafe_cli_value(fqdn, "fqdn") or reject_unsafe_cli_value(username, "username")
        if cli_error:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": cli_error})
            return

        self._send_json(HTTPStatus.OK, self._run_validate_credentials_script(fqdn, username, password, root_password))

    def _handle_run_cancel(self) -> None:
        """Terminates the active launcher subprocess and drops the rest of the queue, so a
        browser-side cancel actually stops the server-side run instead of only resetting the
        tab's own isRunning flag - previously the orphaned pwsh process (and RunQueue's own
        process reference) lived on, failing the next /api/run/start with "A run is already in
        progress" until it happened to exit on its own."""
        _run_queue.cancel()
        self._send_json(HTTPStatus.OK, {"cancelled": True})

    def _handle_run_force_clear(self) -> None:
        """Emergency reset: force-clears the run state without gracefully terminating the process.
        Use this only if the normal cancel doesn't work (e.g. process is hung or zombie).
        This allows a new run to be started even if the old one is still lurking in the background."""
        _run_queue.force_clear()
        self._send_json(HTTPStatus.OK, {"forcedCleared": True, "message": "Run state cleared. You can now start a new scan."})

    def _handle_run_start(self, body: dict) -> None:
        catalog = _load_check_catalog(self.base_directory)
        root_credential_ids = set(_root_credential_check_ids(catalog))

        explicit_check_ids = body.get("checkIds")
        if isinstance(explicit_check_ids, list) and explicit_check_ids:
            candidate_ids = [str(c) for c in explicit_check_ids]
        else:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "A non-empty checkIds array is required"})
            return

        unknown_ids = [c for c in candidate_ids if c not in catalog]
        if unknown_ids:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"Unknown check id(s): {', '.join(unknown_ids)}"})
            return

        # Run-wide domain scope (empty = every domain), same "no upfront validation against a
        # known list" convention as -CheckId already uses - applied uniformly to every
        # queued environment, same as candidate_ids above.
        raw_domains = body.get("domains")
        selected_domains = [str(d) for d in raw_domains] if isinstance(raw_domains, list) else []

        # A single comma-joined string, not one argv element per check id, is passed to
        # -CheckId (see _start_next_queue_item) - confirmed live that pwsh -File's argv binding
        # does NOT greedily consume multiple space-separated tokens into a named array parameter;
        # a second bare token silently binds positionally to the NEXT declared parameter instead,
        # corrupting the run. Every id here is already validated to be a real catalog key (none
        # contain a comma), so the join/split round-trip on the PowerShell side is unambiguous.

        raw_items = body.get("items")
        queue_items = []

        if isinstance(raw_items, list) and raw_items:
            environments = {env["id"]: env for env in _load_environments(self.base_directory)}
            for raw_item in raw_items:
                environment_id = str(raw_item.get("environmentId", "")).strip()
                environment = environments.get(environment_id)
                if not environment:
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"Unknown environment id: {environment_id!r}"})
                    return
                password = str(raw_item.get("password", "") or "")
                if not password:
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"A password is required for environment {environment['name']!r}"})
                    return
                root_password = str(raw_item.get("rootPassword", "") or "")
                item_check_ids = candidate_ids if root_password else [c for c in candidate_ids if c not in root_credential_ids]
                if not item_check_ids:
                    self._send_json(
                        HTTPStatus.BAD_REQUEST,
                        {"error": f"No checks to run for environment {environment['name']!r} - every selected check requires the SDDC Manager root password, which was not provided"},
                    )
                    return
                aria_ops_credentials = _resolve_aria_ops_credentials(environment, raw_item.get("integrationCredentials"))
                queue_items.append({
                    "environmentId": environment_id, "name": environment["name"],
                    "findingsSlug": _slugify_environment_name(environment["name"]),
                    "fqdn": environment["sddcManagerFqdn"], "username": environment["sddcManagerUser"],
                    "password": password, "rootPassword": root_password, "ariaOpsCredentials": aria_ops_credentials,
                    "checkIds": item_check_ids, "domains": selected_domains, "status": "pending", "runId": None,
                    "totalChecks": len(item_check_ids),
                })
        else:
            # Back-compat: the original single-target flat body.
            fqdn = str(body.get("fqdn", "")).strip()
            username = str(body.get("username", "")).strip()
            password = str(body.get("password", "") or "")
            root_password = str(body.get("rootPassword", "") or "")

            if not fqdn or not username or not password:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "fqdn, username, and password are required"})
                return
            cli_error = reject_unsafe_cli_value(fqdn, "fqdn") or reject_unsafe_cli_value(username, "username")
            if cli_error:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": cli_error})
                return

            item_check_ids = candidate_ids if root_password else [c for c in candidate_ids if c not in root_credential_ids]
            if not item_check_ids:
                self._send_json(
                    HTTPStatus.BAD_REQUEST,
                    {"error": "No checks to run - every selected check requires the SDDC Manager root password, which was not provided"},
                )
                return

            if bool(body.get("saveUsername", False)):
                try:
                    config_dir = _config_dir(self.base_directory)
                    config_dir.mkdir(parents=True, exist_ok=True)
                    settings_path = config_dir / "settings.json"
                    settings_path.write_text(
                        json.dumps({"SddcManagerFqdn": fqdn, "SddcManagerUser": username}, indent=2),
                        encoding="utf-8",
                    )
                except OSError as exc:
                    logger.warning("Could not write settings.json: %s", exc)

            queue_items.append({
                "environmentId": None, "name": fqdn, "fqdn": fqdn, "username": username,
                "password": password, "rootPassword": root_password,
                "checkIds": item_check_ids, "domains": selected_domains, "status": "pending", "runId": None,
                "totalChecks": len(item_check_ids),
            })

        if _run_queue.is_active(self.base_directory):
            self._send_json(HTTPStatus.CONFLICT, {"error": "A run is already in progress"})
            return

        result = _run_queue.start(self.base_directory, queue_items)

        if not result["started"]:
            detail = "; ".join(result["blockReasons"]) if result["blockReasons"] else "no reason was recorded"
            self._send_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": f"Could not start any queued run - {detail}"},
            )
            return

        # Never log the request body/env - only run metadata.
        self._send_json(
            HTTPStatus.ACCEPTED,
            {
                "runId": result["runId"],
                "totalChecks": queue_items[0]["totalChecks"],
                "startedAt": result["startedAt"],
                "queueLength": len(queue_items),
            },
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="VcfCheck local report viewer and launcher")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument(
        "--base-directory",
        type=Path,
        default=Path.home() / "VcfCheck",
        help="VcfCheck user working directory (contains Findings/, Logs/, Run/, etc.)",
    )
    parser.add_argument(
        "--pid-file",
        type=Path,
        default=None,
        help="Path to write the server PID after binding (used by Manage-VcfCheckServer.py)",
    )
    args = parser.parse_args()
    pid_file_path = args.pid_file

    # Resolve to an absolute path unconditionally, even though the default is already
    # absolute - argparse's type=Path does not resolve a relative --base-directory value
    # passed explicitly, and this directory is embedded verbatim into the launcher
    # subprocess's VcfCheckBaseDirectory env var (_build_launcher_env below). A relative
    # value there would resolve against the pwsh subprocess's inherited CWD instead of this
    # server's intended data directory, scattering Findings/Logs wherever the server happened
    # to be started from.
    args.base_directory = args.base_directory.expanduser().resolve()

    logs_dir = args.base_directory / "Logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    # Naming mirrors pwsh-vcf-sa/VCF.Patch.Scanner's own Server log
    # (VcfPatchScannerServer-yyyy-MM-dd.log): PascalCase prefix, ISO-like hyphenated date, one
    # file per calendar day (every request that day appends to the same file).
    server_log_path = logs_dir / f"VcfCheckServer-{datetime.now().strftime('%Y-%m-%d')}.log"
    formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    file_handler = logging.FileHandler(server_log_path)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False

    VcfCheckRequestHandler.base_directory = args.base_directory
    VcfCheckRequestHandler.port = args.port
    server = ThreadingHTTPServer(("127.0.0.1", args.port), VcfCheckRequestHandler)
    logger.info("VcfCheck report viewer listening on http://127.0.0.1:%s", args.port)
    logger.info("Module PSD1: %s (exists: %s)", _MODULE_PSD1, _MODULE_PSD1.is_file())
    logger.info(
        "Server script: %s (last modified: %s) - restart this process after pulling code "
        "changes; a running process keeps serving whatever routes/logic it loaded at startup.",
        Path(__file__).resolve(),
        datetime.fromtimestamp(Path(__file__).resolve().stat().st_mtime).isoformat(timespec="seconds"),
    )

    if pid_file_path:
        try:
            pid_file_path.parent.mkdir(parents=True, exist_ok=True)
            pid_file_path.write_text(str(os.getpid()), encoding="utf-8")
            try:
                pid_file_path.chmod(0o600)
            except OSError:
                pass
            logger.info("PID file: %s", pid_file_path)
        except OSError as exc:
            logger.warning("Could not write PID file %s: %s", pid_file_path, exc)
            pid_file_path = None

    def _handle_sigterm(signum, frame):  # noqa: ARG001 - required signal handler signature
        # Manage-VcfCheckServer.py's `stop` command (and Stop-VcfCheckServer /
        # Start-VcfCheckServer -Force in Tools.ps1) only ever os.kill()/Stop-Process the
        # server's own PID - server.shutdown() must run off the thread that's blocked in
        # serve_forever(), so it is dispatched from here rather than called directly.
        logger.info("Received SIGTERM, shutting down.")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _handle_sigterm)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down.")
    finally:
        _run_queue.terminate()
        _sizing_worker.terminate()
        if pid_file_path:
            try:
                pid_file_path.unlink(missing_ok=True)
            except OSError:
                pass
        server.server_close()


if __name__ == "__main__":
    main()
