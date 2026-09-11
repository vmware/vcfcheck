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
"""Environment CRUD/persistence and validation helpers for Start-VcfCheckServer.py."""

import json
import logging
import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path

from vcfcheck_server.json_utils import _load_json_file
from vcfcheck_server.paths import _config_dir

logger = logging.getLogger("VcfCheck-Server")

_SLUG_INVALID_CHARS = re.compile(r"[^a-z0-9]+")


def _new_environment_id() -> str:
    """Matches Private/Environments.ps1's New-VcfCheckEnvironmentId (uuid4 hex[:12]) - both
    sides agree on the same id shape even though environments.json is written directly by this
    server (no PowerShell subprocess round-trip needed for a plain JSON list edit)."""
    return uuid.uuid4().hex[:12]


def _environments_path(base_directory: Path) -> Path:
    return _config_dir(base_directory) / "environments.json"


def _load_environments(base_directory: Path) -> list:
    """Loads environments.json, migrating a legacy single-target settings.json into it the first
    time this is called if environments.json does not exist yet - so an existing
    single-environment user's setup is not lost. Mirrors Private/Environments.ps1's
    Get-VcfCheckEnvironments migration logic; implemented independently here since this
    server is what actually serves the browser UI (Get-VcfCheckEnvironments exists so
    Invoke-VcfCheck/CLI users get the same capability from the module directly)."""
    environments_path = _environments_path(base_directory)
    environments = _load_json_file(environments_path)
    if environments is not None:
        return environments

    settings = _load_json_file(_config_dir(base_directory) / "settings.json") or {}
    fqdn = settings.get("SddcManagerFqdn")
    username = settings.get("SddcManagerUser")
    if not fqdn or not username:
        return []

    now = datetime.now(timezone.utc).isoformat()
    migrated = [
        {
            "id": _new_environment_id(),
            "name": fqdn,
            "sddcManagerFqdn": fqdn,
            "sddcManagerUser": username,
            "enableRootCredentialChecks": False,
            "createdAt": now,
            "updatedAt": now,
        }
    ]
    _save_environments(base_directory, migrated)
    logger.info("Migrated settings.json's single SDDC Manager target into environments.json as %r.", fqdn)
    return migrated


def _save_environments(base_directory: Path, environments: list) -> None:
    """Writes atomically (temp file in the same directory, then os.replace) so a reader never
    observes a partially-written file - same durability goal as
    Private/Environments.ps1's Save-VcfCheckEnvironments."""
    environments_path = _environments_path(base_directory)
    environments_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = environments_path.with_suffix(f".{uuid.uuid4().hex}.tmp")
    try:
        temp_path.write_text(json.dumps(environments, indent=2), encoding="utf-8")
        os.replace(temp_path, environments_path)
    finally:
        temp_path.unlink(missing_ok=True)


def _slugify_environment_name(name: str) -> str:
    """Turns a friendly environment name into a filesystem-safe Findings/ subdirectory segment -
    lowercase, non-alphanumeric runs collapsed to a single hyphen, leading/trailing hyphens
    stripped. Falls back to "environment" for a name that slugifies to nothing (e.g. one made
    entirely of punctuation), so a Findings path segment is never empty. Results are scanned by a
    human browsing Findings/ on disk, so the folder should read as the environment's name, not an
    opaque environment id - the id remains the stable lookup key everywhere else (environments.json,
    the queue, the browser's API calls); only the Findings/ path segment is name-derived, and is
    therefore recomputed from whatever the name currently is, not cached from when the environment
    was created."""
    slug = _SLUG_INVALID_CHARS.sub("-", name.strip().lower()).strip("-")
    return slug or "environment"


def _findings_slug_for_environment_id(base_directory: Path, environment_id: str) -> str:
    """Resolves an environment id to the Findings/ subdirectory its runs are (or would be)
    written under, using whatever the environment is named right now - a rename takes effect for
    the next run, not retroactively, since renaming a Findings/ directory out from under a
    possibly-in-progress run would be its own hazard. Returns "" if the id is unknown."""
    environment = next((env for env in _load_environments(base_directory) if env.get("id") == environment_id), None)
    return _slugify_environment_name(environment["name"]) if environment else ""


def _environment_name_conflict(environments: list, name: str, exclude_id: str = None) -> str:
    """Returns another environment's name if it slugifies to the same Findings/ subdirectory as
    `name`, or "" if there's no conflict. Findings/ is now named after the environment's friendly
    name rather than its id, so two environments that resolve to the same slug (exact duplicates,
    or names that only differ in punctuation/case) would silently share - and overwrite each
    other's - reports."""
    target_slug = _slugify_environment_name(name)
    for existing in environments:
        if existing.get("id") == exclude_id:
            continue
        if _slugify_environment_name(existing.get("name", "")) == target_slug:
            return existing.get("name", "")
    return ""


