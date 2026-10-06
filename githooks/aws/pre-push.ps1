#Requires -Version 5.1
# HOOK_VERSION = '2026.10.06'
#
# ──────────────────────────────────────────────────────────────────────────────
#  pre-push.ps1  –  safe AWS S3 upload for Cimian repo
#
#  • Decided by the refs being pushed (stdin), not the checked-out branch. A
#    push that lands on main/master from the primary checkout gets the full
#    path below; anything else, including any push from a linked worktree,
#    runs pre-push-pr-packages.ps1 to make sure the packages its pkgsinfo
#    needs are in S3, and nothing more.
#  • Skips entirely when the push touches nothing under deployment/ or an
#    installers/ or packages/ payload.
#  • Aborts when behind origin (unless fast-forward succeeds).
#  • Re-runs makecatalogs as a final pre-flight (both warning dialects).
#  • Checks categories in the pushed manifests when the repo carries
#    quality/lint/Test-Categories.ps1.
#  • Uploads are additive: deployment/pkgs is a partial on-demand cache on
#    every machine, so a sync from it must never delete. The only delete path
#    is the orphan cleanup, driven by committed pkgsinfo on every remote
#    branch, with a floor and a cap. macOS sidecars (._*, .DS_Store) are never
#    uploaded and are removed from S3 on sight.
#  • --sync and --force also purge cimipkg build output that is already
#    imported into deployment/pkgs.
#
#  Env bypass: GIT_NO_VERIFY, SKIP_CIMIAN_HOOKS, SKIP_PRE_PUSH, DISABLE_CUSTOM_HOOKS
# ──────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HookDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path (Join-Path $HookDir '..') 'lib\common.ps1')

Test-HookVersion -HookName 'pre-push' -HookVersion '2026.10.06'
if (Test-ShouldSkipHook -HookName 'pre-push') { exit 0 }
Add-WorktreeCacheLink
if (-not (Lock-Hook -HookName 'pre-push')) { exit 1 }
if (-not (Test-StagedBinarySize)) { exit 1 }

# ── Configuration ────────────────────────────────────────────────────────────
$RepoRoot = Get-CimianRepoRoot
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path $HookDir '..\..')).Path }
$Deployment = Get-CimianDeploymentRoot -RepoRoot $RepoRoot
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
    $line = Hide-UrlSecret "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
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

