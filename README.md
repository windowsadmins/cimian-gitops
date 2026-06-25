# Running Cimian under a DevOps model

Samples for managing a Windows fleet with [Cimian](https://github.com/windowsadmins/cimian) — the Windows-native managed-software tool modelled on [Munki](https://github.com/munki/munki) — entirely from Git: hooks, CI/CD pipelines, message queues, and local caching servers. This is the Windows companion to [munki-gitops](https://github.com/rodchristiansen/munki-gitops); the two repos mirror each other so a shop running both fleets uses one mental model.

**Cloud Provider Options**: every sample ships in both an **Azure** form (Azure DevOps, Azure Blob Storage, Service Bus, Front Door) and an **AWS** form (GitHub Actions, S3, SQS/SNS, CloudFront). Pick the cloud you're on; the admin experience is identical.

## MDM as a dumb, approved pipe

The core idea: **the MDM does exactly one job** — deliver a single signed bootstrapper to a freshly-enrolled device during the Enrollment Status Page. It never sees the app catalog. Everything else — the real software stack, configuration, patch state — is orchestrated by Cimian pulling from the GitOps repo. Intune is a pipe, not the brain.

That split is what makes the whole fleet reproducible from Git:

- A device enrols → Intune delivers **BootstrapMate** (one Win32 LOB) → BootstrapMate reads `management.json` and lays down the Cimian agent + its config → Cimian takes over and converges the machine against the repo.
- New app, new version, new config? It's a commit and a pull request. The MDM is untouched.

The pipeline that publishes that pipe is the centerpiece here: [`pipelines/azure/bootstrap-to-intune.yml`](pipelines/azure/bootstrap-to-intune.yml) (and its GitHub Actions / S3 twin at [`pipelines/github/bootstrap-to-intune.yml`](pipelines/github/bootstrap-to-intune.yml)). It builds and signs the BootstrapMate MSI, wraps it as an `.intunewin`, regenerates and uploads `management.json`, and pushes the Win32 LOB to Intune via Microsoft Graph with a single group assignment.

## From manual to DevOps

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

## Git hooks at a glance

PowerShell hooks, opt in per clone (git doesn't use `githooks/` by default):

```sh
git config core.hooksPath githooks/azure
```

```sh
git config core.hooksPath githooks/aws
```

They validate Cimian pkgsinfo with `makecatalogs`, auto-download missing `.nupkg`/`.msi`/`.exe` from cloud storage, lint for structural errors `makecatalogs` lets through, and sync the repo to Azure Blob or S3 on push — with size guards, concurrency locks, capped orphan cleanup, and a version floor. See [`githooks/README.md`](githooks/README.md) for the full reference and the `CIMIAN_*` environment variables.

## Cimian vs Munki

Same architecture, different platform specifics:

- Packages are `.nupkg` / `.msi` / `.exe`, architecture `x64`, built with [`cimipkg`](https://github.com/windowsadmins/cimian-pkg).
- Hooks are PowerShell (a small POSIX shim execs `pwsh` on the `.ps1`), so they run from Git Bash, WSL, or any `sh` Git ships on Windows.
- `makecatalogs` emits a slightly different missing-installer warning; the hooks and the superseded resolver handle both dialects.

## Talk

This repo accompanies the **MacDevOps YUL 2026** talk on running Windows and Mac fleets as code with MDM reduced to an approved delivery pipe.

Questions or want to compare notes? Find me on [BlueSky](https://bsky.app/profile/rodchristiansen.net) or the [blog](https://blog.focused.systems).
