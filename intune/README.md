# intune

The manifest tree becomes MDM state. Three keys the client ignores
(`managed_apps`, `managed_profiles`, `managed_scripts`) ride along in the same
reviewed YAML Cimian reads, and become Intune assignments against Entra groups.

The engine that does this is shared with the macOS sibling and lives in
[windowsadmins/intune-gitops](https://github.com/windowsadmins/intune-gitops).
This directory keeps only what is Cimian's: the manifests, the profiles, the
catalog waterfall check and the pipelines that call the engine at a pinned tag
(currently `v0.1.2`). Stages, guards, the condition translator and their tests
are documented and tested there.

**This writes to a live tenant.** Every stage plans before it writes, and
whatIf is the default. Run the plan first, read the object names it prints, and
only then let it write.

## Layout

| Path | What it is |
|---|---|
| `manifests/` | The sample manifest tree. A path is an address: `manifests/Assigned/Staff/IT.yaml` is the group `Devices-Assigned-Staff-IT`. |
| `profiles/` | Profile definitions the manifests name. |
| `checks/catalog_waterfall.py` | The Cimian-only check: every profile and managed app declares a cumulative prefix of Development, Testing, Staging, Production. |
| `pipelines/azure/intune-mgmt.yml` | Azure Pipelines caller for the intune-gitops stages template. |
| `pipelines/github/intune-mgmt.yml` | GitHub Actions caller for the intune-gitops composite action. Copy it into `.github/workflows/` to run it. |
| `pipelines/reference/` | The production pipeline, sanitized. See below. |

## Try it, offline

Check the engine out beside this repo at the pinned tag, and install PyYAML:

```
git clone --branch v0.1.2 https://github.com/windowsadmins/intune-gitops ../intune-gitops
```

```
pip install pyyaml
```

From the repo root, lint the tree. Every condition has to translate into an
assignment filter, or the build fails:

```
python3 ../intune-gitops/engine/stages/lint_conditions.py --platform windows intune/manifests
```

Then plan it. On the sample tree that is fifteen assignments across three keys,
two of them filtered, one live exclusion and one inert one:

```
python3 ../intune-gitops/engine/stages/plan_assignments.py --platform windows intune/manifests
```

Then the catalog check:

```
python3 intune/checks/catalog_waterfall.py
```

## Conditions on Windows

An assignment filter can only reference what Intune holds about a device, so
only some Cimian conditions translate: `hostname`, `machine_model` (on
manufacturer or model) and `os_version` (`==` a three-part build, or
`BEGINSWITH`). Filters have no ordered comparison, so `os_vers_major >= 11`
does not translate; write the build prefix instead:

```
- condition: os_version BEGINSWITH "10.0.2"
```

The full table, and the rules Intune enforces on `NOT`, are in the
[intune-gitops README](https://github.com/windowsadmins/intune-gitops#conditions-become-assignment-filters).

## Pipelines

Both callers pin intune-gitops: the Azure one by `ref: refs/tags/v0.1.2` on its
repository resource, the GitHub one by the tag's commit SHA. An engine change
reaches this repo only when the pin moves. Both pass the catalog waterfall
check into the engine's test stage.

The real apply runs only from `main`, behind an environment, with a separate
write identity. The YAML conditions are a convenience; the boundary is the
approvals, branch control and required-template checks on the write service
connection and environment (Azure), or the environment protection rules and
federated credential (GitHub). Set those up from
[pipelines/README.md](https://github.com/windowsadmins/intune-gitops/blob/v0.1.2/pipelines/README.md)
in intune-gitops before the first real run.

`pipelines/reference/` is the production pipeline, lifted nearly as-is and
sanitized. It is there for accuracy, not as a model: several thousand lines of
script inline in YAML is why the engine moved into tested modules. Come here
when you want to see how it is really wired, or what a stage does that the
sample omits.

Sanitized means: service connection, variable group, storage account and
container names are placeholders, and the Teams webhook reads from a variable
group. If you lift your own, check that last one especially: a Power Automate
URL with a `sig=` parameter is a working credential, and a pipeline file is not
where it belongs.
