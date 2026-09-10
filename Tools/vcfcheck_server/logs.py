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
"""Log file path/tailing helpers for Start-VcfCheckServer.py.

_tail_launcher_log stays in Start-VcfCheckServer.py itself rather than here - it reads the
current run id off _run_queue (the RunQueue instance), which still lives in the main module
until the B2 round of the modularization plan extracts it into run_queue.py; moving it here
now would create a circular import.
"""

from datetime import datetime
from pathlib import Path


def _engine_log_path(base_directory: Path) -> Path:
    """The dated log file Initialize-VcfCheckLogging (Private/Logging.ps1) writes to - shared
    by Invoke-VcfCheck's own run and Invoke-VcfCheckValidateCredentials.ps1's credential
    checks, both of which call it. Tailed by /api/validate-credentials/log for the browser's
    Live Log panel."""
    return base_directory / "Logs" / f"VcfCheckEngine-{datetime.now().strftime('%Y-%m-%d')}.log"


def _list_log_files(base_directory: Path) -> list:
    """Every dated *.log file under Logs/ (VcfCheckServer and VcfCheckEngine logs, plus
    any older dated files from previous days) - matches the sibling VCF.Patch.Scanner tool's own
    /scan/collect-logs convention of bundling the whole logs directory rather than just today's
    file."""
    logs_dir = base_directory / "Logs"
    if not logs_dir.is_dir():
        return []
    return sorted(logs_dir.glob("*.log"), key=lambda p: p.stat().st_mtime)


def _tail_log_file(log_path: Path, since: int, marker: bytes | None = None) -> dict:
    """Shared byte-offset tailing logic for both /api/run/log and /api/validate-credentials/log -
    previously duplicated verbatim (minus the marker step) between _tail_launcher_log and
    _tail_credential_log. Returns {"text": ..., "offset": ...} - callers pass the returned offset
    back as `since` on their next poll so only newly appended bytes are re-sent.

    `marker`, when given and `since<=0`, rewinds `start` to the last occurrence of that byte
    string in the file instead of the very beginning - used by _tail_launcher_log to scope a
    freshly opened live-log panel to the current run's own header line rather than the whole
    day's file. `_tail_credential_log` has no such marker (a credential check has no run id to
    anchor on); the browser primes that case itself by passing an out-of-range `since`, clamped
    to the file's current size below, so it starts from "now" instead.
    """
    if not log_path.is_file():
        return {"text": "", "offset": 0}

    size = log_path.stat().st_size
    start = min(max(since, 0), size)

    if marker is not None and since <= 0:
        marker_index = log_path.read_bytes().rfind(marker)
        if marker_index != -1:
            start = marker_index

    with log_path.open("rb") as handle:
        handle.seek(start)
        chunk = handle.read()

    return {"text": chunk.decode("utf-8", errors="replace"), "offset": start + len(chunk)}


def _tail_credential_log(base_directory: Path, since: int) -> dict:
    """Tails today's engine log (_engine_log_path) from a byte offset - no marker-scoping like
    _tail_launcher_log, since a credential check has no run id to anchor on."""
    return _tail_log_file(_engine_log_path(base_directory), since)
