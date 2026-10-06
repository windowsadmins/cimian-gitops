# ──────────────────────────────────────────────────────────────────────────────
#  common.ps1  –  shared helpers for Cimian git hooks (PowerShell, Windows)
#
#  Cloud-agnostic. Dot-sourced by every Azure and AWS hook.
#
#  Provides:
#    Test-HookVersion           – warn if this hook is older than .min-version
#    Test-ShouldSkipHook        – respect env bypass flags
#    Test-StagedBinarySize      – reject >CIMIAN_MAX_FILE_SIZE_MB MB files
#                                 outside deployment/pkgs | deployment/icons
#    Add-WorktreeCacheLink      – junction gitignored caches in linked worktrees
#    Get-CimianDeploymentRoot   – resolve the deployment/ root from the repo
#    Test-CimianDeployment      – sanity-check a deployment dir before destructive ops
#    Test-PathIsReparsePoint    – detect a junction/symlink (linked worktree cache)
#    Lock-Hook / Unlock-Hook    – exclusive lock across worktrees
#    Test-IsLinkedWorktree      – true inside a `git worktree add` checkout
#    Test-SkipInLinkedWorktree  – the default "leave linked worktrees alone"
#    Read-ConfigYamlRepoPath    – RepoPath from ManagedInstalls\Config.yaml
#    Get-PushRefLine / Get-PushedChangedFile – what a push actually carries
#    Test-PushTargetsMain       – does any pushed ref land on main/master
#    Add-RemotePkgsInfoLocation – fold other branches' pkgsinfo into a keep-set
#    Test-IsSidecarName         – ._* and .DS_Store, never payloads
#    Remove-ImportedBuildArtifact – drop build/ copies already in deployment/pkgs
#    Invoke-CategoryGate        – run quality/lint/Test-Categories.ps1 on a diff
#
#  Every .ps1 hook should start with a HOOK_VERSION comment and dot-source this:
#
#      # HOOK_VERSION = '2026.10.06'
#      $HookDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
#      . (Join-Path $HookDir '..' 'lib' 'common.ps1')
#      Test-HookVersion -HookName 'pre-commit' -HookVersion '2026.10.06'
#      if (Test-ShouldSkipHook -HookName 'pre-commit') { exit 0 }
#      if (Test-SkipInLinkedWorktree -HookName 'pre-commit') { exit 0 }
#      Add-WorktreeCacheLink
#      if (-not (Lock-Hook -HookName 'pre-commit')) { exit 1 }
#      if (-not (Test-StagedBinarySize)) { exit 1 }
# ──────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest

# Minimum pkgsinfo count that a directory must contain to be treated as an
# authoritative Cimian deployment. Anything below this is almost certainly a
# sparse checkout, scratch workspace, or wrong path — destructive operations
# (orphan prune, delete-sync) must refuse rather than trust it.
# Override via $env:CIMIAN_MIN_PKGSINFO_FOR_VALID to match your fleet size.
$script:CIMIAN_MIN_PKGSINFO_FOR_VALID = 50
if ($env:CIMIAN_MIN_PKGSINFO_FOR_VALID) {
    $parsed = 0
    if ([int]::TryParse($env:CIMIAN_MIN_PKGSINFO_FOR_VALID, [ref]$parsed) -and $parsed -gt 0) {
        $script:CIMIAN_MIN_PKGSINFO_FOR_VALID = $parsed
    }
}

# Module-scoped state for the lock helper.
$script:HookLockDir = $null

