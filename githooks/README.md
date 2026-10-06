# Cimian Git Hooks

A battle-tested set of git hooks that turn a Cimian repo into a GitOps-native deployment system. Every commit validates `pkgsinfo`, every pull downloads the packages it just referenced, every push syncs the repo to cloud storage. The hooks catch the kind of silent-failure mistakes `makecatalogs` lets through, protect against the failure modes that have bitten real deployments, and stay out of the way when nothing's changed.

These are the Windows/PowerShell counterpart to the macOS [munki-gitops](https://github.com/rodchristiansen/munki-gitops) bash hooks. Cimian is the Windows software-deployment system from `windowsadmins/cimian`; its packages are `.nupkg`/`.msi`/`.exe`, its only architecture is `x64`, and its catalog tool is Cimian's own `makecatalogs`.

Two parallel implementations ship here:

- **`azure/`** — Azure Blob Storage via `azcopy`.
- **`aws/`** — S3 via `aws s3 cp`/`sync`.

Both use the same hook names, same flags, same env-var bypass, same safety guards. Pick the cloud you're on; the admin UX is identical.

## How the hooks run

Git invokes the extensionless hook file (`pre-commit`, `pre-push`, …). Each of those is a tiny POSIX `sh` shim that execs PowerShell on the sibling `.ps1`:

```sh
#!/usr/bin/env sh
exec pwsh -NoProfile -File "$(dirname "$0")/pre-commit.ps1" "$@"
```

The real logic lives in the `.ps1` files. PowerShell 7+ (`pwsh`) must be on `PATH` — install it with `winget install Microsoft.PowerShell`.

## Contents

| Path                                 | Purpose                                                          |
|--------------------------------------|-----------------------------------------------------------------|
| `.min-version`                       | Enforced floor — every hook warns if older than this YYYY.MM.DD. |
| `lib/common.ps1`                     | Shared helpers: version check, worktree handling, size guard, lock, push-ref parsing, branch-aware keep-set, sidecars, build purge, category gate. |
| `lib/pkgsinfo-lint.py`               | Structural pkgsinfo validator (Cimian-native schema).            |
| `lib/resolve-superseded-pkgsinfo.py` | Removes older pkgsinfo whose installer was retired by `repoclean`, when a newer version is present locally. |
| `azure/pre-commit{,.ps1}`            | Validate pkgsinfo, auto-download missing pkgs, block bad commits. |
| `azure/pre-push{,.ps1}`              | Sync changes to Azure Blob, remove orphans from blob storage.    |
| `azure/pre-push-pr-packages.ps1`     | Branch pushes: make sure every package the pushed pkgsinfo needs is in blob storage, create-only. |
| `azure/post-merge{,.ps1}`            | Download packages referenced by newly-pulled pkgsinfo.           |
| `azure/post-rewrite{,.ps1}`          | Safety net for `git rebase` / `git commit --amend`.              |
| `azure/post-checkout{,.ps1}`         | (Optional) per-admin secrets bootstrap scaffolding.              |
| `aws/*`                              | Parallel implementation against S3, including `pre-push-pr-packages.ps1`. |
| `tests/`                             | `pwsh -NoProfile -File githooks/tests/<test>.ps1`. Fake `az`/`azcopy`/`aws` on PATH, no cloud access. |

## Install

Opt in per clone — git doesn't use `githooks/` by default.

Clone the repo and enter it:

```sh
git clone https://github.com/windowsadmins/your-cimian-repo.git
cd your-cimian-repo
```

Point git at the cloud variant you run:

```sh
git config core.hooksPath githooks/azure
```

Or, for S3:

```sh
git config core.hooksPath githooks/aws
```

On Windows the shims need an `sh` interpreter on `PATH` — Git for Windows ships one (`C:\Program Files\Git\usr\bin\sh.exe`), which git already uses to run hooks. PowerShell 7 (`pwsh`) must also be installed.

## Configuration

The hooks read environment variables for everything that might differ between organisations. Set them with `[Environment]::SetEnvironmentVariable(...)` (user scope) or in your PowerShell profile.

### Azure

| Variable                    | Default               | Purpose                                          |
|-----------------------------|-----------------------|--------------------------------------------------|
| `CIMIAN_STORAGE_ACCOUNT`    | `yourstorageaccount`  | Azure Blob storage account name.                 |
| `CIMIAN_CONTAINER`          | `cimian`              | Container name inside the storage account.       |
| `CIMIAN_AZURE_TENANT_ID`    | *(empty)*             | Tenant ID for `az login`. Empty → plain `az login`. |
| `CIMIAN_CACHING_SERVERS`    | *(empty)*             | `host1;host2` HTTP caching servers for download fast-path. |
| `CIMIAN_FD_RESOURCE_GROUP`, `CIMIAN_FD_PROFILE`, `CIMIAN_FD_ENDPOINT` | *(empty)* | Front Door to purge when a branch push creates a package path. Unset → no purge. |

### AWS

| Variable                    | Default               | Purpose                                          |
|-----------------------------|-----------------------|--------------------------------------------------|
| `CIMIAN_S3_BUCKET`          | `your-cimian-bucket`  | S3 bucket name.                                  |
| `CIMIAN_S3_PREFIX`          | *(empty)*             | Optional key prefix inside the bucket.           |
| `CIMIAN_AWS_REGION`         | `us-east-1`           | Region for SigV4 signing / endpoint.             |
| `CIMIAN_CACHING_SERVERS`    | *(empty)*             | Same as Azure — HTTP caching fast-path.          |
| `CIMIAN_CLOUDFRONT_DISTRIBUTION_ID` | *(empty)*     | CloudFront to invalidate when a branch push creates a package key. |

### Cross-cutting

| Variable                     | Default                                              | Purpose                       |
|------------------------------|------------------------------------------------------|-------------------------------|
| `CIMIAN_MAX_FILE_SIZE_MB`    | `50`                                                 | Binary-size guard threshold.  |
| `CIMIAN_ALLOW_BINARY_PATHS`  | `^deployment/pkgs/;^deployment/icons/`               | Semicolon-separated regexes of paths where big files are allowed. |
| `CIMIAN_WORKTREE_LINK_PATHS` | `deployment\pkgs;deployment\icons;deployment\catalogs` | Semicolon-separated paths to junction in linked worktrees. |
| `CIMIAN_MIN_PKGSINFO_FOR_VALID` | `50`                                              | Floor below which destructive ops refuse to run. |
| `CIMIAN_HOOKS_IN_WORKTREES`  | *(unset)*                                            | `1` runs every hook in linked worktrees too (see below). |
| `CIMIAN_CONFIG_YAML`         | `C:\ProgramData\ManagedInstalls\Config.yaml`         | Where to read `RepoPath` when the checkout itself does not look like a Cimian deployment. |

### Where the repo is

Hooks work on `<repo>\deployment` when it validates as a Cimian deployment
(`pkgsinfo/`, `catalogs/`, at least `CIMIAN_MIN_PKGSINFO_FOR_VALID` pkgsinfo
files). Otherwise they try `RepoPath` from the Cimian client's `Config.yaml`,
which on an admin machine that also runs the client is where the repo really
lives. Destructive steps re-check before acting, so a sparse scratch checkout
is never treated as the source of truth.

### Linked worktrees

A `git worktree add` checkout is for task work. The primary checkout on `main`
owns cache sync and full validation, and CI rebuilds the catalogs, so in a
linked worktree `pre-commit`, `post-merge`, `post-rewrite` and `post-checkout`
exit straight away, and `pre-push` runs only its branch check. Set
`CIMIAN_HOOKS_IN_WORKTREES=1` to run everything; the gitignored caches are then
junctioned in from the primary checkout.

### Emergency bypass

All env vars silently skip the hook.

| Variable                     | Effect                                          |
|------------------------------|-------------------------------------------------|
| `GIT_NO_VERIFY=1`            | Generic git bypass — skips every hook.          |
| `SKIP_CIMIAN_HOOKS=1`       | Cimian-specific — skips all hooks.              |
| `SKIP_CIMIAN_POST_MERGE=1`  | Skips only `post-merge`.                        |
| `SKIP_PRE_PUSH=1`           | Skips only `pre-push`.                          |
| `DISABLE_CUSTOM_HOOKS=1`    | Kills every hook.                               |

Per-hook flags are also derived from the hook name: `SKIP_<HOOKNAME>` with dashes turned into underscores (e.g. `SKIP_PRE_COMMIT`, `SKIP_POST_REWRITE`).

## What each hook does

### `pre-commit`

1. **Hook version check** — warns if the hook is older than `.min-version`.
2. **Concurrency lock** — prevents overlap with `pre-push`; stale locks auto-steal from dead PIDs.
3. **Binary-size guard** — rejects staged files larger than `CIMIAN_MAX_FILE_SIZE_MB` outside recognised pkg/icon paths.
4. **Worktree cache link** — silent no-op in the primary worktree; junctions cloud caches in linked worktrees.
5. **Datetime auto-quote** — rewrites unquoted tz-aware ISO8601 scalars (`creation_date: 2026-04-22T17:51:22Z`) to quoted strings in staged pkgsinfo and re-stages them. Unquoted, PyYAML loads them as tz-aware `datetime` objects that crash any consumer comparing them against a naive datetime (a catalog promoter, a report script). Silent, idempotent.
6. **Structural pkgsinfo linter** — catches typos, wrong-case keys, invalid `installer` type, `nopkg`/`script` install-loop traps, `RequireRestart`+`unattended_install` combos. See `lib/pkgsinfo-lint.py` for the full schema.
7. **`makecatalogs` validation** — parse errors, missing required keys, missing installer/uninstaller items, empty catalogs.
8. **Missing-pkg auto-download** — pulls the referenced installer items from cloud storage (delegates to `post-merge.ps1`); blocks only if still missing after download.
9. **Installer-type detection** — a cimipkg project with no `install_location` builds a hidden wrapper with a fresh ProductCode on every build. Its pkgsinfo must describe the wrapped app with `installs[]` or an `installcheck_script`, or Cimian reinstalls it every cycle; the linter blocks the commit otherwise.
10. **Superseded-pkgsinfo resolution** — if a package is still "missing" after download, it's usually an older pkgsinfo whose installer was retired by `repoclean --keep N` (the blob is gone too). When a strictly newer version of the same package is present locally with its installer intact, the old pkgsinfo is dead weight: `lib/resolve-superseded-pkgsinfo.py` deletes it (newest-version-safe, capped) and re-validates instead of blocking.
11. **Orphan pkg cleanup** — main branch only, capped at 10 deletions (prevents catastrophic mass-delete on partial branches).
12. **Stale-upstream detection** — if local pkgsinfo references packages already removed from `origin/main`, blocks and asks you to pull first.

### `pre-push`

What happens is decided by the refs on stdin, the ones actually being pushed, not by the branch that happens to be checked out. `git push origin feature:main` lands on main; `git push origin feature` from `main` does not.

**A push that lands on `main`/`master` from the primary checkout:**

1. **Short-circuit** — exits at once when the push touches nothing under `deployment/` or an `installers/` or `packages/` project.
2. **Fast-forward check** — pulls if behind; aborts on non-FF.
3. **`makecatalogs` re-validate** — one last check against reality, with missing-package auto-download.
4. **Category gate** — when the repo carries `quality/lint/Test-Categories.ps1`, runs it against the manifests in this push only, and blocks on an unknown or missing category. Skips, never blocks, when it cannot tell what changed or cannot run.
5. **Additive sync** — uploads `deployment/pkgs`, `deployment/icons`, and each `installers/<name>/payload` and `packages/<name>/payload`. Never `--delete`: every machine holds only part of `deployment/pkgs`, so deleting what a partial cache lacks would empty the bucket. Azure uploads use `--put-md5` so later `--compare-hash=MD5` runs have something to compare.
6. **Sidecars** — `._*` and `.DS_Store` are never uploaded, and any found in storage are removed on sight, outside the orphan cap.
7. **Branch-aware orphan cleanup** — the one delete path. The keep-set is the pkgsinfo on `main` plus every `origin/*` branch, because a pull request's package is uploaded before it merges. No remote refs, too small a keep-set, or more orphans than the cap: it skips with a note, and the push still succeeds.
8. **Build purge** (`--sync`, `--force`) — removes cimipkg output under `installers/*/build` and `packages/*/build` whose file is already imported into `deployment/pkgs`.

**Any other push, and every push from a linked worktree,** runs `pre-push-pr-packages.ps1` under the same lock. For each pkgsinfo the push adds or changes:

- `nopkg` items are skipped; they have no payload.
- A local package must match the pkgsinfo's size and SHA-256.
- Package paths are immutable. An object already there must carry the same SHA-256 in its metadata; a different one blocks the push.
- A missing object is created create-only (`azcopy --overwrite=false`, or S3 `put-object --if-none-match '*'`), with the SHA-256 in its metadata, so two worktrees racing for one path either match byte for byte or the loser is blocked.
- A legacy object without that metadata is backfilled only when its identity is proven, by `origin/main` recording the same hash or by its MD5.

Flags: `--sync` / `--upload` (skip change detection), `--force`, `--dry-run`, `--path <relative>` (targeted file).

### `post-merge`

Fires after every `git pull`, `git merge`, `git checkout <branch>`. Downloads the packages referenced by pkgsinfo that just changed.

1. **HTTP caching server probe** — if `CIMIAN_CACHING_SERVERS` is set and reachable, pulls from there first. Falls back to cloud on miss.
2. **Batched download** — Azure cache misses go into a single `azcopy copy --list-of-files` call; S3 downloads run per-file via `aws s3 cp`.
3. **Orphan cleanup** — main branch only, junction-safe.

Flags: `--sync`, `--force` (double-confirm), `--dry-run`, `--path <relative>`.

### `post-rewrite`

Safety net for `git rebase` and `git commit --amend` — delegates to `post-merge` with the same change-detection logic. Amends don't change HEAD's reachable commits, so they're skipped.

### `post-checkout`

Skeleton — your implementation should fetch org-specific secrets (Azure Key Vault / AWS Secrets Manager), write config files, and do fresh-clone setup. The version shipped here is a reference only.

## The pkgsinfo linter

`lib/pkgsinfo-lint.py` runs in `pre-commit` on every staged pkgsinfo YAML file. The schema is Cimian-native, derived from the `PkgsInfo` model — not Munki's.

**Required keys**: `name`, `version`, `catalogs`, and either a nested `installer:` mapping (with `type` / `location` / `hash` sub-keys) or a top-level `installer_item_location`. `installer` may be omitted for script-only or `requires`-only meta items.

**Valid installer types**: `pkg`, `script`, `nopkg`, `msi`, `exe`.

**Valid `supported_architectures`**: `x64` (not `x86_64`/`arm64` — that's Munki/macOS).

**Valid catalogs**: `Development`, `Testing`, `Staging`, `Production` (PascalCase).

**Valid `restart_action`**: `None`, `RequireRestart`, `RecommendRestart` (PascalCase).

**Blocked patterns**:

- Unknown top-level keys (`install_scritp`, typos) and wrong-case keys.
- Wrong-case or invalid catalogs / architectures / enums.
- Empty `catalogs: []`.
- `nopkg`/`script` with an install action but no `installcheck_script` and no `installs` → reinstalls every `managedsoftwareupdate` cycle.
- `restart_action: RequireRestart` + `unattended_install: true` → a forced restart isn't unattended.
- `msi`/`exe`/`pkg` without an installer `location`.
- `install_script` on a binary installer type (silently ignored at runtime).
- Duplicate top-level YAML keys (silently drops earlier values).
- A pkgsinfo for an installer-type wrapper (a cimipkg project under `installers/` or `packages/` whose `build-info.yaml` has no `install_location`) with no `installs` and no `installcheck_script`.

The two `makecatalogs` warning dialects are both handled by the hooks when grepping for missing installers:

- Cimian: `WARNING: <ref> has missing installer => pkgs/<loc>`
- Munki: `WARNING: <ref> refers to missing installer item: <loc>`

## Extending

**New pkgsinfo key / installer type** → edit `VALID_TOP_KEYS` / `VALID_INSTALLER_TYPES` in `lib/pkgsinfo-lint.py`.

**New caching server** → set `CIMIAN_CACHING_SERVERS="host1;host2"`. No code change needed.

**New binary-cache path** → add to `CIMIAN_ALLOW_BINARY_PATHS`. No code change needed.

When bumping functionality that admins must have, bump `.min-version` and each hook's own `HOOK_VERSION` stamp in the same commit.

## Tests

```sh
pwsh -NoProfile -File githooks/tests/test-common.ps1
pwsh -NoProfile -File githooks/tests/test-remote-pkgsinfo-locations.ps1
pwsh -NoProfile -File githooks/tests/test-pr-packages-azure.ps1
pwsh -NoProfile -File githooks/tests/test-pr-packages-aws.ps1
```

They build throwaway repos and put fake cloud CLIs on `PATH`; nothing reaches a real account. The fakes are POSIX shell scripts, so run the tests on macOS or Linux.

## Why bother?

The simplest version of this system — `git commit` → `azcopy sync` — works until:

- Two admins push at once and the sync races itself into an inconsistent state.
- Someone commits a YAML with a typo in `installer` type and `makecatalogs` silently excludes it from the catalog.
- A fresh clone tries to run `makecatalogs` on a thousand pkgsinfo files and fails with "missing installer" for every one of them.
- `git rebase` during a conflict resolution accidentally forks a branch and a `pre-push` deletes blob storage files the other branch still references.
- A Mac touches the share, and `._*` files count as orphans until the cleanup refuses to run at all.
- A pull request's package is uploaded, main's orphan cleanup deletes it, and the merge ships a catalog entry that 404s.

Each of the guards in these hooks exists because one of those scenarios actually happened. Read them, steal them, adapt them to your org. Issues and PRs welcome.
