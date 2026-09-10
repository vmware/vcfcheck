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
"""Sizing-estimator worker process and HTML rendering for Start-VcfCheckServer.py.

SIZING_WORKER_SCRIPT and _NO_WINDOW_KWARGS are computed independently here (rather than
imported back from the entry-point module) to avoid a circular import between the two - the
same rationale as paths.py's own copy of _NO_WINDOW_KWARGS.
"""

import html
import json
import os
import subprocess
import sys
import threading
from pathlib import Path

from vcfcheck_server.json_utils import _load_json_file
from vcfcheck_server.paths import _MODULE_PSD1, _data_dir

MODULE_DIR = Path(__file__).resolve().parent.parent
SIZING_WORKER_SCRIPT = MODULE_DIR / "Invoke-VcfCheckSizingWorker.ps1"

_NO_WINDOW_KWARGS = (
    {"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" else {}
)


def _sizing_estimator_enabled() -> bool:
    return os.environ.get("VCF_CHECK_RESOURCE_ESTIMATOR_UI", "").strip().lower() in ("true", "1")


class SizingWorker:
    """Owns a single long-lived `pwsh -File Invoke-VcfCheckSizingWorker.ps1` subprocess used
    to answer /api/sizing/estimate requests, instead of spawning a fresh `pwsh` process (and
    paying its ~1 second module-import cost) on every "Calculate" click. The worker script
    imports the VcfCheck module and loads the sizing reference/treatment data once at
    startup, then answers one selections-array request per stdin line with one estimate per
    stdout line for as long as the process lives.

    Locking convention: `request()` acquires self.lock for its entire request/response
    round-trip, since the worker is a single stdin/stdout pipe pair that cannot interleave two
    requests. A request that finds the process dead (first use, prior crash, or a stuck pipe
    killed by a previous timeout) starts a fresh one before writing to it. A request that gets
    no reply within its timeout is treated as a dead worker: the process is killed, restarted
    once, and the same selections are retried exactly once before giving up.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.process = None

    def _start_locked(self) -> None:
        env = dict(os.environ)
        env["VCFCHECK_MODULE_PSD1"] = str(_MODULE_PSD1)
        process = subprocess.Popen(
            ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(SIZING_WORKER_SCRIPT)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, env=env, **_NO_WINDOW_KWARGS,
        )
        ready_line = self._readline_locked(process, timeout=30)
        if ready_line is None or ready_line.strip() != "READY":
            stderr_text = ""
            try:
                process.kill()
                stderr_text = process.communicate(timeout=5)[1].strip()
            except Exception:
                pass
            raise RuntimeError(f"Sizing worker failed to start: {stderr_text or 'no READY signal'}")
        self.process = process

    @staticmethod
    def _readline_locked(process: subprocess.Popen, timeout: float) -> "str | None":
        """Read one line from process.stdout, or return None if it doesn't arrive within
        `timeout` seconds or the pipe closes. A background thread does the actual blocking
        readline() call - `Popen.stdout` has no cross-platform readline-with-timeout, and
        Windows pipes don't support select()."""
        result: list = []

        def _reader():
            try:
                result.append(process.stdout.readline())
            except Exception:
                result.append("")

        reader_thread = threading.Thread(target=_reader, daemon=True)
        reader_thread.start()
        reader_thread.join(timeout)
        if not result or result[0] == "":
            return None
        return result[0]

    def _request_once_locked(self, selections: list, timeout: float) -> dict:
        if self.process is None or self.process.poll() is not None:
            self._start_locked()

        self.process.stdin.write(json.dumps(selections) + "\n")
        self.process.stdin.flush()
        response_line = self._readline_locked(self.process, timeout)
        if response_line is None:
            raise TimeoutError("Sizing worker did not respond in time")
        return json.loads(response_line)

    def request(self, selections: list, timeout: float = 30) -> dict:
        """Compute one sizing estimate. Raises RuntimeError/TimeoutError/json.JSONDecodeError
        on unrecoverable failure - callers translate that into an HTTP error response."""
        with self.lock:
            try:
                return self._request_once_locked(selections, timeout)
            except (TimeoutError, OSError, BrokenPipeError, json.JSONDecodeError):
                if self.process is not None:
                    try:
                        self.process.kill()
                    except Exception:
                        pass
                    self.process = None
                return self._request_once_locked(selections, timeout)

    def terminate(self) -> None:
        with self.lock:
            if self.process is not None:
                try:
                    self.process.kill()
                except Exception:
                    pass
                self.process = None


def _humanize_sizing_text(text: str) -> str:
    """Fixes up label fragments that vcf-check-ui.html's own humanizer can't reach because
    they have no lowercase-to-uppercase boundary to split on (e.g. "Firstinstance",
    "Highavailability"), so a saved estimate from before that fix still renders readably."""
    fixes = {
        "Firstinstance": "First Instance",
        "Additionalinstance": "Additional Instance",
        "Highavailability": "High Availability",
    }
    for broken, fixed in fixes.items():
        text = text.replace(broken, fixed)
    return text


def _render_sizing_estimate_html(estimate: dict) -> str:
    """Renders the resource estimator's saved payload (built client-side by
    buildSizingEstimatePayload() in vcf-check-ui.html) as a standalone HTML report, split into
    two independent sections: "Component Resources" (every component's vCPU/RAM/disk footprint,
    followed by the steady-state/peak-swing/physical-resources totals shown in the wizard's
    Refinement step) and "Service Configuration" (the human-readable recipe - size, availability,
    replicas, etc. - behind every component or service that has one). The two sections are a
    deliberate bifurcation: resource numbers live only in the first, configuration text only in
    the second, so neither table duplicates the other's columns. Deliberately plain inline CSS,
    no external assets - same "self-contained single file" convention as
    Export-VcfCheckReportHtml (Private/Reporting.ps1), so this can later be merged into that
    check report's own HTML without pulling in a second stylesheet."""

    def esc(value) -> str:
        return html.escape(_humanize_sizing_text(str(value)))

    def num(value) -> str:
        return f"{round(float(value)):,}"

    totals = estimate.get("totals") or {}
    components = estimate.get("components") or []
    services = estimate.get("services") or []
    saved_at = esc(estimate.get("savedAt", ""))
    environment_id = esc(estimate.get("environmentId", ""))
    cpu_ratio = estimate.get("cpuOvercommitRatio", 1)
    mem_ratio = estimate.get("memOvercommitRatio", 1)
    concurrent_vcenters = estimate.get("concurrentVCenters", 1)

    component_rows = "".join(
        "<tr><td>{name}</td><td class=\"num\">{vcpu}</td><td class=\"num\">{mem}</td><td class=\"num\">{storage}</td></tr>".format(
            name=esc(row.get("displayName", "")) + (" (net change)" if row.get("isDelta") else ""),
            vcpu=num(row.get("vCpu", 0)),
            mem=num(row.get("memoryGb", 0)),
            storage=num(row.get("storageGb", 0)),
        )
        for row in components
    )

    total_rows = [
        (
            "Total (steady state)",
            totals.get("vCpu", 0),
            totals.get("memoryGb", 0),
            totals.get("storageGb", 0),
        )
    ]
    if totals.get("peakVCpu") or totals.get("peakMemoryGb") or totals.get("peakStorageGb"):
        total_rows.append(
            (
                "Peak swing capacity (old + new side by side)",
                totals.get("peakVCpu", 0),
                totals.get("peakMemoryGb", 0),
                totals.get("peakStorageGb", 0),
            )
        )
    # Omitted at the 1:1 default since it would just duplicate the steady-state row above;
    # shown only once overcommitment makes the physical footprint genuinely different.
    if float(cpu_ratio) != 1 or float(mem_ratio) != 1:
        total_rows.append(
            (
                f"Physical resources needed (at {cpu_ratio}:1 CPU, {mem_ratio}:1 memory)",
                totals.get("physicalVCpu", 0),
                totals.get("physicalMemoryGb", 0),
                totals.get("storageGb", 0),
            )
        )
    total_row_html = "".join(
        "<tr class=\"totals-row\"><td>{label}</td><td class=\"num\">{vcpu}</td><td class=\"num\">{mem}</td><td class=\"num\">{storage}</td></tr>".format(
            label=esc(label), vcpu=num(vcpu), mem=num(mem), storage=num(storage)
        )
        for label, vcpu, mem, storage in total_rows
    )

    # Every component or service that has a configSummary describes a service's configuration
    # in the sense this section means - the fact some of them (e.g. VCF Operations) also get
    # their own standalone resource row above doesn't change that; a service's config and its
    # resource footprint are two different facets of the same thing, shown in separate sections.
    configured_rows = [
        (row.get("displayName", ""), row.get("configSummary", ""))
        for row in components
        if row.get("configSummary")
    ] + [
        (service.get("name", ""), service.get("configSummary") or f"Runs within {service.get('hostComponent', '')}")
        for service in services
    ]
    service_rows = "".join(
        "<tr><td>{name}</td><td>{config}</td></tr>".format(name=esc(name), config=esc(config))
        for name, config in configured_rows
    )
    service_section = ""
    if configured_rows:
        service_section = f"""
  <section>
    <h2>Service Configuration</h2>
    <p class="meta">The size, availability, and replica settings behind each configured component or service above - resource totals are shown in Component Resources, not repeated here.</p>
    <table>
      <thead><tr><th>Service</th><th>Configuration</th></tr></thead>
      <tbody>{service_rows}</tbody>
    </table>
  </section>"""

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>VCF Upgrade Resource Estimate</title>
<style>
  body {{ font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; margin: 2rem; color: #1a1a1a; background: #f7f8fa; }}
  h1 {{ font-size: 1.4rem; margin-bottom: 0.25rem; }}
  h2 {{ font-size: 1.1rem; margin-bottom: 0.5rem; }}
  .meta {{ color: #555; font-size: 0.9rem; margin-bottom: 1.5rem; }}
  table {{ width: 100%; border-collapse: collapse; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }}
  th, td {{ padding: 0.5rem 0.75rem; border-bottom: 1px solid #e5e7eb; text-align: left; }}
  th {{ background: #eef1f5; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.03em; }}
  td.num, th.num {{ text-align: right; font-variant-numeric: tabular-nums; }}
  tr.totals-row {{ font-weight: 600; background: #f0f4ff; }}
  section {{ margin-bottom: 2rem; }}
</style>
</head>
<body>
  <h1>VCF Upgrade Resource Estimate</h1>
  <div class="meta">Saved {saved_at} &middot; Environment {environment_id} &middot; Concurrent vCenter upgrades: {esc(concurrent_vcenters)}</div>
  <section>
    <h2>Component Resources</h2>
    <table>
      <thead><tr><th>Component</th><th class="num">vCPU</th><th class="num">Memory (GB)</th><th class="num">Storage (GB)</th></tr></thead>
      <tbody>{component_rows}{total_row_html}</tbody>
    </table>
  </section>{service_section}
</body>
</html>
"""


def _describe_sizing_detect_progress(progress_file: Path) -> str:
    """Turns the last step Write-VcfCheckSizingProgress recorded before a sizing-detect
    subprocess was killed for a timeout into a short user-facing clause, e.g. 'checking
    Supervisor presence on vCenter "vc01.example.com" (domain "m01")'. Returns an empty
    string if no progress was recorded (e.g. the subprocess never got past module import)."""
    try:
        progress = _load_json_file(progress_file)
    except ValueError:
        # The subprocess could have been killed mid-write to this file - a corrupt/partial
        # progress file just means we fall back to the generic timeout message below.
        return ""
    if not isinstance(progress, dict):
        return ""
    step = str(progress.get("step") or "").strip()
    if not step:
        return ""
    vcenter_fqdn = str(progress.get("vcenterFqdn") or "").strip()
    domain_name = str(progress.get("domainName") or "").strip()
    description = step
    if vcenter_fqdn:
        description += f' on "{vcenter_fqdn}"'
    if domain_name:
        description += f' (domain "{domain_name}")'
    return description


def _load_sizing_reference_data(base_directory: Path) -> dict:
    return _load_json_file(_data_dir(base_directory) / "Sizing" / "vms-sizing-references-9.1.1.json") or {}


def _load_sizing_treatment_data(base_directory: Path) -> dict:
    return _load_json_file(_data_dir(base_directory) / "Sizing" / "brownfield-upgrade-treatment.json") or {}
