<#
.SYNOPSIS
Fail the deploy if any pkgsinfo points at a package that is not in cloud
storage.

.DESCRIPTION
Package binaries are not in git, so CI never sees them. A pkgsinfo whose
installer was never uploaded (a hand edit, a skipped pre-push hook, one admin's
tree drifting from the bucket) would otherwise publish a catalog entry that
404s on every client. This is the backstop.

The caller lists the bucket or container and passes the object keys in a text
file, one per line, so the same check serves Azure Blob and S3. Keys are
compared as deployment/pkgs/<location>, with backslashes turned into forward
slashes.

.EXAMPLE
az storage blob list ... --prefix deployment/pkgs/ --query '[].name' -o tsv > keys.txt
./pipelines/scripts/Test-PackagesPresent.ps1 -RepoPath deployment -InventoryFile keys.txt
#>
param(
    [Parameter(Mandatory)] [string] $RepoPath,
    [Parameter(Mandatory)] [string] $InventoryFile
)

$ErrorActionPreference = 'Stop'

$existing = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($line in Get-Content -LiteralPath $InventoryFile) {
    $t = $line.Trim()
    if ($t) { [void]$existing.Add($t) }
}
Write-Host "$($existing.Count) package objects in storage"

$root = (Resolve-Path -LiteralPath $RepoPath).Path
$pkgsinfo = Join-Path $root 'pkgsinfo'
$missing = [System.Collections.Generic.List[string]]::new()
$checked = 0
Get-ChildItem -Path $pkgsinfo -Recurse -File -Include '*.yaml', '*.yml' | ForEach-Object {
    $file = $_.FullName
    foreach ($line in Get-Content -LiteralPath $file) {
        # installer.location and uninstaller.location are both indented keys.
        if ($line -match '^\s+location:\s*(.+?)\s*$') {
            $loc = $Matches[1].Trim().Trim("'").Trim('"')
            if ([string]::IsNullOrWhiteSpace($loc)) { continue }
            $checked++
            $key = 'deployment/pkgs/' + ($loc -replace '\\', '/').TrimStart('/')
            if (-not $existing.Contains($key)) {
                $missing.Add("$($file.Substring($root.Length).TrimStart('\', '/')) -> $key")
            }
        }
    }
}

if ($missing.Count -gt 0) {
    $msg = "Deploy blocked: $($missing.Count) pkgsinfo location(s) point at packages that are not in storage."
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::error::$msg" } else { Write-Host "##vso[task.logissue type=error]$msg" }
    $missing | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Upload the package (the pre-push hook does this), or fix or remove the pkgsinfo.'
    exit 1
}
Write-Host "OK: all $checked referenced package(s) are present in storage."
