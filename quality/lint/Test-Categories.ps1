<#
.SYNOPSIS
Assert that every pkgsinfo and every build-info carries a category from the
agreed vocabulary.

.DESCRIPTION
Two places decide what category a package ends up with, and both are checked:

  deployment\pkgsinfo   what is live today, and what makecatalogs reads
  packages\*\build-info.yaml   what cimiimport writes for a package built here

The build-info half is the one that goes wrong quietly. cimiimport carries
metadata forward from the newest existing pkgsinfo, so an established package
keeps its category whether or not build-info names one. A package being built
for the FIRST time has nothing to carry forward -- if its build-info has no
category, the pkgsinfo lands without one and nothing complains.

autopkg-sourced packages take a third path, cimian_info_category in the recipe
override, which is a processor argument and therefore actually consumed. Those
are checked too where an override imports.

Microsoft Store app descriptors under pkgsinfo\apps\managed are owned by the
Intune layer, carry no category, and are skipped.

Exits 1 if anything fails, so this can gate a push. The pre-push hook calls
it with -RepoRoot and -OnlyFile; a manual or CI run sweeps everything.

.EXAMPLE
pwsh -File quality/lint/Test-Categories.ps1

.EXAMPLE
pwsh -File quality/lint/Test-Categories.ps1 -PkgsinfoPath pkgsinfo
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')),
    # Repo-relative folder holding pkgsinfo. Cimian repos keep it under
    # deployment/; this sample repo keeps its examples at pkgsinfo/.
    [string]$PkgsinfoPath = 'deployment/pkgsinfo',
    # Restrict the check to these repo-relative paths. The pre-push hook passes
    # the files the push actually changes: a gate that judges the whole tree
    # blocks every branch older than a category rename over state the person
    # pushing did not cause. Omit it to sweep everything, which is what a
    # manual or CI run wants.
    [string[]]$Only,
    # Same thing, one path per line in a file. This is what the pre-push hook
    # uses: pwsh -File passes every argument as a separate string, so it cannot
    # bind an array to -Only at all -- `-Only a b c` makes b and c positional and
    # the script dies with "a positional parameter cannot be found", exit 1,
    # push blocked. A file has no array or quoting problem.
    [string]$OnlyFile,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# Exit 0 with a warning, never 1, when this cannot run. A developer's push must
# not be blocked because their machine is missing a module -- that is not a bad
# category, and a gate that cannot tell the difference is worse than no gate.
try {
    Import-Module powershell-yaml -Force
} catch {
    Write-Host "SKIPPED: powershell-yaml is not available, cannot validate categories ($($_.Exception.Message))" -ForegroundColor Yellow
    exit 0
}

. (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'common') 'Category-Vocabulary.ps1')

