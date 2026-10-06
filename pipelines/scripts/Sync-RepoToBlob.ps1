<#
.SYNOPSIS
Sync the Cimian repo trees to an Azure Blob container with azcopy.

.DESCRIPTION
Run after `az login` as the pipeline identity (AzureCLI@2 in Azure DevOps,
azure/login in GitHub Actions). The identity needs Storage Blob Data
Contributor on the account.

azcopy is authorised with a user-delegation SAS minted from that login, valid
for two hours. Letting azcopy fetch its own token from the az CLI
(AZCOPY_AUTO_LOGIN_TYPE=AZCLI) is unreliable on Windows hosted agents, where
it intermittently fails with "unexpected end of JSON input". A user-delegation
SAS is signed by the identity's Entra token rather than the account key, so
there is still no stored secret, and it expires with the run.

Metadata trees mirror git exactly (--delete-destination=true). Packages and
the installers/packages source trees are only ever added to, because a
package another branch's pkgsinfo still uses must not vanish when main stops
referencing it.
#>
param(
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9]{3,24}$')] [string] $StorageAccount,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9-]{3,63}$')] [string] $Container,
    [Parameter(Mandatory)] [string] $RepoRoot,
    # Upload deployment/pkgs only, add-only. For a pipeline that imports
    # packages and commits their pkgsinfo: the packages must be in storage
    # before the commit that references them, and the metadata trees are
    # published later by push-to-production from the committed state.
    [switch] $PackagesOnly,
    [string] $DefaultBranch = 'main'
)

$ErrorActionPreference = 'Stop'

# Catalogs, manifests and pkgsinfo are what clients act on, so they are only
# ever published from the default branch: a run queued by hand on another
# branch must not be able to put unreviewed or unpromoted metadata in front
# of the fleet. -PackagesOnly uploads deployment/pkgs and nothing else, from
# any branch, since a package nothing references is inert. An unknown ref
# fails closed.
$ref = if ($env:GITHUB_REF) { $env:GITHUB_REF } elseif ($env:BUILD_SOURCEBRANCH) { $env:BUILD_SOURCEBRANCH } else { '' }
if (-not $PackagesOnly -and $ref -ne "refs/heads/$DefaultBranch") {
    throw "Refusing to publish repo metadata from '$ref'; only refs/heads/$DefaultBranch may. Use -PackagesOnly to upload packages alone."
}

$expiry = (Get-Date).ToUniversalTime().AddHours(2).ToString("yyyy-MM-ddTHH:mm'Z'")
$sas = az storage container generate-sas --account-name $StorageAccount --name $Container `
    --permissions racwdl --expiry $expiry --auth-mode login --as-user -o tsv
if ($LASTEXITCODE -ne 0 -or -not $sas) { throw 'Could not mint a user-delegation SAS; check the identity has Storage Blob Data Contributor.' }
if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::add-mask::$sas" } else { Write-Host "##vso[task.setsecret]$sas" }

$base = "https://$StorageAccount.blob.core.windows.net/$Container"

function Sync([string] $Source, [string] $Dest, [bool] $Mirror) {
    $src = Join-Path $RepoRoot $Source
    if (-not (Test-Path $src)) { Write-Host "Skipping $Source (not in this repo)"; return }
    $del = if ($Mirror) { 'true' } else { 'false' }
    azcopy sync $src "$base/$Dest`?$sas" --recursive --delete-destination=$del
    if ($LASTEXITCODE -ne 0) { throw "azcopy sync $Source failed ($LASTEXITCODE)" }
}

if ($PackagesOnly) {
    # Create-only: an existing package is never replaced, whatever is on disk.
    $src = Join-Path $RepoRoot 'deployment/pkgs'
    if (-not (Test-Path $src)) { Write-Host 'No packages to upload'; return }
    azcopy copy (Join-Path $src '*') "$base/deployment/pkgs`?$sas" --recursive --overwrite=false
    if ($LASTEXITCODE -ne 0) { throw "azcopy copy of packages failed ($LASTEXITCODE)" }
    return
}

foreach ($d in 'catalogs', 'manifests', 'pkgsinfo', 'icons') {
    Sync "deployment/$d" "deployment/$d" $true
}
Sync 'deployment/pkgs' 'deployment/pkgs' $false
Sync 'installers' 'installers' $false
Sync 'packages' 'packages' $false
