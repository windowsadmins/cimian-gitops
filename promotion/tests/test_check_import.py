"""Tests for check_import.py and the default-branch gate in Sync-RepoToBlob.ps1.

    python3 -m unittest discover -s promotion/tests
"""
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent.parent
CHECK = HERE / "check_import.py"
SYNC = HERE.parent / "pipelines" / "scripts" / "Sync-RepoToBlob.ps1"


def pkgsinfo(catalogs, created_by="autopkg"):
    cats = "".join(f"- {c}\n" for c in catalogs)
    meta = f"_metadata:\n  created_by: {created_by}\n" if created_by else ""
    return f"name: App\nversion: 1.0\ncatalogs:\n{cats}{meta}"


class CheckImportRepo(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.tmp.name)
        subprocess.run(["git", "-C", str(self.repo), "init", "-q"], check=True)
        self.dir = self.repo / "deployment" / "pkgsinfo" / "apps"
        self.dir.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def check(self):
        return subprocess.run([sys.executable, str(CHECK), "--repo", str(self.repo)], capture_output=True, text=True)

    def test_first_stage_import_passes(self):
        (self.dir / "App.yaml").write_text(pkgsinfo(["Development", "Testing"]))
        self.assertEqual(self.check().returncode, 0)

    def test_import_into_production_fails(self):
        (self.dir / "App.yaml").write_text(pkgsinfo(["Development", "Testing", "Production"]))
        r = self.check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("Production", r.stderr)

    def test_unstamped_new_file_fails(self):
        (self.dir / "App.yaml").write_text(pkgsinfo(["Testing"], created_by=None))
        self.assertEqual(self.check().returncode, 1)


class CheckImportArtifact(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, rel, text="x"):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def check(self):
        return subprocess.run([sys.executable, str(CHECK), "--artifact", str(self.root)], capture_output=True, text=True)

    def test_packages_and_pkgsinfo_pass(self):
        self.put("deployment/pkgs/apps/App-1.0.msi")
        self.put("deployment/pkgsinfo/apps/App.yaml", pkgsinfo(["Testing"]))
        self.assertEqual(self.check().returncode, 0)

    def test_catalogs_are_rejected(self):
        self.put("deployment/catalogs/Production.yaml")
        self.assertEqual(self.check().returncode, 1)

    def test_manifests_are_rejected(self):
        self.put("deployment/manifests/site_default.yaml")
        self.assertEqual(self.check().returncode, 1)

    def test_pipeline_files_are_rejected(self):
        self.put("pipelines/azure/push-to-production-azure.yml")
        self.assertEqual(self.check().returncode, 1)

    def test_promoted_pkgsinfo_is_rejected(self):
        self.put("deployment/pkgsinfo/apps/App.yaml", pkgsinfo(["Staging"]))
        self.assertEqual(self.check().returncode, 1)


@unittest.skipUnless(shutil.which("pwsh"), "pwsh not installed")
class SyncBranchGate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        bindir = pathlib.Path(self.tmp.name)
        (bindir / "pwsh").symlink_to(shutil.which("pwsh"))
        az = bindir / "az"
        az.write_text("#!/bin/sh\necho fake az >&2\nexit 1\n")
        az.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_sync(self, ref, *extra):
        env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_REF", "BUILD_SOURCEBRANCH")}
        if ref:
            env["GITHUB_REF"] = ref
        # A PATH holding only pwsh and an az that fails at once, so a run
        # that passes the gate stops at the SAS step instead of reaching a
        # real account.
        bindir = pathlib.Path(self.tmp.name)
        env["PATH"] = str(bindir)
        return subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(SYNC), "-StorageAccount", "examplecimianstorage",
             "-Container", "repo", "-RepoRoot", ".", *extra],
            capture_output=True, text=True, env=env, timeout=60,
        )

    def test_metadata_from_other_branch_refused(self):
        r = self.run_sync("refs/heads/feature")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Refusing to publish repo metadata", r.stdout + r.stderr)

    def test_unknown_ref_refused(self):
        r = self.run_sync("")
        self.assertIn("Refusing to publish repo metadata", r.stdout + r.stderr)

    def test_packages_only_passes_the_gate(self):
        r = self.run_sync("refs/heads/feature", "-PackagesOnly")
        self.assertNotIn("Refusing to publish repo metadata", r.stdout + r.stderr)

    def test_main_passes_the_gate(self):
        r = self.run_sync("refs/heads/main")
        self.assertNotIn("Refusing to publish repo metadata", r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
