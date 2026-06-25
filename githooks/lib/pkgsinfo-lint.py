#!/usr/bin/env python3
"""
pkgsinfo-lint.py  —  static pkgsinfo structural validation for Cimian pre-commit.

Schema derived from Cimian's PkgsInfo model, not copied from Munki. Cimian
targets Windows: package types are msi/exe/nupkg, the only architecture is
x64, and the installer descriptor is a nested `installer:` mapping with
`type`/`location`/`hash` sub-keys (Munki uses flat installer_item_location).

Usage:
    pkgsinfo-lint.py <repo-root>

Reads staged pkgsinfo paths via `git diff --cached --name-only`, filters to
deployment/pkgsinfo/**/*.{yaml,yml}, validates each, and emits a
human-readable report on stderr. Exit 0 pass, exit 1 errors found.

Catches problems `makecatalogs` silently accepts:
    * Unknown top-level keys (typos like install_scritp)
    * Wrong-case keys (Name vs name)
    * Wrong-case catalogs (production vs Production)
    * Invalid installer types (only pkg/script/nopkg/msi/exe)
    * Invalid arch values (only x64)
    * Missing required keys (name, version, catalogs, installer)
    * Empty catalogs: []
    * nopkg with no installcheck_script and no installs — install-loop trap
    * msi/exe/nupkg/pkg without nested installer location
    * Duplicate top-level keys (YAML silently drops all but the last)
"""

from __future__ import annotations

import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

try:
    import yaml  # PyYAML
except ImportError:
    sys.stderr.write("ERROR: PyYAML not available; cannot lint pkgsinfo\n")
    sys.exit(0)  # don't block commits if lint can't run


# ── Cimian-native schema (distinct from Munki's schema) ─────────────────────

VALID_TOP_KEYS: set[str] = {
    # Identity
    "name", "display_name", "identifier", "version", "description",
    "category", "developer", "notes", "icon_name", "_metadata",
    # Catalog assignment
    "catalogs",
    # Installer descriptors
    "installer", "installer_type", "uninstaller",
    "installer_item_location", "installer_item_hash",
    "uninstallable",
    # Install behaviour
    "unattended_install", "unattended_uninstall",
    "autoremove", "OnDemand", "install_window",
    "restart_action", "conditional_items",
    # System compatibility
    "minimum_os_version", "maximum_os_version",
    "supported_architectures",
    # Detection / tracking
    "installs", "blocking_applications",
    "days_untouched_before_uninstall", "usage_tracked_paths",
    "minimum_usage_history_days",
    # Scripts
    "preinstall_script", "postinstall_script",
    "preuninstall_script", "postuninstall_script",
    "install_script", "uninstall_script",
    "installcheck_script", "uninstallcheck_script",
    # Relationships
    "requires", "update_for",
}

# Sub-keys valid inside the nested `installer:` / `uninstaller:` mapping.
VALID_INSTALLER_KEYS: set[str] = {
    "location", "hash", "type", "size", "switches", "flags",
    "subcommand", "arguments", "args", "temp_dir",
    "product_code", "upgrade_code", "installer_item_location",
}

# Valid installer types in Cimian (the headline set for this validator).
# Absent installer.type defaults to a binary package install.
VALID_INSTALLER_TYPES: set[str] = {
    "pkg", "script", "nopkg", "msi", "exe",
}

# Types where a binary package is the installer and a nested location is needed.
LOCATION_INSTALLER_TYPES: set[str] = {"pkg", "msi", "exe"}

# Types where a script IS the main installer (no binary location).
SCRIPT_INSTALLER_TYPES: set[str] = {"nopkg", "script"}

# Valid catalog names (PascalCase). Same dialect as Munki's promotion stages.
VALID_CATALOGS: set[str] = {
    "Development", "Testing", "Staging", "Production",
}

# Valid supported_architectures in Cimian — Windows only.
VALID_ARCHES: set[str] = {"x64"}

# Valid restart_action values (PascalCase enum).
VALID_RESTART_ACTIONS: set[str] = {
    "None", "RequireRestart", "RecommendRestart",
}


def _installer_descriptor(data: dict[str, Any]) -> tuple[str | None, dict[str, Any] | None]:
    """Return (installer_type, installer_mapping) resolving both the nested
    `installer: {type: ...}` form and the flat top-level `installer_type`."""
    installer = data.get("installer")
    installer_map = installer if isinstance(installer, dict) else None
    itype = None
    if installer_map and isinstance(installer_map.get("type"), str):
        itype = installer_map["type"]
    elif isinstance(data.get("installer_type"), str):
        itype = data["installer_type"]
    return itype, installer_map


