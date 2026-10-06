# Dot-source from a pipeline step:  . "$PWD/pipelines/scripts/GitHubRelease.ps1"
#
# One GitHub Releases client for every pipeline that pulls a published asset
# (the Cimian tools, the BootstrapMate MSI). It exists because the obvious
# "Invoke-RestMethod releases/latest, glob the assets" one-liner fails in two
# ways on hosted agents:
#
#   1. Anonymous api.github.com calls share a 60/hour quota per source IP, and
#      hosted agents share IPs. A 403 rate limit mid-run fails the job with
#      nothing to retry.
#   2. A release is "latest" the moment it is published, before its CI has
#      finished uploading assets. Fetching in that window finds the tag but not
#      the asset. With -Tag latest this falls back to the newest complete
#      release instead of failing.
#
# Auth: set GITHUB_TOKEN in the step env. A fine-grained token with public-repo
# read is enough and lifts the quota to 5,000/hour. No token means anonymous
# calls, still retried.

Set-StrictMode -Version Latest
$script:WarnedAnonymous = $false

function Write-PipelineWarning([string] $Message) {
    # Same call from Azure Pipelines and GitHub Actions.
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::warning::$Message" }
    else { Write-Host "##vso[task.logissue type=warning]$Message" }
}

function Get-GitHubAuthHeaders {
    $h = @{ 'User-Agent' = 'cimian-gitops-pipelines'; 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $tok = $env:GITHUB_TOKEN
    # An unset pipeline variable arrives as its own macro, not as empty.
    if ($tok -and -not $tok.StartsWith('$(')) { $h['Authorization'] = "Bearer $tok" }
    elseif (-not $script:WarnedAnonymous) {
        # Say so once: a 403 rate limit otherwise looks like a GitHub outage.
        $script:WarnedAnonymous = $true
        Write-PipelineWarning "GITHUB_TOKEN is not set; GitHub API calls are anonymous and share 60/hour per agent IP"
    }
    return $h
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [int] $MaxAttempts = 5
    )
    $delays = @(5, 15, 45, 90, 120)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Headers (Get-GitHubAuthHeaders) -TimeoutSec 60
        } catch {
            $code = $null
            try { $code = [int] $_.Exception.Response.StatusCode } catch {}
            $retryAfter = $null
            try { $retryAfter = [int] $_.Exception.Response.Headers['Retry-After'] } catch {}
            $reset = $null
            try { $reset = [int64] $_.Exception.Response.Headers['X-RateLimit-Reset'] } catch {}
            $remaining = $null
            try { $remaining = [int] $_.Exception.Response.Headers['X-RateLimit-Remaining'] } catch {}

            $transient = ($code -in 403, 429, 500, 502, 503, 504) -or ($null -eq $code)
            if ($code -eq 403 -and $null -ne $remaining -and $remaining -gt 0) { $transient = $false }
            if (-not $transient -or $attempt -eq $MaxAttempts) { throw }

            $wait = $delays[[math]::Min($attempt - 1, $delays.Count - 1)]
            if ($retryAfter) { $wait = [math]::Max($wait, $retryAfter) }
            elseif ($reset) {
                $untilReset = $reset - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                if ($untilReset -gt 0 -and $untilReset -le 300) { $wait = [math]::Max($wait, $untilReset + 2) }
            }
            $why = if ($code) { "HTTP $code" } else { $_.Exception.Message }
            Write-Host "GitHub API $why on $Uri (attempt $attempt/$MaxAttempts); retrying in ${wait}s"
            Start-Sleep -Seconds $wait
        }
    }
}

function Get-GitHubRelease {
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [string] $Tag = 'latest'
    )
    $base = "https://api.github.com/repos/$Owner/$Repo/releases"
    if ($Tag -eq 'latest') { return Invoke-GitHubApi -Uri "$base/latest" }
    return Invoke-GitHubApi -Uri "$base/tags/$Tag"
}

function Get-GitHubReleaseAsset {
    <#
    .SYNOPSIS
    Resolve one release asset by glob and download it to DestDir.

    Returns @{ Path; Name; Size; Tag; Version; Release }.
    With -Tag latest and no matching asset on the latest release (assets still
    uploading, or a release that never shipped this arch), walks back through
    the most recent published releases and takes the newest one that has it,
    with a pipeline warning naming the tag it settled on. A pinned -Tag never
    falls back: a pin that does not resolve is a real error.
    #>
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [string] $Tag = 'latest',
        [Parameter(Mandatory)] [string] $AssetGlob,
        [Parameter(Mandatory)] [string] $DestDir,
        [int] $FallbackDepth = 10,
        [int] $TimeoutSec = 300
    )
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

    $release = Get-GitHubRelease -Owner $Owner -Repo $Repo -Tag $Tag
    $hits = @($release.assets | Where-Object { $_.name -like $AssetGlob })

    if ($hits.Count -eq 0 -and $Tag -eq 'latest') {
        $wanted = $release.tag_name
        $candidates = Invoke-GitHubApi -Uri "https://api.github.com/repos/$Owner/$Repo/releases?per_page=$FallbackDepth"
        foreach ($c in @($candidates)) {
            if ($c.draft -or $c.prerelease -or $c.tag_name -eq $wanted) { continue }
            $h = @($c.assets | Where-Object { $_.name -like $AssetGlob })
            if ($h.Count -gt 0) {
                Write-PipelineWarning "$Owner/$Repo@$wanted has no asset matching '$AssetGlob' (assets: $(@($release.assets.name) -join ', ')); using $($c.tag_name) instead"
                $release = $c; $hits = $h
                break
            }
        }
    }

    if ($hits.Count -eq 0) { throw "No assets matched '$AssetGlob' in $Owner/$Repo@$($release.tag_name) (assets: $(@($release.assets.name) -join ', '))" }
    if ($hits.Count -gt 1) { throw "Glob '$AssetGlob' ambiguous in $Owner/$Repo@$($release.tag_name) ($($hits.Count) hits: $(@($hits.name) -join ', '))" }

    $asset = $hits[0]
    $version = if ($asset.name -match '(\d+\.\d+\.\d+(?:\.\d+)?)') { $Matches[1] } else { $release.tag_name -replace '^v', '' }
    $destPath = Join-Path $DestDir $asset.name
    Write-Host "Downloading $($asset.browser_download_url) -> $destPath"

    $delays = @(5, 15, 45)
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $destPath -Headers (Get-GitHubAuthHeaders) -MaximumRedirection 5 -UseBasicParsing -TimeoutSec $TimeoutSec
            if ((Get-Item $destPath).Length -ne $asset.size) { throw "Size mismatch on $($asset.name): got $((Get-Item $destPath).Length), release says $($asset.size)" }
            break
        } catch {
            if (Test-Path $destPath) { Remove-Item -Force $destPath -ErrorAction SilentlyContinue }
            if ($attempt -eq 4) { throw }
            $wait = $delays[$attempt - 1]
            Write-Host "Download of $($asset.name) failed ($($_.Exception.Message)); retrying in ${wait}s"
            Start-Sleep -Seconds $wait
        }
    }

    return [pscustomobject]@{
        Path    = $destPath
        Name    = $asset.name
        Size    = $asset.size
        Tag     = $release.tag_name
        Version = $version
        Release = $release
    }
}
