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
"""JSON file/text loading helpers for Start-VcfCheckServer.py."""

import json
from pathlib import Path


def _load_json_file(path: Path):
    if not path.is_file():
        return None
    with path.open("r", encoding="utf-8") as handle:
        try:
            return json.load(handle)
        except json.JSONDecodeError as exc:
            # Reraised with the file path in the message - the bare JSONDecodeError text alone
            # (e.g. "Expecting ',' delimiter: line 286 column 5") gives no hint which of the
            # several JSON files this server reads on demand is the broken one, and _run_safely's
            # catch-all below is what a browser request ultimately sees.
            raise ValueError(f"{path} is not valid JSON: {exc}") from exc


def _load_latest_findings_json(path: Path):
    """Loads a latest.json/progress.json the same way _load_json_file does, except both a JSON
    parse failure and a transient file-lock error are treated as "no run yet" instead of
    propagating - unlike every other file this server reads, these files are actively being
    overwritten by the PowerShell engine's partial-flush writes (Private/Reporting.ps1's
    Write-VcfCheckReport/Write-VcfCheckSubProgress, via a non-atomic Set-Content) while a run
    is live, so a request that lands mid-write can genuinely observe a truncated/empty file (POSIX)
    or find the file exclusively locked by the writer (Windows). Both are an expected race, not
    real corruption - confirmed live as the cause of an unhandled 500 on GET /api/runs/latest and
    GET /api/run/status during an in-progress run on Windows, where Set-Content's exclusive lock
    makes a concurrent open() raise PermissionError instead of returning a truncated read."""
    try:
        return _load_json_file(path)
    except (ValueError, OSError):
        return None


def _extract_json_object(text: str, required_key: str):
    """Return the last line of `text` that parses as JSON and contains `required_key`.

    Invoke-VcfCheckValidateCredentials.ps1 (and any similar script) writes exactly one
    ConvertTo-Json -Compress line, but Write-LogMessage's own console output (plain Write-Host,
    not affected by $InformationPreference - confirmed empirically, not assumed) can appear
    before AND after it on the same stdout stream. Scanning every line for one that both parses
    and has the expected shape is robust to that interleaving without needing to touch the
    shared logging code just to get a clean single-purpose stdout.
    """
    result = None
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict) and required_key in candidate:
            result = candidate
    return result