# Scope on whether -Only was PASSED, not on whether it looks non-empty. In
# PowerShell both @() and @('') are falsy, so testing the value itself turned an
# explicitly empty scope into a full-tree sweep -- exactly the behaviour that
# blocks a push over files the person never touched.
$scoped = $PSBoundParameters.ContainsKey('Only') -or $PSBoundParameters.ContainsKey('OnlyFile')
$rawScope = @()
if ($PSBoundParameters.ContainsKey('Only'))     { $rawScope += $Only }
if ($PSBoundParameters.ContainsKey('OnlyFile')) {
    if (Test-Path -LiteralPath $OnlyFile) { $rawScope += @(Get-Content -LiteralPath $OnlyFile) }
}
$wantedPaths = @($rawScope | ForEach-Object { "$_".Trim() } | Where-Object { $_ } |
    ForEach-Object { $_.Replace('\', '/') })

$failures = New-Object System.Collections.Generic.List[string]
$checked = 0

function Get-TrackedFiles {
    <#
    .SYNOPSIS
    Files git tracks in this repository, under one path.

    .DESCRIPTION
    Deliberately not Get-ChildItem -Recurse. packages/ may hold git
    submodules, each a separate project with its own build-info.yaml that has
    no category and never will. Recursing would find those, plus copies inside
    their .worktrees and build output, and block pushes on packages this repo
    does not own. It would also let a developer's untracked scratch file block
    a push.

    The parent repo tracks a submodule as a single gitlink, so ls-files lists
    none of their contents -- which is exactly the set that should be checked.
    #>
    param([string]$RelativePath)

    Push-Location $RepoRoot
    try {
        $output = & git ls-files -- $RelativePath 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        $tracked = @($output | Where-Object { $_ })
        if ($scoped) { $tracked = @($tracked | Where-Object { $wantedPaths -contains $_ }) }
        return @($tracked | ForEach-Object { Join-Path $RepoRoot $_ })
    } finally { Pop-Location }
}

function Read-Yaml([string]$Path) {
    ConvertFrom-Yaml (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

# --- pkgsinfo -------------------------------------------------------------
# Every file, not *.yaml: makecatalogs reads whatever is in the tree, so an
# extensionless or .plist manifest would otherwise be checked by nobody. Munki
# had exactly that, and it kept a retired category live for months.
function Test-ManagedDescriptor([string]$Path) {
    $Path.Replace('\', '/') -match '/managed/'
}

foreach ($path in Get-TrackedFiles $PkgsinfoPath) {
    if ([IO.Path]::GetFileName($path).StartsWith('.')) { continue }
    if (Test-ManagedDescriptor $path) { continue }
    $checked++
    try { $data = Read-Yaml $path }
    catch {
        $failures.Add("$path could not be parsed: $($_.Exception.Message)")
        continue
    }
    $problem = Test-CimianCategory ([string]$data['category'])
    if ($problem) { $failures.Add("$path $problem") }
}

# --- scripts that name a cache folder ------------------------------------
# DownloadService.GetCachePath caches a download at <cache>\<category>\<file>,
# lowercasing the category and turning spaces into underscores. The category is
# therefore part of an on-disk path, and renaming it MOVES the cached installer.
#
# A postinstall script that hardcodes the cache folder of an old category
# reads a folder the client no longer writes after a rename, and every install
# fails at "installer not found". Nothing else in the repo connects the two.
#
# The folder name is often not adjacent to the cache root in the source -- a
# script may build $CacheDir on one line and Join-Path "docs\..." on the next -- so
# this looks for a category-named segment ANYWHERE in a pkgsinfo that mentions
# the cache, rather than trying to match one path expression. Only a segment that
# IS a category name is judged, so a script that makes its own folder
# (Cache\OpenSSH, Cache\dev) is left alone.
$categoryFolders = @{}
foreach ($value in @(Get-CimianCategories) + @((Get-CimianRetiredCategories).Keys)) {
    $categoryFolders[$value.Replace(' ', '_').ToLowerInvariant()] = $value
}
$cacheRootPattern = [regex]'(?i)ManagedInstalls[\\/]+Cache'
$segmentPattern   = [regex]'(?i)["''\\/]([A-Za-z0-9_]+)[\\/]'

foreach ($path in Get-TrackedFiles $PkgsinfoPath) {
    if ([IO.Path]::GetFileName($path).StartsWith('.')) { continue }
    if (Test-ManagedDescriptor $path) { continue }
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if (-not $cacheRootPattern.IsMatch($text)) { continue }

    try { $data = Read-Yaml $path } catch { continue }
    $own = ([string]$data['category']).Replace(' ', '_').ToLowerInvariant()

    $reported = @{}
    foreach ($match in $segmentPattern.Matches($text)) {
        $segment = $match.Groups[1].Value.ToLowerInvariant()
        if (-not $categoryFolders.ContainsKey($segment)) { continue }
        if ($segment -eq $own -or $reported.ContainsKey($segment)) { continue }
        $reported[$segment] = $true
        $failures.Add("$path a script names the cache folder '$segment' but this item's category is '$($data['category'])', so Cimian caches its payload under '$own' - the install will not find it")
    }
}

# --- build-info -----------------------------------------------------------
# Two schemas exist: most nest under `product:`, some are flat. Accept either.
$buildInfos = @(Get-TrackedFiles 'packages') + @(Get-TrackedFiles 'installers')
foreach ($path in ($buildInfos | Where-Object { [IO.Path]::GetFileName($_) -eq 'build-info.yaml' })) {
    $checked++
    try { $data = Read-Yaml $path }
    catch {
        $failures.Add("$path could not be parsed: $($_.Exception.Message)")
        continue
    }
    $category = if ($data['product']) { [string]$data['product']['category'] } else { [string]$data['category'] }
    $problem = Test-CimianCategory $category
    if ($problem) {
        $failures.Add("$path $problem (a first build of this package would import with no category)")
    }
}

# --- autopkg recipe overrides --------------------------------------------
$overrides = @(Get-TrackedFiles 'deployment/autopkg/RecipeOverrides') + @(Get-TrackedFiles 'promotion/RecipeOverrides')
foreach ($path in ($overrides | Where-Object { $_ -like '*.yaml' })) {
    try { $data = Read-Yaml $path } catch { continue }
    $category = $null
    $imports = $false
    foreach ($step in @($data['Process'])) {
        if (-not $step) { continue }
        $arguments = $step['Arguments']
        if (-not $arguments) { continue }
        if ($arguments['cimian_info_category']) { $category = [string]$arguments['cimian_info_category'] }
        if ($arguments['cimian_subdirectory']) { $imports = $true }
    }
    # A download-only recipe writes no pkgsinfo and needs no category.
    if (-not $imports -and -not $category) { continue }
    $checked++
    $problem = Test-CimianCategory $category
    if ($problem) { $failures.Add("$path $problem") }
}

foreach ($failure in ($failures | Sort-Object)) { Write-Host $failure -ForegroundColor Red }

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) of $checked manifests failed the category check." -ForegroundColor Red
    exit 1
}

if (-not $Quiet) {
    $scope = if ($scoped) { " of the $($wantedPaths.Count) path(s) in this push" } else { '' }
    Write-Host "$checked manifests checked$scope, all categories valid." -ForegroundColor Green
}
exit 0
