<#
.SYNOPSIS
Install AutoPkg with Cimian support, point it at this repo, and run the
recipes in promotion/recipe_list.yaml.

.DESCRIPTION
Windows only. Uses the AutoPkg fork with the Cimian importer
(rodchristiansen/autopkg), run from a clone with the Python on PATH. AutoPkg
on Windows reads its preferences from %LOCALAPPDATA%\AutoPkg\config.json,
which this writes.

Everything it executes is pinned, because recipes run arbitrary download and
processing steps:

  - AutoPkg itself is checked out at -AutoPkgCommit, a reviewed 40-character
    SHA, and the checkout is verified.
  - Each recipe repo in recipe_list.yaml is written url@sha and checked out at
    that commit.
  - Python dependencies install from requirements-autopkg.txt with
    --require-hashes.
  - Recipes run only as overrides carrying ParentRecipeTrustInfo, with
    FAIL_RECIPES_WITHOUT_TRUST_INFO set, so a parent recipe that changed since
    its override was reviewed fails instead of running. Refresh trust with
    `autopkg update-trust-info <override>` after reading the diff.

Run this in a job that holds no write credentials. GitHub downloads use
AUTOPKG_GITHUB_TOKEN if set, which should be a read-only token, never the
job's own GITHUB_TOKEN.

New packages land in deployment/pkgs and new pkgsinfo in deployment/pkgsinfo.
Run promotion/stamp_metadata.py afterwards so the promoter knows they came
from AutoPkg, upload the packages, then commit.

Exits non-zero if any recipe failed, after every recipe has run.

.PARAMETER Recipes
Optional subset of identifiers. Defaults to every recipe in the list.
#>
param(
    [Parameter(Mandatory)] [string] $RepoRoot,
    [Parameter(Mandatory)] [string] $CimiimportPath,
    [string[]] $Recipes,
    [string] $WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'autopkg'),
    [string] $AutoPkgRepo = 'https://github.com/rodchristiansen/autopkg.git',
    # The add-cimian-support branch as reviewed. Bump deliberately.
    [ValidatePattern('^[0-9a-f]{40}$')] [string] $AutoPkgCommit = 'd868068e7559912d483f760f9696d3344ca9ac79'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path $RepoRoot).Path
$listFile = Join-Path $RepoRoot 'promotion/recipe_list.yaml'

# ── Read the recipe list (no YAML module on a stock agent; the format is flat) ─
$repos = [System.Collections.Generic.List[string]]::new()
$listed = [System.Collections.Generic.List[string]]::new()
$section = $null
foreach ($line in Get-Content $listFile) {
    $clean = ($line -split '#', 2)[0].TrimEnd()
    if ($clean -match '^(repos|recipes):\s*$') { $section = $Matches[1]; continue }
    if ($clean -match '^\s+-\s+(\S+)\s*$') {
        if ($section -eq 'repos') { $repos.Add($Matches[1]) } elseif ($section -eq 'recipes') { $listed.Add($Matches[1]) }
    }
}
$run = if ($Recipes) { $Recipes } else { $listed }
if ($run.Count -eq 0) { throw "No recipes to run from $listFile" }
foreach ($r in $run) {
    if ($r -notmatch '^[A-Za-z0-9._-]+$') { throw "Recipe identifier '$r' has unexpected characters" }
}

# ── AutoPkg itself ───────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
function Get-PinnedRepo([string] $Url, [string] $Commit, [string] $Dest) {
    # autocrlf off: trust info hashes the recipe files byte for byte, and a
    # CRLF checkout would change every hash.
    if (-not (Test-Path (Join-Path $Dest '.git'))) {
        git -c core.autocrlf=false init --quiet $Dest
        git -C $Dest config core.autocrlf false
        git -C $Dest remote add origin $Url
    }
    git -C $Dest fetch --quiet --depth 1 origin $Commit
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch $Url at $Commit" }
    git -C $Dest checkout --quiet --force FETCH_HEAD
    $head = (git -C $Dest rev-parse HEAD).Trim()
    if ($head -ne $Commit) { throw "$Url checked out at $head, expected $Commit" }
}

$autopkgDir = Join-Path $WorkDir 'autopkg'
Get-PinnedRepo $AutoPkgRepo $AutoPkgCommit $autopkgDir
python -m pip install --quiet --require-hashes --only-binary=:all: -r (Join-Path $RepoRoot 'promotion/requirements-autopkg.txt')
if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }
$autopkg = Join-Path $autopkgDir 'Code/autopkg'

# ── Recipe repos, named the way AutoPkg names them (com.github.owner.repo) ───
$repoDir = Join-Path $WorkDir 'RecipeRepos'
New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
foreach ($entry in $repos) {
    if ($entry -notmatch '^(https://github\.com/([\w.-]+)/([\w.-]+?)(\.git)?)@([0-9a-f]{40})$') {
        throw "Recipe repo '$entry' must be https://github.com/<owner>/<repo>.git@<40-character commit>"
    }
    Get-PinnedRepo $Matches[1] $Matches[5] (Join-Path $repoDir "com.github.$($Matches[2]).$($Matches[3])")
}

# ── Preferences ──────────────────────────────────────────────────────────────
$overrides = Join-Path $RepoRoot 'promotion/RecipeOverrides'
$prefs = [ordered]@{
    CIMIAN_REPO                   = $RepoRoot
    RECIPE_SEARCH_DIRS            = @($repoDir) + @(Get-ChildItem $repoDir -Directory | ForEach-Object FullName) + @($overrides)
    RECIPE_OVERRIDE_DIRS          = @($overrides)
    RECIPE_REPO_DIR               = $repoDir
    CACHE_DIR                     = Join-Path $WorkDir 'Cache'
    CIMIAN_PKGINFO_FILE_EXTENSION = 'yaml'
    CIMIIMPORT_PATH               = $CimiimportPath
    CURL_PATH                     = "$env:SystemRoot\System32\curl.exe"
    FAIL_RECIPES_WITHOUT_TRUST_INFO = $true
}
# GitHub-hosted downloads share the agent's anonymous 60/hour quota without a
# token. Only ever a read-only one: recipes can read their preferences.
if ($env:AUTOPKG_GITHUB_TOKEN) { $prefs.GITHUB_TOKEN = $env:AUTOPKG_GITHUB_TOKEN }
$prefsDir = Join-Path $env:LOCALAPPDATA 'AutoPkg'
New-Item -ItemType Directory -Force -Path $prefsDir | Out-Null
$prefs | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $prefsDir 'config.json') -Encoding UTF8

# ── Run ──────────────────────────────────────────────────────────────────────
$report = Join-Path $WorkDir 'report.plist'
Write-Host "Running $($run.Count) recipe(s)"
python $autopkg run --report-plist $report -v @run
$code = $LASTEXITCODE
if ($code -ne 0) { Write-Host "AutoPkg exited $code; at least one recipe failed. Imports that succeeded are kept." }
exit $code
