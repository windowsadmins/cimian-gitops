"""Offline tests for promoter.py and stamp_metadata.py.

    python3 -m unittest discover -s promotion/tests

Needs PyYAML and git, nothing else.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

import yaml

HERE = pathlib.Path(__file__).resolve().parent.parent
PROMOTER = HERE / "promoter.py"
STAMP = HERE / "stamp_metadata.py"
CONFIG = HERE / "promoter.yml"


def pkgsinfo(name, catalogs, created_by="autopkg", created="2020-01-01T00:00:00Z"):
    cats = "".join(f"- {c}\n" for c in catalogs)
    meta = (
        f"_metadata:\n  created_by: {created_by}\n  creation_date: '{created}'\n"
        if created_by
        else ""
    )
    return f"name: {name}\nversion: 1.0.0\ncatalogs:\n{cats}installer:\n  location: apps/{name}.msi\n{meta}"


class PromoterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.apps = pathlib.Path(self.tmp.name) / "apps"
        self.apps.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, text):
        p = self.apps / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        return p

    def run_promoter(self, *extra):
        return subprocess.run(
            [
                sys.executable,
                str(PROMOTER),
                "--pkgsinfo",
                str(self.apps),
                "--yaml",
                str(CONFIG),
                "--auto",
                *extra,
            ],
            capture_output=True,
            text=True,
            check=True,
        )

    def catalogs(self, path):
        return yaml.safe_load(path.read_text())["catalogs"]

    def test_autopkg_item_moves_one_stage(self):
        p = self.write("tools/Zip.yaml", pkgsinfo("Zip", ["Development", "Testing"]))
        self.run_promoter()
        self.assertEqual(self.catalogs(p), ["Development", "Testing", "Staging"])

    def test_hand_made_item_stays_put(self):
        p = self.write(
            "tools/Internal.yaml",
            pkgsinfo("Internal", ["Development", "Testing"], created_by="admin"),
        )
        self.run_promoter()
        self.assertEqual(self.catalogs(p), ["Development", "Testing"])

    def test_custom_item_skips_to_production(self):
        p = self.write(
            "browsers/Chrome.yaml", pkgsinfo("Chrome", ["Development", "Testing"])
        )
        self.run_promoter()
        self.assertEqual(
            self.catalogs(p), ["Development", "Testing", "Staging", "Production"]
        )

    def test_too_new_waits(self):
        p = self.write(
            "tools/New.yaml",
            pkgsinfo("New", ["Development", "Testing"], created="2999-01-01T00:00:00Z"),
        )
        self.run_promoter()
        self.assertEqual(self.catalogs(p), ["Development", "Testing"])

    def test_dry_run_writes_nothing(self):
        p = self.write("tools/Zip.yaml", pkgsinfo("Zip", ["Development", "Testing"]))
        before = p.read_text()
        self.run_promoter("--dry-run")
        self.assertEqual(p.read_text(), before)

    def test_managed_store_apps_ignored(self):
        p = self.write(
            "managed/Portal.yaml", pkgsinfo("Portal", ["Development", "Testing"])
        )
        before = p.read_text()
        self.run_promoter()
        self.assertEqual(p.read_text(), before)


class StampTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.tmp.name)
        git = ["git", "-C", str(self.repo)]
        subprocess.run([*git, "init", "-q"], check=True)
        subprocess.run([*git, "config", "user.email", "test@example.com"], check=True)
        subprocess.run([*git, "config", "user.name", "Test"], check=True)
        self.dir = self.repo / "deployment" / "pkgsinfo" / "apps"
        self.dir.mkdir(parents=True)
        (self.dir / "Old.yaml").write_text(
            pkgsinfo(
                "Old", ["Testing"], created_by="admin", created="2021-05-05T00:00:00Z"
            )
        )
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-qm", "seed"], check=True)

    def tearDown(self):
        self.tmp.cleanup()

    def stamp(self):
        subprocess.run(
            [sys.executable, str(STAMP), "--repo", str(self.repo)],
            check=True,
            capture_output=True,
        )

    def test_new_file_gets_autopkg_metadata(self):
        p = self.dir / "New.yaml"
        p.write_text(pkgsinfo("New", ["Testing"], created_by=None))
        self.stamp()
        meta = yaml.safe_load(p.read_text())["_metadata"]
        self.assertEqual(meta["created_by"], "autopkg")
        self.assertIn("creation_date", meta)

    def test_rewrite_keeps_original_metadata(self):
        p = self.dir / "Old.yaml"
        p.write_text(
            textwrap.dedent(pkgsinfo("Old", ["Testing"], created_by=None)).replace(
                "1.0.0", "1.1.0"
            )
        )
        self.stamp()
        meta = yaml.safe_load(p.read_text())["_metadata"]
        self.assertEqual(meta["created_by"], "admin")
        self.assertEqual(str(meta["creation_date"]), "2021-05-05T00:00:00Z")


if __name__ == "__main__":
    unittest.main()
