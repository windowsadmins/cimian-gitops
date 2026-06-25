#Requires -Version 5.1
# HOOK_VERSION = '2026.06.25'
#
# ──────────────────────────────────────────────────────────────────────────────
#  post-merge.ps1  –  targeted package downloads after git pull/merge (AWS S3)
#
#  • Fires after: git pull, git merge, git checkout <branch>, rebases that move HEAD.
#  • HTTP caching server fast-path (if CIMIAN_CACHING_SERVERS set).
#  • S3 downloads run per-file via `aws s3 cp` (throttled by a parallel cap).
#  • Orphan cleanup (main/master only, capped, junction-safe).
#
#  Flags: --sync, --force (double-confirm), --dry-run, --path <relative>
#  Env bypass: GIT_NO_VERIFY, SKIP_CIMIAN_HOOKS, SKIP_CIMIAN_POST_MERGE, DISABLE_CUSTOM_HOOKS
# ──────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HookDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path (Join-Path $HookDir '..') 'lib\common.ps1')

Test-HookVersion -HookName 'post-merge' -HookVersion '2026.06.25'
if (Test-ShouldSkipHook -HookName 'post-merge') { exit 0 }
Add-WorktreeCacheLink

# ── Configuration ────────────────────────────────────────────────────────────
$RepoRoot = Get-CimianRepoRoot
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path $HookDir '..\..')).Path }
$Deployment = Join-Path $RepoRoot 'deployment'
$PkgsDir    = Join-Path $Deployment 'pkgs'

$S3Bucket = if ($env:CIMIAN_S3_BUCKET) { $env:CIMIAN_S3_BUCKET } else { 'your-cimian-bucket' }
$S3Prefix = if ($env:CIMIAN_S3_PREFIX) { $env:CIMIAN_S3_PREFIX } else { '' }
$AwsRegion = if ($env:CIMIAN_AWS_REGION) { $env:CIMIAN_AWS_REGION } elseif ($env:AWS_REGION) { $env:AWS_REGION } else { 'us-east-1' }
$S3Url = if ($S3Prefix) { "s3://$S3Bucket/$S3Prefix" } else { "s3://$S3Bucket" }

$CachingServersRaw    = if ($env:CIMIAN_CACHING_SERVERS) { $env:CIMIAN_CACHING_SERVERS } else { '' }
$CachingProbeTimeout  = 2
$CachingDownloadTimeout = 600
$script:CachingBaseUrl = ''
$script:CachingProbed  = $false

$OrphanDeletionCap = 10
if ($env:CIMIAN_ORPHAN_DELETION_CAP) {
    $p = 0
    if ([int]::TryParse($env:CIMIAN_ORPHAN_DELETION_CAP, [ref]$p) -and $p -gt 0) { $OrphanDeletionCap = $p }
}

# ── aws cli detection ────────────────────────────────────────────────────────
$Aws = Get-Command aws -ErrorAction SilentlyContinue
if (-not $Aws) { $Aws = Get-Command aws.exe -ErrorAction SilentlyContinue }
if (-not $Aws) {
    Write-Host ''
    Write-Host 'ERROR: aws CLI not found — install with: winget install Amazon.AWSCLI'
    exit 1
}
$AwsExe = $Aws.Source

# ── flags ────────────────────────────────────────────────────────────────────
$SyncMode = $false; $ForceMode = $false; $DryRun = $false; $TargetPaths = @()
$i = 0
while ($i -lt $args.Count) {
    switch ($args[$i]) {
        '--sync'    { $SyncMode = $true }
        '--force'   { $ForceMode = $true }
        '--dry-run' { $DryRun = $true }
        '--path'    { $i++; if ($i -lt $args.Count) { $TargetPaths += $args[$i] } }
    }
    $i++
}

# ── logging ──────────────────────────────────────────────────────────────────
$LogDir = Join-Path $RepoRoot '.git\logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$Today   = (Get-Date -Format 'yyyy-MM-dd')
$LogFile = Join-Path $LogDir "hook-post-merge-download-$Today.log"
Set-Content -Path $LogFile -Value '' -ErrorAction SilentlyContinue
Get-ChildItem -Path $LogDir -Filter 'hook-post-merge-download-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}
function Get-NextLogIndex {
    $max = 0
    Get-ChildItem -Path $LogDir -Filter "hook-post-merge-download-$Today-*.log" -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.BaseName -match '-(\d+)$') { $n = [int]$Matches[1]; if ($n -gt $max) { $max = $n } } }
    return ($max + 1)
}
function Complete-Log {
    Move-Item -Path $LogFile -Destination (Join-Path $LogDir "hook-post-merge-download-$Today-$(Get-NextLogIndex).log") -Force -ErrorAction SilentlyContinue
}