# ── what is being pushed ─────────────────────────────────────────────────────
$Manual = $ForceSync -or $DryRun -or $UploadSync -or ($TargetPaths.Count -gt 0)
$RefLines = @()
$PushedFiles = $null
if (-not $Manual) {
    $RefLines = @(Get-PushRefLine)
    if ([Console]::IsInputRedirected -and $RefLines.Count -eq 0) {
        Write-Log 'Nothing to push - skipping.'
        Complete-Log
        exit 0
    }

    # Branch pushes, and every push from a linked worktree, get the PR package
    # check only. Without ref lines (run by hand) fall back to the branch.
    $toMain = if ($RefLines.Count -gt 0) { Test-PushTargetsMain -RefLines $RefLines }
              else { ([string](git symbolic-ref --quiet --short HEAD 2>$null)).Trim() -in @('main', 'master') }
    if (-not $toMain -or (Test-IsLinkedWorktree)) {
        Complete-Log
        & (Join-Path $HookDir 'pre-push-pr-packages.ps1') -RefLines $RefLines
        exit $LASTEXITCODE
    }

    if ($RefLines.Count -gt 0) {
        $PushedFiles = Get-PushedChangedFile -RefLines $RefLines
        $syncRelevant = '^(deployment/|installers/[^/]+/(payload/|build-info\.yaml)|packages/[^/]+/(payload/|build-info\.yaml))'
        if ($null -ne $PushedFiles -and -not ($PushedFiles | Where-Object { $_ -match $syncRelevant })) {
            Write-Log 'No deployment, installer or package changes in this push - skipping validation and sync.'
            Complete-Log
            exit 0
        }
    }
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
                $rel = ConvertTo-PkgRelativePath $Matches[1]; if ($rel) { $set[$rel] = $true }
            } elseif ($content -match '(?m)^installer_item_location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$') {
                $rel = ConvertTo-PkgRelativePath $Matches[1]; if ($rel) { $set[$rel] = $true }
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

    # A payload is only an orphan if no branch needs it: an open pull request's
    # package is already uploaded but not yet on main.
    $branchSet = @{}
    $remote = Add-RemotePkgsInfoLocation -CanonicalSet $branchSet -RepoRoot $RepoRoot
    if (-not $remote.Available) {
        Write-Log 'SKIP orphan cleanup: no remote branch refs, so it cannot tell which payloads other branches need. The push is unaffected.'
        return
    }
    foreach ($loc in $branchSet.Keys) { $canonical[$loc.ToLower()] = $true }
    Write-Log "  $($canonical.Count) packages in use across $($remote.RemoteRefCount) remote branch(es)"

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
        $key = $parts[3] -replace '^.*?deployment/pkgs/', ''
        if (-not (ConvertTo-PkgRelativePath $key)) { continue }
        if ($key -match '\.(nupkg|msi|exe|zip|intunewin|pkg)$' -or (Test-IsSidecarName $key)) { $s3Keys += ($key -replace '\\', '/') }
    }
    Write-Log "  $($s3Keys.Count) objects in S3"

    # Sidecars are never payloads: remove them on sight, outside the cap.
    $sidecars = @($s3Keys | Where-Object { Test-IsSidecarName $_ })
    if ($sidecars.Count -gt 0) {
        Write-Log "Removing $($sidecars.Count) macOS sidecar(s) (._*, .DS_Store) from S3"
        if (-not $DryRun) {
            foreach ($sc in $sidecars) { & $AwsExe s3 rm "$S3Url/deployment/pkgs/$sc" --region $AwsRegion --only-show-errors 2>&1 | Out-Null }
        }
    }

    $orphans = @($s3Keys | Where-Object { -not (Test-IsSidecarName $_) -and -not $canonical.ContainsKey($_.ToLower()) } | Sort-Object -Unique)

    if ($orphans.Count -gt $AwsOrphanDeletionCap) {
        Write-Log "SKIP orphan cleanup: $($orphans.Count) orphans exceed the review cap ($AwsOrphanDeletionCap). Nothing was deleted and the push is unaffected."
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
                ForEach-Object { Add-Content -Path $LogFile -Value (Hide-UrlSecret $_) }
            $lp = Resolve-PkgLocalPath -PkgsDir $PkgsDir -RelPath $o
            if ($lp -and (Test-Path -LiteralPath $lp)) { Remove-Item $lp -Force -ErrorAction SilentlyContinue }
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

    if ($null -ne $PushedFiles) {
        $parts = @()
        if ($PushedFiles | Where-Object { $_ -match '^deployment/(pkgs|pkgsinfo)/' }) { $parts += 'pkgs' }
        if ($PushedFiles | Where-Object { $_ -match '^deployment/icons/' })          { $parts += 'icons' }
        if ($PushedFiles | Where-Object { $_ -match '^(installers|packages)/[^/]+/payload/' }) { $parts += 'payloads' }
        if ($parts.Count -eq 0) { return 'none' }
        return ($parts -join ' ')
    }
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
    $payloadChanges = git diff --name-only "origin/$branch..HEAD" -- installers/ packages/ 2>$null
    if ($payloadChanges -match '(?m)^(installers|packages)/[^/]+/payload/') { $parts += 'payloads' }
    if ($parts.Count -eq 0) { return 'none' }
    return ($parts -join ' ')
}