def issues_for_file(path: Path) -> list[str]:
    """Validate one pkgsinfo file. Returns a list of error strings."""
    errors: list[str] = []

    raw_bytes = path.read_bytes()
    try:
        data = yaml.safe_load(raw_bytes)
    except Exception:
        # makecatalogs already blocks on parse errors with better messages;
        # don't duplicate here. Return empty so the commit path gets to it.
        return []

    # Duplicate top-level keys (safe_load silently drops earlier values).
    for k in _yaml_duplicate_top_keys(raw_bytes.decode("utf-8", "replace")):
        errors.append(f"Duplicate top-level key '{k}' (YAML drops all but the last value)")

    if not isinstance(data, dict):
        errors.append("Top-level structure is not a mapping/dict")
        return errors

    top_keys = set(data.keys())

    # 1. Unknown top-level keys (typos)
    for key in sorted(top_keys - VALID_TOP_KEYS):
        ci_match = next((v for v in VALID_TOP_KEYS if v.lower() == str(key).lower()), None)
        if ci_match:
            errors.append(f"Key '{key}' has wrong case — should be '{ci_match}'")
        else:
            errors.append(f"Unknown top-level key '{key}' (typo? not in Cimian pkgsinfo schema)")

    # 2. Required fields. installer is required unless a top-level installer_type
    #    is present, the item is script-driven, or it's a requires-only meta item.
    for required in ("name", "version", "catalogs"):
        if required not in data:
            errors.append(f"Missing required field '{required}'")

    has_any_script = any(
        k in data for k in (
            "preinstall_script", "postinstall_script", "install_script",
            "uninstall_script", "preuninstall_script", "postuninstall_script",
        )
    )
    if (
        "installer" not in data
        and "installer_type" not in data
        and "installer_item_location" not in data
        and not has_any_script
        and "requires" not in data
    ):
        errors.append("Missing required field 'installer'")

    # 3. Empty name/version
    for k in ("name", "version"):
        if k in data and not str(data.get(k) or "").strip():
            errors.append(f"Field '{k}' is empty")

    # 4. catalogs must be a non-empty list of valid values
    if "catalogs" in data:
        catalogs = data.get("catalogs")
        if not isinstance(catalogs, list):
            errors.append("Field 'catalogs' must be a list")
        elif len(catalogs) == 0:
            errors.append("Field 'catalogs' is empty — pkgsinfo won't be assigned to any catalog")
        else:
            for c in catalogs:
                if c not in VALID_CATALOGS:
                    ci = next((v for v in VALID_CATALOGS if v.lower() == str(c).lower()), None)
                    if ci:
                        errors.append(f"Catalog '{c}' has wrong case — should be '{ci}'")
                    else:
                        errors.append(f"Invalid catalog '{c}' (valid: {', '.join(sorted(VALID_CATALOGS))})")

    # 5. supported_architectures — Cimian uses x64 only
    if "supported_architectures" in data:
        archs = data.get("supported_architectures") or []
        if not isinstance(archs, list):
            errors.append("Field 'supported_architectures' must be a list")
        else:
            for a in archs:
                if a not in VALID_ARCHES:
                    if a in ("x86_64", "arm64"):
                        errors.append(f"Invalid architecture '{a}' — Cimian uses 'x64' (that's Munki/macOS)")
                    else:
                        errors.append(f"Invalid architecture '{a}' (valid: {', '.join(sorted(VALID_ARCHES))})")

    # 6. restart_action (PascalCase)
    if "restart_action" in data:
        ra = data.get("restart_action")
        if ra not in VALID_RESTART_ACTIONS:
            errors.append(
                f"Invalid restart_action '{ra}' "
                f"(valid: {', '.join(sorted(VALID_RESTART_ACTIONS))})"
            )
        # RequireRestart + unattended_install: true — incompatible
        if ra == "RequireRestart" and bool(data.get("unattended_install")) is True:
            errors.append(
                "'restart_action: RequireRestart' cannot combine with "
                "'unattended_install: true' — a forced restart is not unattended"
            )

    # 7. installer descriptor + nested-key validation
    installer_type, installer_map = _installer_descriptor(data)

    if installer_map is not None:
        for sk in sorted(set(installer_map.keys()) - VALID_INSTALLER_KEYS):
            errors.append(f"Unknown installer key '{sk}'")

    if installer_type is not None and installer_type not in VALID_INSTALLER_TYPES:
        errors.append(
            f"Invalid installer type '{installer_type}' "
            f"(valid: {', '.join(sorted(VALID_INSTALLER_TYPES))})"
        )

    # 8. binary types must carry a location
    if installer_type in LOCATION_INSTALLER_TYPES:
        has_location = (
            (installer_map is not None and installer_map.get("location"))
            or data.get("installer_item_location")
        )
        if not has_location:
            errors.append(
                f"installer type '{installer_type}' requires an installer "
                f"'location' (or top-level 'installer_item_location')"
            )

    # 9. nupkg / pkg / msi / exe: install_script is silently ignored for binary
    #    types — flag it so the author moves logic to pre/postinstall_script.
    if installer_type in LOCATION_INSTALLER_TYPES and "install_script" in data:
        errors.append(
            f"install_script is ignored for type '{installer_type}' "
            f"(use preinstall_script / postinstall_script)"
        )

    # 10. nopkg/script install-loop trap
    # A script-driven item runs its install action every managedsoftwareupdate
    # cycle unless installcheck_script (or installs) tells Cimian it's done.
    if installer_type in SCRIPT_INSTALLER_TYPES:
        is_ondemand = str(data.get("OnDemand") or "").lower() == "true"
        has_install_action = any(
            k in data for k in ("install_script", "preinstall_script", "postinstall_script")
        )
        has_uninstall_action = any(
            k in data for k in ("uninstall_script", "preuninstall_script", "postuninstall_script")
        )
        has_installcheck = "installcheck_script" in data
        has_installs = "installs" in data and data.get("installs")

        if not has_install_action and not has_uninstall_action:
            errors.append(
                f"installer type '{installer_type}' has no install_script, "
                f"preinstall_script, postinstall_script, uninstall_script, "
                f"preuninstall_script, or postuninstall_script (nothing will execute)"
            )

        if not is_ondemand and has_install_action and not has_installcheck and not has_installs:
            errors.append(
                f"installer type '{installer_type}' has an install action but no "
                f"'installcheck_script' and no 'installs' — will re-run on every "
                f"managedsoftwareupdate cycle. Add an installcheck_script that "
                f"exits non-zero when already applied, or populate 'installs'."
            )
        if not is_ondemand and has_uninstall_action and "uninstallcheck_script" not in data:
            errors.append(
                f"installer type '{installer_type}' has an uninstall action but no "
                f"'uninstallcheck_script' — will re-run the uninstall every check. "
                f"Add an uninstallcheck_script that exits non-zero when already removed."
            )

    return errors