def _find_password_like_key(value) -> str:
    """Recursively scans a JSON-decoded value (dict/list) for a key containing "password",
    mirroring Private/Environments.ps1's Find-VcfCheckPasswordLikePropertyName so both the
    browser's write path (this file) and the PowerShell CLI path (Save-VcfCheckEnvironments)
    enforce the identical "never persist a password" rule, including inside nested
    integrations/endpoints entries."""
    if isinstance(value, dict):
        for key, nested in value.items():
            if "password" in key.lower():
                return key
            found = _find_password_like_key(nested)
            if found:
                return found
    elif isinstance(value, list):
        for item in value:
            found = _find_password_like_key(item)
            if found:
                return found
    return ""


def reject_unsafe_cli_value(value: str, field_name: str) -> str:
    """Returns an error message, or "" when `value` is safe to pass as a pwsh -File positional
    argument value. A leading "-" (or "/" on Windows) makes PowerShell's parameter binder treat
    the value as a switch/parameter name of its own rather than plain text, letting a value like
    fqdn or username inject additional parameters into the child pwsh invocation."""
    if value.startswith("-") or value.startswith("/"):
        return f"{field_name} must not start with '-' or '/'."
    return ""


def _validate_integrations(integrations) -> str:
    """Validates the optional `integrations` field - components (e.g. a standalone Aria
    Operations instance) SDDC Manager/VRSLCM have zero knowledge of, declared directly by the
    user. Mirrors Test-VcfCheckEnvironmentIsValid's Integrations rules (Private/Environments.ps1)
    so both write paths agree on what's acceptable."""
    if integrations is None:
        return ""
    if not isinstance(integrations, list):
        return "integrations must be a list."
    for integration in integrations:
        if not isinstance(integration, dict):
            return "each integration must be an object."
        integration_type = str(integration.get("type", "")).strip()
        if not integration_type:
            return "each integration must have a type."
        shared = bool(integration.get("sharedCredentials"))
        if shared and not str(integration.get("username", "")).strip():
            return f'integration "{integration_type}" has sharedCredentials enabled but no username.'
        endpoints = integration.get("endpoints") or []
        if not isinstance(endpoints, list) or len(endpoints) == 0:
            return f'integration "{integration_type}" must have at least one endpoint.'
        for endpoint in endpoints:
            if not isinstance(endpoint, dict):
                return f'integration "{integration_type}" has a malformed endpoint.'
            endpoint_name = str(endpoint.get("name", "")).strip()
            if not endpoint_name:
                return f'integration "{integration_type}" has an endpoint with no name.'
            if not str(endpoint.get("fqdn", "")).strip():
                return f'integration "{integration_type}" endpoint "{endpoint_name}" has no fqdn.'
            if not shared and not str(endpoint.get("username", "")).strip():
                return f'integration "{integration_type}" endpoint "{endpoint_name}" has no username (sharedCredentials is disabled, so each endpoint needs its own).'
    return ""


def _validate_environment_body(body: dict, environments: list, exclude_id: str = None) -> str:
    """Returns an error message string, or "" when the body is acceptable. Rejects any
    password-shaped key as a hard failure (not just a warning) - this is the write path reachable
    from the browser's Add/Edit form, mirroring Save-VcfCheckEnvironments's guardrail. The
    password scan is recursive (see _find_password_like_key) so a password entered on a nested
    integrations[].endpoints[] object is caught the same as a top-level one."""
    password_key = _find_password_like_key(body)
    if password_key:
        return f"environments may never carry a password field (found {password_key!r})."
    name = str(body.get("name", "")).strip()
    if not name:
        return "name must not be empty."
    fqdn = str(body.get("sddcManagerFqdn", "")).strip()
    if not fqdn:
        return "sddcManagerFqdn must not be empty."
    fqdn_error = reject_unsafe_cli_value(fqdn, "sddcManagerFqdn")
    if fqdn_error:
        return fqdn_error
    username = str(body.get("sddcManagerUser", "")).strip()
    if not username:
        return "sddcManagerUser must not be empty."
    username_error = reject_unsafe_cli_value(username, "sddcManagerUser")
    if username_error:
        return username_error
    integrations_error = _validate_integrations(body.get("integrations"))
    if integrations_error:
        return integrations_error
    conflict = _environment_name_conflict(environments, name, exclude_id)
    if conflict:
        return f"Another environment ({conflict!r}) already uses this name (or one that resolves to the same Findings folder name). Choose a different name."
    return ""
