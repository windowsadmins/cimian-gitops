# Promotion

New app versions arrive by AutoPkg and move through the catalogs on a
schedule, without anyone editing a pkgsinfo by hand:

```
AutoPkg import  ──>  Development, Testing
                       │  days_in_catalog
                       ▼
                     + Staging
                       │  days_in_catalog
                       ▼
                     + Production
```

Catalogs are cumulative. An item in Staging is also in Development and
Testing, so a machine on any earlier cohort still sees it.

| Path | What it is |
|---|---|
| `recipe_list.yaml` | The recipe repos, pinned to commits, and the overrides the scheduled run imports. |
| `RecipeOverrides/` | One override per recipe, carrying the parent recipe's trust info. |
| `requirements-autopkg.txt` | AutoPkg's Python dependencies, pinned with hashes. |
| `Invoke-AutoPkgRun.ps1` | Installs the Cimian-aware AutoPkg fork at a pinned commit on a Windows agent, writes its preferences, and runs the list. |
| `check_import.py` | Fails an import that lands beyond the first-stage catalogs, skips the stamp, or carries anything but pkgsinfo and packages. |
| `stamp_metadata.py` | Marks new pkgsinfo `created_by: autopkg` with a `creation_date`, and restores the original `_metadata` on a re-import that dropped it. |
| `promoter.py` | Moves eligible items one stage on. Adapted from munki-promoter. |
| `promoter.yml` | The rules: stages, days in each, per-item exceptions. |
| `tests/` | Offline tests for the promoter and the stamp. |

The pipelines are `pipelines/{azure,github}/autopkg.yml` and
`pipelines/{azure,github}/promote-catalogs.yml`.

## Trusting what AutoPkg runs

A recipe is code: it downloads things and runs processors on them. So
everything the import executes is pinned and reviewed, and the job that runs
it can write nothing.

- **Pinned.** AutoPkg is checked out at a reviewed commit and verified.
  Recipe repos are `url@sha` in `recipe_list.yaml`. Python dependencies
  install with `--require-hashes`.
- **Trust info.** Recipes run only through the overrides in
  `RecipeOverrides/`, and `FAIL_RECIPES_WITHOUT_TRUST_INFO` is set. An
  override records the hash of its parent recipe, so a parent that changed
  upstream fails the run until someone reads the change and accepts it:

  ```sh
  autopkg verify-trust-info -vv local.cimian.Chrome
  ```

  ```sh
  autopkg update-trust-info local.cimian.Chrome
  ```

  Bump a repo's pinned commit and refresh the trust info in the same pull
  request, so review sees both.
- **No credentials in the import job.** It has no cloud login, no persisted
  git credential, and only a read-only GitHub token for downloads. It hands
  its output to a separate publish job as an artifact. The publish job checks
  that artifact with `check_import.py` before and after applying it, then
  uploads the packages and commits.
- **First stage only.** An import may only land in Development and Testing.
  Anything later is the promoter's job, and `check_import.py` fails an import
  that skips ahead.

## What moves on its own

Only pkgsinfo whose `_metadata.created_by` is listed under
`selection.created_by` in `promoter.yml`, which by default means only AutoPkg
imports. A package you built and imported yourself stays where you put it
until you commit a catalog change. Without that gate, an internal package
would ride the stages into Production unattended.

Microsoft Store apps under `pkgsinfo/apps/managed/` are never touched; the
Intune layer owns them.

## The daily rhythm

1. **Morning: AutoPkg.** New versions land in Development and Testing.
2. **Mid-morning: preview.** The promoter runs with `--dry-run --as-of 18`,
   so it lists what the afternoon run will move, judged at that run's hour.
   That is the window to pull an item: move it out of the stage it is in, or
   add it to `selection` as an exclusion.
3. **Afternoon: promote.** The promoter edits the catalogs and commits to
   main, and push-to-production publishes them.

## Try it

```sh
python3 promotion/promoter.py --list --yaml promotion/promoter.yml
```

```sh
python3 promotion/promoter.py --pkgsinfo deployment/pkgsinfo/apps --yaml promotion/promoter.yml --dry-run
```

```sh
python3 -m unittest discover -s promotion/tests
```
