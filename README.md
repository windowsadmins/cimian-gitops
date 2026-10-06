# Running Cimian under a GitOps model

Samples for managing a Windows fleet with [Cimian](https://github.com/windowsadmins/cimian) — the Windows-native managed-software tool modelled on [Munki](https://github.com/munki/munki) — entirely from Git: hooks, CI/CD pipelines, message queues, and local caching servers. This is the Windows companion to [munki-gitops](https://github.com/rodchristiansen/munki-gitops); the two repos mirror each other so a shop running both fleets uses one mental model.

**Cloud Provider Options**: the samples ship as Azure DevOps pipelines and as GitHub Actions workflows, against Azure Blob Storage, Service Bus and Front Door or against S3, SQS and CloudFront. Every pipeline signs in with workload identity federation or OpenID Connect, so no client secret or access key is stored anywhere. Pick the CI and cloud you're on; the admin experience is identical.

## MDM as a dumb, approved pipe

The core idea: **the MDM does exactly one job** — deliver a single signed bootstrapper to a freshly-enrolled device during the Enrollment Status Page. It never sees the app catalog. Everything else — the real software stack, configuration, patch state — is orchestrated by Cimian pulling from the GitOps repo. Intune is a pipe, not the brain.

That split is what makes the whole fleet reproducible from Git:

- A device enrols → Intune delivers **BootstrapMate** (one Win32 LOB) → BootstrapMate reads `management.json` and lays down the Cimian agent + its config → Cimian takes over and converges the machine against the repo.
- New app, new version, new config? It's a commit and a pull request. The MDM is untouched.

The pipeline that publishes that pipe is the centerpiece here: [`pipelines/azure/bootstrap-to-intune.yml`](pipelines/azure/bootstrap-to-intune.yml) (and its GitHub Actions / S3 twin at [`pipelines/github/bootstrap-to-intune.yml`](pipelines/github/bootstrap-to-intune.yml)). It fetches and signs the BootstrapMate MSI from its GitHub release, wraps it as an `.intunewin`, publishes [`provisioning/public/management.json`](provisioning/public/management.json), and replaces the Win32 LOB in Intune via Microsoft Graph with a single group assignment, then repoints the Enrollment Status Page at the new app.

## From manual to GitOps

The legacy flow was a shared admin box, one central share, many hands, no pipeline, no gates. Now:

- Git repos and CI/CD pipelines (Azure DevOps or GitHub Actions)
- Git hooks that upload/download packages automatically (Azure Blob or S3)
- A separate working copy per admin, validated on every commit
- Local caching servers that sync intelligently over Service Bus / SQS
- AutoPkg imports that land in Testing and move to Production on a schedule, without a hand edit
- A full CI/CD system that builds, signs, promotes, and deploys via pull requests

## What's in here

| Path | What it is |
|------|------------|
| `githooks/` | PowerShell git hooks (`azure/` + `aws/`) that validate pkgsinfo on commit, download referenced packages on pull, and sync the repo to cloud storage on push. Opt-in per clone. |
| `pipelines/azure/` | Azure DevOps pipelines: `push-to-production-*` (build catalogs + sync storage), `bootstrap-to-intune.yml` (the centerpiece), `autopkg.yml`, `promote-catalogs.yml`, `prod-checks.yml` and `infrastructure.yml`. |
| `pipelines/github/` | The same pipelines as GitHub Actions workflows, with actions pinned to commits and OIDC confined to protected environments. |
| `pipelines/scripts/` | Helpers the pipelines share: a retrying GitHub Releases client, the hash-pinned Cimian tools installer, the missing-package gate, the blob sync and the Intune Win32 app publisher. |
| `promotion/` | AutoPkg import and staged catalog promotion: pinned, trust-checked recipes, the promoter and its rules, and the checks that keep an import to the first stage. |
| `quality/` | Pkgsinfo structure and category lints (the pre-push hook calls the category gate) and a read-only production check for catalog drift. |
| `remediations/` | Intune proactive remediation pairs for Cimian clients: a stuck watcher, stale preferences, the last BootstrapMate run. |
| `infrastructure/` | Terraform for the storage account, Front Door and Key Vault behind the repo, with token-checked client access. |
| `provisioning/` | The BootstrapMate first-boot manifest the bootstrap pipeline publishes. |
| `preflight/cimian/` | A cimipkg sample that installs a Cimian preflight script run before each check. |
| `local-caching/` | Service Bus / SQS commit-listener packages that keep on-prem caching servers in sync. |
| `inventory/` | The twelve-column device contract, a sample fleet, and the projection script that narrows it per system. |
| `enrollment/` | One consumer per downstream system. The Intune one builds the Entra group ladder everything else addresses. |
| `intune/` | Renders three manifest keys the client ignores into Intune: Store apps, Settings Catalog and OMA-URI profiles, scripts. |
| `pkgsinfo/apps/managed/` | One YAML source-of-truth descriptor for each managed Store app. |
| `.github/` | CI for this repo: the offline tests, a parse of every script and pipeline, terraform validate, and the workflow pin and permission lint. |

Every folder has its own README with the detail.

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
on a green build. So the input is validated before anything is written (row
floors, resolution ratios, per-group and total shrink limits), a run that fails
any check aborts whole rather than converging part of the estate, ownership
markers keep the pipeline to its own objects, and `whatIf` is a supported way
to run. See [`enrollment/README.md`](enrollment/README.md#guards).

## Cimian vs Munki

Same architecture, different platform specifics:

- Packages are `.nupkg` / `.msi` / `.exe`, for `x64` and `arm64`, built with `cimipkg`. It ships with the Cimian tools and is developed at [cimian-pkg](https://github.com/windowsadmins/cimian-pkg).
- Hooks are PowerShell (a small POSIX shim execs `pwsh` on the `.ps1`), so they run from Git Bash, WSL, or any `sh` Git ships on Windows.
- `makecatalogs` emits a slightly different missing-installer warning; the hooks and the superseded resolver handle both dialects.
- One condition genuinely differs. `machine_type == "laptop"` translates on macOS because Apple's marketing names carry the form factor, so it maps to a model-name prefix. Windows has no equivalent — "Surface Laptop" and "Surface Studio" share a prefix — so form factor comes from `deviceCategory`, and the linter says so rather than emitting a filter that would quietly match the wrong machines.

The macOS half of the same pattern is [munki-gitops](https://github.com/rodchristiansen/munki-gitops).

## Talk

This repo accompanies the **MacDevOps YUL 2026** talk on running Windows and Mac fleets as code with MDM reduced to an approved delivery pipe.

Questions or want to compare notes? Find me on [BlueSky](https://bsky.app/profile/rodchristiansen.net) or the [blog](https://blog.focused.systems).

## License

[MIT](LICENSE).
