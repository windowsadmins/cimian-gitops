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
changes through a reviewed edit to the pipeline. Bump the pin in every pipeline
that calls this at the same time.

.EXAMPLE
./pipelines/scripts/Install-CimianTools.ps1 -Tag 2026.09.18.1356 -Destination $env:RUNNER_TEMP/cimian -Tools makecatalogs.exe
#>
param(
    [Parameter(Mandatory)] [string] $Tag,
    [Parameter(Mandatory)] [string] $Destination,
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

    # A nupkg is a zip; Expand-Archive only insists on the extension.
    $zip = [IO.Path]::ChangeExtension($got.Path, '.zip')
    Copy-Item -LiteralPath $got.Path -Destination $zip -Force
    $extract = Join-Path $work 'extract'
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

    foreach ($tool in $Tools) {
        $hit = Get-ChildItem -Path $extract -Filter $tool -File -Recurse | Select-Object -First 1
        if (-not $hit) { throw "$tool not found in $($got.Name)" }
        Copy-Item -LiteralPath $hit.FullName -Destination (Join-Path $Destination $tool) -Force
        Write-Host "Installed $tool from $($got.Name) ($($got.Tag))"
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