# ── repo / deployment resolution ────────────────────────────────────────────
function Get-CimianRepoRoot {
    $root = git rev-parse --show-toplevel 2>$null
    if (-not $root) { return $null }
    return ($root.Trim() -replace '/', '\')
}

# RepoPath from Cimian's own client config. On an admin machine that also runs
# the client, this is where the repo really lives, so it is the best second
# opinion when the git checkout the hook runs in does not look like one.
function Read-ConfigYamlRepoPath {
    $configPath = if ($env:CIMIAN_CONFIG_YAML) { $env:CIMIAN_CONFIG_YAML } else { 'C:\ProgramData\ManagedInstalls\Config.yaml' }
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    try {
        foreach ($line in (Get-Content -LiteralPath $configPath -ErrorAction Stop)) {
            if ($line -match '^\s*RepoPath\s*:\s*(.+?)\s*$') {
                return $Matches[1].Trim().Trim('"', "'")
            }
        }
    } catch { }
    return $null
}

# Resolve the deployment/ directory. Cimian's repo layout is
# deployment/{pkgs,pkgsinfo,catalogs,icons}.
#
# Every candidate is validated before it is trusted, because the destructive
# steps (orphan prune) believe whatever this returns. A sparse scratch
# workspace with one pkgsinfo once looked authoritative enough to call two
# hundred blobs orphans. Precedence, first validated wins:
#   1. <git repo root>\deployment
#   2. RepoPath in ManagedInstalls\Config.yaml
# With neither valid, the git path comes back unvalidated, and every
# destructive caller re-checks Test-CimianDeployment before acting.
function Get-CimianDeploymentRoot {
    param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Get-CimianRepoRoot }
    $gitPath = if ($RepoRoot) { Join-Path $RepoRoot 'deployment' } else { $null }
    if ($gitPath -and (Test-CimianDeployment -Path $gitPath)) { return $gitPath }

    $configPath = Read-ConfigYamlRepoPath
    if ($configPath -and (Test-CimianDeployment -Path $configPath)) {
        if ($gitPath) { Write-Host "Using Config.yaml RepoPath $configPath ($gitPath does not validate as a Cimian deployment)" }
        return $configPath
    }
    return $gitPath
}

# ── hook-version check ──────────────────────────────────────────────────────
# Compares the hook's own stamped version against githooks/.min-version.
# Lexicographic YYYY.MM.DD comparison — no date math needed.
# Warns but never blocks (blocking would fail exactly the pull that would fix it).
function Test-HookVersion {
    param(
        [Parameter(Mandatory)] [string]$HookName,
        [Parameter(Mandatory)] [string]$HookVersion
    )

    $repoRoot = Get-CimianRepoRoot
    if (-not $repoRoot) { return }

    $minFile = $null
    foreach ($cand in @(
        (Join-Path $repoRoot '.githooks\.min-version'),
        (Join-Path $repoRoot 'githooks\.min-version')
    )) {
        if (Test-Path $cand) { $minFile = $cand; break }
    }
    if (-not $minFile) { return }

    $minVersion = (Get-Content $minFile -Raw -ErrorAction SilentlyContinue)
    if (-not $minVersion) { return }
    $minVersion = $minVersion.Trim()
    if (-not $minVersion) { return }

    # Lexicographic compare is correct for zero-padded YYYY.MM.DD.
    if ([string]::Compare($HookVersion, $minVersion) -lt 0) {
        Write-Host ''
        Write-Host "WARNING: Your git hook ($HookName, v$HookVersion) is older than required (v$minVersion)."
        Write-Host '         Pull latest: git pull --rebase origin main'
        Write-Host ''
    }
}

# ── hook-bypass check ───────────────────────────────────────────────────────
# Env vars that skip the hook silently. Any one of them short-circuits.
#   GIT_NO_VERIFY=1            – git's own broad bypass
#   SKIP_CIMIAN_HOOKS=1        – Cimian-specific bypass (all hooks)
#   SKIP_PRE_PUSH=1            – skip only pre-push
#   SKIP_CIMIAN_POST_MERGE=1  – skip only post-merge
#   DISABLE_CUSTOM_HOOKS=1     – kill switch
#
# Per-hook flags also derived from the hook name: SKIP_<HOOKNAME> with dashes
# turned into underscores (e.g. pre-push → SKIP_PRE_PUSH).
function Test-ShouldSkipHook {
    param([string]$HookName)

    if ($env:GIT_NO_VERIFY -eq '1')       { return $true }
    if ($env:SKIP_CIMIAN_HOOKS -eq '1')   { return $true }
    if ($env:DISABLE_CUSTOM_HOOKS -eq '1') { return $true }

    if ($HookName) {
        $varName = 'SKIP_' + ($HookName.ToUpper() -replace '-', '_')
        $val = [System.Environment]::GetEnvironmentVariable($varName)
        if ($val -eq '1') { return $true }
        # Cimian-prefixed per-hook flag (e.g. SKIP_CIMIAN_POST_MERGE).
        $cimianVar = 'SKIP_CIMIAN_' + ($HookName.ToUpper() -replace '-', '_')
        $cimianVal = [System.Environment]::GetEnvironmentVariable($cimianVar)
        if ($cimianVal -eq '1') { return $true }
    }

    return $false
}

