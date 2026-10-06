# Unit checks for the helpers in lib/common.ps1 and the installer-type rule in
# lib/pkgsinfo-lint.py. Needs git, and python3 with PyYAML for the lint case.
#   pwsh -NoProfile -File githooks/tests/test-common.ps1
$ErrorActionPreference = 'Stop'
$hookDir = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $hookDir 'lib') 'common.ps1')

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# Sidecars
Assert-True (Test-IsSidecarName 'apps/.DS_Store') '.DS_Store is a sidecar'
Assert-True (Test-IsSidecarName 'apps/._Thing.msi') 'AppleDouble is a sidecar'
Assert-True (-not (Test-IsSidecarName 'apps/Thing.msi')) 'a package is not a sidecar'
Assert-True (-not (Test-IsSidecarName 'apps/my._file.msi')) 'only a leading ._ marks a sidecar'

# Push targets come from the ref lines, not the checked-out branch
$sha = 'a' * 40
$zero = '0' * 40
Assert-True (Test-PushTargetsMain @("refs/heads/feature $sha refs/heads/main $zero")) 'feature:main lands on main'
Assert-True (-not (Test-PushTargetsMain @("refs/heads/main $sha refs/heads/feature $zero"))) 'main:feature does not'
Assert-True (-not (Test-PushTargetsMain @("(delete) $zero refs/heads/main $sha"))) 'deleting main is not a push to it'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("cimian-common-test-" + [guid]::NewGuid())
try {
    # Imported build artifacts are purged; unimported builds stay.
    New-Item -ItemType Directory -Path "$fixture/deployment/pkgs/apps", "$fixture/packages/Tool/build", "$fixture/installers/App/build" -Force | Out-Null
    Set-Content "$fixture/deployment/pkgs/apps/Tool-1.0.msi" 'x'
    Set-Content "$fixture/packages/Tool/build/Tool-1.0.msi" 'x'
    Set-Content "$fixture/installers/App/build/App-2.0.msi" 'y'
    Remove-ImportedBuildArtifact -RepoRoot $fixture -PkgsDir "$fixture/deployment/pkgs" | Out-Null
    Assert-True (-not (Test-Path "$fixture/packages/Tool/build")) 'imported build output should be removed'
    Assert-True (Test-Path "$fixture/installers/App/build/App-2.0.msi") 'an unimported build must stay'

    # Installer-type wrapper with no detection fails the lint; with installs it passes.
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if ($python) {
        git -C $fixture init -q -b main
        git -C $fixture config core.hooksPath .disabled-hooks
        New-Item -ItemType Directory -Path "$fixture/installers/Wrapped", "$fixture/deployment/pkgsinfo/apps" -Force | Out-Null
        "product:`n  name: Wrapped`n  version: 1.0`n" | Set-Content "$fixture/installers/Wrapped/build-info.yaml"
        "name: Wrapped`nversion: '1.0'`ncatalogs:`n- Testing`ninstaller:`n  type: msi`n  location: apps/Wrapped-1.0.msi`n  hash: abc`n" |
            Set-Content "$fixture/deployment/pkgsinfo/apps/Wrapped.yaml"
        git -C $fixture add -A
        $lint = Join-Path (Join-Path $hookDir 'lib') 'pkgsinfo-lint.py'
        $out = & $python.Source $lint $fixture 2>&1
        Assert-True ($LASTEXITCODE -eq 1 -and "$out" -match 'installer-type wrapper') "expected the wrapper rule to fire: $out"

        "name: Wrapped`nversion: '1.0'`ncatalogs:`n- Testing`ninstaller:`n  type: msi`n  location: apps/Wrapped-1.0.msi`n  hash: abc`ninstalls:`n- type: file`n  path: C:\Program Files\Wrapped\wrapped.exe`n" |
            Set-Content "$fixture/deployment/pkgsinfo/apps/Wrapped.yaml"
        git -C $fixture add -A
        $out = & $python.Source $lint $fixture 2>&1
        Assert-True ("$out" -notmatch 'installer-type wrapper') "installs[] should satisfy the wrapper rule: $out"
    } else {
        Write-Host 'SKIP: python3 not found, lint case not run'
    }
    Write-Host 'PASS: common helpers and installer-type lint'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

# Package path validation and log redaction
foreach ($bad in '../x.msi', 'apps/../../x.msi', '..\..\x.msi', 'C:\Windows\x.msi', 'c:x.msi', '\\server\share\x.msi', '//server/x.msi', 'apps//x.msi', 'apps/./x.msi', '') {
    Assert-True ($null -eq (ConvertTo-PkgRelativePath $bad)) "'$bad' should be rejected"
}
Assert-True ((ConvertTo-PkgRelativePath '/apps/x.msi') -eq 'apps/x.msi') 'a leading slash means under pkgs'
Assert-True ((ConvertTo-PkgRelativePath 'deployment\pkgs\apps\x.msi') -eq 'apps/x.msi') 'a deployment/pkgs prefix is dropped'
$pk = Join-Path ([IO.Path]::GetTempPath()) 'pk-root'
Assert-True ($null -ne (Resolve-PkgLocalPath -PkgsDir $pk -RelPath 'apps/x.msi')) 'an in-root path resolves'
Assert-True ($null -eq (Resolve-PkgLocalPath -PkgsDir $pk -RelPath '../pk-root-evil/x.msi')) 'a sibling prefix must not resolve'
$red = Hide-UrlSecret 'https://acct.blob.core.windows.net/c/x?sv=2022&sig=abc%2Fdef&se=2030 and https://b.s3.amazonaws.com/k?X-Amz-Signature=ff&X-Amz-Credential=AK'
Assert-True ($red -notmatch 'abc%2Fdef|=ff|=AK') "secrets should be redacted: $red"
Write-Host 'PASS: path validation and redaction'
