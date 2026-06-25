# Cimian Git Hooks

A battle-tested set of git hooks that turn a Cimian repo into a GitOps-native deployment system. Every commit validates `pkgsinfo`, every pull downloads the packages it just referenced, every push syncs the repo to cloud storage. The hooks catch the kind of silent-failure mistakes `makecatalogs` lets through, protect against the failure modes that have bitten real deployments, and stay out of the way when nothing's changed.

These are the Windows/PowerShell counterpart to the macOS [`munki-gitops`](https://github.com/windowsadmins) bash hooks. Cimian is the Windows software-deployment system from `windowsadmins/cimian`; its packages are `.nupkg`/`.msi`/`.exe`, its only architecture is `x64`, and its catalog tool is Cimian's own `makecatalogs`.

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
| `lib/common.ps1`                     | Shared helpers: version check, worktree linker, size guard, lock. |
| `lib/pkgsinfo-lint.py`               | Structural pkgsinfo validator (Cimian-native schema).            |
| `lib/resolve-superseded-pkgsinfo.py` | Removes older pkgsinfo whose installer was retired by `repoclean`, when a newer version is present locally. |
| `azure/pre-commit{,.ps1}`            | Validate pkgsinfo, auto-download missing pkgs, block bad commits. |
| `azure/pre-push{,.ps1}`              | Sync changes to Azure Blob, remove orphans from blob storage.    |
| `azure/post-merge{,.ps1}`            | Download packages referenced by newly-pulled pkgsinfo.           |
| `azure/post-rewrite{,.ps1}`          | Safety net for `git rebase` / `git commit --amend`.              |
| `azure/post-checkout{,.ps1}`         | (Optional) per-admin secrets bootstrap scaffolding.              |
| `aws/*`                              | Parallel implementation against S3.                              |

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

### AWS

| Variable                    | Default               | Purpose                                          |
|-----------------------------|-----------------------|--------------------------------------------------|
| `CIMIAN_S3_BUCKET`          | `your-cimian-bucket`  | S3 bucket name.                                  |
| `CIMIAN_S3_PREFIX`          | *(empty)*             | Optional key prefix inside the bucket.           |
| `CIMIAN_AWS_REGION`         | `us-east-1`           | Region for SigV4 signing / endpoint.             |
| `CIMIAN_CACHING_SERVERS`    | *(empty)*             | Same as Azure — HTTP caching fast-path.          |

### Cross-cutting

| Variable                     | Default                                              | Purpose                       |
|------------------------------|------------------------------------------------------|-------------------------------|
| `CIMIAN_MAX_FILE_SIZE_MB`    | `50`                                                 | Binary-size guard threshold.  |
| `CIMIAN_ALLOW_BINARY_PATHS`  | `^deployment/pkgs/;^deployment/icons/`               | Semicolon-separated regexes of paths where big files are allowed. |
| `CIMIAN_WORKTREE_LINK_PATHS` | `deployment\pkgs;deployment\icons;deployment\catalogs` | Semicolon-separated paths to junction in linked worktrees. |
| `CIMIAN_MIN_PKGSINFO_FOR_VALID` | `50`                                              | Floor below which destructive ops refuse to run. |

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
9. **Superseded-pkgsinfo resolution** — if a package is still "missing" after download, it's usually an older pkgsinfo whose installer was retired by `repoclean --keep N` (the blob is gone too). When a strictly newer version of the same package is present locally with its installer intact, the old pkgsinfo is dead weight: `lib/resolve-superseded-pkgsinfo.py` deletes it (newest-version-safe, capped) and re-validates instead of blocking.
10. **Orphan pkg cleanup** — main branch only, capped at 10 deletions (prevents catastrophic mass-delete on partial branches).
11. **Stale-upstream detection** — if local pkgsinfo references packages already removed from `origin/main`, blocks and asks you to pull first.

### `pre-push`

1. **Branch gate** — only syncs when pushing `main`/`master`; other branches push freely.
2. **Fast-forward check** — pulls if behind; aborts on non-FF.
3. **`makecatalogs` re-validate** — one last check against reality.
4. **Targeted or bulk sync** — uploads the files referenced by changed pkgsinfo, or everything with `--sync`.
5. **MD5 hash metadata** — Azure uploads use `--put-md5` so future `--compare-hash=MD5` runs have something to compare.
6. **Azure/S3 orphan cleanup** — removes blob/object storage entries not referenced by any committed pkgsinfo (main only, floor + hard cap).

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

The two `makecatalogs` warning dialects are both handled by the hooks when grepping for missing installers:

- Cimian: `WARNING: <ref> has missing installer => pkgs/<loc>`
- Munki: `WARNING: <ref> refers to missing installer item: <loc>`

## Extending

**New pkgsinfo key / installer type** → edit `VALID_TOP_KEYS` / `VALID_INSTALLER_TYPES` in `lib/pkgsinfo-lint.py`.

**New caching server** → set `CIMIAN_CACHING_SERVERS="host1;host2"`. No code change needed.

**New binary-cache path** → add to `CIMIAN_ALLOW_BINARY_PATHS`. No code change needed.

When bumping functionality that admins must have, bump `.min-version` and each hook's own `HOOK_VERSION` stamp in the same commit.

## Why bother?

The simplest version of this system — `git commit` → `azcopy sync` — works until:

- Two admins push at once and the sync races itself into an inconsistent state.
- Someone commits a YAML with a typo in `installer` type and `makecatalogs` silently excludes it from the catalog.
- A fresh clone tries to run `makecatalogs` on a thousand pkgsinfo files and fails with "missing installer" for every one of them.
- `git rebase` during a conflict resolution accidentally forks a branch and a `pre-push` deletes blob storage files the other branch still references.

Each of the guards in these hooks exists because one of those scenarios actually happened. Read them, steal them, adapt them to your org. Issues and PRs welcome.
