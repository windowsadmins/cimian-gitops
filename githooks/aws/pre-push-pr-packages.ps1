#Requires -Version 5.1
# HOOK_VERSION = '2026.10.06'
#
# ──────────────────────────────────────────────────────────────────────────────
#  pre-push-pr-packages.ps1  –  package check for pushes that are not to main (S3)
#
#  The S3 twin of ../azure/pre-push-pr-packages.ps1, with the same rules for
#  the pkgsinfo a push adds or changes:
#
#    • nopkg items are skipped: they have no payload to upload or hash.
#    • A local package must match the pkgsinfo's size and SHA-256.
#    • Package paths are immutable. An object already at the key must carry
#      the same SHA-256 (user metadata `sha256`); a different one blocks the
#      push rather than overwrite what main may already serve.
#    • A missing object is created with put-object --if-none-match '*' and the
#      SHA-256 in its metadata, so two worktrees racing to upload the same key
#      either agree byte for byte or the loser is blocked.
#    • A legacy object with no sha256 metadata is backfilled (an in-place
#      copy-object, conditional on its ETag) only when its identity is proven:
#      origin/main records the same hash for the key, or the object's
#      single-part ETag equals the local file's MD5.
#    • When a CloudFront distribution is given, the new key is invalidated so
#      a 404 cached before the upload does not linger.
#
#  put-object and copy-object handle objects up to 5 GB. A larger package
#  needs a multipart upload with the same create-only condition.
#
#  Config (env): CIMIAN_S3_BUCKET, CIMIAN_S3_PREFIX, CIMIAN_AWS_REGION, and
#  optionally CIMIAN_CLOUDFRONT_DISTRIBUTION_ID.
# ──────────────────────────────────────────────────────────────────────────────
param([string[]]$RefLines)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HookDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path (Join-Path (Join-Path $HookDir '..') 'lib') 'common.ps1')

$repoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { Write-Error 'Not inside a git repository'; exit 1 }
$repoRoot = $repoRoot.Trim()
$bucket = if ($env:CIMIAN_S3_BUCKET) { $env:CIMIAN_S3_BUCKET } else { 'your-cimian-bucket' }
$prefix = if ($env:CIMIAN_S3_PREFIX) { $env:CIMIAN_S3_PREFIX.Trim('/') + '/' } else { '' }
$region = if ($env:CIMIAN_AWS_REGION) { $env:CIMIAN_AWS_REGION } elseif ($env:AWS_REGION) { $env:AWS_REGION } else { 'us-east-1' }
$zeroSha = '0000000000000000000000000000000000000000'
$immutableCache = 'public, max-age=31536000, immutable'
$commonDir = (git rev-parse --path-format=absolute --git-common-dir 2>$null)
$primaryRoot = if ($commonDir) { Split-Path -Parent $commonDir.Trim() } else { $repoRoot }
if (-not $PSBoundParameters.ContainsKey('RefLines')) { $RefLines = @(Get-PushRefLine) }

function Get-PushedPkgsInfo {
    $files = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in @($RefLines)) {
        $parts = $line -split '\s+'
        if ($parts.Count -lt 4) { throw "Cannot parse pre-push ref: $line" }
        $localSha = $parts[1]
        $remoteSha = $parts[3]
        if ($localSha -eq $zeroSha) { continue }
        if ($remoteSha -eq $zeroSha) {
            $base = & git merge-base $localSha origin/main 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $base) { throw 'Cannot determine the branch point from origin/main.' }
            $range = "$($base.Trim())..$localSha"
        } else {
            $range = "$remoteSha..$localSha"
        }
        $changed = & git diff --diff-filter=ACMR --name-only $range -- deployment/pkgsinfo/ 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Cannot inspect pushed range $range." }
        foreach ($file in $changed) { if ($file) { [void]$files.Add($file.Trim()) } }
    }
    return @($files | Sort-Object)
}

