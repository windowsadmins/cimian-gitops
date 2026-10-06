#Requires -Version 5.1
# HOOK_VERSION = '2026.10.06'
#
# ──────────────────────────────────────────────────────────────────────────────
#  pre-push-pr-packages.ps1  –  package check for pushes that are not to main (Azure)
#
#  A pull request adds pkgsinfo whose installer must be in blob storage before
#  the merge, or the catalog build on main points clients at a 404. Branches
#  do not get the full main-only sync and orphan prune, so this does the one
#  thing a branch push needs, for the pkgsinfo the push actually adds or
#  changes:
#
#    • nopkg items are skipped: they have no payload to upload or hash.
#    • A local package must match the pkgsinfo's size and SHA-256.
#    • Package paths are immutable. A blob already at the path must carry the
#      same SHA-256 (blob metadata `sha256`); a different one blocks the push
#      rather than overwrite what main may already serve.
#    • A missing blob is created with azcopy --overwrite=false and the SHA-256
#      in its metadata, so two worktrees racing to upload the same path either
#      agree byte for byte or the loser is blocked.
#    • A legacy blob with no sha256 metadata is backfilled only when its
#      identity is proven: origin/main records the same hash for the path, or
#      the blob's Content-MD5 matches the local file.
#    • When Front Door settings are given, the new path is purged so a 404
#      cached before the upload does not linger.
#
#  Called by pre-push.ps1 with the pushed ref lines, after the shared lock is
#  held. Reads them from stdin when run on its own.
#
#  Config (env): CIMIAN_STORAGE_ACCOUNT, CIMIAN_CONTAINER, and optionally
#  CIMIAN_FD_RESOURCE_GROUP, CIMIAN_FD_PROFILE, CIMIAN_FD_ENDPOINT.
# ──────────────────────────────────────────────────────────────────────────────
param([string[]]$RefLines)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HookDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path (Join-Path (Join-Path $HookDir '..') 'lib') 'common.ps1')

$repoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { Write-Error 'Not inside a git repository'; exit 1 }
$repoRoot = $repoRoot.Trim()
$storageAccount = if ($env:CIMIAN_STORAGE_ACCOUNT) { $env:CIMIAN_STORAGE_ACCOUNT } else { 'yourstorageaccount' }
$container      = if ($env:CIMIAN_CONTAINER)       { $env:CIMIAN_CONTAINER }       else { 'cimian' }
$storageUrl = "https://$storageAccount.blob.core.windows.net/$container"
$zeroSha = '0000000000000000000000000000000000000000'
$commonDir = (git rev-parse --path-format=absolute --git-common-dir 2>$null)
$primaryRoot = if ($commonDir) { Split-Path -Parent $commonDir.Trim() } else { $repoRoot }
if (-not $PSBoundParameters.ContainsKey('RefLines')) { $RefLines = @(Get-PushRefLine) }

function Get-PushedPkgsInfo {
    $lines = @($RefLines)
    $files = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($line in $lines) {
        $parts = $line -split '\s+'
        if ($parts.Count -lt 4) { throw "Cannot parse pre-push ref: $line" }
        $localSha = $parts[1]
        $remoteSha = $parts[3]
        if ($localSha -eq $zeroSha) { continue }

        if ($remoteSha -eq $zeroSha) {
            $base = & git merge-base $localSha origin/main 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $base) {
                throw 'Cannot determine the branch point from origin/main.'
            }
            $range = "$($base.Trim())..$localSha"
        } else {
            $range = "$remoteSha..$localSha"
        }

        $changed = & git diff --diff-filter=ACMR --name-only $range -- deployment/pkgsinfo/ 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Cannot inspect pushed range $range." }
        foreach ($file in $changed) {
            if ($file) { [void]$files.Add($file.Trim()) }
        }
    }
    return @($files | Sort-Object)
}

function Test-NoPkgInstaller([string]$Content) {
    # A nopkg item is script-only: it has no installer payload, so there is
    # nothing to upload and nothing to hash. Requiring a location for one would
    # block every removal or remediation item.
    return [regex]::IsMatch($Content, '(?m)^\s*type:\s*[''"]?nopkg[''"]?\s*$')
}