def _yaml_duplicate_top_keys(text: str) -> list[str]:
    """Scan raw YAML text for top-level key duplicates.

    PyYAML safe_load silently drops earlier values when a key repeats;
    we detect by line-level parsing (only zero-indent `^key:` lines).
    Skips lines inside block scalars and inside '# comment' lines.
    """
    seen: Counter[str] = Counter()
    in_block_scalar = False
    block_indent = 0
    for raw_line in text.splitlines():
        stripped = raw_line.rstrip()
        if not stripped:
            continue
        if stripped.lstrip().startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if in_block_scalar:
            if indent > block_indent:
                continue
            in_block_scalar = False
        if indent == 0:
            if ":" in stripped:
                key = stripped.split(":", 1)[0]
                if all(c.isalnum() or c == "_" for c in key):
                    rest = stripped.split(":", 1)[1].strip()
                    if rest.startswith("|") or rest.startswith(">"):
                        in_block_scalar = True
                        block_indent = 0
                    seen[key] += 1
    return [k for k, n in seen.items() if n > 1]


def get_staged_pkgsinfo(repo_root: Path) -> list[Path]:
    """Return absolute paths of staged pkgsinfo files."""
    proc = subprocess.run(
        ["git", "-C", str(repo_root),
         "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        return []

    staged: list[Path] = []
    for line in proc.stdout.splitlines():
        if not line.startswith("deployment/pkgsinfo/"):
            continue
        if not (line.endswith(".yaml") or line.endswith(".yml")):
            continue
        path = repo_root / line
        if path.is_file():
            staged.append(path)
    return staged


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("Usage: pkgsinfo-lint.py <repo-root>\n")
        return 2

    repo_root = Path(sys.argv[1]).resolve()
    staged = get_staged_pkgsinfo(repo_root)

    if not staged:
        return 0

    issues: list[tuple[str, list[str]]] = []
    for f in staged:
        rel = str(f.relative_to(repo_root)).replace("\\", "/")
        errs = issues_for_file(f)
        if errs:
            issues.append((rel, errs))

    if not issues:
        sys.stderr.write(f"[pre-commit] pkgsinfo structural lint passed ({len(staged)} file(s))\n")
        return 0

    total_errors = sum(len(e) for _, e in issues)
    sys.stderr.write("\n")
    sys.stderr.write(f"  COMMIT BLOCKED: {total_errors} structural error(s) in {len(issues)} pkgsinfo file(s)\n")
    sys.stderr.write("\n")
    for rel, errs in issues:
        sys.stderr.write(f"  {rel}\n")
        for e in errs:
            sys.stderr.write(f"    - {e}\n")
        sys.stderr.write("\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
