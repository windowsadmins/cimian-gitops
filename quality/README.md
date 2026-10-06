# Quality

Checks that catch what `makecatalogs` lets through, and a daily look at what
production actually serves.

| Path | What it is |
|---|---|
| `common/Category-Vocabulary.ps1` | The closed list of package categories, and the retired ones with what replaced them. The values are an example; replace them with your own. |
| `lint/Test-Categories.ps1` | Every pkgsinfo, `packages/*/build-info.yaml`, `installers/*/build-info.yaml` and AutoPkg override that imports names a category from the list. Also catches a script that hardcodes the cache folder of a different category. |
| `lint/Test-PkgsinfoStructure.ps1` | Every pkgsinfo parses, has a name and version, uses known and cumulative catalogs, names only x64 or arm64, and has a safe `installer.location` and a SHA-256 `installer.hash`. |
| `prod_checks.py` | `stalled`: hand-made items that never reached Production, and manifest conditions that hold an item back. `drift`: recent pkgsinfo missing from a published catalog they declare. |
| `tests/` | `Test-Lints.ps1` (plain PowerShell) and `test_prod_checks.py` (unittest). |

The pipelines are `pipelines/{azure,github}/prod-checks.yml`, which run the
lints and both checks every weekday and report findings as warnings.

## Category gate on push

The pre-push hook in `githooks/` runs `lint/Test-Categories.ps1` when it is
present, against the manifests in the push only:

```sh
pwsh -NoProfile -File quality/lint/Test-Categories.ps1 -RepoRoot . -OnlyFile <file listing repo-relative paths>
```

Judging only the pushed files means a branch is never blocked by state the
person pushing did not touch. Exit 1 blocks the push. If `powershell-yaml` is
missing the check says so and exits 0, because a missing module is not a bad
category.

## Running the lints

Both lints need the `powershell-yaml` module:

```sh
pwsh -c "Install-Module powershell-yaml -Scope CurrentUser"
```

A Cimian repo keeps pkgsinfo under `deployment/pkgsinfo`, the default. This
sample repo keeps its examples at `pkgsinfo/`, so point the lints there:

```sh
pwsh -NoProfile -File quality/lint/Test-Categories.ps1 -PkgsinfoPath pkgsinfo
```

```sh
pwsh -NoProfile -File quality/lint/Test-PkgsinfoStructure.ps1 -Path pkgsinfo
```

Microsoft Store app descriptors under `pkgsinfo/apps/managed/` belong to the
Intune layer and are skipped by both.

## Production checks

```sh
python3 quality/prod_checks.py stalled --repo .
```

```sh
python3 quality/prod_checks.py drift --repo . --published <folder of downloaded catalogs> --days 4
```

Findings print as warnings and exit 0. Add `--strict` to exit 1 instead.
AutoPkg imports are left out of `stalled`, because the promoter moves them on
its own; see [`../promotion/`](../promotion/).

## Tests

```sh
pwsh -NoProfile -File quality/tests/Test-Lints.ps1
```

```sh
python3 -m unittest discover -s quality/tests
```
