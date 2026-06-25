#Requires -Version 5.1
# HOOK_VERSION = '2026.06.25'
#
# ──────────────────────────────────────────────────────────────────────────────
#  pre-push.ps1  –  safe AWS S3 upload for Cimian repo
#
#  • Gated to pushing main/master — other branches push freely, no sync.
#  • Aborts when behind origin (unless fast-forward succeeds).
#  • Re-runs makecatalogs as a final pre-flight (both warning dialects).
#  • `aws s3 sync --delete` removes S3 objects not present locally.
#  • S3 orphan cleanup vs committed pkgsinfo after successful sync (floor + cap).
#  • Junction guard refuses delete-syncs that would traverse the primary cache.
#
#  Env bypass: GIT_NO_VERIFY, SKIP_CIMIAN_HOOKS, SKIP_PRE_PUSH, DISABLE_CUSTOM_HOOKS
# ──────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HookDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path (Join-Path $HookDir '..') 'lib\common.ps1')

Test-HookVersion -HookName 'pre-push' -HookVersion '2026.06.25'
if (Test-ShouldSkipHook -HookName 'pre-push') { exit 0 }
Add-WorktreeCacheLink
if (-not (Lock-Hook -HookName 'pre-push')) { exit 1 }
if (-not (Test-StagedBinarySize)) { exit 1 }

# ── Configuration ────────────────────────────────────────────────────────────
$RepoRoot = Get-CimianRepoRoot
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path $HookDir '..\..')).Path }
$Deployment = Join-Path $RepoRoot 'deployment'
$PkgsDir    = Join-Path $Deployment 'pkgs'

$S3Bucket = if ($env:CIMIAN_S3_BUCKET) { $env:CIMIAN_S3_BUCKET } else { 'your-cimian-bucket' }
$S3Prefix = if ($env:CIMIAN_S3_PREFIX) { $env:CIMIAN_S3_PREFIX } else { '' }
$AwsRegion = if ($env:CIMIAN_AWS_REGION) { $env:CIMIAN_AWS_REGION } elseif ($env:AWS_REGION) { $env:AWS_REGION } else { 'us-east-1' }
$S3Url = if ($S3Prefix) { "s3://$S3Bucket/$S3Prefix" } else { "s3://$S3Bucket" }

$AwsOrphanDeletionCap = 50
if ($env:CIMIAN_AWS_ORPHAN_DELETION_CAP) {
    $p = 0
    if ([int]::TryParse($env:CIMIAN_AWS_ORPHAN_DELETION_CAP, [ref]$p) -and $p -gt 0) { $AwsOrphanDeletionCap = $p }
}

$Aws = Get-Command aws -ErrorAction SilentlyContinue
if (-not $Aws) { $Aws = Get-Command aws.exe -ErrorAction SilentlyContinue }
if (-not $Aws) {
    Write-Host 'ERROR: aws CLI not found — install with: winget install Amazon.AWSCLI'
    exit 1
}
$AwsExe = $Aws.Source

# ── flags ────────────────────────────────────────────────────────────────────
$ForceSync = $false; $DryRun = $false; $UploadSync = $false; $TargetPaths = @()
$i = 0
while ($i -lt $args.Count) {
    switch ($args[$i]) {
        '--force'   { $ForceSync = $true }
        '--dry-run' { $DryRun = $true }
        '--upload'  { $UploadSync = $true }
        '--sync'    { $UploadSync = $true }
        '--path'    { $i++; if ($i -lt $args.Count) { $TargetPaths += $args[$i] } }
    }
    $i++
}

# ── logging ──────────────────────────────────────────────────────────────────
$LogDir = Join-Path $RepoRoot '.git\logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$Today   = (Get-Date -Format 'yyyy-MM-dd')
$LogFile = Join-Path $LogDir "hook-pre-push-upload-$Today.log"
Set-Content -Path $LogFile -Value '' -ErrorAction SilentlyContinue
Get-ChildItem -Path $LogDir -Filter 'hook-pre-push-upload-*.log' -ErrorAction SilentlyContinue |
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
    Get-ChildItem -Path $LogDir -Filter "hook-pre-push-upload-$Today-*.log" -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.BaseName -match '-(\d+)$') { $n = [int]$Matches[1]; if ($n -gt $max) { $max = $n } } }
    return ($max + 1)
}
function Complete-Log {
    Move-Item -Path $LogFile -Destination (Join-Path $LogDir "hook-pre-push-upload-$Today-$(Get-NextLogIndex).log") -Force -ErrorAction SilentlyContinue
}

