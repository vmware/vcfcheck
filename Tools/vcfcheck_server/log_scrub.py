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
"""Optional sensitive-data scrubbing for the /api/export/logbundle download.

Three layers, run in this order by scrub_text():

1. Known-identifier substitution - every FQDN, username, and declared Aria VmNames entry
   sourced from environments.json is replaced with a stable, type-tagged placeholder
   (`sddcmgr-1.example.com`, `vcenter-1.example.com`, `ariaoperations-node-1.example.com`,
   `svc-user-1`, `ariaoperations-vm-1`), so the same real value maps to the same placeholder
   everywhere in the bundle, and the placeholder itself says what kind of thing it replaced.
   Built once per export by build_identifier_map() and applied literally (no regex),
   longest-value-first, so a short FQDN that is a substring of a longer one never gets
   partially clobbered by a later, shorter match. This only catches the VM name the user typed
   into the environment's VmNames field (e.g. "xint-idm01") - a name a check resolves at
   runtime instead, such as the VMware Tools guest-IP fallback match logged as "matched VM
   \"vidm-primary\"" when the declared name isn't found, is never in environments.json and so
   is NOT caught by any layer here.
2. Domain-suffix substitution - environments.json only ever stores the SDDC Manager's own
   FQDN and any manually-configured integration endpoints; the per-domain vCenter/NSX/ESX
   FQDNs a check discovers at runtime (e.g. "vcf-pd-vc01.lvn.broadcom.net") are never
   persisted anywhere, so layer 1 never learns them. This layer derives the internal domain
   suffix (e.g. "lvn.broadcom.net") from every known FQDN and generically redacts any other
   hostname sharing that suffix. Since environments.json has no record of what kind of host
   this is, the type tag is guessed from the surrounding text (the check-id log tag, e.g.
   "[vcenter_machine_id_check]", or a nearby product name) - "vcenter", "nsxmgr"/"nsxedge",
   "esx", or "sddcmgr" if one of those appears shortly before the match, else the untagged
   "host" fallback. Callers that scrub multiple files for one export should run
   discover_domain_suffix_types() across all of them first and pass the result in as
   discovered_types, so a host's type is picked from its best context anywhere in the export -
   otherwise a context-free mention in whichever file happens to be scrubbed first permanently
   locks in the "host" fallback for a host another file types unambiguously. The chosen
   placeholder (and the short label derived from it) is recorded back into identifier_map so the
   same discovered host maps consistently, short-name references included, across every
   remaining file in the bundle.
3. Generic pattern substitution for values that do not require environments.json context:
   IPv4 addresses, MAC addresses, PEM key/cert blocks, VCF-style license keys, and
   credential-bearing lines (Authorization headers, bearer tokens, password/token/secret
   fields) - the latter mirrors Private/Logging.ps1's Protect-VcfCheckLogMessage regex set,
   applied here too since Findings/*.json and the Python server's own log lines never pass
   through that PowerShell-side redaction. There is no generic pattern for VM names (unlike
   FQDNs, they have no shared suffix to key off of), so a resolved-at-runtime VM name is only
   ever redacted if it happens to also match a declared identifier.

Every pattern operates on the raw text and preserves surrounding structure (log line
brackets, JSON punctuation) - it only ever replaces the matched substring, never
reformats the line, so downstream log/JSON parsing is unaffected.
"""

import re

_IPV4_PATTERN = re.compile(r"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b")
_MAC_PATTERN = re.compile(r"\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b")
_PEM_BLOCK_PATTERN = re.compile(r"-----BEGIN [A-Z ]+-----.*?-----END [A-Z ]+-----", re.DOTALL)
_LICENSE_KEY_PATTERN = re.compile(r"\b[0-9A-Za-z]{5}-[0-9A-Za-z]{5}-[0-9A-Za-z]{5}-[0-9A-Za-z]{5}-[0-9A-Za-z]{5}\b")

