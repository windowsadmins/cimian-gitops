#!/usr/bin/env python3
"""Fail when a profile or managed app declares catalogs out of waterfall order.

    python3 intune/checks/catalog_waterfall.py

Run from the repo root. Cimian promotes through Development, Testing, Staging
and Production in that order, so a declaration must be a prefix of that list:
`[Development, Testing]` is valid, `[Testing]` or `[Development, Staging]` is a
gap that strands the item in a catalog nobody tests from. This is the
Cimian-only check the intune-gitops pipeline runs in its test stage.
"""
from __future__ import annotations

import pathlib
import sys

import yaml

WATERFALL = ["Development", "Testing", "Staging", "Production"]
ROOTS = ["intune/profiles", "pkgsinfo/apps/managed"]


def problems(root: pathlib.Path) -> list[str]:
    found = []
    for base in ROOTS:
        for path in sorted((root / base).rglob("*.yaml")):
            catalogs = (yaml.safe_load(path.read_text(encoding="utf-8")) or {}).get("catalogs") or []
            if not catalogs or catalogs != WATERFALL[: len(catalogs)]:
                found.append(f"{path.relative_to(root).as_posix()}: catalogs {catalogs} "
                             f"must be a prefix of {WATERFALL}")
    return found


def main() -> int:
    found = problems(pathlib.Path.cwd())
    for line in found:
        print(f"error: {line}", file=sys.stderr)
    if not found:
        print("Catalog declarations are cumulative.")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
