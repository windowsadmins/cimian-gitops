<#
.SYNOPSIS
Check every pkgsinfo for the structural mistakes makecatalogs lets through.

.DESCRIPTION
makecatalogs is forgiving: a pkgsinfo with a misspelled catalog, a
non-cumulative catalog list or a bad installer path still lands in a catalog,
and the failure shows up later on a client. This checks, per file:

  - it parses to a mapping with name and version
  - catalogs is a non-empty list of known stages, and cumulative: an item in
    Staging is also in Development and Testing, so every earlier cohort still
    sees it
  - supported_architectures, if present, names only x64 and arm64
  - installer.location, if present, is a relative path under pkgs (no drive,
    UNC, absolute or ".." segments), and installer.hash is a SHA-256

Microsoft Store app descriptors under pkgsinfo/apps/managed are owned by the
Intune layer and skipped.

Exits 1 on any failure. Needs the powershell-yaml module; without it, it
says so and exits 0, so a missing module never blocks someone's work.

.EXAMPLE
pwsh -File quality/lint/Test-PkgsinfoStructure.ps1 -Path deployment/pkgsinfo
#>
[CmdletBinding()]
param(
    [string]$Path = 'deployment/pkgsinfo',
    # The release stages in order. Change it if your catalogs differ.
    [string[]]$Stages = @('Development', 'Testing', 'Staging', 'Production')
)

$ErrorActionPreference = 'Stop'

try { Import-Module powershell-yaml -ErrorAction Stop }
catch {
    Write-Host "SKIPPED: powershell-yaml is not available ($($_.Exception.Message))" -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "No pkgsinfo folder at $Path" -ForegroundColor Red
    exit 1
}

function Test-SafeLocation([string]$Location) {
    if ([string]::IsNullOrWhiteSpace($Location)) { return $false }
    if ($Location -match '^[A-Za-z]:' -or $Location -match '^(\\\\|//)') { return $false }
    $rel = ($Location -replace '\\', '/').TrimStart('/')
    foreach ($segment in $rel.Split('/')) {
        if ($segment -in '', '.', '..' -or $segment -match '[\x00-\x1f:]') { return $false }
    }
    return $true
}

$failures = [System.Collections.Generic.List[string]]::new()
$checked = 0
$files = Get-ChildItem -LiteralPath $Path -Recurse -File -Include '*.yaml', '*.yml' |
    Where-Object { $_.FullName.Replace('\', '/') -notmatch '/managed/' -and -not $_.Name.StartsWith('.') }

foreach ($file in $files) {
    $checked++
    $rel = $file.FullName
    try { $data = ConvertFrom-Yaml (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8) }
    catch { $failures.Add("${rel}: does not parse ($($_.Exception.Message))"); continue }
    if ($data -isnot [System.Collections.IDictionary]) { $failures.Add("${rel}: not a mapping"); continue }

    foreach ($key in 'name', 'version') {
        if ([string]::IsNullOrWhiteSpace([string]$data[$key])) { $failures.Add("${rel}: no $key") }
    }

    $catalogs = @($data['catalogs'] | Where-Object { $_ })
    if ($catalogs.Count -eq 0) {
        $failures.Add("${rel}: no catalogs")
    } else {
        $unknown = @($catalogs | Where-Object { $_ -cnotin $Stages })
        if ($unknown) {
            $failures.Add("${rel}: unknown catalog(s) $($unknown -join ', '); stages are $($Stages -join ', ')")
        } else {
            $highest = ($catalogs | ForEach-Object { [array]::IndexOf($Stages, $_) } | Measure-Object -Maximum).Maximum
            $expected = $Stages[0..$highest]
            $missing = @($expected | Where-Object { $_ -notin $catalogs })
            if ($missing) {
                $failures.Add("${rel}: catalogs are not cumulative; in $($Stages[$highest]) but not $($missing -join ', ')")
            }
        }
    }

    if ($data.Contains('supported_architectures')) {
        $bad = @($data['supported_architectures'] | Where-Object { $_ -notin 'x64', 'arm64' })
        if ($bad) { $failures.Add("${rel}: unsupported architecture(s) $($bad -join ', ')") }
    }

    $installer = $data['installer']
    if ($installer -is [System.Collections.IDictionary]) {
        if ($installer.Contains('location') -and -not (Test-SafeLocation ([string]$installer['location']))) {
            $failures.Add("${rel}: installer.location '$($installer['location'])' is not a relative path under pkgs")
        }
        if ($installer.Contains('hash') -and [string]$installer['hash'] -notmatch '^[0-9a-fA-F]{64}$') {
            $failures.Add("${rel}: installer.hash is not a SHA-256")
        }
    }
}

foreach ($f in $failures) { Write-Host $f -ForegroundColor Red }
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) problem(s) in $checked pkgsinfo file(s)." -ForegroundColor Red
    exit 1
}
Write-Host "$checked pkgsinfo file(s) checked, structure valid." -ForegroundColor Green
exit 0