# ── reparse-point detection ─────────────────────────────────────────────────
# Returns $true if the path is a junction or symlink. On Windows, linked
# worktree caches are NTFS junctions pointing at the primary worktree.
function Test-PathIsReparsePoint {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    try {
        $attrs = [System.IO.File]::GetAttributes($Path)
        return ($attrs -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
    } catch {
        return $false
    }
}

# ── worktree cache linking ──────────────────────────────────────────────────
# When a hook fires inside a linked worktree (created via `git worktree add`),
# gitignored binary caches — deployment/pkgs (potentially hundreds of GB),
# deployment/icons, deployment/catalogs — don't exist in the worktree. They
# live only under the primary worktree, populated from cloud storage.
#
# Without this helper, pre-commit's makecatalogs flags every pkgsinfo as
# referencing a missing pkg, and commits get blocked. Re-syncing from the cloud
# wastes bandwidth and storage.
#
# Fix: create zero-copy NTFS junctions from the primary worktree. Idempotent.
# No-op when called from the primary worktree or outside a git repo.
#
# Which paths get linked is configurable via $env:CIMIAN_WORKTREE_LINK_PATHS
# (semicolon-separated, relative to repo root). Defaults cover the common case.
function Add-WorktreeCacheLink {
    $repoRoot = Get-CimianRepoRoot
    if (-not $repoRoot) { return }

    $gitCommon = git rev-parse --git-common-dir 2>$null
    $currentGitDir = git rev-parse --git-dir 2>$null
    if (-not $gitCommon -or -not $currentGitDir) { return }
    $gitCommon = $gitCommon.Trim()
    $currentGitDir = $currentGitDir.Trim()

    # Primary worktree: --git-dir equals --git-common-dir. Bail if not linked.
    if ($gitCommon -eq $currentGitDir) { return }

    # --git-common-dir points at <primary>\.git; primary root is its parent.
    try {
        $primaryRoot = (Resolve-Path (Join-Path $gitCommon '..') -ErrorAction Stop).Path
    } catch {
        return
    }
    if (-not (Test-Path $primaryRoot) -or $primaryRoot -eq $repoRoot) { return }

    $linkPaths = $env:CIMIAN_WORKTREE_LINK_PATHS
    if (-not $linkPaths) { $linkPaths = 'deployment\pkgs;deployment\icons;deployment\catalogs' }

    $linkedCount = 0
    $announced = $false
    foreach ($rel in ($linkPaths -split ';')) {
        $rel = $rel.Trim() -replace '/', '\'
        if (-not $rel) { continue }
        $src = Join-Path $primaryRoot $rel
        $dst = Join-Path $repoRoot $rel
        if (-not (Test-Path $src)) { continue }
        if (Test-PathIsReparsePoint $dst) { continue }   # already linked
        if (Test-Path $dst) { continue }                 # existing real dir — never clobber

        $parent = Split-Path -Parent $dst
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

        New-Item -ItemType Junction -Path $dst -Target $src -ErrorAction SilentlyContinue | Out-Null
        if (Test-PathIsReparsePoint $dst) {
            if (-not $announced) {
                Write-Host ''
                Write-Host 'Worktree detected — linking gitignored caches from primary:'
                Write-Host "  Primary:  $primaryRoot"
                Write-Host "  Worktree: $repoRoot"
                $announced = $true
            }
            Write-Host "  linked: $rel"
            $linkedCount++
        }
    }

    if ($linkedCount -gt 0) {
        Write-Host "  Total linked: $linkedCount"
        Write-Host ''
    }
}

# ── binary-size guard ───────────────────────────────────────────────────────
# Reject staged files > $env:CIMIAN_MAX_FILE_SIZE_MB (default 50) unless they
# live under a recognised binary-cache path. Cheap belt-and-suspenders so a
# careless `git add` doesn't blow up the repo size.
#
# Override allow paths with $env:CIMIAN_ALLOW_BINARY_PATHS (semicolon-separated
# regexes). Defaults cover deployment/pkgs/ and deployment/icons/.
function Test-StagedBinarySize {
    $maxMb = 50
    if ($env:CIMIAN_MAX_FILE_SIZE_MB) {
        $parsed = 0
        if ([int]::TryParse($env:CIMIAN_MAX_FILE_SIZE_MB, [ref]$parsed) -and $parsed -gt 0) { $maxMb = $parsed }
    }
    $maxBytes = [int64]$maxMb * 1024 * 1024

    $allowPaths = $env:CIMIAN_ALLOW_BINARY_PATHS
    if (-not $allowPaths) { $allowPaths = '^deployment/pkgs/;^deployment/icons/' }
    $allowRegexes = @($allowPaths -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $repoRoot = Get-CimianRepoRoot
    if (-not $repoRoot) { return $true }

    $staged = git diff --cached --name-only --diff-filter=ACM 2>$null
    if (-not $staged) { return $true }

    $offenders = @()
    foreach ($f in ($staged -split "`n")) {
        $f = $f.Trim()
        if (-not $f) { continue }
        $forward = $f -replace '\\', '/'

        $allowed = $false
        foreach ($re in $allowRegexes) {
            if ($forward -match $re) { $allowed = $true; break }
        }
        if ($allowed) { continue }

        $full = Join-Path $repoRoot ($f -replace '/', '\')
        if (-not (Test-Path $full -PathType Leaf)) { continue }
        $sz = (Get-Item $full -ErrorAction SilentlyContinue).Length
        if ($null -ne $sz -and $sz -gt $maxBytes) {
            $szMb = [math]::Round($sz / 1MB, 1)
            $offenders += "${szMb}MB  $forward"
        }
    }

    if ($offenders.Count -gt 0) {
        Write-Host ''
        Write-Host "COMMIT BLOCKED: staged file(s) > ${maxMb}MB outside recognised binary paths:"
        foreach ($o in $offenders) { Write-Host "  - $o" }
        Write-Host ''
        Write-Host 'If this is intentional:'
        Write-Host '  - Move the file under deployment/pkgs/ (and add a pkgsinfo entry)'
        Write-Host '  - Or unstage it:  git restore --staged <file>'
        Write-Host '  - Or widen CIMIAN_ALLOW_BINARY_PATHS / CIMIAN_MAX_FILE_SIZE_MB'
        Write-Host ''
        return $false
    }
    return $true
}

# ── deployment-path validator ───────────────────────────────────────────────
# A deployment dir is only trusted as authoritative if it has pkgsinfo/,
# catalogs/, and at least CIMIAN_MIN_PKGSINFO_FOR_VALID pkgsinfo files. Without
# this, downstream destructive operations (orphan prune, delete-sync) can wipe
# hundreds of production blobs when fed a stale or sparse deployment path.
function Test-CimianDeployment {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path $Path -PathType Container)) { return $false }
    $pkgsInfo = Join-Path $Path 'pkgsinfo'
    $catalogs = Join-Path $Path 'catalogs'
    if (-not (Test-Path $pkgsInfo -PathType Container)) { return $false }
    if (-not (Test-Path $catalogs -PathType Container)) { return $false }

    $count = 0
    Get-ChildItem -Path $pkgsInfo -Recurse -File -Include '*.yaml', '*.yml' -ErrorAction SilentlyContinue |
        ForEach-Object { $count++ }
    return ($count -ge $script:CIMIAN_MIN_PKGSINFO_FOR_VALID)
}

# ── concurrency lock ────────────────────────────────────────────────────────
# Prevents overlap between pre-commit and pre-push. Uses the primary git dir so
# worktrees share one lock.
#
# Stale-lock detection: if the PID stored in the lock isn't running, steal the
# lock instead of blocking indefinitely — handles the case where a previous
# hook crashed before releasing. Also treats empty-content lock files as stale.
function Lock-Hook {
    param([string]$HookName = 'hook')

    $gitCommon = git rev-parse --git-common-dir 2>$null
    if (-not $gitCommon) { return $true }   # not a repo — nothing to lock
    $gitCommon = $gitCommon.Trim() -replace '/', '\'

    $logsDir = Join-Path $gitCommon 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    $lockDir = Join-Path $logsDir '.hook.lockdir'
    $pidFile = Join-Path $lockDir 'pid'

    # Stale-lock detection.
    if (Test-Path $lockDir) {
        $storedPid = $null
        if (Test-Path $pidFile) { $storedPid = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue) }
        if ($storedPid) { $storedPid = $storedPid.Trim() }

        if (-not $storedPid) {
            Write-Host '  Stealing stale hook lock (empty — previous hook crashed mid-acquire)'
            Remove-Item $lockDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            $alive = Get-Process -Id ([int]$storedPid) -ErrorAction SilentlyContinue
            if (-not $alive) {
                Write-Host "  Stealing stale hook lock (pid $storedPid no longer running)"
                Remove-Item $lockDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    try {
        New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
    } catch {
        $otherPid = '?'
        if (Test-Path $pidFile) { $otherPid = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim() }
        Write-Host ''
        Write-Host "Another hook is running (pid $otherPid, lock: $lockDir)."
        Write-Host "Try again in a moment. If stuck: Remove-Item -Recurse -Force '$lockDir'"
        Write-Host ''
        return $false
    }

    Set-Content -Path $pidFile -Value $PID -ErrorAction SilentlyContinue
    $script:HookLockDir = $lockDir

    # Auto-release on PowerShell exit.
    Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        if ($script:HookLockDir -and (Test-Path $script:HookLockDir)) {
            Remove-Item $script:HookLockDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } | Out-Null

    return $true
}

function Unlock-Hook {
    if ($script:HookLockDir -and (Test-Path $script:HookLockDir)) {
        Remove-Item $script:HookLockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:HookLockDir = $null
}

# ── linked worktrees ────────────────────────────────────────────────────────
# A linked worktree (git worktree add) is for task work. The primary checkout
# on main owns cache sync and full validation, and CI rebuilds the catalogs.
# Running the heavy hooks in every worktree only blocks commits on caches the
# worktree does not have. pre-push still runs there, in its PR-branch form.
# Set CIMIAN_HOOKS_IN_WORKTREES=1 to run every hook anyway (caches are then
# junctioned in from the primary by Add-WorktreeCacheLink).
function Test-IsLinkedWorktree {
    $gitDir = git rev-parse --path-format=absolute --git-dir 2>$null
    $common = git rev-parse --path-format=absolute --git-common-dir 2>$null
    if (-not $gitDir -or -not $common) { return $false }
    return ($gitDir.Trim() -ne $common.Trim())
}

function Test-SkipInLinkedWorktree {
    param([string]$HookName = 'hook')
    if ($env:CIMIAN_HOOKS_IN_WORKTREES -eq '1') { return $false }
    if (Test-IsLinkedWorktree) {
        Write-Host "[$HookName] linked worktree - skipping (the primary checkout and CI cover this; CIMIAN_HOOKS_IN_WORKTREES=1 to run)"
        return $true
    }
    return $false
}

# ── what a push carries ─────────────────────────────────────────────────────
# git pipes one line per ref to pre-push on stdin:
#   <local-ref> SP <local-sha> SP <remote-ref> SP <remote-sha>
# The refs being pushed, not the branch that happens to be checked out, decide
# what a push is. `git push origin feature:main` from a feature branch lands
# on main; `git push origin feature` from main does not.
$script:ZeroSha = '0000000000000000000000000000000000000000'

function Get-PushRefLine {
    if (-not [Console]::IsInputRedirected) { return @() }
    try {
        return @(([Console]::In.ReadToEnd() -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } catch { return @() }
}

function Test-PushTargetsMain {
    param([string[]]$RefLines)
    foreach ($line in $RefLines) {
        $parts = $line -split '\s+'
        if ($parts.Count -ge 4 -and $parts[1] -ne $script:ZeroSha -and $parts[2] -in @('refs/heads/main', 'refs/heads/master')) {
            return $true
        }
    }
    return $false
}

# Files changed by the pushed commits, or $null when that cannot be worked out
# (a caller then does the full check rather than skipping it). A new ref is
# diffed from its merge-base with origin/main, so only the branch's own
# commits count.
function Get-PushedChangedFile {
    param([string[]]$RefLines, [string]$PathSpec = '')
    $files = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $RefLines) {
        $parts = $line -split '\s+'
        if ($parts.Count -lt 4) { return $null }
        $localSha = $parts[1]; $remoteSha = $parts[3]
        if ($localSha -eq $script:ZeroSha) { continue }
        if ($remoteSha -eq $script:ZeroSha) {
            $mb = git merge-base $localSha origin/main 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $mb) { return $null }
            $range = "$($mb.Trim())..$localSha"
        } else {
            $range = "$remoteSha..$localSha"
        }
        $gitArgs = @('diff', '--name-only', $range)
        if ($PathSpec) { $gitArgs += @('--', $PathSpec) }
        $changed = & git @gitArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        foreach ($f in $changed) { if ($f) { [void]$files.Add($f.Trim()) } }
    }
    return ,@($files | Sort-Object)
}

# ── branch-aware orphan detection ───────────────────────────────────────────
# A payload is orphaned only when no branch needs it. Packages are uploaded
# when the branch that adds them is pushed, before it merges, so main alone is
# not the whole package set: prune from main's view and an open pull request
# loses its installer. This folds every origin branch tip's pkgsinfo
# locations into the keep-set. With no remote refs it reports Available =
# $false and the caller must skip the prune.
function Add-RemotePkgsInfoLocation {
    param(
        [Parameter(Mandatory)] [hashtable]$CanonicalSet,
        [Parameter(Mandatory)] [string]$RepoRoot
    )
    $remoteRefs = @(git -C $RepoRoot for-each-ref --format='%(refname)' refs/remotes/origin 2>$null |
        Where-Object { $_ -and $_ -notmatch '/HEAD$' })
    if ($LASTEXITCODE -ne 0 -or $remoteRefs.Count -eq 0) {
        return [pscustomobject]@{ Available = $false; RemoteRefCount = 0; AddedCount = 0 }
    }

    $lines = @(git -C $RepoRoot grep -h -E '^[[:space:]]*location:[[:space:]]' $remoteRefs -- 'deployment/pkgsinfo/' 2>$null)
    $added = 0
    foreach ($line in $lines) {
        $value = ($line -split 'location:', 2)[-1].Trim().Trim("'").Trim('"')
        if (-not $value) { continue }
        $loc = $value.TrimStart('\', '/').Replace('\', '/')
        if (-not $CanonicalSet.ContainsKey($loc)) { $CanonicalSet[$loc] = $true; $added++ }
    }
    return [pscustomobject]@{ Available = $true; RemoteRefCount = $remoteRefs.Count; AddedCount = $added }
}

# ── macOS sidecars ──────────────────────────────────────────────────────────
# A Mac that touches a share or a synced folder leaves an AppleDouble (._Name)
# beside each file and a .DS_Store per directory. Nothing references them, so
# they read as orphans and inflate the prune count past its cap. Worse, if one
# process treats them as payload and another as junk, the same directory
# copies back and forth forever. They are excluded from every sync and removed
# on sight, outside the orphan cap.
$script:SidecarExcludePattern = '.DS_Store;._*'

function Test-IsSidecarName {
    param([string]$Path)
    $leaf = [IO.Path]::GetFileName(($Path -replace '\\', '/'))
    return ($leaf -eq '.DS_Store' -or $leaf.StartsWith('._'))
}

# ── imported build artifacts ────────────────────────────────────────────────
# installers/<name>/build and packages/<name>/build hold what cimipkg built.
# Once an artifact is imported into deployment/pkgs, the build copy duplicates
# bytes already kept and synced, and nothing else removes it because build/ is
# gitignored. On a busy admin machine that is easily a hundred gigabytes. Only
# artifacts whose file name already exists under deployment/pkgs are removed;
# an unimported build is left alone.
function Remove-ImportedBuildArtifact {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [string]$PkgsDir = (Join-Path $RepoRoot 'deployment\pkgs'),
        [switch]$DryRun
    )
    if (-not (Test-Path -LiteralPath $PkgsDir)) { Write-Host 'Build purge: deployment/pkgs not present, skipping'; return }
    $imported = @{}
    foreach ($f in Get-ChildItem -LiteralPath $PkgsDir -Recurse -File -ErrorAction SilentlyContinue) { $imported[$f.Name] = $true }
    if ($imported.Count -eq 0) { Write-Host 'Build purge: no imported packages, skipping'; return }

    $freed = 0L; $files = 0; $dirs = 0
    foreach ($top in 'installers', 'packages') {
        $topDir = Join-Path $RepoRoot $top
        if (-not (Test-Path -LiteralPath $topDir)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $topDir -Directory -ErrorAction SilentlyContinue) {
            $buildDir = Join-Path $item.FullName 'build'
            if (-not (Test-Path -LiteralPath $buildDir)) { continue }
            foreach ($artifact in Get-ChildItem -LiteralPath $buildDir -Recurse -File -ErrorAction SilentlyContinue) {
                if (-not $imported.ContainsKey($artifact.Name)) { continue }
                if ($DryRun) { Write-Host "  [DRY RUN] would remove $($artifact.FullName)"; continue }
                $size = $artifact.Length
                Remove-Item -LiteralPath $artifact.FullName -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $artifact.FullName)) { $freed += $size; $files++ }
            }
            if ($DryRun) { continue }
            if (-not (Get-ChildItem -LiteralPath $buildDir -Recurse -File -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $buildDir)) { $dirs++ }
            }
        }
    }
    if ($files -gt 0) {
        Write-Host ('Build purge: removed {0} imported artifact(s) and {1} empty build dir(s), freeing {2} GB' -f $files, $dirs, [math]::Round($freed / 1GB, 2))
    } else {
        Write-Host 'Build purge: nothing to remove'
    }
}

# ── category gate ───────────────────────────────────────────────────────────
# makecatalogs copies whatever category it finds into the catalogs, where it
# becomes a user-visible grouping in the client and a cache folder name. A
# typo there is a new category. When the repo carries
# quality/lint/Test-Categories.ps1 this runs it against the manifests in the
# push, and only those: judging the whole tree would block pushes over state
# the person pushing never touched. It skips, never blocks, when it cannot
# tell what changed or cannot run. Returns $false only for a real failure.
function Invoke-CategoryGate {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [AllowNull()] [string[]]$ChangedFiles
    )
    $check = Join-Path (Join-Path (Join-Path $RepoRoot 'quality') 'lint') 'Test-Categories.ps1'
    if (-not (Test-Path -LiteralPath $check)) { return $true }
    if ($null -eq $ChangedFiles) { Write-Host 'Category gate: cannot tell what changed, skipping'; return $true }
    $scope = @($ChangedFiles | Where-Object { $_ -like 'deployment/pkgsinfo/*' -or $_ -like 'packages/*/build-info.yaml' -or $_ -like 'installers/*/build-info.yaml' })
    if ($scope.Count -eq 0) { return $true }

    $ps = (Get-Command pwsh -ErrorAction SilentlyContinue)
    if (-not $ps) { $ps = Get-Command powershell -ErrorAction SilentlyContinue }
    if (-not $ps) { Write-Host 'Category gate: no PowerShell host found, skipping'; return $true }

    Write-Host "Category gate: checking $($scope.Count) changed manifest(s)"
    # A file, not an array argument: -File cannot bind an array, so a list
    # would arrive as one string per argument and the check would fail on
    # argument binding alone.
    $scopeFile = [IO.Path]::GetTempFileName()
    Set-Content -LiteralPath $scopeFile -Value $scope -Encoding UTF8
    try {
        $out = & $ps.Source -NoProfile -File $check -RepoRoot $RepoRoot -OnlyFile $scopeFile 2>&1
        $rc = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $scopeFile -Force -ErrorAction SilentlyContinue
    }
    if ($rc -ne 0) {
        Write-Host (($out | Out-String).Trim())
        Write-Host 'PUSH BLOCKED: a manifest in this push has a category outside the agreed list, or none.'
        return $false
    }
    return $true
}

