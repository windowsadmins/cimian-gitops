"""Tests for prod_checks.py.

    python3 -m unittest discover -s quality/tests
"""
from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import unittest

CHECKS = pathlib.Path(__file__).resolve().parent.parent / "prod_checks.py"


class ProdChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        git = ["git", "-C", str(self.repo)]
        subprocess.run([*git, "init", "-q"], check=True)
        subprocess.run([*git, "config", "user.email", "t@example.com"], check=True)
        subprocess.run([*git, "config", "user.name", "T"], check=True)
        self.git = git

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, text):
        p = self.repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def commit(self):
        subprocess.run([*self.git, "add", "-A"], check=True)
        subprocess.run([*self.git, "commit", "-qm", "x"], check=True)

    def run_checks(self, *args):
        return subprocess.run([sys.executable, str(CHECKS), *args, "--repo", str(self.repo)],
                              capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})

    def test_stalled_lists_hand_made_items_only(self):
        self.write("deployment/pkgsinfo/apps/Hand.yaml", "name: Hand\nversion: 1\ncatalogs: [Development, Testing]\n_metadata:\n  created_by: admin\n")
        self.write("deployment/pkgsinfo/apps/Auto.yaml", "name: Auto\nversion: 1\ncatalogs: [Testing]\n_metadata:\n  created_by: autopkg\n")
        self.write("deployment/pkgsinfo/apps/Live.yaml", "name: Live\nversion: 1\ncatalogs: [Development, Testing, Staging, Production]\n")
        self.write("deployment/pkgsinfo/apps/managed/Store.yaml", "name: Store\n")
        r = self.run_checks("stalled")
        self.assertIn("Hand", r.stdout)
        self.assertNotIn("Auto ", r.stdout)
        self.assertNotIn("Live", r.stdout)
        self.assertNotIn("Store", r.stdout)
        self.assertEqual(r.returncode, 0)

    def test_stalled_flags_non_production_conditions(self):
        self.write("deployment/pkgsinfo/x.yaml", "name: X\nversion: 1\ncatalogs: [Development, Testing, Staging, Production]\n")
        self.write("deployment/manifests/Lab.yaml",
                   "conditional_items:\n- condition: catalogs CONTAINS \"Testing\"\n  managed_installs: [Beta]\n")
        r = self.run_checks("stalled", "--strict")
        self.assertIn("Beta", r.stdout)
        self.assertEqual(r.returncode, 1)

    def test_drift_finds_missing_catalog_entry(self):
        self.write("deployment/pkgsinfo/apps/App.yaml", "name: App\nversion: '2.0'\ncatalogs: [Development, Testing, Staging, Production]\n")
        self.commit()
        pub = pathlib.Path(self.tmp.name) / "pub"
        pub.mkdir()
        (pub / "Testing.yaml").write_text("items:\n- name: App\n  version: '2.0'\n")
        (pub / "Production.yaml").write_text("items:\n- name: App\n  version: '1.0'\n")
        r = self.run_checks("drift", "--published", str(pub), "--strict")
        self.assertIn("declares Production", r.stdout)
        self.assertNotIn("declares Testing", r.stdout)
        self.assertEqual(r.returncode, 1)

    def test_drift_clean(self):
        self.write("deployment/pkgsinfo/apps/App.yaml", "name: App\nversion: '2.0'\ncatalogs: [Testing]\n")
        self.commit()
        pub = pathlib.Path(self.tmp.name) / "pub"
        pub.mkdir()
        (pub / "Testing.yaml").write_text("items:\n- name: App\n  version: '2.0'\n")
        r = self.run_checks("drift", "--published", str(pub), "--strict")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
