<#
.SYNOPSIS
Install AutoPkg with Cimian support, point it at this repo, and run the
recipes in promotion/recipe_list.yaml.

.DESCRIPTION
Windows only. Uses the AutoPkg fork with the Cimian importer
(rodchristiansen/autopkg, branch add-cimian-support), run from a clone with
the Python on PATH. AutoPkg on Windows reads its preferences from
%LOCALAPPDATA%\AutoPkg\config.json, which this writes.

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
    [string] $AutoPkgBranch = 'add-cimian-support'
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
$autopkgDir = Join-Path $WorkDir 'autopkg'
if (-not (Test-Path $autopkgDir)) {
    git clone --quiet --depth 1 --branch $AutoPkgBranch $AutoPkgRepo $autopkgDir
    if ($LASTEXITCODE -ne 0) { throw 'Could not clone AutoPkg' }
}
python -m pip install --quiet pyyaml appdirs certifi lxml generateDS
if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }
$autopkg = Join-Path $autopkgDir 'Code/autopkg'

# ── Recipe repos, named the way AutoPkg names them (com.github.owner.repo) ───
$repoDir = Join-Path $WorkDir 'RecipeRepos'
New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
foreach ($url in $repos) {
    if ($url -notmatch '^https://github\.com/([\w.-]+)/([\w.-]+?)(\.git)?$') { throw "Unsupported recipe repo URL $url" }
    $dest = Join-Path $repoDir "com.github.$($Matches[1]).$($Matches[2])"
    if (Test-Path $dest) { git -C $dest pull --quiet --ff-only } else { git clone --quiet --depth 1 $url $dest }
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch $url" }
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
}
# GitHub-hosted downloads share the agent's anonymous 60/hour quota without one.
if ($env:GITHUB_TOKEN) { $prefs.GITHUB_TOKEN = $env:GITHUB_TOKEN }
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
