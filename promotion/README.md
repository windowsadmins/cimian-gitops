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
| `recipe_list.yaml` | The recipe repos to fetch and the recipes the scheduled run imports. |
| `Invoke-AutoPkgRun.ps1` | Installs the Cimian-aware AutoPkg fork on a Windows agent, writes its preferences, and runs the list. |
| `stamp_metadata.py` | Marks new pkgsinfo `created_by: autopkg` with a `creation_date`, and restores the original `_metadata` on a re-import that dropped it. |
| `promoter.py` | Moves eligible items one stage on. Adapted from munki-promoter. |
| `promoter.yml` | The rules: stages, days in each, per-item exceptions. |
| `tests/` | Offline tests for the promoter and the stamp. |

The pipelines are `pipelines/{azure,github}/autopkg.yml` and
`pipelines/{azure,github}/promote-catalogs.yml`.

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
