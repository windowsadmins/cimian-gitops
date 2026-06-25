#Requires -Version 5.1
# HOOK_VERSION = '2026.06.25'
#
# ──────────────────────────────────────────────────────────────────────────────
#  pre-commit.ps1  –  validates Cimian pkgsinfo before committing (Azure)
#
#  Guards applied, in order:
#    1. Hook version check (warns if stale)
#    2. Env bypass (GIT_NO_VERIFY, SKIP_CIMIAN_HOOKS, etc.)
#    3. Concurrency lock (prevents overlap with pre-push)
#    4. Binary-size guard (>CIMIAN_MAX_FILE_SIZE_MB outside pkgs | icons)
#    5. Worktree cache link (no-op in primary)
#    6. Datetime auto-quote (tz-aware ISO8601 → quoted string, re-staged)
#    7. Structural pkgsinfo linter (typos, invalid enums, install loops)
#    8. makecatalogs validation (parse errors, missing keys, missing installers)
#    9. Missing-pkg auto-download from Azure (batched, cache-first)
#   10. Superseded-pkgsinfo resolution (repoclean'd older version, newest-safe)
#   11. Orphan pkg cleanup (main only, capped, junction-safe, deployment-validated)
#   12. Stale-upstream detection (pkgsinfo deleted on origin/main)
#
#  Messages are terminal-based (Write-Host) — no GUI dialog dependency.
# ──────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HookDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path (Join-Path $HookDir '..') 'lib\common.ps1')

Test-HookVersion -HookName 'pre-commit' -HookVersion '2026.06.25'
if (Test-ShouldSkipHook -HookName 'pre-commit') { exit 0 }
Add-WorktreeCacheLink
if (-not (Lock-Hook -HookName 'pre-commit')) { exit 1 }
if (-not (Test-StagedBinarySize)) { exit 1 }

# ── Configuration ────────────────────────────────────────────────────────────
$RepoRoot = Get-CimianRepoRoot
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path $HookDir '..\..')).Path }
$Deployment  = Join-Path $RepoRoot 'deployment'
$PkgsDir     = Join-Path $Deployment 'pkgs'
$PkgsInfoDir = Join-Path $Deployment 'pkgsinfo'
$LintScript  = Join-Path (Join-Path $HookDir '..') 'lib\pkgsinfo-lint.py'
$Resolver    = Join-Path (Join-Path $HookDir '..') 'lib\resolve-superseded-pkgsinfo.py'
$OrphanDeletionCap = 10
if ($env:CIMIAN_ORPHAN_DELETION_CAP) {
    $p = 0
    if ([int]::TryParse($env:CIMIAN_ORPHAN_DELETION_CAP, [ref]$p) -and $p -gt 0) { $OrphanDeletionCap = $p }
}

# ── check for makecatalogs ───────────────────────────────────────────────────
$makecatalogs = Get-Command makecatalogs -ErrorAction SilentlyContinue
if (-not $makecatalogs) { $makecatalogs = Get-Command makecatalogs.exe -ErrorAction SilentlyContinue }
if (-not $makecatalogs) {
    Write-Host 'ERROR: makecatalogs not found in PATH'
    Write-Host 'Install Cimian tools from: https://github.com/windowsadmins/cimian'
    exit 1
}
$MakeCatalogsExe = $makecatalogs.Source

$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
$PythonExe = if ($python) { $python.Source } else { $null }

