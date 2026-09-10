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
"""VCF destination-release version/family lookup helpers for Start-VcfCheckServer.py."""

import logging
import sys
from pathlib import Path

from vcfcheck_server.json_utils import _load_json_file
from vcfcheck_server.paths import _config_dir

MODULE_DIR = Path(__file__).resolve().parent.parent

logger = logging.getLogger("VcfCheck-Server")

VCF_DESTINATION_RELEASE_FLOOR = (9, 0, 0, 0)
# Same shipped snapshot Private/InteropMatrixHelpers.ps1's Invoke-VcfCheckInteropMatrixUpgrades
# reads for SDDC Manager (product ID 851) - refreshed by maintainers via
# InternalTools/Update-VcfInteropMatrixData.ps1 before packaging a release, rather than this server
# independently calling Broadcom's live API (and carrying its own copy of the reverse-engineered
# x-auth-key) on every settings-panel open.
_INTEROP_MATRIX_SDDC_MANAGER_DATA_FILE = MODULE_DIR.parent / "Data" / "Interoperability" / "SddcManager.json"

_vcf_destination_release_options_cache = {"mtime": None, "versions": None}


def _parse_dotted_version(version: str):
    parts = []
    for part in version.split("."):
        if not part.isdigit():
            return None
        parts.append(int(part))
    return tuple(parts) if parts else None


def _families_from_versions(versions):
    """Reduces a list of full concrete release strings (e.g. '9.1.0.0300') to their distinct
    major.minor.patch families (e.g. '9.1.0'), sorted newest-first. The web UI's destination-
    release selector offers a family rather than a specific 4th-digit patch build, since
    Test-VcfSddcBomCheck/Test-VcfVrslcmFetchProducts each resolve a family to the newest matching
    release independently per component - two components in the same family can have a different
    real newest patch, so a single pre-picked 4th-digit build here would misrepresent at least
    one of them.
    """
    families = set()
    for version in versions:
        parsed = _parse_dotted_version(version)
        if parsed and len(parsed) >= 3:
            families.add(".".join(str(p) for p in parsed[:3]))
    return sorted(families, key=_parse_dotted_version, reverse=True)


def _fetch_vcf_destination_release_options():
    """List of published SDDC Manager release versions >= VCF_DESTINATION_RELEASE_FLOOR, read from
    the shipped Interop Matrix snapshot (_INTEROP_MATRIX_SDDC_MANAGER_DATA_FILE), for the UI's
    destination-release dropdown/datalist. Returns None (not an empty list) when the file is
    missing or fails to parse, so the caller/UI can tell "confirmed no releases" apart from
    "couldn't check," and let the free-text input still work unassisted in the latter case.
    Cached in-process, invalidated by the file's own mtime, so a maintainer-refreshed snapshot
    is picked up without a server restart.

    Resolves _INTEROP_MATRIX_SDDC_MANAGER_DATA_FILE through the entry-point module's own namespace
    (falling back to this module's copy) so a test/caller that patches
    Start-VcfCheckServer._INTEROP_MATRIX_SDDC_MANAGER_DATA_FILE - the re-exported name callers
    actually see - is honored, rather than always reading this submodule's own binding.
    """
    entry_point = sys.modules.get("Start-VcfCheckServer")
    data_file = getattr(entry_point, "_INTEROP_MATRIX_SDDC_MANAGER_DATA_FILE", _INTEROP_MATRIX_SDDC_MANAGER_DATA_FILE)
    try:
        mtime = data_file.stat().st_mtime
    except OSError:
        return None

    if _vcf_destination_release_options_cache["mtime"] == mtime:
        return _vcf_destination_release_options_cache["versions"]

    payload = _load_json_file(data_file)
    if not isinstance(payload, dict) or not isinstance(payload.get("upgradeProducts"), list):
        logger.warning(
            "Shipped Interop Matrix data file %s is missing or has an unexpected shape (no "
            "'upgradeProducts' list)", data_file,
        )
        return None

    versions = set()
    for upgrade_product in payload.get("upgradeProducts") or []:
        versions.add(upgrade_product.get("version"))
        for release in upgrade_product.get("releases") or []:
            versions.add(release.get("version"))

    parsed = [(v, _parse_dotted_version(v)) for v in versions if v]
    filtered = sorted(
        (v for v, p in parsed if p is not None and p >= VCF_DESTINATION_RELEASE_FLOOR),
        key=_parse_dotted_version,
        reverse=True,
    )

    _vcf_destination_release_options_cache["mtime"] = mtime
    _vcf_destination_release_options_cache["versions"] = filtered
    return filtered


def _get_vcf_destination_release(base_directory: Path) -> str:
    """Zero-touch: a user should never have to manually choose a destination release before their
    first run, whether or not they ever opened the settings panel (e.g. a CLI-only workflow that
    never loads the UI at all). 'latest' is a literal value Test-VcfSddcBomCheck/
    Test-VcfVrslcmFetchProducts both understand natively (Resolve-VcfCheckInteropMatrixRelease
    InFamily resolves it live, independently per component, every run) - so unlike the previous
    approach of resolving and pinning one concrete version here, nothing needs to be pre-resolved
    or persisted at all; an unset preference is already the right zero-touch behavior on its own.
    """
    settings = _load_json_file(_config_dir(base_directory) / "settings.json") or {}
    return settings.get("VcfDestinationRelease") or "latest"
