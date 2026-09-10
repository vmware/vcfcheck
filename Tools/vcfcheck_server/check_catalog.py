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
"""Check-catalog loading/grouping helpers for Start-VcfCheckServer.py."""

from pathlib import Path

from vcfcheck_server.json_utils import _load_json_file
from vcfcheck_server.paths import _data_dir


def _load_check_catalog(base_directory: Path) -> dict:
    return _load_json_file(_data_dir(base_directory) / "CheckCatalog.json") or {}


def _load_check_descriptions(base_directory: Path) -> dict:
    return _load_json_file(_data_dir(base_directory) / "CheckDescription.json") or {}


def _checks_by_area(catalog: dict, descriptions: dict) -> dict:
    """Group real (non-Sample) catalog checks by area for the browser's check picker.

    The browser lists individual checks straight from the catalog, grouped by area,
    defaulting to all selected.
    """
    areas: dict = {}
    for check_id, entry in sorted(catalog.items()):
        if not isinstance(entry, dict):
            continue
        area = entry.get("area")
        if not area or area == "Sample":
            continue
        display_name = entry.get("displayName") or check_id
        areas.setdefault(area, []).append(
            {
                "id": check_id,
                "displayName": display_name,
                "blocking": bool(entry.get("blocking")),
                "description": descriptions.get(area, {}).get(display_name, ""),
            }
        )
    return areas


def _root_credential_check_ids(catalog: dict) -> list:
    root_keys = ("requiresSddcManagerRootCredential", "requiresVcenterRootCredential")
    return sorted(
        check_id
        for check_id, entry in catalog.items()
        if isinstance(entry, dict) and any(entry.get(key) is True for key in root_keys)
    )
