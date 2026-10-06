#!/usr/bin/env python3
"""Stamp _metadata on pkgsinfo that an AutoPkg run just created.

The promoter counts days in a catalog from _metadata.creation_date and only
auto-promotes items whose _metadata.created_by is "autopkg". AutoPkg's Cimian
importer writes neither, so run this after `autopkg run` and before the
commit:

    python3 promotion/stamp_metadata.py --repo .

New files (untracked in git) get created_by and creation_date. A modified
file whose rewrite dropped the _metadata block gets the block back from HEAD,
so a re-import keeps the original author and date instead of looking new.
"""
from __future__ import annotations

import argparse
import datetime
import pathlib
import subprocess
import sys

IDENTITY = "autopkg"


def metadata_block(text: str) -> str | None:
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("_metadata:"):
            j = i + 1
            while j < len(lines) and (lines[j].startswith((" ", "\t")) or not lines[j].strip()):
                j += 1
            return "\n".join(lines[i:j]).rstrip() + "\n"
    return None


def append_block(path: pathlib.Path, block: str) -> None:
    text = path.read_text(encoding="utf-8")
    if not text.endswith("\n"):
        text += "\n"
    path.write_text(text + block, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", type=pathlib.Path, default=pathlib.Path("."))
    ap.add_argument("--pkgsinfo", default="deployment/pkgsinfo")
    args = ap.parse_args(argv)

    repo = args.repo.resolve()
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    status = subprocess.run(
        ["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=all", "--", args.pkgsinfo],
        capture_output=True, text=True, check=True,
    ).stdout

    stamped = restored = 0
    for line in status.splitlines():
        code, rel = line[:2].strip(), line[3:].strip().strip('"')
        if not rel.endswith((".yaml", ".yml")):
            continue
        path = repo / rel
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        if metadata_block(text):
            continue
        if code == "??":
            append_block(path, f"_metadata:\n  created_by: {IDENTITY}\n  creation_date: '{now}'\n")
            stamped += 1
        elif code == "M":
            head = subprocess.run(["git", "-C", str(repo), "show", f"HEAD:{rel}"],
                                  capture_output=True, text=True)
            block = metadata_block(head.stdout) if head.returncode == 0 else None
            if block:
                append_block(path, block)
                restored += 1

    print(f"Stamped {stamped} new pkgsinfo; restored _metadata on {restored} rewritten one(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
