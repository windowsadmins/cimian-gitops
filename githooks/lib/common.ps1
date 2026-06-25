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
#
#  Every .ps1 hook should start with a HOOK_VERSION comment and dot-source this:
#
#      # HOOK_VERSION = '2026.06.25'
#      $HookDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
#      . (Join-Path $HookDir '..' 'lib' 'common.ps1')
#      Test-HookVersion -HookName 'pre-commit' -HookVersion '2026.06.25'
#      if (Test-ShouldSkipHook -HookName 'pre-commit') { exit 0 }
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

# Resolve the deployment/ directory at the repo root. Cimian's repo layout is
# deployment/{pkgs,pkgsinfo,catalogs,icons}.
function Get-CimianDeploymentRoot {
    param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Get-CimianRepoRoot }
    if (-not $RepoRoot) { return $null }
    return (Join-Path $RepoRoot 'deployment')
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