function Get-PackageMetadata([string]$Path) {
    $content = Get-Content -LiteralPath $Path -Raw
    if (Test-NoPkgInstaller $content) { return 'nopkg' }
    $locationMatch = [regex]::Match($content, '(?m)^\s+location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$')
    if (-not $locationMatch.Success) { return $null }
    $hashMatch = [regex]::Match($content, '(?m)^\s+hash:\s*[''"]?([0-9a-fA-F]{64})[''"]?\s*$')
    $sizeMatch = [regex]::Match($content, '(?m)^\s+size:\s*(\d+)\s*$')
    return @{
        Location = $locationMatch.Groups[1].Value.Trim().TrimStart('/', '\').Replace('\', '/')
        Hash = if ($hashMatch.Success) { $hashMatch.Groups[1].Value.ToLowerInvariant() } else { '' }
        Size = if ($sizeMatch.Success) { [long]$sizeMatch.Groups[1].Value } else { 0 }
    }
}

function Get-RemoteBlobIdentity([string]$BlobPath) {
    $exists = & $script:AzPath storage blob exists --account-name $storageAccount --container-name $container `
        --name $BlobPath --auth-mode login --query exists -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not verify Azure blob $BlobPath." }
    if ($exists.Trim() -ne 'true') {
        return [pscustomobject]@{ Exists = $false; Sha256 = ''; Md5 = ''; ETag = '' }
    }

    $identityJson = & $script:AzPath storage blob show --account-name $storageAccount --container-name $container `
        --name $BlobPath --auth-mode login `
        --query '{sha256:metadata.sha256,md5:properties.contentSettings.contentMd5,etag:properties.etag}' `
        -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $identityJson) { throw "Could not read identity for Azure blob $BlobPath." }
    $identity = $identityJson | ConvertFrom-Json
    return [pscustomobject]@{
        Exists = $true
        Sha256 = if ($identity.sha256) { ([string]$identity.sha256).ToLowerInvariant() } else { '' }
        Md5 = if ($identity.md5) { [string]$identity.md5 } else { '' }
        ETag = if ($identity.etag) { [string]$identity.etag } else { '' }
    }
}

function Get-LocalContentMD5([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        return [Convert]::ToBase64String($md5.ComputeHash($stream))
    } finally {
        $md5.Dispose()
        $stream.Dispose()
    }
}