# Same intent as Private/Logging.ps1's Protect-VcfCheckLogMessage: redact the value half of a
# credential-bearing field/header, keep the field name so the line is still readable.
_CREDENTIAL_LINE_PATTERNS = [
    (re.compile(r"(?i)(authorization\s*:\s*)(basic|bearer)\s+\S+"), r"\1\2 REDACTED"),
    (re.compile(r'(?i)("(?:password|pwd|token|secret|apikey|api_key)"\s*:\s*")[^"]*(")'), r"\1REDACTED\2"),
    (re.compile(r"(?i)((?:-p|--password|-guestpassword|password)[\s=]+)\S+"), r"\1REDACTED"),
]

_FQDN_PLACEHOLDER_SUFFIX = "host"
_USERNAME_PLACEHOLDER_PREFIX = "svc-user"
_VM_NAME_PLACEHOLDER_SUFFIX = "vm"
_FQDN_KEY_HINT = "fqdn"
_VCENTER_FQDN_KEY_HINT = "vcenterfqdn"
_SDDC_MANAGER_KEY_HINT = "sddcmanager"
_USERNAME_KEY_HINTS = ("username", "user")
_VM_NAME_KEY_HINT = "vmnames"
_EXCLUDED_KEY_HINTS = ("password", "pwd")
_SDDC_MGR_TYPE = "sddcmgr"
_VCENTER_TYPE = "vcenter"

# Renames an Integration's raw JSON "type" value (lowercased, e.g. "ariaopsforlogs") to the
# slug used in its placeholders, where that differs from the raw value.
_ARIA_TYPE_SLUGS = {"ariaopsforlogs": "arialogs"}

# Types whose FQDN placeholder is the bare "<type>-N.example.com" - every other known type
# (an Aria integration) instead gets "<type>-node-N.example.com" (see _fqdn_placeholder_stem),
# distinguishing "the appliance itself" from "a VM backing that appliance"
# ("<type>-vm-N", see _vm_placeholder_stem).
_BARE_FQDN_TYPES = (_SDDC_MGR_TYPE, _VCENTER_TYPE, "nsxmgr", "nsxedge", "esx")

# Guessed from the surrounding log text for a domain-suffix-discovered host, since
# environments.json has no record of what kind of host that one is. Checked in order, first
# match wins - the nsxedge check must precede the more general nsxmgr one, since "nsx edge"
# text also contains "nsx".
_TYPE_CONTEXT_PATTERNS = (
    (_VCENTER_TYPE, re.compile(r"(?i)vcenter")),
    ("nsxedge", re.compile(r"(?i)nsx[\s_-]*edge")),
    ("nsxmgr", re.compile(r"(?i)\bnsx\b")),
    ("esx", re.compile(r"(?i)\besxi?\b")),
    (_SDDC_MGR_TYPE, re.compile(r"(?i)sddc[ _-]?manager")),
)
_CONTEXT_WINDOW_CHARS = 100


def _walk_identifier_values(node, fqdns: dict, usernames: set, vm_names: dict, current_type: str = None) -> None:
    """Recursively collects FQDN/username/VmNames-shaped values out of an environments.json
    entry - generic key-name matching rather than a hardcoded per-integration-type field list,
    so a new integration type's endpoint fields are covered automatically. fqdns/vm_names map
    each value to a type tag (the enclosing Integration's "type", e.g. "AriaOperations" ->
    "ariaoperations") used to build a type-prefixed placeholder; current_type carries that tag
    down into an Integration's nested Endpoints so an endpoint's own fqdn/VmNames inherit it."""
    if isinstance(node, dict):
        node_type = current_type
        for key, value in node.items():
            if key.lower() == "type" and isinstance(value, str) and value:
                node_type = value.lower()
        for key, value in node.items():
            key_lower = key.lower()
            if any(hint in key_lower for hint in _EXCLUDED_KEY_HINTS):
                continue
            if isinstance(value, str) and value:
                if _FQDN_KEY_HINT in key_lower:
                    fqdns[value] = _fqdn_type(key_lower, node_type)
                elif any(hint in key_lower for hint in _USERNAME_KEY_HINTS):
                    usernames.add(value)
            elif isinstance(value, list):
                if _FQDN_KEY_HINT in key_lower:
                    for v in value:
                        if isinstance(v, str) and v:
                            fqdns[v] = _fqdn_type(key_lower, node_type)
                elif _VM_NAME_KEY_HINT in key_lower:
                    for v in value:
                        if isinstance(v, str) and v:
                            vm_names[v] = node_type
            _walk_identifier_values(value, fqdns, usernames, vm_names, node_type)
    elif isinstance(node, list):
        for item in node:
            _walk_identifier_values(item, fqdns, usernames, vm_names, current_type)