# ── helper: run makecatalogs, return cleaned output lines ────────────────────
function Invoke-MakeCatalogs {
    $tmp = [System.IO.Path]::GetTempFileName()
    $exit = 0
    try {
        $proc = Start-Process -FilePath $MakeCatalogsExe `
            -ArgumentList '--repo_path', "`"$Deployment`"", '--silent' `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput "$tmp.stdout" -RedirectStandardError "$tmp.stderr"
        $exit = $proc.ExitCode
        $out = ''
        if (Test-Path "$tmp.stdout") { $out += Get-Content "$tmp.stdout" -Raw }
        if (Test-Path "$tmp.stderr") { $out += "`n" + (Get-Content "$tmp.stderr" -Raw) }
    } catch {
        $out = $_.Exception.Message
        $exit = 1
    } finally {
        Remove-Item "$tmp*" -Force -ErrorAction SilentlyContinue
    }
    $out = $out -replace '\x1b\[[0-9;]*m', ''
    $lines = @($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return [PSCustomObject]@{ Lines = $lines; ExitCode = $exit }
}

# Both Cimian and Munki warning dialects:
#   Cimian:  "WARNING: <ref> has missing installer => pkgs/<loc>"
#   Munki:   "WARNING: <ref> refers to missing installer item: <loc>"
function Select-MissingInstaller {
    param([string[]]$Lines)
    return @($Lines | Where-Object {
        $_ -match 'has missing installer =>' -or $_ -match 'refers to missing installer item:'
    })
}

function Get-MissingPkgPath {
    param([string]$Line)
    if ($Line -match 'has missing installer =>\s*pkgs[\\/](.+)$') { return ($Matches[1].Trim() -replace '\\', '/') }
    if ($Line -match 'has missing installer =>\s*(.+)$')          { return ($Matches[1].Trim() -replace '\\', '/') }
    if ($Line -match 'refers to missing installer item:\s*(.+)$') { return ($Matches[1].Trim() -replace '\\', '/') }
    return ''
}

# ── Auto-quote tz-aware ISO datetimes in staged pkgsinfo ─────────────────────
# Unquoted `creation_date: 2026-04-22T17:51:22Z` parses as a tz-aware datetime
# in PyYAML and crashes anything comparing it against a naive datetime (a
# catalog-promotion script). Quoting keeps it a string. Silent fix: rewrite
# staged YAMLs in place and re-stage.
$stagedYaml = @(git diff --cached --name-only --diff-filter=ACM -- 'deployment/pkgsinfo/*.yaml' 'deployment/pkgsinfo/*.yml' 2>$null |
    ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($stagedYaml.Count -gt 0) {
    $isoRe = [regex]::new(
        '^(?<prefix>\s*(?:-\s+)?[A-Za-z_][\w-]*\s*:\s*)(?<value>\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2}))(?<suffix>\s*(?:\#.*)?)$',
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    )
    $fixCount = 0
    foreach ($rel in $stagedYaml) {
        $full = Join-Path $RepoRoot ($rel -replace '/', '\')
        if (-not (Test-Path $full)) { continue }
        $text = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
        $new  = $isoRe.Replace($text, '${prefix}''${value}''${suffix}')
        if ($new -ne $text) {
            [System.IO.File]::WriteAllText($full, $new, [System.Text.UTF8Encoding]::new($false))
            git add -- $full 2>$null
            $fixCount++
        }
    }
    if ($fixCount -gt 0) { Write-Host "[pre-commit] Auto-quoted tz-aware datetimes in $fixCount pkgsinfo file(s)" }
}

# ── structural pkgsinfo linter ───────────────────────────────────────────────
# Runs before makecatalogs so typos and schema errors get friendly messages
# instead of makecatalogs' opaque output.
if ((Test-Path $LintScript) -and $PythonExe) {
    $lintOut = & $PythonExe $LintScript $RepoRoot 2>&1
    $lintExit = $LASTEXITCODE
    if ("$lintOut".Trim()) { $lintOut | ForEach-Object { Write-Host $_ } }
    if ($lintExit -ne 0) { exit 1 }
}

# ── run makecatalogs ─────────────────────────────────────────────────────────
Write-Host 'Running makecatalogs to validate pkgsinfo...'
$mc = Invoke-MakeCatalogs

# ── check for parse errors ───────────────────────────────────────────────────
$parseErrors = @($mc.Lines | Where-Object { $_ -match 'Error parsing' -or $_ -match 'Unexpected error reading' })
if ($parseErrors.Count -gt 0) {
    Write-Host ''
    Write-Host "COMMIT BLOCKED: $($parseErrors.Count) pkgsinfo file(s) cannot be parsed."
    $parseErrors | ForEach-Object { Write-Host "  $_" }
    exit 1
}

# ── orphan pkg cleanup (main/master only, capped, junction-safe) ─────────────
# Run BEFORE missing-pkg handling so we don't download pkgs we're about to delete.
$currentBranch = (git rev-parse --abbrev-ref HEAD 2>$null)
if ($currentBranch) { $currentBranch = $currentBranch.Trim() }
if ($currentBranch -in @('main', 'master')) {
    if (Test-PathIsReparsePoint $PkgsDir) {
        Write-Host "[pre-commit] SKIP orphan cleanup: '$PkgsDir' is a junction (linked worktree cache)."
    } elseif (-not (Test-CimianDeployment -Path $Deployment)) {
        Write-Host "[pre-commit] SKIP orphan cleanup: '$Deployment' does not validate as a Cimian deployment."
    } elseif ((Test-Path $PkgsDir) -and (Test-Path $PkgsInfoDir)) {
        $canonical = @{}
        Get-ChildItem -Path $PkgsInfoDir -Recurse -File -Include '*.yaml', '*.yml' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -match '(?m)^\s+location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$') {
                    $loc = ($Matches[1].Trim().TrimStart('\', '/') -replace '\\', '/')
                    $canonical[$loc.ToLower()] = $true
                } elseif ($content -match '(?m)^installer_item_location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$') {
                    $loc = ($Matches[1].Trim().TrimStart('\', '/') -replace '\\', '/')
                    $canonical[$loc.ToLower()] = $true
                }
            }

        if ($canonical.Count -lt $script:CIMIAN_MIN_PKGSINFO_FOR_VALID) {
            Write-Host "[pre-commit] SKIP orphan cleanup: canonical pkgsinfo parse returned only $($canonical.Count) entries (min $script:CIMIAN_MIN_PKGSINFO_FOR_VALID)."
            Write-Host '[pre-commit] Likely a YAML parse error, sparse checkout, or wrong deployment path.'
        } else {
            $orphans = @()
            foreach ($ext in @('*.nupkg', '*.msi', '*.exe', '*.zip', '*.intunewin', '*.pkg')) {
                Get-ChildItem -Path $PkgsDir -Recurse -Filter $ext -File -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $rel = ($_.FullName.Substring($PkgsDir.Length + 1) -replace '\\', '/')
                        if (-not $canonical.ContainsKey($rel.ToLower())) { $orphans += $rel }
                    }
            }

            if ($orphans.Count -gt $OrphanDeletionCap) {
                Write-Host ''
                Write-Host "COMMIT BLOCKED: $($orphans.Count) orphan package(s) found (cap is $OrphanDeletionCap)."
                Write-Host 'This is unusual — possible causes:'
                Write-Host '  - Partial pkgsinfo set (branch switch in progress)'
                Write-Host '  - Stale local pkgs from a prior branch'
                Write-Host '  - YAML parse errors masking the installer location'
                Write-Host ''
                Write-Host 'Sample orphans (first 15):'
                $orphans | Select-Object -First 15 | ForEach-Object { Write-Host "  - $_" }
                if ($orphans.Count -gt 15) { Write-Host "  ... and $($orphans.Count - 15) more" }
                exit 1
            }

            if ($orphans.Count -gt 0) {
                Write-Host ''
                Write-Host "Found $($orphans.Count) orphan package(s) — cleaning up:"
                foreach ($o in $orphans) {
                    Write-Host "  - $o"
                    Remove-Item (Join-Path $PkgsDir ($o -replace '/', '\')) -Force -ErrorAction SilentlyContinue
                }
                Write-Host ''
            }
        }
    }
} else {
    Write-Host "[pre-commit] Skipping orphan cleanup (branch '$currentBranch' is not main/master)."
}

# ── check for missing installer warnings ─────────────────────────────────────
$missing = Select-MissingInstaller -Lines $mc.Lines

if ($missing.Count -gt 0) {
    $warningCount = $missing.Count
    $missingPaths = @()
    foreach ($line in $missing) {
        $p = Get-MissingPkgPath -Line $line
        if ($p) { $missingPaths += $p }
    }

    # ── stale-upstream detection (pkgsinfo deleted on origin/main) ───────────
    # If our local pkgsinfo points at pkgs gone from origin/main (e.g. retired by
    # repoclean), downloading is futile — the blob is gone too. Ask for a pull.
    $remoteName   = if ($env:CIMIAN_REMOTE_NAME)   { $env:CIMIAN_REMOTE_NAME }   else { 'origin' }
    $remoteBranch = if ($env:CIMIAN_REMOTE_BRANCH) { $env:CIMIAN_REMOTE_BRANCH } else { 'main' }
    git fetch --quiet $remoteName $remoteBranch 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $mergeBase = (git merge-base HEAD "$remoteName/$remoteBranch" 2>$null)
        if ($mergeBase) { $mergeBase = $mergeBase.Trim() }
        $stale = @()
        foreach ($line in $missing) {
            $rel = $null
            if ($line -match '(?:^|\s)((?:deployment/)?pkgsinfo/\S+)') {
                $rel = $Matches[1] -replace '\\', '/'
                if ($rel -notmatch '^deployment/') { $rel = "deployment/$rel" }
            }
            if (-not $rel -or -not $mergeBase) { continue }
            git cat-file -e "${mergeBase}:${rel}" 2>$null; $inBase = $LASTEXITCODE -eq 0
            git cat-file -e "$remoteName/${remoteBranch}:${rel}" 2>$null; $inUpstream = $LASTEXITCODE -eq 0
            if ($inBase -and -not $inUpstream) { $stale += $rel }
        }
        if ($stale.Count -gt 0) {
            Write-Host ''
            Write-Host "COMMIT BLOCKED: $($stale.Count) pkgsinfo file(s) reference packages removed from $remoteName/$remoteBranch."
            Write-Host "Pull first: git pull --rebase $remoteName $remoteBranch"
            Write-Host ''
            Write-Host 'Stale pkgsinfo (will be removed on pull):'
            $stale | Select-Object -First 10 | ForEach-Object { Write-Host "  - $_" }
            if ($stale.Count -gt 10) { Write-Host "  ... and $($stale.Count - 10) more" }
            exit 1
        }
    }

    # ── safety gate: cap auto-downloads relative to staged pkgsinfo ─────────
    $stagedPkgsInfoCount = @(git diff --cached --name-only --diff-filter=ACM 2>$null |
        Where-Object { $_ -match '^deployment/pkgsinfo/.*\.(yaml|yml)$' }).Count
    $maxAutoDownload = [math]::Max(25, $stagedPkgsInfoCount * 5)
    if ($warningCount -gt $maxAutoDownload) {
        Write-Host ''
        Write-Host "COMMIT CANCELLED: $warningCount missing packages exceeds safe auto-download limit ($maxAutoDownload)."
        Write-Host '  Run: githooks/azure/post-merge --sync'
        exit 1
    }

    Write-Host ''
    Write-Host "Found $warningCount missing package(s). Downloading from Azure..."
    $missingPaths | Select-Object -First 10 | ForEach-Object { Write-Host "  - $_" }
    if ($warningCount -gt 10) { Write-Host "  ... and $($warningCount - 10) more" }

    # Delegate to post-merge which has batched azcopy + caching-server logic.
    $pathArgs = @()
    foreach ($p in $missingPaths) { $pathArgs += '--path'; $pathArgs += $p }
    $postMerge = Join-Path $HookDir 'post-merge.ps1'
    if (Test-Path $postMerge) {
        & pwsh -NoProfile -File $postMerge @pathArgs
    } else {
        Write-Host "WARNING: post-merge.ps1 not found at $postMerge — cannot auto-download."
    }

    # ── re-validate ──────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host 'Re-validating pkgsinfo after download...'
    $mc = Invoke-MakeCatalogs
    $missingRecheck = Select-MissingInstaller -Lines $mc.Lines

    # ── superseded-pkgsinfo resolution ──────────────────────────────────────
    # A "still missing" item is usually an older pkgsinfo whose .nupkg/.msi was
    # retired by `repoclean --keep N` once a newer version landed (blob is gone
    # too). If a strictly newer version of the same package is present locally
    # with its installer intact, delete the old pkgsinfo (newest-safe, capped)
    # and re-validate instead of blocking.
    if ($missingRecheck.Count -gt 0 -and (Test-Path $Resolver) -and $PythonExe) {
        $resolverOut = ($missingRecheck -join "`n") | & $PythonExe $Resolver --repo-root $RepoRoot --apply 2>$null
        $supersededCount = 0
        try {
            $parsed = ($resolverOut | Out-String) | ConvertFrom-Json
            if ($parsed.superseded) { $supersededCount = @($parsed.superseded).Count }
        } catch { $supersededCount = 0 }
        if ($supersededCount -gt 0) {
            Write-Host "[pre-commit] Removed $supersededCount superseded pkgsinfo (newer version present locally)."
            git add -A deployment/pkgsinfo 2>$null
            $mc = Invoke-MakeCatalogs
            $missingRecheck = Select-MissingInstaller -Lines $mc.Lines
        }
    }

    if ($missingRecheck.Count -gt 0) {
        Write-Host ''
        Write-Host "COMMIT BLOCKED: $($missingRecheck.Count) package(s) still missing after download."
        $missingRecheck | Select-Object -First 10 | ForEach-Object {
            $p = Get-MissingPkgPath -Line $_
            Write-Host "  - $p"
        }
        Write-Host 'Either add the package files manually or fix the pkgsinfo references.'
        exit 1
    }

    Write-Host 'All missing packages downloaded successfully'
    Write-Host 'pkgsinfo validation passed'
    exit 0
}

# ── check for missing uninstaller warnings ───────────────────────────────────
$missingUninstall = @($mc.Lines | Where-Object { $_ -match 'has missing uninstaller =>' })
if ($missingUninstall.Count -gt 0) {
    Write-Host ''
    Write-Host "COMMIT BLOCKED: $($missingUninstall.Count) pkgsinfo file(s) reference missing uninstaller packages."
    $missingUninstall | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Add the missing uninstaller files or update the pkgsinfo references.'
    exit 1
}

# ── check for makecatalogs exit code ─────────────────────────────────────────
if ($mc.ExitCode -ne 0) {
    Write-Host ''
    Write-Host "COMMIT BLOCKED: makecatalogs failed with exit code $($mc.ExitCode)"
    ($mc.Lines | Select-Object -Last 20) | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host '[pre-commit] pkgsinfo validation passed.'
exit 0
