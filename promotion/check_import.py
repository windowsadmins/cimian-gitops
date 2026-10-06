#!/usr/bin/env python3
"""Check what an AutoPkg run produced before any of it is published.

The import job runs third-party recipe code, so its output is untrusted until
this passes. Run it in the import job on the working tree, and in the publish
job on the artifact before it touches anything:

    python3 promotion/check_import.py --repo .
    python3 promotion/check_import.py --artifact <dir> --base . --existing-pkgs keys.txt

Every pkgsinfo the run created or changed:
  - lists only first-stage catalogs (Development and Testing by default).
    Moving on is the promoter's job, and an import that skips ahead would
    bypass the staged release.
  - if new, carries _metadata.created_by: autopkg.

An artifact, additionally:
  - holds only regular, singly-linked files under deployment/pkgsinfo/
    (*.yaml) and deployment/pkgs/, with plain ASCII path segments: no "..",
    no hidden or empty segments, no drive letters or backslashes.
  - is create-only for packages. Every package must be named by a pkgsinfo
    in the same artifact whose installer.hash is the file's SHA-256, and must
    not already exist in storage (--existing-pkgs, compared without regard to
    case, since Windows clients and blob paths are case-insensitive in
    practice). A run cannot replace a binary a promoted pkgsinfo points at.
  - may rewrite an existing pkgsinfo (--base) only if that item is still in
    first-stage catalogs on main. A path that differs from an existing one
    only by case is refused.
  - never carries catalogs, manifests or anything else; push-to-production
    builds catalogs from the committed main.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import stat
import subprocess
import sys

import yaml

DEFAULT_ALLOWED = "Development,Testing"
SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+()-]*$")


def load(path: pathlib.Path):
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (yaml.YAMLError, UnicodeDecodeError) as exc:
        return None, f"not valid YAML ({exc})"
    if not isinstance(data, dict):
        return None, "not a mapping"
    return data, None


def first_stage_only(data: dict, allowed: set[str]) -> str | None:
    catalogs = data.get("catalogs")
    if not isinstance(catalogs, list) or not catalogs:
        return "no catalogs"
    beyond = [str(c) for c in catalogs if c not in allowed]
    if beyond:
        return (
            f"in {', '.join(beyond)}; imports may only use {', '.join(sorted(allowed))}"
        )
    return None


def check_pkgsinfo(
    path: pathlib.Path, rel: str, allowed: set[str], is_new: bool
) -> list[str]:
    data, err = load(path)
    if err:
        return [f"{rel}: {err}"]
    errors = []
    bad = first_stage_only(data, allowed)
    if bad:
        errors.append(f"{rel}: {bad}")
    if is_new:
        meta = data.get("_metadata") if isinstance(data.get("_metadata"), dict) else {}
        if meta.get("created_by") != "autopkg":
            errors.append(f"{rel}: new pkgsinfo without _metadata.created_by: autopkg")
    return errors


def check_repo(repo: pathlib.Path, allowed: set[str]) -> list[str]:
    out = subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--",
            "deployment/pkgsinfo",
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    errors = []
    for line in out.splitlines():
        code, rel = line[:2].strip(), line[3:].strip().strip('"')
        if code.startswith("D") or not rel.endswith((".yaml", ".yml")):
            continue
        if "/managed/" in rel:
            errors.append(
                f"{rel}: imports must not touch the managed Store app descriptors"
            )
            continue
        errors += check_pkgsinfo(repo / rel, rel, allowed, is_new=(code == "??"))
    return errors


def location_key(location) -> str | None:
    """deployment/pkgs/<location>, normalised, or None if it is not a safe relative path."""
    if not isinstance(location, str):
        return None
    loc = location.replace("\\", "/").strip().lstrip("/")
    parts = loc.split("/")
    if not loc or any(not SEGMENT.match(p) for p in parts):
        return None
    return "deployment/pkgs/" + loc


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tracked_pkgsinfo(base: pathlib.Path) -> dict[str, str]:
    """Lower-cased path -> actual path for every pkgsinfo on the base checkout."""
    out = subprocess.run(
        ["git", "-C", str(base), "ls-files", "--", "deployment/pkgsinfo"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return {p.lower(): p for p in out.splitlines()}


def check_artifact(
    root: pathlib.Path,
    allowed: set[str],
    base: pathlib.Path | None,
    existing_pkgs: set[str] | None,
) -> list[str]:
    errors: list[str] = []
    pkgsinfo: dict[str, pathlib.Path] = {}
    pkgs: dict[str, pathlib.Path] = {}

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            p = pathlib.Path(dirpath) / name
            rel = p.relative_to(root).as_posix()
            st = os.lstat(p)
            if name in dirnames:
                if not stat.S_ISDIR(st.st_mode):
                    errors.append(f"{rel}: not a plain directory")
                continue
            if not stat.S_ISREG(st.st_mode):
                errors.append(f"{rel}: not a regular file")
                continue
            if st.st_nlink > 1:
                errors.append(f"{rel}: hard links are not allowed")
                continue
            parts = rel.split("/")
            if any(not SEGMENT.match(s) for s in parts):
                errors.append(f"{rel}: path segments must be plain ASCII names")
                continue
            if rel.startswith("deployment/pkgs/"):
                pkgs[rel] = p
            elif (
                rel.startswith("deployment/pkgsinfo/")
                and rel.endswith((".yaml", ".yml"))
                and "/managed/" not in rel
            ):
                pkgsinfo[rel] = p
            else:
                errors.append(f"{rel}: not allowed in an import artifact")

    base_paths = tracked_pkgsinfo(base) if base else {}
    referenced: dict[str, str] = {}
    for rel, p in pkgsinfo.items():
        data, err = load(p)
        if err:
            errors.append(f"{rel}: {err}")
            continue
        bad = first_stage_only(data, allowed)
        if bad:
            errors.append(f"{rel}: {bad}")
        existing = base_paths.get(rel.lower())
        if existing and existing != rel:
            errors.append(f"{rel}: differs only by case from {existing} on main")
        elif existing and base:
            old, old_err = load(base / existing)
            if old_err or first_stage_only(old, allowed):
                errors.append(
                    f"{rel}: rewrites a pkgsinfo that main has already promoted past {', '.join(sorted(allowed))}"
                )
        elif base:
            meta = (
                data.get("_metadata") if isinstance(data.get("_metadata"), dict) else {}
            )
            if meta.get("created_by") != "autopkg":
                errors.append(
                    f"{rel}: new pkgsinfo without _metadata.created_by: autopkg"
                )
        installer = (
            data.get("installer") if isinstance(data.get("installer"), dict) else {}
        )
        key = location_key(installer.get("location"))
        if installer.get("location") is not None and key is None:
            errors.append(f"{rel}: installer.location is not a safe relative path")
        elif key:
            referenced[key.lower()] = str(installer.get("hash") or "").lower()

    for rel, p in pkgs.items():
        want = referenced.get(rel.lower())
        if want is None:
            errors.append(f"{rel}: no pkgsinfo in this import references it")
        elif sha256(p) != want:
            errors.append(
                f"{rel}: SHA-256 does not match installer.hash in its pkgsinfo"
            )
        if existing_pkgs is not None and rel.lower() in existing_pkgs:
            errors.append(f"{rel}: already in storage; imports may only add packages")
    return errors


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--repo", type=pathlib.Path)
    group.add_argument("--artifact", type=pathlib.Path)
    ap.add_argument(
        "--base",
        type=pathlib.Path,
        help="checkout of main to compare an artifact against",
    )
    ap.add_argument(
        "--existing-pkgs",
        type=pathlib.Path,
        help="file listing package keys already in storage, one deployment/pkgs/... per line",
    )
    ap.add_argument(
        "--allowed-catalogs",
        default=DEFAULT_ALLOWED,
        help=f"comma-separated first-stage catalogs (default {DEFAULT_ALLOWED})",
    )
    args = ap.parse_args(argv)
    allowed = {c.strip() for c in args.allowed_catalogs.split(",") if c.strip()}

    if args.repo:
        errors = check_repo(args.repo.resolve(), allowed)
    else:
        existing = None
        if args.existing_pkgs:
            existing = {
                ln.strip().lower()
                for ln in args.existing_pkgs.read_text(encoding="utf-8").splitlines()
                if ln.strip()
            }
        errors = check_artifact(
            args.artifact.resolve(),
            allowed,
            args.base.resolve() if args.base else None,
            existing,
        )

    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    if errors:
        return 1
    print("Import output OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