# ── targeted path upload ─────────────────────────────────────────────────────
# Only a package that tracked pkgsinfo references, or an image under
# deployment/icons, and only by a validated path.
if ($TargetPaths.Count -gt 0) {
    Write-Log ">> targeted path upload — $($TargetPaths.Count) path(s)"
    Test-AwsAuth
    $tracked = @{}
    foreach ($l in (Get-TrackedPkgLocation -RepoRoot $RepoRoot)) { $tracked[$l.ToLower()] = $true }
    $iconsDir = Join-Path $Deployment 'icons'
    foreach ($t in $TargetPaths) {
        $t = ([string]$t) -replace '\\', '/'
        if ($t -like 'deployment/icons/*') {
            $name = ConvertTo-PkgRelativePath ($t.Substring('deployment/icons/'.Length))
            $local = if ($name) { Resolve-PkgLocalPath -PkgsDir $iconsDir -RelPath $name } else { $null }
            $isImage = $name -and @($script:IconPatterns | Where-Object { $name -like $_ }).Count -gt 0
            if (-not $local -or -not $isImage) { Write-Log "  REFUSED: $t is not an image under deployment/icons"; continue }
            $remote = "deployment/icons/$name"
        } else {
            $rel = ConvertTo-PkgRelativePath $t
            $local = if ($rel) { Resolve-PkgLocalPath -PkgsDir $PkgsDir -RelPath $rel } else { $null }
            if (-not $local) { Write-Log "  REFUSED: $t is not a safe path under deployment/pkgs"; continue }
            if (-not $tracked.ContainsKey($rel.ToLower())) { Write-Log "  REFUSED: $rel is not referenced by tracked pkgsinfo"; continue }
            $remote = "deployment/pkgs/$rel"
        }
        Write-Log "  -> uploading: $remote"
        & $AwsExe s3 cp $local "$S3Url/$remote" `
            --region $AwsRegion --only-show-errors 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value (Hide-UrlSecret $_) }
    }
    Write-Log 'Targeted path upload complete'
    Complete-Log
    exit 0
}

# ── branch ───────────────────────────────────────────────────────────────────
# Only main/master reach this point (see "what is being pushed" above).
$currentBranch = (git symbolic-ref --quiet --short HEAD 2>$null)
if ($currentBranch) { $currentBranch = $currentBranch.Trim() } else { $currentBranch = 'main' }

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
        if (Test-Path $postMerge) { & pwsh -NoProfile -File $postMerge @pathArgs 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value (Hide-UrlSecret $_) } }

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

# ── category gate ────────────────────────────────────────────────────────────
if (-not (Invoke-CategoryGate -RepoRoot $RepoRoot -ChangedFiles $PushedFiles)) {
    Complete-Log
    exit 1
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

# SAFETY: never sync from a junctioned deployment/pkgs (a linked worktree's
# view of the primary's cache). Push from the primary worktree.
if (Test-PathIsReparsePoint $PkgsDir) {
    Write-Log 'Aborting pre-push — deployment/pkgs is a junction (linked worktree). Push from the primary worktree.'
    Complete-Log
    exit 1
}

# What leaves the machine, and nothing else:
#   • deployment/pkgs: only files that tracked pkgsinfo reference, each by a
#     validated path. Untracked or ignored files in the cache stay local.
#   • deployment/icons: image files only.
#   • installers/<name>/payload and packages/<name>/payload: only for projects
#     whose build-info.yaml is tracked, minus sidecars and anything shaped
#     like a credential or key (.env, *.pem, *.key, *.pfx, ...).
# No --acl is ever passed; objects get the bucket's default (keep Block Public
# Access on).
#
# Additive only: no --delete. Nobody holds all of deployment/pkgs locally, so
# deleting what a partial cache lacks would empty the bucket. The orphan
# cleanup is the one delete path.
$syncOpts = @()
foreach ($pat in $script:UploadDenyPatterns) { $syncOpts += @('--exclude', $pat, '--exclude', "*/$pat") }
$syncOpts += @('--only-show-errors', '--region', $AwsRegion)
if ($DryRun) { $syncOpts += '--dryrun' }

function Sync-Up([string]$Local, [string]$Remote, [string[]]$Extra = @()) {
    if (-not (Test-Path -LiteralPath $Local)) { return }
    Write-Log ">> syncing $Remote"
    & $AwsExe s3 sync $Local "$S3Url/$Remote" @Extra @syncOpts 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value (Hide-UrlSecret $_) }
    if ($LASTEXITCODE -ne 0) { Write-Log "ERROR: aws s3 sync of $Remote failed ($LASTEXITCODE)"; Complete-Log; exit 1 }
}

# Packages are immutable: only keys not already in S3 are uploaded.
function Send-ReferencedPkgs {
    $rels = @(Get-TrackedPkgLocation -RepoRoot $RepoRoot | Where-Object {
        $lp = Resolve-PkgLocalPath -PkgsDir $PkgsDir -RelPath $_
        $lp -and (Test-Path -LiteralPath $lp -PathType Leaf) -and -not (Test-IsSidecarName $_)
    })
    if ($rels.Count -eq 0) { Write-Log 'No referenced packages present locally to upload'; return }
    $existing = @{}
    foreach ($line in (& $AwsExe s3 ls "$S3Url/deployment/pkgs/" --recursive --region $AwsRegion 2>$null)) {
        $parts = ($line -split '\s+', 4)
        if ($parts.Count -eq 4) { $existing[($parts[3] -replace '^.*?deployment/pkgs/', '').ToLower()] = $true }
    }
    $todo = @($rels | Where-Object { -not $existing.ContainsKey($_.ToLower()) })
    Write-Log ">> $($todo.Count) of $($rels.Count) referenced package(s) not yet in S3"
    foreach ($rel in $todo) {
        if ($DryRun) { Write-Log "  [DRY RUN] $rel"; continue }
        $lp = Resolve-PkgLocalPath -PkgsDir $PkgsDir -RelPath $rel
        & $AwsExe s3 cp $lp "$S3Url/deployment/pkgs/$rel" --region $AwsRegion --only-show-errors 2>&1 |
            ForEach-Object { Add-Content -Path $LogFile -Value (Hide-UrlSecret $_) }
        if ($LASTEXITCODE -ne 0) { Write-Log "ERROR: upload of $rel failed ($LASTEXITCODE)"; Complete-Log; exit 1 }
    }
}

# installers/<name>/payload and packages/<name>/payload are the source trees
# cimipkg builds from. They go to S3 so another admin, or a build pipeline,
# can rebuild without the original download.
function Sync-Payloads {
    foreach ($top in 'installers', 'packages') {
        $topDir = Join-Path $RepoRoot $top
        if (-not (Test-Path -LiteralPath $topDir)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $topDir -Directory -ErrorAction SilentlyContinue) {
            if ($item.Name -match '[^A-Za-z0-9._ -]' -or $item.Name.StartsWith('.')) { continue }
            git -C $RepoRoot ls-files --error-unmatch -- "$top/$($item.Name)/build-info.yaml" 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Log "  skip $top/$($item.Name): build-info.yaml is not tracked"; continue }
            $payload = Join-Path $item.FullName 'payload'
            if (Test-Path -LiteralPath $payload) { Sync-Up $payload "$top/$($item.Name)/payload/" }
        }
    }
}

$iconFilter = @('--exclude', '*')
foreach ($pat in $script:IconPatterns) { $iconFilter += @('--include', $pat) }

$all = $changedPaths -in @('all', 'upload')
if ($all -or $changedPaths -match 'pkgs')     { Send-ReferencedPkgs }
if ($all -or $changedPaths -match 'icons')    { Sync-Up (Join-Path $Deployment 'icons') 'deployment/icons/' $iconFilter }
if ($all -or $changedPaths -match 'payloads') { Sync-Payloads }
if ($all -or $changedPaths -match 'pkgs')     { Remove-S3Orphan }
if ($all) { Remove-ImportedBuildArtifact -RepoRoot $RepoRoot -PkgsDir $PkgsDir -DryRun:$DryRun }

Write-Log 'pre-push complete'
Complete-Log
exit 0