function Get-PackageMetadata([string]$Path) {
    $content = Get-Content -LiteralPath $Path -Raw
    # nopkg items are script-only; there is no payload to check.
    if ([regex]::IsMatch($content, '(?m)^\s*type:\s*[''"]?nopkg[''"]?\s*$')) { return 'nopkg' }
    $locationMatch = [regex]::Match($content, '(?m)^\s+location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$')
    if (-not $locationMatch.Success) { return $null }
    $hashMatch = [regex]::Match($content, '(?m)^\s+hash:\s*[''"]?([0-9a-fA-F]{64})[''"]?\s*$')
    $sizeMatch = [regex]::Match($content, '(?m)^\s+size:\s*(\d+)\s*$')
    return @{
        Location = $locationMatch.Groups[1].Value.Trim().TrimStart('/', '\').Replace('\', '/')
        Hash     = if ($hashMatch.Success) { $hashMatch.Groups[1].Value.ToLowerInvariant() } else { '' }
        Size     = if ($sizeMatch.Success) { [long]$sizeMatch.Groups[1].Value } else { 0 }
    }
}

function Get-RemoteObjectIdentity([string]$Key) {
    $out = & $script:AwsPath s3api head-object --bucket $bucket --key $Key --region $region `
        --query '{sha256:Metadata.sha256,etag:ETag}' --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ("$out" -match '404|Not Found|NoSuchKey') {
            return [pscustomobject]@{ Exists = $false; Sha256 = ''; ETag = '' }
        }
        throw "Could not read S3 object $Key."
    }
    $identity = ($out | Out-String) | ConvertFrom-Json
    return [pscustomobject]@{
        Exists = $true
        Sha256 = if ($identity.sha256) { ([string]$identity.sha256).ToLowerInvariant() } else { '' }
        ETag   = if ($identity.etag) { [string]$identity.etag } else { '' }
    }
}

function Get-LocalMd5Hex([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash.ToLowerInvariant()
}

function Set-ObjectSha256([string]$Key, [string]$Sha256, [string]$ETag) {
    # Metadata on S3 is replaced by copying the object onto itself. The ETag
    # condition makes it fail if someone else changed the object meanwhile.
    & $script:AwsPath s3api copy-object --bucket $bucket --key $Key --region $region `
        --copy-source "$bucket/$Key" --copy-source-if-match $ETag `
        --metadata-directive REPLACE --metadata "sha256=$Sha256" --cache-control $immutableCache `
        --output text 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-MainSha256ForLocation([string]$Location, [string]$PreferredPath = '') {
    if ($PreferredPath) {
        $preferred = (& git show "origin/main:$PreferredPath" 2>$null) -join "`n"
        if ($LASTEXITCODE -eq 0 -and $preferred) {
            $l = [regex]::Match($preferred, '(?m)^\s+location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$')
            $h = [regex]::Match($preferred, '(?m)^\s+hash:\s*[''"]?([0-9a-fA-F]{64})[''"]?\s*$')
            if ($l.Success -and $h.Success) {
                $n = $l.Groups[1].Value.Trim().TrimStart('/', '\').Replace('\', '/') -replace '^deployment/pkgs/', '' -replace '^pkgs/', ''
                if ($n -eq $Location) { return $h.Groups[1].Value.ToLowerInvariant() }
            }
        }
    }
    $hits = @(& git grep -l -F -- $Location origin/main -- deployment/pkgsinfo/ 2>$null)
    if ($LASTEXITCODE -notin @(0, 1)) { throw "Could not inspect origin/main for $Location." }
    $hashes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($hit in $hits) {
        $path = ([string]$hit) -replace '^origin/main:', ''
        $content = (& git show "origin/main:$path" 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $content) { continue }
        $l = [regex]::Match($content, '(?m)^\s+location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$')
        $h = [regex]::Match($content, '(?m)^\s+hash:\s*[''"]?([0-9a-fA-F]{64})[''"]?\s*$')
        if (-not $l.Success -or -not $h.Success) { continue }
        $n = $l.Groups[1].Value.Trim().TrimStart('/', '\').Replace('\', '/') -replace '^deployment/pkgs/', '' -replace '^pkgs/', ''
        if ($n -eq $Location) { [void]$hashes.Add($h.Groups[1].Value.ToLowerInvariant()) }
    }
    if ($hashes.Count -gt 1) { return 'conflict' }
    if ($hashes.Count -eq 1) { return @($hashes)[0] }
    return ''
}

try {
    $pkgsInfoFiles = @(Get-PushedPkgsInfo)
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if ($pkgsInfoFiles.Count -eq 0) { exit 0 }

$aws = Get-Command aws -ErrorAction SilentlyContinue
if (-not $aws) { Write-Host 'ERROR: the AWS CLI is required to verify PR package references.' -ForegroundColor Red; exit 1 }
$script:AwsPath = $aws.Source
& $script:AwsPath sts get-caller-identity --region $region --output text 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'ERROR: AWS credentials are required to verify PR package references.' -ForegroundColor Red
    Write-Host 'Run: aws sso login   (or configure a profile)'
    exit 1
}

$failures = 0
foreach ($relativePkgsInfo in $pkgsInfoFiles) {
    $pkgsInfoPath = Join-Path $repoRoot ($relativePkgsInfo -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $pkgsInfoPath -PathType Leaf)) { continue }
    $metadata = Get-PackageMetadata -Path $pkgsInfoPath
    if ($metadata -is [string] -and $metadata -eq 'nopkg') {
        Write-Host "SKIP:  $relativePkgsInfo is nopkg (script-only, no payload)." -ForegroundColor DarkGray
        continue
    }
    if (-not $metadata) { Write-Host "ERROR: $relativePkgsInfo has no installer location." -ForegroundColor Red; $failures++; continue }
    if ($metadata.Hash -notmatch '^[0-9a-f]{64}$') { Write-Host "ERROR: $relativePkgsInfo has no valid SHA-256 installer hash." -ForegroundColor Red; $failures++; continue }

    # The location is commit data: validate it before it becomes a local path
    # or a storage key, so `..` or an absolute path cannot escape deployment/pkgs.
    $location = ConvertTo-PkgRelativePath $metadata.Location
    if (-not $location) {
        Write-Host "ERROR: $relativePkgsInfo has an unsafe installer location '$($metadata.Location)' (absolute, drive, UNC or '..')." -ForegroundColor Red
        $failures++
        continue
    }
    $localPath = Resolve-PkgLocalPath -PkgsDir (Join-Path (Join-Path $repoRoot 'deployment') 'pkgs') -RelPath $location
    if (-not $localPath) { Write-Host "ERROR: $location resolves outside deployment/pkgs." -ForegroundColor Red; $failures++; continue }
    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf) -and $primaryRoot -ne $repoRoot) {
        $primaryPath = Resolve-PkgLocalPath -PkgsDir (Join-Path (Join-Path $primaryRoot 'deployment') 'pkgs') -RelPath $location
        if ($primaryPath -and (Test-Path -LiteralPath $primaryPath -PathType Leaf)) { $localPath = $primaryPath }
    }
    $key = "${prefix}deployment/pkgs/$location"

    $hasLocalPackage = Test-Path -LiteralPath $localPath -PathType Leaf
    if ($hasLocalPackage) {
        $file = Get-Item -LiteralPath $localPath
        $localSizeKb = [long][math]::Round($file.Length / 1024)
        if ($metadata.Size -gt 0 -and [math]::Abs($localSizeKb - $metadata.Size) -gt 1) {
            Write-Host "ERROR: Size mismatch for $location (pkgsinfo $($metadata.Size) KB, local $localSizeKb KB)." -ForegroundColor Red
            $failures++; continue
        }
        if ((Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $metadata.Hash) {
            Write-Host "ERROR: SHA-256 mismatch for $location." -ForegroundColor Red
            $failures++; continue
        }
    }

    try { $remote = Get-RemoteObjectIdentity -Key $key } catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; $failures++; continue }

    if ($remote.Exists) {
        if ($remote.Sha256 -eq $metadata.Hash) { Write-Host "[pre-push] Immutable package already in S3: $location"; continue }
        if ($remote.Sha256) {
            Write-Host "ERROR: Refusing to overwrite immutable package path $location." -ForegroundColor Red
            Write-Host "  S3 SHA-256:       $($remote.Sha256)"
            Write-Host "  pkgsinfo SHA-256: $($metadata.Hash)"
            $failures++; continue
        }
        try { $mainHash = Get-MainSha256ForLocation -Location $location -PreferredPath $relativePkgsInfo } catch { $mainHash = '' }
        if ($mainHash -eq 'conflict' -or ($mainHash -and $mainHash -ne $metadata.Hash)) {
            Write-Host "ERROR: origin/main assigns a different SHA-256 identity to $location." -ForegroundColor Red
            $failures++; continue
        }
        # A single-part upload's ETag is the hex MD5 of the bytes; a multipart
        # ETag carries a '-' and proves nothing.
        $etagMd5 = $remote.ETag.Trim('"').ToLowerInvariant()
        $md5Proven = $hasLocalPackage -and $etagMd5 -notmatch '-' -and $etagMd5 -eq (Get-LocalMd5Hex -Path $localPath)
        if (($mainHash -ne $metadata.Hash -and -not $md5Proven) -or -not $remote.ETag) {
            Write-Host "ERROR: S3 object $location has no SHA-256 identity and it cannot be proven equal to this package." -ForegroundColor Red
            $failures++; continue
        }
        if (Set-ObjectSha256 -Key $key -Sha256 $metadata.Hash -ETag $remote.ETag) {
            Write-Host "[pre-push] Backfilled SHA-256 metadata for legacy object: $location"
            continue
        }
        try { $after = Get-RemoteObjectIdentity -Key $key } catch { $after = $null }
        if ($after -and $after.Sha256 -eq $metadata.Hash) {
            Write-Host "[pre-push] Another worktree backfilled the identical package: $location"
        } else {
            Write-Host "ERROR: Object $location changed while its identity was being backfilled." -ForegroundColor Red
            $failures++
        }
        continue
    }

    if (-not $hasLocalPackage) {
        Write-Host "ERROR: $relativePkgsInfo references a package absent locally and in S3:" -ForegroundColor Red
        Write-Host "  $localPath"
        $failures++; continue
    }

    Write-Host "[pre-push] Creating immutable package required by $relativePkgsInfo`: $location"
    & $script:AwsPath s3api put-object --bucket $bucket --key $key --region $region --body $localPath `
        --if-none-match '*' --metadata "sha256=$($metadata.Hash)" --cache-control $immutableCache --output text 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        if ($env:CIMIAN_CLOUDFRONT_DISTRIBUTION_ID) {
            & $script:AwsPath cloudfront create-invalidation --distribution-id $env:CIMIAN_CLOUDFRONT_DISTRIBUTION_ID `
                --paths "/deployment/pkgs/$location" --output text 2>$null | Out-Null
        }
        continue
    }
    # The create-only condition failed: another worktree may have won the
    # race. Accept only the exact same bytes.
    try { $winner = Get-RemoteObjectIdentity -Key $key } catch { $winner = $null }
    if ($winner -and $winner.Sha256 -eq $metadata.Hash) {
        Write-Host "[pre-push] Another worktree created the identical package: $location"
    } else {
        Write-Host "ERROR: Concurrent upload collision at immutable package path $location." -ForegroundColor Red
        $failures++
    }
}

if ($failures -gt 0) {
    Write-Host "[pre-push] Push blocked: $failures package reference(s) are unresolved." -ForegroundColor Red
    exit 1
}
Write-Host '[pre-push] PR package references are present in S3.'
exit 0