def _fqdn_type(key_lower: str, node_type: str) -> str:
    """Picks the type tag for an FQDN-shaped field: the SDDC Manager's own FQDN and a
    vCenterFqdn/AriaVCenterFqdn field (an Aria component's own vCenter, used for its guestOS
    checks) get a fixed tag regardless of enclosing context; any other FQDN field (e.g. an Aria
    component's own endpoint fqdn) inherits the enclosing Integration's type; failing both,
    there is no type to tag it with."""
    if _SDDC_MANAGER_KEY_HINT in key_lower:
        return _SDDC_MGR_TYPE
    if _VCENTER_FQDN_KEY_HINT in key_lower:
        return _VCENTER_TYPE
    return node_type


def _domain_suffixes(fqdns) -> set:
    """Derives the internal domain suffix (everything after the first label) from every known
    FQDN, e.g. "vcf-pd-sddcmgr01.lvn.broadcom.net" -> "lvn.broadcom.net". A bare single-label
    value (no dot) contributes no suffix - there is nothing to generalize from."""
    suffixes = set()
    for fqdn in fqdns:
        if "." in fqdn:
            suffixes.add(fqdn.split(".", 1)[1])
    return suffixes


def _fqdn_placeholder_stem(type_tag: str) -> str:
    """Builds the FQDN placeholder stem for a given type tag: an untagged host (type_tag is
    None) gets the bare "host" stem; a recognized infrastructure type (SDDC Manager, vCenter,
    NSX Manager/Edge, ESX) gets its own bare "<type>" stem (e.g. "vcenter"); anything else is
    assumed to be an Aria integration type and gets "<type>-node", distinguishing the
    appliance's own FQDN from a VM backing it (see _vm_placeholder_stem)."""
    if type_tag is None:
        return _FQDN_PLACEHOLDER_SUFFIX
    if type_tag in _BARE_FQDN_TYPES:
        return type_tag
    return f"{_ARIA_TYPE_SLUGS.get(type_tag, type_tag)}-node"


def _vm_placeholder_stem(type_tag: str) -> str:
    """Builds the VM-name placeholder stem for a given type tag: an untagged VM name (type_tag
    is None) gets the bare "vm" stem; anything else (an Aria integration type) gets
    "<type>-vm"."""
    if type_tag is None:
        return _VM_NAME_PLACEHOLDER_SUFFIX
    return f"{_ARIA_TYPE_SLUGS.get(type_tag, type_tag)}-vm"