# ── HTTP caching server probe ────────────────────────────────────────────────
function Test-CachingServer {
    if ($script:CachingProbed) { return [bool]$script:CachingBaseUrl }
    $script:CachingProbed = $true
    if (-not $CachingServersRaw) { return $false }

    $probePath = if ($env:CIMIAN_CACHING_PROBE_PATH) { $env:CIMIAN_CACHING_PROBE_PATH } else { '/deployment/catalogs/all' }
    foreach ($cacheHost in ($CachingServersRaw -split '[:;]')) {
        $cacheHost = $cacheHost.Trim()
        if (-not $cacheHost) { continue }
        try {
            $resp = Invoke-WebRequest -Uri "http://${cacheHost}${probePath}" -Method Head `
                -TimeoutSec $CachingProbeTimeout -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -in 200, 401, 403, 404) { $script:CachingBaseUrl = "http://$cacheHost"; return $true }
        } catch {
            $sc = $null
            try { $sc = $_.Exception.Response.StatusCode.value__ } catch { $sc = $null }
            if ($sc -in 401, 403, 404) { $script:CachingBaseUrl = "http://$cacheHost"; return $true }
        }
    }
    return $false
}

function Invoke-CachingDownload {
    param([string]$RelPath, [string]$Dest)
    if (-not (Test-CachingServer)) { return $false }
    $parent = Split-Path -Parent $Dest
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $tmp = "$Dest.caching.$PID"
    try {
        Invoke-WebRequest -Uri "$script:CachingBaseUrl/$RelPath" -OutFile $tmp `
            -TimeoutSec $CachingDownloadTimeout -UseBasicParsing -ErrorAction Stop
        Move-Item -Path $tmp -Destination $Dest -Force
        return $true
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
}

# ── AWS auth check ───────────────────────────────────────────────────────────
function Test-AwsAuth {
    & $AwsExe sts get-caller-identity --region $AwsRegion 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "AWS CLI not authenticated — run 'aws configure' or 'aws sso login' first."
        Complete-Log
        exit 1
    }
}

# ── pkgsinfo → installer location extraction ─────────────────────────────────
function Get-InstallerLocation {
    param([string]$PkgsInfoFile)
    if (-not (Test-Path $PkgsInfoFile)) { return '' }
    $content = Get-Content $PkgsInfoFile -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return '' }
    if ($content -match '(?m)^\s+location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$') {
        return ($Matches[1].Trim().TrimStart('\', '/') -replace '\\', '/')
    }
    if ($content -match '(?m)^installer_item_location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$') {
        return ($Matches[1].Trim().TrimStart('\', '/') -replace '\\', '/')
    }
    return ''
}

function Get-CanonicalPkgList {
    $pkgsInfoDir = Join-Path $Deployment 'pkgsinfo'
    $set = @{}
    Get-ChildItem -Path $pkgsInfoDir -Recurse -File -Include '*.yaml', '*.yml' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $loc = Get-InstallerLocation $_.FullName
            if ($loc) { $set[$loc] = $true }
        }
    return $set.Keys
}

# ── orphan cleanup (main/master, capped, junction-safe) ──────────────────────
function Remove-OrphanPackage {
    if (-not (Test-Path $PkgsDir)) { return }
    if (Test-PathIsReparsePoint $PkgsDir) {
        Write-Log "SKIP orphan cleanup: '$PkgsDir' is a junction (linked worktree cache)."
        return
    }

    $canonical = @{}
    foreach ($loc in (Get-CanonicalPkgList)) { $canonical[$loc.ToLower()] = $true }
    Write-Log "Found $($canonical.Count) packages referenced in pkgsinfo"

    if ($canonical.Count -lt $script:CIMIAN_MIN_PKGSINFO_FOR_VALID) {
        Write-Log "SKIP orphan cleanup: canonical pkgsinfo count $($canonical.Count) < floor $script:CIMIAN_MIN_PKGSINFO_FOR_VALID."
        return
    }
    if (-not (Test-CimianDeployment -Path $Deployment)) {
        Write-Log "SKIP orphan cleanup: '$Deployment' does not validate as a Cimian deployment."
        return
    }

    $orphans = @()
    foreach ($ext in @('*.nupkg', '*.msi', '*.exe', '*.zip', '*.intunewin', '*.pkg')) {
        Get-ChildItem -Path $PkgsDir -Recurse -Filter $ext -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $rel = ($_.FullName.Substring($PkgsDir.Length + 1) -replace '\\', '/')
                if (-not $canonical.ContainsKey($rel.ToLower())) { $orphans += $rel }
            }
    }

    if ($orphans.Count -eq 0) { Write-Log 'No orphan packages found'; return }
    if ($orphans.Count -gt $OrphanDeletionCap) {
        Write-Log "WARNING: $($orphans.Count) orphan package(s) found (cap $OrphanDeletionCap) — not auto-cleaning."
        return
    }
    foreach ($o in $orphans) {
        Write-Log "  orphan: $o"
        if (-not $DryRun) { Remove-Item (Join-Path $PkgsDir ($o -replace '/', '\')) -Force -ErrorAction SilentlyContinue }
    }
    Write-Log "Cleaned up $($orphans.Count) orphan package(s)"
}

# ── batched S3 download: cache-first, per-file fallback ───────────────────────
function Invoke-CacheFirstDownload {
    param([string[]]$RelPaths)
    if (-not $RelPaths -or $RelPaths.Count -eq 0) { return }

    $useCache = $false
    if (Test-CachingServer) {
        $useCache = $true
        Write-Log ">> caching server reachable: $($script:CachingBaseUrl -replace '^https?://', '') (preferring over S3)"
    } else {
        Write-Log '>> no caching server reachable — using S3'
    }

    $s3Batch = @()
    $total = 0; $cacheHits = 0
    foreach ($rel in $RelPaths) {
        if (-not $rel) { continue }
        $total++
        $dest = Join-Path $PkgsDir ($rel -replace '/', '\')
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

        if ($DryRun) { Write-Log "  [DRY RUN] $rel"; continue }

        if ($useCache) {
            if (Invoke-CachingDownload -RelPath "deployment/pkgs/$rel" -Dest $dest) {
                Write-Log "  [cache] $rel"; $cacheHits++; continue
            }
            Write-Log "    [cache miss -> S3] $rel"
        }
        $s3Batch += $rel
    }

    if ($s3Batch.Count -gt 0 -and -not $DryRun) {
        Test-AwsAuth
        Write-Log ">> downloading $($s3Batch.Count) file(s) from S3"
        foreach ($rel in $s3Batch) {
            $src = "$S3Url/deployment/pkgs/$rel"
            $dst = Join-Path $PkgsDir ($rel -replace '/', '\')
            $out = & $AwsExe s3 cp $src $dst --region $AwsRegion --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Log "  WARNING: Failed to download $rel" }
            if ("$out".Trim()) { Add-Content -Path $LogFile -Value ($out | Out-String) }
        }
    }
    Write-Log "  Cache hits: $cacheHits / $total - S3 batch: $($s3Batch.Count)"
}

# ── targeted download ────────────────────────────────────────────────────────
if ($TargetPaths.Count -gt 0) {
    Write-Log ">> targeted download: $($TargetPaths.Count) specific package(s)"
    $rels = @()
    foreach ($t in $TargetPaths) {
        $t = $t -replace '\\', '/'
        if ($t -like 'deployment/pkgs/*') { $t = $t -replace '^deployment/pkgs/', '' }
        $rels += $t
    }
    Invoke-CacheFirstDownload -RelPaths $rels
    Write-Log 'Targeted path sync complete'
    Complete-Log
    exit 0
}

# ── branch gate ──────────────────────────────────────────────────────────────
$currentBranch = (git symbolic-ref --quiet --short HEAD 2>$null)
if ($currentBranch) { $currentBranch = $currentBranch.Trim() }
if ($currentBranch -and $currentBranch -notin @('main', 'master')) {
    Write-Log "Skipping downloads — branch '$currentBranch' is not main/master."
    Complete-Log
    exit 0
}

# ── change detection ─────────────────────────────────────────────────────────
$changedPaths = ''
$changedPkgsInfo = @()
if ($ForceMode) {
    $changedPaths = 'force'
} elseif ($SyncMode) {
    $changedPaths = 'sync'
} else {
    git rev-parse ORIG_HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'No ORIG_HEAD — skipping. Use --sync for full sync.'
        Complete-Log
        exit 0
    }
    $changedFiles = git diff --name-only ORIG_HEAD HEAD -- deployment/ 2>$null
    if (-not $changedFiles) {
        Write-Log 'No changes detected in deployment/.'
        Complete-Log
        exit 0
    }
    $needsCatalogs = $false; $needsIcons = $false
    foreach ($file in ($changedFiles -split "`n")) {
        $file = $file.Trim()
        if (-not $file) { continue }
        if     ($file -match '^deployment/catalogs/') { $needsCatalogs = $true }
        elseif ($file -match '^deployment/icons/')    { $needsIcons = $true }
        elseif ($file -match '^deployment/pkgsinfo/') { $changedPkgsInfo += $file }
    }
    $parts = @()
    if ($needsCatalogs) { $parts += 'catalogs' }
    if ($needsIcons)    { $parts += 'icons' }
    if ($changedPkgsInfo.Count -gt 0) { $parts += 'pkgsinfo' }
    $changedPaths = ($parts -join ' ')
}

if (-not $changedPaths) {
    Write-Log 'No sync-relevant changes.'
    Complete-Log
    exit 0
}

# ── force mode (double-confirm) ──────────────────────────────────────────────
if ($changedPaths -eq 'force') {
    Write-Host ''
    Write-Host '============================================================================'
    Write-Host '  FORCE MODE — NUCLEAR OPTION'
    Write-Host ''
    Write-Host '  Will re-download deployment/ from S3 bypassing sync diff logic.'
    Write-Host '  Use --sync for an incremental sync instead.'
    Write-Host '============================================================================'
    $first = Read-Host 'Are you SURE? (y/N)'
    if ($first -ne 'y' -and $first -ne 'Y') { Write-Log 'Aborted.'; Complete-Log; exit 0 }
    $second = Read-Host "Type 'FORCE' to proceed"
    if ($second -ne 'FORCE') { Write-Log 'Aborted (second confirmation not matched).'; Complete-Log; exit 0 }

    if (Test-PathIsReparsePoint $PkgsDir) {
        Write-Log 'Aborting --force — deployment/pkgs is a junction (linked worktree). Run from the primary worktree.'
        Complete-Log
        exit 1
    }

    Test-AwsAuth
    foreach ($sub in @('catalogs', 'pkgs', 'icons')) {
        Write-Log ">> force downloading deployment/$sub"
        & $AwsExe s3 sync "$S3Url/deployment/$sub/" (Join-Path $Deployment $sub) `
            --region $AwsRegion --delete --exclude '*.DS_Store' 2>&1 |
            ForEach-Object { Add-Content -Path $LogFile -Value $_ }
    }
    Complete-Log
    exit 0
}

# ── sync mode ────────────────────────────────────────────────────────────────
if ($changedPaths -eq 'sync') {
    if (Test-PathIsReparsePoint $PkgsDir) {
        Write-Log 'Aborting --sync — deployment/pkgs is a junction (linked worktree). Run from the primary worktree.'
        Complete-Log
        exit 1
    }

    Test-AwsAuth
    Write-Log '>> sync mode — aws s3 sync with ETag-based diff'
    $syncOpts = @('--delete', '--exclude', '*.DS_Store', '--only-show-errors', '--region', $AwsRegion)
    if ($DryRun) { $syncOpts += '--dryrun' }
    foreach ($sub in @('catalogs', 'pkgs', 'icons')) {
        Write-Log ">> syncing deployment/$sub"
        & $AwsExe s3 sync "$S3Url/deployment/$sub/" (Join-Path $Deployment $sub) @syncOpts 2>&1 |
            ForEach-Object { Add-Content -Path $LogFile -Value $_ }
    }
    Complete-Log
    exit 0
}

# ── targeted downloads ───────────────────────────────────────────────────────
Test-AwsAuth

if ($changedPaths -match 'catalogs') {
    Write-Log '>> syncing deployment/catalogs'
    & $AwsExe s3 sync "$S3Url/deployment/catalogs/" (Join-Path $Deployment 'catalogs') `
        --region $AwsRegion --exclude '*.DS_Store' --only-show-errors 2>&1 |
        ForEach-Object { Add-Content -Path $LogFile -Value $_ }
}
if ($changedPaths -match 'icons') {
    Write-Log '>> syncing deployment/icons'
    & $AwsExe s3 sync "$S3Url/deployment/icons/" (Join-Path $Deployment 'icons') `
        --region $AwsRegion --exclude '*.DS_Store' --only-show-errors 2>&1 |
        ForEach-Object { Add-Content -Path $LogFile -Value $_ }
}
if ($changedPaths -match 'pkgsinfo' -and $changedPkgsInfo.Count -gt 0) {
    Write-Log '>> extracting installer location from changed pkgsinfo'
    $locations = @()
    foreach ($rel in $changedPkgsInfo) {
        $full = Join-Path $RepoRoot ($rel -replace '/', '\')
        $loc = Get-InstallerLocation $full
        if ($loc) { $locations += $loc }
    }
    if ($locations.Count -gt 0) {
        Write-Log ">> downloading $($locations.Count) package(s) (cache-first, S3)"
        Invoke-CacheFirstDownload -RelPaths $locations
    } else {
        Write-Log 'No installer locations found'
    }
}

# ── orphan cleanup (main/master only) ────────────────────────────────────────
Write-Log 'Checking for orphan packages...'
Remove-OrphanPackage

Write-Log 'Git post-merge hook complete'
Complete-Log
exit 0