function Test-AwsAuth {
    & $AwsExe sts get-caller-identity --region $AwsRegion 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "AWS CLI not authenticated — run 'aws configure' or 'aws sso login' first."
        Complete-Log
        exit 1
    }
}

function Get-CanonicalPkgList {
    $pkgsInfoDir = Join-Path $Deployment 'pkgsinfo'
    $set = @{}
    Get-ChildItem -Path $pkgsInfoDir -Recurse -File -Include '*.yaml', '*.yml' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match '(?m)^\s+location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$') {
                $set[($Matches[1].Trim().TrimStart('\', '/') -replace '\\', '/')] = $true
            } elseif ($content -match '(?m)^installer_item_location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$') {
                $set[($Matches[1].Trim().TrimStart('\', '/') -replace '\\', '/')] = $true
            }
        }
    return $set.Keys
}

# ── S3 orphan cleanup (floor + cap + deployment check) ───────────────────────
function Remove-S3Orphan {
    Write-Log 'Building canonical pkg list from committed pkgsinfo...'
    $canonical = @{}
    foreach ($loc in (Get-CanonicalPkgList)) { $canonical[$loc.ToLower()] = $true }
    Write-Log "  $($canonical.Count) packages referenced in committed pkgsinfo"

    if ($canonical.Count -lt $script:CIMIAN_MIN_PKGSINFO_FOR_VALID) {
        Write-Log "ABORT orphan cleanup: canonical set has only $($canonical.Count) pkgsinfo entries (min $script:CIMIAN_MIN_PKGSINFO_FOR_VALID)."
        return
    }
    if (-not (Test-CimianDeployment -Path $Deployment)) {
        Write-Log "ABORT orphan cleanup: '$Deployment' does not validate as a Cimian deployment."
        return
    }

    $s3Keys = @()
    $listing = & $AwsExe s3 ls "$S3Url/deployment/pkgs/" --recursive --region $AwsRegion 2>$null
    foreach ($line in $listing) {
        $parts = ($line -split '\s+', 4)
        if ($parts.Count -lt 4) { continue }
        $key = $parts[3] -replace '^deployment/pkgs/', ''
        if ($key -match '\.(nupkg|msi|exe|zip|intunewin|pkg)$') { $s3Keys += ($key -replace '\\', '/') }
    }
    Write-Log "  $($s3Keys.Count) objects in S3"

    $orphans = @($s3Keys | Where-Object { -not $canonical.ContainsKey($_.ToLower()) } | Sort-Object -Unique)

    if ($orphans.Count -gt $AwsOrphanDeletionCap) {
        Write-Log "ABORT orphan cleanup: $($orphans.Count) S3 orphans exceed cap ($AwsOrphanDeletionCap)."
        $orphans | Select-Object -First 20 | ForEach-Object { Write-Log "    - $_" }
        if ($orphans.Count -gt 20) { Write-Log "    ... and $($orphans.Count - 20) more" }
        Write-Log '  Review manually or raise CIMIAN_AWS_ORPHAN_DELETION_CAP if intentional.'
        return
    }

    if ($orphans.Count -eq 0) { Write-Log 'No orphans in S3'; return }

    Write-Log "Found $($orphans.Count) orphan object(s) in S3:"
    $orphans | Select-Object -First 20 | ForEach-Object { Write-Log "  - $_" }
    if ($orphans.Count -gt 20) { Write-Log "  ... and $($orphans.Count - 20) more" }

    if (-not $DryRun) {
        foreach ($o in $orphans) {
            & $AwsExe s3 rm "$S3Url/deployment/pkgs/$o" --region $AwsRegion --only-show-errors 2>&1 |
                ForEach-Object { Add-Content -Path $LogFile -Value $_ }
            $lp = Join-Path $PkgsDir ($o -replace '/', '\')
            if (Test-Path $lp) { Remove-Item $lp -Force -ErrorAction SilentlyContinue }
        }
    } else {
        Write-Log "[DRY RUN] Would delete $($orphans.Count) orphans"
    }
}

function Select-MissingInstaller {
    param([string[]]$Lines)
    return @($Lines | Where-Object { $_ -match 'has missing installer =>' -or $_ -match 'refers to missing installer item:' })
}
function Get-MissingPkgPath {
    param([string]$Line)
    if ($Line -match 'has missing installer =>\s*pkgs[\\/](.+)$') { return ($Matches[1].Trim() -replace '\\', '/') }
    if ($Line -match 'has missing installer =>\s*(.+)$')          { return ($Matches[1].Trim() -replace '\\', '/') }
    if ($Line -match 'refers to missing installer item:\s*(.+)$') { return ($Matches[1].Trim() -replace '\\', '/') }
    return ''
}

function Get-ChangedPaths {
    if ($ForceSync)  { return 'all' }
    if ($UploadSync) { return 'upload' }
    $branch = (git symbolic-ref --short HEAD 2>$null)
    if ($branch) { $branch = $branch.Trim() }
    $changedFiles = ''
    git show-ref --verify --quiet "refs/remotes/origin/$branch" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $changedFiles = git diff --name-only "origin/$branch..HEAD" -- deployment/ 2>$null
    } else {
        git rev-parse HEAD~1 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $changedFiles = git diff --name-only HEAD~1 HEAD -- deployment/ 2>$null }
        else { return 'all' }
    }
    if (-not $changedFiles) { return 'none' }
    $parts = @()
    if ($changedFiles -match '(?m)^deployment/(pkgs|pkgsinfo)/') { $parts += 'pkgs' }
    if ($changedFiles -match '(?m)^deployment/icons/')          { $parts += 'icons' }
    if ($parts.Count -eq 0) { return 'none' }
    return ($parts -join ' ')
}

# ── targeted path upload ─────────────────────────────────────────────────────
if ($TargetPaths.Count -gt 0) {
    Write-Log ">> targeted path upload — $($TargetPaths.Count) path(s)"
    Test-AwsAuth
    foreach ($t in $TargetPaths) {
        $t = $t -replace '\\', '/'
        if ($t -notlike 'deployment/*') { $t = "deployment/pkgs/$t" }
        Write-Log "  -> uploading: $t"
        & $AwsExe s3 cp (Join-Path $RepoRoot ($t -replace '/', '\')) "$S3Url/$t" `
            --region $AwsRegion --only-show-errors 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value $_ }
    }
    Write-Log 'Targeted path upload complete'
    Complete-Log
    exit 0
}

# ── branch gating ────────────────────────────────────────────────────────────
$currentBranch = (git symbolic-ref --quiet --short HEAD 2>$null)
if ($currentBranch) { $currentBranch = $currentBranch.Trim() }
if ($currentBranch -and $currentBranch -notin @('main', 'master')) {
    Write-Log "Skipping upload — branch '$currentBranch' is not main/master."
    Complete-Log
    exit 0
}

# ── fast-forward guard ───────────────────────────────────────────────────────
git fetch --quiet origin $currentBranch 2>$null | Out-Null
$behind = (git rev-list --count "HEAD..origin/$currentBranch" 2>$null)
if (-not $behind) { $behind = '0' }
if ([int]$behind -gt 0) {
    Write-Log "Local $currentBranch is $behind commit(s) behind — pulling with --ff-only"
    git pull --ff-only origin $currentBranch
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Fast-forward OK — now at $(git rev-parse --short HEAD)"
    } else {
        Write-Log "PUSH CANCELLED: non-FF merge needed. Run: git pull --rebase origin $currentBranch"
        Complete-Log
        exit 1
    }
}

Write-Log "On branch '$currentBranch' — checking for changes"

# ── makecatalogs re-validation ───────────────────────────────────────────────
$makecatalogs = Get-Command makecatalogs -ErrorAction SilentlyContinue
if (-not $makecatalogs) { $makecatalogs = Get-Command makecatalogs.exe -ErrorAction SilentlyContinue }
if (-not $makecatalogs) {
    Write-Log 'WARNING: makecatalogs not found — skipping pkgsinfo validation'
} else {
    $MakeCatalogsExe = $makecatalogs.Source
    Write-Log 'Running makecatalogs to validate pkgsinfo...'
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $MakeCatalogsExe `
            -ArgumentList '--repo_path', "`"$Deployment`"", '--silent' `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput "$tmp.stdout" -RedirectStandardError "$tmp.stderr"
        $mcOut = ''
        if (Test-Path "$tmp.stdout") { $mcOut += Get-Content "$tmp.stdout" -Raw }
        if (Test-Path "$tmp.stderr") { $mcOut += "`n" + (Get-Content "$tmp.stderr" -Raw) }
    } catch { $mcOut = $_.Exception.Message } finally { Remove-Item "$tmp*" -Force -ErrorAction SilentlyContinue }
    $mcOut = $mcOut -replace '\x1b\[[0-9;]*m', ''
    $mcLines = @($mcOut -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Add-Content -Path $LogFile -Value ($mcLines -join "`n")

    $parseErrors = @($mcLines | Where-Object { $_ -match 'Error parsing' -or $_ -match 'Unexpected error reading' })
    if ($parseErrors.Count -gt 0) {
        Write-Log 'PUSH BLOCKED: parse errors in pkgsinfo'
        $parseErrors | ForEach-Object { Write-Log "  $_" }
        Complete-Log
        exit 1
    }

    $missing = Select-MissingInstaller -Lines $mcLines
    if ($missing.Count -gt 0) {
        Write-Log "Found $($missing.Count) missing package(s) — attempting auto-download"
        $pathArgs = @()
        foreach ($line in $missing) { $p = Get-MissingPkgPath -Line $line; if ($p) { $pathArgs += '--path'; $pathArgs += $p } }
        $postMerge = Join-Path $HookDir 'post-merge.ps1'
        if (Test-Path $postMerge) { & pwsh -NoProfile -File $postMerge @pathArgs 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value $_ } }

        $tmp2 = [System.IO.Path]::GetTempFileName()
        try {
            $proc = Start-Process -FilePath $MakeCatalogsExe `
                -ArgumentList '--repo_path', "`"$Deployment`"", '--silent' `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput "$tmp2.stdout" -RedirectStandardError "$tmp2.stderr"
            $rc = ''
            if (Test-Path "$tmp2.stdout") { $rc += Get-Content "$tmp2.stdout" -Raw }
            if (Test-Path "$tmp2.stderr") { $rc += "`n" + (Get-Content "$tmp2.stderr" -Raw) }
        } catch { $rc = $_.Exception.Message } finally { Remove-Item "$tmp2*" -Force -ErrorAction SilentlyContinue }
        $rc = $rc -replace '\x1b\[[0-9;]*m', ''
        $rcLines = @($rc -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $stillMissing = Select-MissingInstaller -Lines $rcLines
        if ($stillMissing.Count -gt 0) {
            Write-Log "PUSH BLOCKED: $($stillMissing.Count) package(s) still missing after download"
            $stillMissing | ForEach-Object { Write-Log "  - $(Get-MissingPkgPath -Line $_)" }
            Complete-Log
            exit 1
        }
        Write-Log 'All missing packages downloaded'
    }
}

# ── change detection → sync ──────────────────────────────────────────────────
$changedPaths = Get-ChangedPaths
if ($changedPaths -eq 'none') {
    Write-Log 'No binary changes — skipping sync'
    Complete-Log
    exit 0
}

Test-AwsAuth
Write-Log "On branch '$currentBranch' — syncing: $changedPaths"

if (Test-PathIsReparsePoint $PkgsDir) {
    Write-Log 'Aborting pre-push — deployment/pkgs is a junction (linked worktree). Push from the primary worktree.'
    Complete-Log
    exit 1
}

$syncOpts = @('--delete', '--exclude', '*.DS_Store', '--only-show-errors', '--region', $AwsRegion)
if ($DryRun) { $syncOpts += '--dryrun' }

if ($changedPaths -eq 'all' -or $changedPaths -match 'pkgs') {
    Write-Log '>> syncing deployment/pkgs'
    & $AwsExe s3 sync $PkgsDir "$S3Url/deployment/pkgs/" @syncOpts 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value $_ }
    Remove-S3Orphan
}
if ($changedPaths -eq 'all' -or $changedPaths -match 'icons') {
    Write-Log '>> syncing deployment/icons'
    & $AwsExe s3 sync (Join-Path $Deployment 'icons') "$S3Url/deployment/icons/" @syncOpts 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value $_ }
}
if ($changedPaths -eq 'upload') {
    Write-Log '>> upload mode — full sync'
    foreach ($sub in @('pkgs', 'icons')) {
        Write-Log ">> syncing deployment/$sub"
        & $AwsExe s3 sync (Join-Path $Deployment $sub) "$S3Url/deployment/$sub/" @syncOpts 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value $_ }
    }
    Remove-S3Orphan
}

Write-Log 'pre-push complete'
Complete-Log
exit 0
