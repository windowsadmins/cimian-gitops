# Tests for quality/lint. Plain PowerShell, no Pester needed. Needs git and
# the powershell-yaml module.
#   pwsh -NoProfile -File quality/tests/Test-Lints.ps1
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable powershell-yaml)) { throw 'powershell-yaml is required for these tests' }

$lint = Join-Path (Split-Path -Parent $PSScriptRoot) 'lint'
$categories = Join-Path $lint 'Test-Categories.ps1'
$structure = Join-Path $lint 'Test-PkgsinfoStructure.ps1'
$failed = 0

function Invoke-Case([string]$Name, [int]$Want, [scriptblock]$Run) {
    $out = & $Run 2>&1 | Out-String
    $got = $LASTEXITCODE
    if ($got -eq $Want) { Write-Host "ok   $Name" }
    else { Write-Host "FAIL $Name (exit $got, wanted $Want)`n$out"; $script:failed++ }
}

function New-Repo([hashtable]$Files) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("quality-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    foreach ($rel in $Files.Keys) {
        $p = Join-Path $root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
        Set-Content -LiteralPath $p -Value $Files[$rel] -Encoding UTF8
    }
    git -C $root init -q
    git -C $root add -A
    return $root
}

function Pkgsinfo([string]$Category, [string]$Catalogs = "- Development`n- Testing", [string]$Extra = '') {
    "name: App`nversion: 1.0.0`ncategory: $Category`ncatalogs:`n$Catalogs`n$Extra"
}

# ── Test-Categories ─────────────────────────────────────────────────────────
$repo = New-Repo @{
    'deployment/pkgsinfo/apps/Good.yaml'    = (Pkgsinfo 'Browsers')
    'deployment/pkgsinfo/apps/managed/Store.yaml' = "name: Store`nsource: microsoft_store"
}
Invoke-Case 'valid category passes, managed descriptor skipped' 0 { pwsh -NoProfile -File $categories -RepoRoot $repo }

$repo = New-Repo @{ 'deployment/pkgsinfo/apps/Bad.yaml' = (Pkgsinfo 'Browser') }
Invoke-Case 'unknown category fails' 1 { pwsh -NoProfile -File $categories -RepoRoot $repo }

$repo = New-Repo @{ 'deployment/pkgsinfo/apps/Old.yaml' = (Pkgsinfo 'Docs') }
Invoke-Case 'retired category fails' 1 { pwsh -NoProfile -File $categories -RepoRoot $repo }

$repo = New-Repo @{
    'deployment/pkgsinfo/apps/Bad.yaml'  = (Pkgsinfo 'Browser')
    'deployment/pkgsinfo/apps/Good.yaml' = (Pkgsinfo 'Browsers')
}
$scope = New-TemporaryFile
Set-Content -LiteralPath $scope -Value 'deployment/pkgsinfo/apps/Good.yaml'
Invoke-Case 'hook scope (-OnlyFile) ignores files outside the push' 0 { pwsh -NoProfile -File $categories -RepoRoot $repo -OnlyFile $scope }
Set-Content -LiteralPath $scope -Value 'deployment/pkgsinfo/apps/Bad.yaml'
Invoke-Case 'hook scope catches a bad file in the push' 1 { pwsh -NoProfile -File $categories -RepoRoot $repo -OnlyFile $scope }

$repo = New-Repo @{ 'packages/Thing/build-info.yaml' = "product:`n  name: Thing`n  version: 1.0" }
Invoke-Case 'build-info without a category fails' 1 { pwsh -NoProfile -File $categories -RepoRoot $repo }

$repo = New-Repo @{ 'pkgsinfo/apps/Good.yaml' = (Pkgsinfo 'Utilities') }
Invoke-Case '-PkgsinfoPath points at another folder' 0 { pwsh -NoProfile -File $categories -RepoRoot $repo -PkgsinfoPath pkgsinfo }

# ── Test-PkgsinfoStructure ──────────────────────────────────────────────────
$hash = 'a' * 64
$repo = New-Repo @{
    'p/Good.yaml' = (Pkgsinfo 'Utilities' "- Development`n- Testing`n- Staging" "installer:`n  location: \apps\App-1.0.msi`n  hash: $hash")
    'p/managed/Store.yaml' = "name: Store"
}
Invoke-Case 'well-formed pkgsinfo passes' 0 { pwsh -NoProfile -File $structure -Path (Join-Path $repo 'p') }

$repo = New-Repo @{ 'p/Gap.yaml' = (Pkgsinfo 'Utilities' "- Development`n- Production") }
Invoke-Case 'non-cumulative catalogs fail' 1 { pwsh -NoProfile -File $structure -Path (Join-Path $repo 'p') }

$repo = New-Repo @{ 'p/Typo.yaml' = (Pkgsinfo 'Utilities' "- Testng") }
Invoke-Case 'unknown catalog fails' 1 { pwsh -NoProfile -File $structure -Path (Join-Path $repo 'p') }

$repo = New-Repo @{ 'p/Walk.yaml' = (Pkgsinfo 'Utilities' "- Testing" "installer:`n  location: ..\..\secrets.txt`n  hash: $hash") }
Invoke-Case 'traversal in installer.location fails' 1 { pwsh -NoProfile -File $structure -Path (Join-Path $repo 'p') }

$repo = New-Repo @{ 'p/Hash.yaml' = (Pkgsinfo 'Utilities' "- Testing" "installer:`n  location: apps/App.msi`n  hash: abc") }
Invoke-Case 'malformed hash fails' 1 { pwsh -NoProfile -File $structure -Path (Join-Path $repo 'p') }

$repo = New-Repo @{ 'p/Arch.yaml' = (Pkgsinfo 'Utilities' "- Testing" "supported_architectures:`n- x86") }
Invoke-Case 'unsupported architecture fails' 1 { pwsh -NoProfile -File $structure -Path (Join-Path $repo 'p') }

if ($failed) { throw "$failed case(s) failed" }
Write-Host 'All lint cases passed.'
