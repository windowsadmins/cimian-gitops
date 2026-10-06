#!/usr/bin/env python3
"""Daily checks on what production actually serves.

Two questions the repo cannot answer by looking at itself:

  stalled   Which hand-made pkgsinfo never reached Production? AutoPkg imports
            are skipped: the promoter moves those on its own. What is left is
            something a person imported and forgot, or a promotion that stalled.
            Also lists manifest conditional_items whose condition restricts them
            to a non-production catalog, which quietly keep an item off the
            Production fleet.

  drift     Does each recently changed pkgsinfo appear in every catalog it
            declares, in the catalogs clients actually download? A pkgsinfo that
            says Production but is missing from the published Production
            catalog cannot be installed by any Production device. The usual
            cause is a push-to-production run that failed or never ran.

    python3 quality/prod_checks.py stalled --repo .
    python3 quality/prod_checks.py drift --repo . --published <dir of downloaded catalogs> --days 4

Findings are reported as pipeline warnings and the exit code is 0, so a
finding never blocks anything; pass --strict to exit 1 instead.
"""

from __future__ import annotations

import argparse
import datetime
import os
import pathlib
import re
import subprocess
import sys

import yaml

try:
    from yaml import CSafeLoader as Loader  # published catalogs run to several MB
except ImportError:  # pragma: no cover
    from yaml import SafeLoader as Loader

AUTOMATED = {"autopkg", "pipeline"}
NON_PROD_CONDITION = [
    re.compile(r"catalogs\s*(==|CONTAINS)\s*[\"']?(Testing|Staging|Development)", re.I),
    re.compile(r"catalogs\s+DOES_NOT_CONTAIN\s*[\"']?Production", re.I),
]
ARRAY_KEYS = [
    "managed_installs",
    "managed_updates",
    "managed_uninstalls",
    "optional_installs",
]


def warn(message: str) -> None:
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::warning::{message}")
    elif os.environ.get("TF_BUILD"):
        print(f"##vso[task.logissue type=warning]{message}")
    else:
        print(f"warning: {message}")


def load(path: pathlib.Path):
    try:
        return yaml.load(
            path.read_text(encoding="utf-8", errors="replace"), Loader=Loader
        )
    except yaml.YAMLError as exc:
        warn(f"{path}: does not parse ({exc})")
        return None


def age_days(value) -> int | None:
    now = datetime.datetime.now(datetime.timezone.utc)
    if isinstance(value, str):
        try:
            value = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    if isinstance(value, datetime.datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=datetime.timezone.utc)
        return (now - value).days
    return None


def stalled(repo: pathlib.Path, pkgsinfo_dir: str, manifests_dir: str) -> list[str]:
    findings = []
    root = repo / pkgsinfo_dir
    for path in sorted(root.rglob("*.y*ml")):
        if "managed" in path.relative_to(root).parts:
            continue
        data = load(path)
        if not isinstance(data, dict):
            continue
        catalogs = data.get("catalogs") or []
        if "Production" in catalogs:
            continue
        meta = data.get("_metadata") if isinstance(data.get("_metadata"), dict) else {}
        if str(meta.get("created_by") or "").strip().lower() in AUTOMATED:
            continue
        days = age_days(meta.get("creation_date"))
        findings.append(
            f"not in Production: {data.get('name', path.stem)} {data.get('version', '?')} "
            f"in {', '.join(map(str, catalogs)) or '(no catalogs)'}"
            f"{f', {days}d old' if days is not None else ''} ({path.relative_to(repo)})"
        )

    for path in sorted((repo / manifests_dir).rglob("*.y*ml")):
        data = load(path)
        if not isinstance(data, dict):
            continue
        for item in data.get("conditional_items") or []:
            cond = str((item or {}).get("condition", ""))
            if not any(p.search(cond) for p in NON_PROD_CONDITION):
                continue
            for key in ARRAY_KEYS:
                if item.get(key):
                    findings.append(
                        f"held back from Production by condition '{cond}': {key} "
                        f"{', '.join(map(str, item[key]))} ({path.relative_to(repo)})"
                    )
    return findings


def catalog_entries(path: pathlib.Path) -> set[tuple[str, str]]:
    data = load(path)
    if isinstance(data, dict):  # Cimian nests entries under items:
        data = data.get("items") or []
    return {
        (str(e.get("name")), str(e.get("version", "")))
        for e in (data or [])
        if isinstance(e, dict) and e.get("name")
    }


def drift(
    repo: pathlib.Path, published_dir: pathlib.Path, days: int, pkgsinfo_dir: str
) -> list[str]:
    published = {
        p.stem: catalog_entries(p) for p in sorted(published_dir.glob("*.yaml"))
    }
    if not published:
        warn("no published catalogs to compare against; drift check skipped")
        return []
    print(
        "published: " + ", ".join(f"{k}={len(v)}" for k, v in sorted(published.items()))
    )

    log = subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "log",
            f"--since={days} days ago",
            "--name-only",
            "--pretty=format:",
            "HEAD",
            "--",
            pkgsinfo_dir,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    recent = sorted(
        {
            ln.strip()
            for ln in log.splitlines()
            if ln.strip().endswith((".yaml", ".yml"))
        }
    )
    print(f"pkgsinfo changed in the last {days} days: {len(recent)}")

    findings = []
    for rel in recent:
        path = repo / rel
        if not path.is_file() or "/managed/" in rel:
            continue
        data = load(path)
        if not isinstance(data, dict) or not data.get("name"):
            continue
        pair = (str(data["name"]), str(data.get("version", "")))
        for cat in data.get("catalogs") or []:
            if cat in published and pair not in published[cat]:
                findings.append(
                    f"catalog drift: {pair[0]} {pair[1]} declares {cat} but the published {cat} catalog lacks it ({rel})"
                )
    return findings


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("stalled", "drift"):
        p = sub.add_parser(name)
        p.add_argument("--repo", type=pathlib.Path, default=pathlib.Path("."))
        p.add_argument("--pkgsinfo", default="deployment/pkgsinfo")
        p.add_argument(
            "--strict", action="store_true", help="exit 1 when there are findings"
        )
    sub.choices["stalled"].add_argument("--manifests", default="deployment/manifests")
    sub.choices["drift"].add_argument("--published", type=pathlib.Path, required=True)
    sub.choices["drift"].add_argument("--days", type=int, default=4)
    args = ap.parse_args(argv)

    repo = args.repo.resolve()
    if args.cmd == "stalled":
        findings = stalled(repo, args.pkgsinfo, args.manifests)
    else:
        findings = drift(repo, args.published.resolve(), args.days, args.pkgsinfo)

    for f in findings:
        warn(f)
    print(f"{len(findings)} finding(s).")
    return 1 if findings and args.strict else 0


if __name__ == "__main__":
    sys.exit(main())
