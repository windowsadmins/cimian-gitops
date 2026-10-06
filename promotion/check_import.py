#!/usr/bin/env python3
"""Check what an AutoPkg run produced before any of it is published.

The import job runs third-party recipe code, so its output is treated as
untrusted until this passes. Run it in the import job, and again in the
publish job on the artifact it received:

    python3 promotion/check_import.py --repo .
    python3 promotion/check_import.py --artifact <dir>

Rules:
  - Every new or changed pkgsinfo lists only first-stage catalogs
    (Development and Testing by default). Anything later is the promoter's
    job, through promoter.yml, and an import that skips ahead would bypass the
    staged release.
  - Every new pkgsinfo is stamped _metadata.created_by: autopkg (run
    stamp_metadata.py first), so the promoter recognises it.
  - An artifact holds nothing but deployment/pkgsinfo/**.yaml and
    deployment/pkgs/** regular files. Catalogs and manifests are never carried
    across; push-to-production builds catalogs from the committed main.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys

import yaml

DEFAULT_ALLOWED = "Development,Testing"


def check_pkgsinfo(
    path: pathlib.Path, rel: str, allowed: set[str], is_new: bool
) -> list[str]:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        return [f"{rel}: not valid YAML ({exc})"]
    if not isinstance(data, dict):
        return [f"{rel}: not a mapping"]
    errors = []
    catalogs = data.get("catalogs")
    if not isinstance(catalogs, list) or not catalogs:
        errors.append(f"{rel}: no catalogs")
    else:
        beyond = [c for c in catalogs if c not in allowed]
        if beyond:
            errors.append(
                f"{rel}: imports straight into {', '.join(map(str, beyond))}; imports may only use {', '.join(sorted(allowed))}"
            )
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


def check_artifact(root: pathlib.Path, allowed: set[str]) -> list[str]:
    errors = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            p = pathlib.Path(dirpath) / name
            if p.is_symlink():
                errors.append(f"{p.relative_to(root)}: symlinks are not allowed")
        for name in filenames:
            p = pathlib.Path(dirpath) / name
            rel = p.relative_to(root).as_posix()
            if rel.startswith("deployment/pkgs/"):
                continue
            if (
                rel.startswith("deployment/pkgsinfo/")
                and rel.endswith((".yaml", ".yml"))
                and "/managed/" not in rel
            ):
                # Every pkgsinfo in the artifact is new or rewritten by the run.
                errors += check_pkgsinfo(p, rel, allowed, is_new=False)
                continue
            errors.append(f"{rel}: not allowed in an import artifact")
    return errors


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--repo", type=pathlib.Path)
    group.add_argument("--artifact", type=pathlib.Path)
    ap.add_argument(
        "--allowed-catalogs",
        default=DEFAULT_ALLOWED,
        help=f"comma-separated first-stage catalogs (default {DEFAULT_ALLOWED})",
    )
    args = ap.parse_args(argv)
    allowed = {c.strip() for c in args.allowed_catalogs.split(",") if c.strip()}

    errors = (
        check_repo(args.repo.resolve(), allowed)
        if args.repo
        else check_artifact(args.artifact.resolve(), allowed)
    )
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    if errors:
        return 1
    print("Import output OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