# ── package path validation ─────────────────────────────────────────────────
# A pkgsinfo `location:` is data from a commit, and the hooks turn it into a
# local file path and a blob or object key. Without a check, `..\..\` or an
# absolute path would read or write outside deployment/pkgs, or name an
# arbitrary key in the bucket. Every location goes through these two before it
# is used.
#
# ConvertTo-PkgRelativePath returns the location as a forward-slash path
# relative to deployment/pkgs, or $null when it is not one: a drive letter, a
# UNC or other absolute path, any `..` or empty segment, or control
# characters. One leading slash is accepted, because Cimian writes locations
# as `/apps/Thing.msi` meaning "under pkgs". A `deployment/pkgs/` or `pkgs/`
# prefix is dropped.
function ConvertTo-PkgRelativePath {
    param([AllowNull()] [string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return $null }
    $loc = $Location.Trim().Trim("'").Trim('"')
    if ($loc -match '[\x00-\x1f]') { return $null }
    if ($loc -match '^[A-Za-z]:') { return $null }
    if ($loc -match '^(\\\\|//|\\/|/\\)') { return $null }
    $loc = $loc -replace '\\', '/'
    if ($loc.StartsWith('/')) { $loc = $loc.Substring(1) }
    $loc = $loc -replace '^deployment/pkgs/', '' -replace '^pkgs/', ''
    if (-not $loc) { return $null }
    foreach ($segment in $loc.Split('/')) {
        if ($segment -eq '' -or $segment -eq '..' -or $segment -eq '.') { return $null }
        if ($segment -match ':') { return $null }
    }
    return $loc
}

# The full local path for a validated relative path, or $null if it would
# land outside $PkgsDir once resolved.
function Resolve-PkgLocalPath {
    param([Parameter(Mandatory)] [string]$PkgsDir, [AllowNull()] [string]$RelPath)
    $rel = ConvertTo-PkgRelativePath $RelPath
    if (-not $rel) { return $null }
    $root = [IO.Path]::GetFullPath($PkgsDir).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

# Every package location referenced by tracked pkgsinfo (installer and
# uninstaller), validated. Untracked or ignored pkgsinfo do not count, so a
# stray local file cannot widen what gets uploaded.
function Get-TrackedPkgLocation {
    param([Parameter(Mandatory)] [string]$RepoRoot)
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = @(git -C $RepoRoot ls-files -- 'deployment/pkgsinfo/*.yaml' 'deployment/pkgsinfo/*.yml' 2>$null)
    foreach ($f in $files) {
        $path = Join-Path $RepoRoot ($f -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        foreach ($m in [regex]::Matches($content, '(?m)^\s+location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$')) {
            $rel = ConvertTo-PkgRelativePath $m.Groups[1].Value
            if ($rel) { [void]$set.Add($rel) } else { Write-Host "WARNING: ignoring unsafe package location '$($m.Groups[1].Value)' in $f" }
        }
    }
    return @($set | Sort-Object)
}

# ── what never leaves the machine ───────────────────────────────────────────
# Payload trees are synced as a whole, so these are excluded from every
# upload: sidecars, and anything that looks like a credential or key.
$script:UploadDenyPatterns = @('.DS_Store', '._*', '.env', '.env.*', '*.pem', '*.key', '*.pfx', '*.p12', '*.kdbx', 'id_rsa*', 'id_ed25519*', '*.ppk')
$script:IconPatterns = @('*.png', '*.ico', '*.jpg', '*.jpeg', '*.svg', '*.webp', '*.gif')

# Strip signatures and credentials from anything about to be logged: SAS
# query parameters and AWS presigned-URL parameters.
function Hide-UrlSecret {
    param([AllowNull()] $Text)
    if ($null -eq $Text) { return $Text }
    return ([string]$Text) -replace '(?i)([?&](sig|se|st|sp|spr|sv|sr|sip|skoid|sktid|skt|ske|sks|skv|x-amz-signature|x-amz-credential|x-amz-security-token)=)[^&\s"'']+', '$1***'
}
