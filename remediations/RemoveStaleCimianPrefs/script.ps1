#Requires -Version 5.1
# Catalogs: [Development, Testing, Staging, Production]
<#
================================================================
 Intune proactive script - SCRIPT
 RemoveStaleCimianPrefs

 Deletes the stale ClientIdentifier and SoftwareRepoURL values from
 HKLM\SOFTWARE\Policies\Cimian and its WOW6432Node mirror so
 managedsoftwareupdate's policy-override merge stops forcing a stale
 manifest. InstallerTimeout and any other value under the key are left
 untouched; the key itself is never
 removed. The next managedsoftwareupdate run re-resolves ClientIdentifier
 and SoftwareRepoURL from the preflight as designed. Idempotent.

 Runs as SYSTEM (deviceHealthScript runAsAccount=system).
 Exit 0 => success; Exit 1 => a stale value could not be removed.
================================================================
#>
$ErrorActionPreference = 'SilentlyContinue'

$PolicyKeys = @(
    'HKLM:\SOFTWARE\Policies\Cimian',
    'HKLM:\SOFTWARE\WOW6432Node\Policies\Cimian'
)
$StaleValues = @('ClientIdentifier', 'SoftwareRepoURL')

$removed = @()
$failed  = @()
foreach ($keyPath in $PolicyKeys) {
    $key = Get-Item -Path $keyPath -ErrorAction SilentlyContinue
    if (-not $key) { continue }
    foreach ($name in $StaleValues) {
        if ($key.GetValueNames() -notcontains $name) { continue }
        $old = $key.GetValue($name)
        Remove-ItemProperty -Path $keyPath -Name $name -Force -ErrorAction SilentlyContinue
        $check = Get-Item -Path $keyPath -ErrorAction SilentlyContinue
        if ($check -and $check.GetValueNames() -contains $name) {
            $failed += "$keyPath\$name"
        } else {
            $removed += "$keyPath\$name (was '$old')"
        }
    }
}

if ($removed.Count -gt 0) {
    Write-Output ("Removed: " + ($removed -join '; '))
}
if ($failed.Count -gt 0) {
    Write-Output ("FAILED to remove: " + ($failed -join '; '))
    exit 1
}
if ($removed.Count -eq 0) {
    Write-Output 'No stale Cimian policy overrides found - nothing to do'
}
exit 0