def build_identifier_map(environments: list) -> dict:
    """Builds the real-value -> placeholder map used by scrub_text()'s known-identifier pass.
    Every environment's FQDNs/usernames/VmNames are pooled into one map (rather than one per
    environment) since Logs/ is shared across all environments and a log line from an
    unrelated environment's check still needs its own FQDN/username/VM name scrubbed. Each
    FQDN/VM name gets its own placeholder numbering sequence per type tag, so e.g. the first
    Aria Operations VM is "ariaoperations-vm-1" regardless of how many vCenter or SDDC Manager
    hosts were numbered first.

    Also maps each FQDN's short label (the part before the first dot, e.g. "sfo-w01-vc01" out
    of "sfo-w01-vc01.example.com") to that FQDN's placeholder without the domain suffix - vCenter
    checks log the vCenter's short name (from the connection object), not its FQDN, so the FQDN
    substitution alone would miss every "Invoking ... on \"sfo-w01-vc01\"" line."""
    fqdns: dict = {}
    usernames: set = set()
    vm_names: dict = {}
    for environment in environments:
        _walk_identifier_values(environment, fqdns, usernames, vm_names)

    identifier_map = {}
    fqdns_by_type: dict = {}
    for fqdn, type_tag in fqdns.items():
        fqdns_by_type.setdefault(type_tag, []).append(fqdn)
    for type_tag, values in fqdns_by_type.items():
        stem = _fqdn_placeholder_stem(type_tag)
        for index, fqdn in enumerate(sorted(values), start=1):
            placeholder = f"{stem}-{index}.example.com"
            identifier_map[fqdn] = placeholder
            short_label = fqdn.split(".", 1)[0]
            if short_label and short_label != fqdn:
                identifier_map.setdefault(short_label, f"{stem}-{index}")

    for index, username in enumerate(sorted(usernames), start=1):
        identifier_map[username] = f"{_USERNAME_PLACEHOLDER_PREFIX}-{index}"

    vm_names_by_type: dict = {}
    for vm_name, type_tag in vm_names.items():
        vm_names_by_type.setdefault(type_tag, []).append(vm_name)
    for type_tag, values in vm_names_by_type.items():
        stem = _vm_placeholder_stem(type_tag)
        for index, vm_name in enumerate(sorted(values), start=1):
            identifier_map[vm_name] = f"{stem}-{index}"

    return identifier_map


def build_domain_suffixes(environments: list) -> set:
    """Derives the set of internal domain suffixes to generically redact, from the same
    environments.json data build_identifier_map() reads. Kept as a separate call (rather than
    folded into the identifier map) since it drives a regex pass, not a literal one."""
    fqdns: dict = {}
    usernames: set = set()
    vm_names: dict = {}
    for environment in environments:
        _walk_identifier_values(environment, fqdns, usernames, vm_names)
    return _domain_suffixes(fqdns)


def _infer_type_from_context(text: str, match_start: int) -> str:
    """Guesses a discovered host's type tag from the text immediately preceding it, e.g. the
    "[vcenter_machine_id_check]" log tag ahead of "Invoking Invoke-VMScript on
    \"sfo-w01-vc01\"...", or the "Connecting to NSX..." phrasing checks commonly log before
    they act on a resolved FQDN. Returns None (untagged "host" placeholder) if nothing nearby
    matches a known product name."""
    window = text[max(0, match_start - _CONTEXT_WINDOW_CHARS):match_start]
    for type_tag, pattern in _TYPE_CONTEXT_PATTERNS:
        if pattern.search(window):
            return type_tag
    return None


def _next_placeholder(identifier_map: dict, type_tag: str) -> str:
    """Picks the next unused placeholder for this type tag's numbering sequence, continuing
    the numbering already present in identifier_map so a domain-suffix-discovered host never
    collides with (or restarts) the numbering used for a known-identifier FQDN of the same
    type."""
    stem = _fqdn_placeholder_stem(type_tag)
    used = {value for value in identifier_map.values() if value.startswith(f"{stem}-")}
    return f"{stem}-{len(used) + 1}.example.com"


def _domain_suffix_pattern(suffix: str) -> "re.Pattern":
    return re.compile(r"\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+" + re.escape(suffix) + r"\b")


