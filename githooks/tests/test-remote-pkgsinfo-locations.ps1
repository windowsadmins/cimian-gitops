# Add-RemotePkgsInfoLocation folds every origin branch's pkgsinfo locations
# into the keep-set, and reports unavailable when there are no remote refs.
#   pwsh -NoProfile -File githooks/tests/test-remote-pkgsinfo-locations.ps1
$ErrorActionPreference = 'Stop'
$hookDir = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $hookDir 'lib') 'common.ps1')

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("cimian-remote-refs-test-" + [guid]::NewGuid())
$sep = [IO.Path]::DirectorySeparatorChar
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd($sep) + $sep
$resolvedFixture = [IO.Path]::GetFullPath($fixture)
if (-not $resolvedFixture.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create test fixture outside the temp directory: $resolvedFixture"
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

try {
    New-Item -ItemType Directory -Path "$fixture/deployment/pkgsinfo/apps" -Force | Out-Null
    git -C $fixture init -q -b main
    git -C $fixture config user.email hooks@example.invalid
    git -C $fixture config user.name 'Hook Test'
    git -C $fixture config core.hooksPath .disabled-hooks
    git -C $fixture config commit.gpgSign false

    @"
name: Main
installer:
  location: apps/Main.msi
"@ | Set-Content -LiteralPath "$fixture/deployment/pkgsinfo/apps/Main.yaml" -NoNewline
    git -C $fixture add deployment/pkgsinfo/apps/Main.yaml
    git -C $fixture commit -qm main
    $mainSha = (git -C $fixture rev-parse HEAD).Trim()

    git -C $fixture switch -q -c package-branch
    @"
name: Branch
installer:
  location: apps/BranchOnly.msi
"@ | Set-Content -LiteralPath "$fixture/deployment/pkgsinfo/apps/Branch.yaml" -NoNewline
    git -C $fixture add deployment/pkgsinfo/apps/Branch.yaml
    git -C $fixture commit -qm branch
    $branchSha = (git -C $fixture rev-parse HEAD).Trim()
    git -C $fixture switch -q main

    git -C $fixture update-ref refs/remotes/origin/main $mainSha
    git -C $fixture update-ref refs/remotes/origin/package-branch $branchSha

    $canonical = @{ 'apps/Main.msi' = $true }
    $result = Add-RemotePkgsInfoLocation -CanonicalSet $canonical -RepoRoot $fixture
    Assert-True $result.Available 'Expected origin refs to be available.'
    Assert-True ($result.RemoteRefCount -eq 2) "Expected 2 origin refs, got $($result.RemoteRefCount)."
    Assert-True ($result.AddedCount -eq 1) "Expected 1 added location, got $($result.AddedCount)."
    Assert-True $canonical.ContainsKey('apps/BranchOnly.msi') 'Remote-only package location was not added.'

    git -C $fixture update-ref -d refs/remotes/origin/main
    git -C $fixture update-ref -d refs/remotes/origin/package-branch
    $withoutRefs = Add-RemotePkgsInfoLocation -CanonicalSet @{} -RepoRoot $fixture
    Assert-True (-not $withoutRefs.Available) 'Expected cleanup to fail safe without origin refs.'

    Write-Host 'PASS: remote pkgsinfo locations are unioned and missing refs fail safe.'
}
finally {
    if (Test-Path -LiteralPath $resolvedFixture) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
