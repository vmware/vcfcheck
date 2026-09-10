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
"""Base-directory path helpers and module/version lookup for Start-VcfCheckServer.py."""

import os
import re
import subprocess
import sys
from pathlib import Path

# Every pwsh subprocess this module launches (module lookup) must stay invisible - see
# Start-VcfCheckServer.py's own copy of this constant for the full rationale. Computed
# independently here (rather than imported back from the entry-point module) to avoid a
# circular import between the two.
_NO_WINDOW_KWARGS = (
    {"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" else {}
)


def _locate_module_psd1() -> Path:
    """Return the path to VcfCheck.psd1, checked in priority order:

    1. VCFCHECK_MODULE_PSD1 already set in the parent environment.
    2. Resolved sibling of Tools/ (correct for the git-repo layout and for deployments
       that keep the module alongside the Tools directory).
    3. PSModulePath directory search (flat and versioned install layouts).
    4. PowerShell-assisted search (Get-Module), only as a last resort.
    5. Unresolved sibling of Tools/, so the return type is always a Path.
    """
    env_override = os.environ.get("VCFCHECK_MODULE_PSD1", "").strip()
    if env_override:
        candidate = Path(env_override)
        if candidate.is_file():
            return candidate

    resolved = Path(__file__).resolve().parent.parent.parent / "VcfCheck.psd1"
    if resolved.is_file():
        return resolved

    sep = ";" if sys.platform == "win32" else ":"
    search_dirs = [d for d in os.environ.get("PSModulePath", "").split(sep) if d]
    default_user_dir = (
        Path.home() / "Documents" / "PowerShell" / "Modules"
        if sys.platform == "win32"
        else Path.home() / ".local" / "share" / "powershell" / "Modules"
    )
    search_dirs.append(str(default_user_dir))
    for module_dir in search_dirs:
        module_root = Path(module_dir) / "VcfCheck"
        if not module_root.is_dir():
            continue

        candidate = module_root / "VcfCheck.psd1"
        if candidate.is_file():
            return candidate

        try:
            versioned = sorted(
                (
                    d / "VcfCheck.psd1"
                    for d in module_root.iterdir()
                    if d.is_dir() and (d / "VcfCheck.psd1").is_file()
                ),
                key=lambda p: [int(x) for x in re.split(r"[.\-]", p.parent.name) if x.isdigit()],
                reverse=True,
            )
            if versioned:
                return versioned[0]
        except OSError:
            pass

    try:
        result = subprocess.run(
            [
                "pwsh", "-NoProfile", "-NonInteractive", "-Command",
                "(Get-Module VcfCheck -ListAvailable"
                " | Sort-Object Version -Descending"
                " | Select-Object -First 1).Path",
            ],
            capture_output=True,
            text=True,
            timeout=20,
            **_NO_WINDOW_KWARGS,
        )
        if result.returncode == 0:
            ps_path = result.stdout.strip()
            if ps_path:
                candidate = Path(ps_path)
                if candidate.is_file():
                    return candidate
    except Exception:
        pass

    return Path(__file__).resolve().parent.parent.parent / "VcfCheck.psd1"


_MODULE_PSD1 = _locate_module_psd1()

_MODULE_VERSION_PATTERN = re.compile(r"ModuleVersion\s*=\s*['\"]([^'\"]+)['\"]")


def _module_version() -> str:
    """Return the ModuleVersion string from VcfCheck.psd1, or "unknown" if it can't be read.

    Resolves _MODULE_PSD1 through the entry-point module's own namespace (falling back to this
    module's copy) so a test/caller that patches Start-VcfCheckServer._MODULE_PSD1 - the re-exported
    name callers actually see - is honored, rather than always reading this submodule's own binding.
    """
    entry_point = sys.modules.get("Start-VcfCheckServer")
    psd1_path = getattr(entry_point, "_MODULE_PSD1", _MODULE_PSD1)
    try:
        text = psd1_path.read_text(encoding="utf-8")
    except OSError:
        return "unknown"
    match = _MODULE_VERSION_PATTERN.search(text)
    return match.group(1) if match else "unknown"


def _findings_dir(base_directory: Path) -> Path:
    return base_directory / "Findings"


def _data_dir(base_directory: Path) -> Path:
    return base_directory / "Data"


def _config_dir(base_directory: Path) -> Path:
    return base_directory / "Config"


def _docs_dir(base_directory: Path) -> Path:
    return base_directory / "Docs"


def _logs_dir(base_directory: Path) -> Path:
    return base_directory / "Logs"


def _findings_dir_for_item(base_directory: Path, item: dict) -> Path:
    """Resolves a queue item's own findings directory - the same -OutputPath the launcher
    subprocess was started with for this item (see _start_next_queue_item)."""
    findings_dir = _findings_dir(base_directory)
    if item.get("findingsSlug"):
        findings_dir = findings_dir / item["findingsSlug"]
    return findings_dir