function Set-BlobSha256([string]$BlobPath, [string]$Sha256, [string]$ETag) {
    & $script:AzPath storage blob metadata update --account-name $storageAccount --container-name $container `
        --name $BlobPath --auth-mode login --metadata "sha256=$Sha256" --if-match $ETag `
        --only-show-errors | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-MainSha256ForLocation([string]$Location, [string]$PreferredPath = '') {
    if ($PreferredPath) {
        $preferredContent = (& git show "origin/main:$PreferredPath" 2>$null) -join "`n"
        if ($LASTEXITCODE -eq 0 -and $preferredContent) {
            $preferredLocation = [regex]::Match($preferredContent, '(?m)^\s+location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$')
            $preferredHash = [regex]::Match($preferredContent, '(?m)^\s+hash:\s*[''"]?([0-9a-fA-F]{64})[''"]?\s*$')
            if ($preferredLocation.Success -and $preferredHash.Success) {
                $normalized = $preferredLocation.Groups[1].Value.Trim().TrimStart('/', '\').Replace('\', '/') `
                    -replace '^deployment/pkgs/', '' -replace '^pkgs/', ''
                if ($normalized -eq $Location) { return $preferredHash.Groups[1].Value.ToLowerInvariant() }
            }
        }
    }

    $hits = @(& git grep -l -F -- $Location origin/main -- deployment/pkgsinfo/ 2>$null)
    if ($LASTEXITCODE -notin @(0, 1)) { throw "Could not inspect origin/main for $Location." }
    $hashes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($match in $hits) {
        $path = ([string]$match) -replace '^origin/main:', ''
        $content = (& git show "origin/main:$path" 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $content) { continue }
        $locationMatch = [regex]::Match($content, '(?m)^\s+location:\s*[''"]?([^''"\r\n]+?)[''"]?\s*$')
        $hashMatch = [regex]::Match($content, '(?m)^\s+hash:\s*[''"]?([0-9a-fA-F]{64})[''"]?\s*$')
        if (-not $locationMatch.Success -or -not $hashMatch.Success) { continue }
        $mainLocation = $locationMatch.Groups[1].Value.Trim().TrimStart('/', '\').Replace('\', '/') `
            -replace '^deployment/pkgs/', '' -replace '^pkgs/', ''
        if ($mainLocation -eq $Location) { [void]$hashes.Add($hashMatch.Groups[1].Value.ToLowerInvariant()) }
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

$az = Get-Command az -ErrorAction SilentlyContinue
if (-not $az) { Write-Host 'ERROR: Azure CLI is required to verify PR package references.' -ForegroundColor Red; exit 1 }
$script:AzPath = $az.Source
& $script:AzPath account get-access-token --resource https://storage.azure.com --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'ERROR: Azure authentication is required to verify PR package references.' -ForegroundColor Red
    Write-Host 'Run: az login   (add --tenant <tenant-id> if your account spans tenants)'
    exit 1
}

$env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI'
$failures = 0

foreach ($relativePkgsInfo in $pkgsInfoFiles) {
    $pkgsInfoPath = Join-Path $repoRoot ($relativePkgsInfo -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $pkgsInfoPath -PathType Leaf)) { continue }
    $metadata = Get-PackageMetadata -Path $pkgsInfoPath
    if ($metadata -is [string] -and $metadata -eq 'nopkg') {
        Write-Host "SKIP:  $relativePkgsInfo is nopkg (script-only, no payload)." -ForegroundColor DarkGray
        continue
    }
    if (-not $metadata) {
        Write-Host "ERROR: $relativePkgsInfo has no installer location." -ForegroundColor Red
        $failures++
        continue
    }
    if ($metadata.Hash -notmatch '^[0-9a-f]{64}$') {
        Write-Host "ERROR: $relativePkgsInfo has no valid SHA-256 installer hash." -ForegroundColor Red
        $failures++
        continue
    }

    $location = $metadata.Location -replace '^deployment/pkgs/', '' -replace '^pkgs/', ''
    $packageRelativePath = "deployment/pkgs/$location" -replace '/', [IO.Path]::DirectorySeparatorChar
    $localPath = Join-Path $repoRoot $packageRelativePath
    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf) -and $primaryRoot -ne $repoRoot) {
        $primaryPath = Join-Path $primaryRoot $packageRelativePath
        if (Test-Path -LiteralPath $primaryPath -PathType Leaf) { $localPath = $primaryPath }
    }
    $blobPath = "deployment/pkgs/$location"

    $hasLocalPackage = Test-Path -LiteralPath $localPath -PathType Leaf
    if ($hasLocalPackage) {
        $file = Get-Item -LiteralPath $localPath
        $localSizeKb = [long][math]::Round($file.Length / 1024)
        if ($metadata.Size -gt 0 -and [math]::Abs($localSizeKb - $metadata.Size) -gt 1) {
            Write-Host "ERROR: Size mismatch for $location (pkgsinfo $($metadata.Size) KB, local $localSizeKb KB)." -ForegroundColor Red
            $failures++
            continue
        }
        $actualHash = (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $metadata.Hash) {
            Write-Host "ERROR: SHA-256 mismatch for $location." -ForegroundColor Red
            $failures++
            continue
        }
    }

    try {
        $remote = Get-RemoteBlobIdentity -BlobPath $blobPath
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
        continue
    }

    if ($remote.Exists) {
        if ($remote.Sha256 -eq $metadata.Hash) {
            Write-Host "[pre-push] Immutable package already exists in Azure: $location"
            continue
        }
        if ($remote.Sha256) {
            Write-Host "ERROR: Refusing to overwrite immutable package path $location." -ForegroundColor Red
            Write-Host "  Azure SHA-256: $($remote.Sha256)"
            Write-Host "  pkgsinfo SHA-256: $($metadata.Hash)"
            $failures++
            continue
        }
        if (-not $hasLocalPackage) {
            try { $mainHash = Get-MainSha256ForLocation -Location $location -PreferredPath $relativePkgsInfo } catch { $mainHash = '' }
            if ($mainHash -eq $metadata.Hash -and $remote.ETag -and
                (Set-BlobSha256 -BlobPath $blobPath -Sha256 $metadata.Hash -ETag $remote.ETag)) {
                Write-Host "[pre-push] Backfilled SHA-256 from origin/main for legacy blob: $location"
            } else {
                Write-Host "ERROR: Azure blob $location predates SHA-256 metadata and no local package is available to prove its identity." -ForegroundColor Red
                $failures++
            }
            continue
        }

        try { $mainHash = Get-MainSha256ForLocation -Location $location -PreferredPath $relativePkgsInfo } catch { $mainHash = '' }
        if ($mainHash -eq 'conflict' -or ($mainHash -and $mainHash -ne $metadata.Hash)) {
            Write-Host "ERROR: origin/main assigns a different SHA-256 identity to $location." -ForegroundColor Red
            $failures++
            continue
        }
        $localMd5 = Get-LocalContentMD5 -Path $localPath
        $identityProven = ($mainHash -eq $metadata.Hash) -or ($remote.Md5 -and $remote.Md5 -eq $localMd5)
        if (-not $identityProven -or -not $remote.ETag) {
            Write-Host "ERROR: Existing blob $location has no SHA-256 identity and its MD5 cannot be proven equal." -ForegroundColor Red
            $failures++
            continue
        }
        if (Set-BlobSha256 -BlobPath $blobPath -Sha256 $metadata.Hash -ETag $remote.ETag) {
            Write-Host "[pre-push] Backfilled SHA-256 metadata for legacy blob: $location"
            continue
        }

        try { $afterBackfill = Get-RemoteBlobIdentity -BlobPath $blobPath } catch { $afterBackfill = $null }
        if ($afterBackfill -and $afterBackfill.Sha256 -eq $metadata.Hash) {
            Write-Host "[pre-push] Another worktree backfilled the identical package: $location"
        } else {
            Write-Host "ERROR: Blob $location changed while its identity was being backfilled." -ForegroundColor Red
            $failures++
        }
        continue
    }

    if ($hasLocalPackage) {
        $azcopy = Get-Command azcopy -ErrorAction SilentlyContinue
        if (-not $azcopy) {
            Write-Host "ERROR: azcopy is required to upload $localPath." -ForegroundColor Red
            $failures++
            continue
        }
        Write-Host "[pre-push] Creating immutable package required by $relativePkgsInfo`: $location"
        & $azcopy.Source copy $localPath "$storageUrl/$blobPath" --put-md5 --overwrite=false `
            "--metadata=sha256=$($metadata.Hash)" --log-level=ERROR --output-level=essential
        if ($LASTEXITCODE -eq 0) {
            & $script:AzPath storage blob update --account-name $storageAccount --container-name $container `
                --name $blobPath --auth-mode login `
                --content-cache-control 'public, max-age=31536000, immutable' --only-show-errors | Out-Null
            if ($LASTEXITCODE -ne 0) { $failures++; continue }
            if ($env:CIMIAN_FD_RESOURCE_GROUP -and $env:CIMIAN_FD_PROFILE -and $env:CIMIAN_FD_ENDPOINT) {
                & $script:AzPath afd endpoint purge --resource-group $env:CIMIAN_FD_RESOURCE_GROUP --profile-name $env:CIMIAN_FD_PROFILE `
                    --endpoint-name $env:CIMIAN_FD_ENDPOINT --no-wait --content-paths "/$blobPath" 2>$null | Out-Null
            }
            continue
        }

        # Another worktree may have won the create-only race. Accept only the
        # exact same bytes; a different identity remains a hard collision.
        try { $raceWinner = Get-RemoteBlobIdentity -BlobPath $blobPath } catch { $raceWinner = $null }
        if ($raceWinner -and $raceWinner.Sha256 -eq $metadata.Hash) {
            Write-Host "[pre-push] Another worktree created the identical package: $location"
        } else {
            Write-Host "ERROR: Concurrent upload collision at immutable package path $location." -ForegroundColor Red
            $failures++
        }
    } else {
        Write-Host "ERROR: $relativePkgsInfo references a package absent locally and in Azure:" -ForegroundColor Red
        Write-Host "  $localPath"
        $failures++
    }
}

if ($failures -gt 0) {
    Write-Host "[pre-push] Push blocked: $failures package reference(s) are unresolved." -ForegroundColor Red
    exit 1
}

Write-Host '[pre-push] PR package references are present in Azure.'
exit 0
