<#
.SYNOPSIS
Download the Cimian command-line tools from a pinned windowsadmins/cimian
release and copy the ones a pipeline needs into a folder.

.DESCRIPTION
Cimian releases ship the admin tools in a CimianTools-<arch>.<version>.nupkg
asset, not as loose .exe files, so there is no
releases/latest/download/makecatalogs.exe to fetch. This resolves the nupkg
through GitHubRelease.ps1 (retries, rate-limit handling), opens it as the zip
it is, and copies the named tools out.

Pin -Tag to a release rather than following latest, so catalog behaviour only
changes through a reviewed edit to the pipeline. -Sha256 pins the nupkg itself:
the download is refused unless its hash matches, so a replaced release asset
cannot put a different binary on the agent. Bump both pins together, in every
pipeline that calls this. GitHub shows the digest for each asset:

    gh api repos/windowsadmins/cimian/releases/tags/<tag> --jq '.assets[] | [.name, .digest] | @tsv'

-ExpectedSigner adds an Authenticode check on each extracted tool (Windows
only). Use it when the tools you install are signed, for example a build you
re-sign and host yourself.

.EXAMPLE
./pipelines/scripts/Install-CimianTools.ps1 -Tag 2026.09.18.1356 -Sha256 e6824a09095e4d1f86cff99469bb96f49b5b597fdbbab157139e97b933b73f71 -Destination $env:RUNNER_TEMP/cimian -Tools makecatalogs.exe
#>
param(
    [Parameter(Mandatory)] [string] $Tag,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{64}$')] [string] $Sha256,
    [Parameter(Mandatory)] [string] $Destination,
    [string] $ExpectedSigner,
    [string[]] $Tools = @('makecatalogs.exe'),
    [ValidateSet('x64', 'arm64')] [string] $Architecture = 'x64'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GitHubRelease.ps1')

$work = Join-Path ([IO.Path]::GetTempPath()) "cimian-tools-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work -Force | Out-Null
New-Item -ItemType Directory -Path $Destination -Force | Out-Null

try {
    $got = Get-GitHubReleaseAsset `
        -Owner 'windowsadmins' `
        -Repo 'cimian' `
        -Tag $Tag `
        -AssetGlob "CimianTools-$Architecture*.nupkg" `
        -DestDir $work

    $actual = (Get-FileHash -LiteralPath $got.Path -Algorithm SHA256).Hash
    if ($actual -ne $Sha256.ToUpperInvariant()) {
        throw "SHA-256 mismatch on $($got.Name): expected $Sha256, got $actual. Refusing to install."
    }
    Write-Host "Verified SHA-256 of $($got.Name)"

    # A nupkg is a zip; Expand-Archive only insists on the extension.
    $zip = [IO.Path]::ChangeExtension($got.Path, '.zip')
    Copy-Item -LiteralPath $got.Path -Destination $zip -Force
    $extract = Join-Path $work 'extract'
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

    foreach ($tool in $Tools) {
        $hit = Get-ChildItem -Path $extract -Filter $tool -File -Recurse | Select-Object -First 1
        if (-not $hit) { throw "$tool not found in $($got.Name)" }
        if ($ExpectedSigner) {
            $sig = Get-AuthenticodeSignature -LiteralPath $hit.FullName
            if ($sig.Status -ne 'Valid') { throw "$tool signature is $($sig.Status), not Valid" }
            if ($sig.SignerCertificate.Subject -notlike "*$ExpectedSigner*") {
                throw "$tool is signed by '$($sig.SignerCertificate.Subject)', expected '$ExpectedSigner'"
            }
        }
        Copy-Item -LiteralPath $hit.FullName -Destination (Join-Path $Destination $tool) -Force
        Write-Host "Installed $tool from $($got.Name) ($($got.Tag))"
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
