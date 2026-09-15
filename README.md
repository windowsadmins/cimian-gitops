# Running Cimian under a GitOps model

Samples for managing a Windows fleet with [Cimian](https://github.com/windowsadmins/cimian) — the Windows-native managed-software tool modelled on [Munki](https://github.com/munki/munki) — entirely from Git: hooks, CI/CD pipelines, message queues, and local caching servers. This is the Windows companion to [munki-gitops](https://github.com/rodchristiansen/munki-gitops); the two repos mirror each other so a shop running both fleets uses one mental model.

**Cloud Provider Options**: every sample ships in both an **Azure** form (Azure DevOps, Azure Blob Storage, Service Bus, Front Door) and an **AWS** form (GitHub Actions, S3, SQS/SNS, CloudFront). Pick the cloud you're on; the admin experience is identical.

## MDM as a dumb, approved pipe

The core idea: **the MDM does exactly one job** — deliver a single signed bootstrapper to a freshly-enrolled device during the Enrollment Status Page. It never sees the app catalog. Everything else — the real software stack, configuration, patch state — is orchestrated by Cimian pulling from the GitOps repo. Intune is a pipe, not the brain.

That split is what makes the whole fleet reproducible from Git:

- A device enrols → Intune delivers **BootstrapMate** (one Win32 LOB) → BootstrapMate reads `management.json` and lays down the Cimian agent + its config → Cimian takes over and converges the machine against the repo.
- New app, new version, new config? It's a commit and a pull request. The MDM is untouched.

The pipeline that publishes that pipe is the centerpiece here: [`pipelines/azure/bootstrap-to-intune.yml`](pipelines/azure/bootstrap-to-intune.yml) (and its GitHub Actions / S3 twin at [`pipelines/github/bootstrap-to-intune.yml`](pipelines/github/bootstrap-to-intune.yml)). It builds and signs the BootstrapMate MSI, wraps it as an `.intunewin`, regenerates and uploads `management.json`, and pushes the Win32 LOB to Intune via Microsoft Graph with a single group assignment.

## From manual to GitOps

The legacy flow was a shared admin box, one central share, many hands, no pipeline, no gates. Now:

- Git repos and CI/CD pipelines (Azure DevOps or GitHub Actions)
- Git hooks that upload/download packages automatically (Azure Blob or S3)
- A separate working copy per admin, validated on every commit
- Local caching servers that sync intelligently over Service Bus / SQS
- A full CI/CD system that builds, signs, promotes, and deploys via pull requests

## What's in here

| Path | What it is |
|------|------------|
| `githooks/` | PowerShell git hooks (`azure/` + `aws/`) that validate pkgsinfo on commit, download referenced packages on pull, and sync the repo to cloud storage on push. Opt-in per clone. |
| `githooks/lib/` | Shared helpers (`common.ps1`), the structural pkgsinfo linter (`pkgsinfo-lint.py`), and the superseded-pkgsinfo resolver. |
| `pipelines/azure/` | Azure DevOps pipelines: `push-to-production-*` (build catalogs + sync storage) and `bootstrap-to-intune.yml` (the centerpiece). |
| `pipelines/github/` | The same pipelines as GitHub Actions workflows. |
| `preflight/cimian/` | A cimipkg sample that installs a Cimian preflight script run before each check. |
| `local-caching/` | Service Bus / SQS commit-listener packages that keep on-prem caching servers in sync. |
| `inventory/` | The twelve-column device contract, a sample fleet, and the projection script that narrows it per system. |
| `enrollment/` | One consumer per downstream system. The Intune one builds the Entra group ladder everything else addresses. |
| `intune/` | Renders three manifest keys the client ignores into Intune: Store apps, Settings Catalog and OMA-URI profiles, scripts. |
| `pkgsinfo/apps/managed/` | One YAML source-of-truth descriptor for each managed Store app. |

## Git hooks at a glance

PowerShell hooks, opt in per clone (git doesn't use `githooks/` by default):

```sh
git config core.hooksPath githooks/azure
```

```sh
git config core.hooksPath githooks/aws
```

They validate Cimian pkgsinfo with `makecatalogs`, auto-download missing `.nupkg`/`.msi`/`.exe` from cloud storage, lint for structural errors `makecatalogs` lets through, and sync the repo to Azure Blob or S3 on push — with size guards, concurrency locks, capped orphan cleanup, and a version floor. See [`githooks/README.md`](githooks/README.md) for the full reference and the `CIMIAN_*` environment variables.

## Inventory, groups and manifests

Four inventory columns — `usage`, `catalog`, `area`, `location` — are one
hierarchy. At enrollment they become five nested Entra groups. Cimian manifests
live in a directory tree built from the same columns. So:

```
manifests/Assigned/Staff/IT.yaml   <->   Devices-Assigned-Staff-IT
```

A manifest path and a group name are the same address written twice, and both
derive from the same row, so they cannot drift.

Which means a manifest can carry keys Cimian ignores and have them mean
something:

| Key | Renders to |
|---|---|
| `managed_apps` | Microsoft Store apps |
| `managed_profiles` | Settings Catalog and OMA-URI profiles |
| `managed_scripts` | PowerShell scripts |

One reviewed file describes what the agent does *and* what MDM does.

### Catalog-staged Intune releases

Machine-manifest `catalogs` identify an endpoint's cohort. Each profile, script,
and managed-app descriptor has a separate cumulative `catalogs` array that
declares how far that artifact has been promoted:

```yaml
catalogs:
- Development
- Testing
- Staging
```

Promotion is a reviewed edit to that array; it is never time-driven. The
pipeline automates only the mechanics: a changed profile or script becomes a
hash-identified candidate, the previous Production object remains assigned to
later cohorts, and the predecessor is retired only when the source explicitly
includes Production. Managed scripts live under `scripts/`, and Store app
identifiers and assignment metadata live under `pkgsinfo/apps/managed/` rather
than in the pipeline body. New release-controller logic stays inline in the
pipeline YAML so the deployment remains self-contained.

**Try it offline.** No tenant, no credentials, PyYAML the only dependency:

```
python3 inventory/projections/project.py inventory/inventory.csv --out-dir out/
cd enrollment && python3 -m consumers.intune ../out/intune.csv --what-if
cd ../intune && python3 -m stages.lint_conditions manifests/
python3 -m stages.plan_assignments manifests/
```

With no `GRAPH_TOKEN` the Intune consumer prints the group plan and stops. Run
that first, before handing it anything.

**Guards.** Adding is safe; removing is not. A degraded parse yields an *empty*
desired set rather than an error — a well-formed answer that removes everything
on a green build. So there is a floor on the desired set, a cap on how much one
run may remove, ownership markers so only this pipeline's own objects are
touched, and `whatIf` as a supported way to run.

## Cimian vs Munki

Same architecture, different platform specifics:

- Packages are `.nupkg` / `.msi` / `.exe`, architecture `x64`, built with [`cimipkg`](https://github.com/windowsadmins/cimian-pkg).
- Hooks are PowerShell (a small POSIX shim execs `pwsh` on the `.ps1`), so they run from Git Bash, WSL, or any `sh` Git ships on Windows.
- `makecatalogs` emits a slightly different missing-installer warning; the hooks and the superseded resolver handle both dialects.
- One condition genuinely differs. `machine_type == "laptop"` translates on macOS because Apple's marketing names carry the form factor, so it maps to a model-name prefix. Windows has no equivalent — "Surface Laptop" and "Surface Studio" share a prefix — so form factor comes from `deviceCategory`, and the linter says so rather than emitting a filter that would quietly match the wrong machines.

The macOS half of the same pattern is [munki-gitops](https://github.com/rodchristiansen/munki-gitops).

## Talk

This repo accompanies the **MacDevOps YUL 2026** talk on running Windows and Mac fleets as code with MDM reduced to an approved delivery pipe.

Questions or want to compare notes? Find me on [BlueSky](https://bsky.app/profile/rodchristiansen.net) or the [blog](https://blog.focused.systems).