def discover_domain_suffix_types(texts, domain_suffixes: set) -> dict:
    """Pre-scans every file in the export (before any placeholder is assigned) so a discovered
    host's type tag is chosen from the best context found anywhere it appears, not just wherever
    it happens to be matched first. Without this pre-scan, a host mentioned once with no nearby
    product name (e.g. a generic connectivity-test line in one log file) permanently locks in
    the untagged "host" placeholder in identifier_map, even though another file logs the same
    host right next to "Connecting to NSX Manager". Returns real value -> type tag (None if no
    occurrence anywhere had recognizable context)."""
    types: dict = {}
    for suffix in domain_suffixes:
        pattern = _domain_suffix_pattern(suffix)
        for text in texts:
            for match in pattern.finditer(text):
                real_value = match.group(0)
                if types.get(real_value) is not None:
                    continue
                types[real_value] = _infer_type_from_context(text, match.start())
    return types


def _scrub_domain_suffixes(text: str, identifier_map: dict, domain_suffixes: set, discovered_types: dict = None) -> str:
    """Redacts any hostname sharing a known internal domain suffix (e.g. a per-domain vCenter
    FQDN like "vcf-pd-vc01.lvn.broadcom.net" discovered at check run-time, never persisted to
    environments.json and therefore absent from identifier_map's literal pass). Each newly-seen
    hostname is assigned the next placeholder for its type - taken from discovered_types (the
    export-wide pre-scan, see discover_domain_suffix_types) when supplied, else guessed from this
    call's own text (see _infer_type_from_context) - and recorded back into identifier_map,
    along with its short label, so the same discovered host - by FQDN or short name - maps
    consistently across every remaining file scrub_text() is called on for this export."""
    for suffix in domain_suffixes:
        pattern = _domain_suffix_pattern(suffix)

        def _replace(match: "re.Match") -> str:
            real_value = match.group(0)
            placeholder = identifier_map.get(real_value)
            if placeholder is None:
                if discovered_types is not None:
                    type_tag = discovered_types.get(real_value)
                else:
                    type_tag = _infer_type_from_context(text, match.start())
                placeholder = _next_placeholder(identifier_map, type_tag)
                identifier_map[real_value] = placeholder
                short_label = real_value.split(".", 1)[0]
                if short_label and short_label != real_value:
                    identifier_map.setdefault(short_label, placeholder.split(".", 1)[0])
            return placeholder

        text = pattern.sub(_replace, text)
    return text


def scrub_text(text: str, identifier_map: dict, domain_suffixes: set = None, discovered_types: dict = None) -> str:
    """Applies the known-identifier map (longest real value first, so a short value that is a
    substring of a longer one never fragments the longer match), then the domain-suffix pass for
    hosts sharing a known internal domain that were never in the known-identifier map, then the
    generic pattern substitutions. Safe to call on both plain-text logs and JSON findings files -
    every substitution replaces only the matched substring, never the surrounding punctuation.

    discovered_types, when supplied, should be the export-wide result of
    discover_domain_suffix_types() run across every file in the export - it lets a newly-seen
    host be typed from its best context anywhere in the export rather than only this call's own
    text, so a context-free mention in one file no longer permanently locks in the untagged
    "host" placeholder for a host that is unambiguously typed elsewhere.

    Each known value is matched with \\b word boundaries rather than a plain substring
    replace: a short username or VM name (e.g. "admin") is otherwise liable to match inside an
    unrelated word that merely contains it (e.g. the "vdcadmintool" binary name), corrupting
    the line instead of redacting anything real."""
    for real_value in sorted(identifier_map, key=len, reverse=True):
        pattern = re.compile(r"\b" + re.escape(real_value) + r"\b")
        text = pattern.sub(identifier_map[real_value], text)

    if domain_suffixes:
        text = _scrub_domain_suffixes(text, identifier_map, domain_suffixes, discovered_types)

    text = _PEM_BLOCK_PATTERN.sub("-----BEGIN REDACTED-----\n-----END REDACTED-----", text)
    text = _LICENSE_KEY_PATTERN.sub("REDACTED-LICENSE-KEY", text)
    text = _MAC_PATTERN.sub("00:00:00:00:00:00", text)
    text = _IPV4_PATTERN.sub("0.0.0.0", text)
    for pattern, replacement in _CREDENTIAL_LINE_PATTERNS:
        text = pattern.sub(replacement, text)
    return text
