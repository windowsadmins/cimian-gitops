#Requires -Version 5.1
<#
================================================================
 Intune proactive script - DETECTION
 RemoveStaleCimianPrefs

 An earlier Cimian preferences profile delivered static policy values for
 ClientIdentifier and SoftwareRepoURL into HKLM\SOFTWARE\Policies\Cimian
 (mirrored under WOW6432Node). Nothing read them until managedsoftwareupdate
 gained its MDM policy-override merge (windowsadmins/cimian#70); once it did,
 policy won over the per-device values the preflight computes, and affected
 devices asked for a manifest that did not exist and fell back to a catch-all.

 ClientIdentifier and SoftwareRepoURL are per-device runtime values: the
 preflight works them out from inventory and from which repo or cache the
 machine can reach, and they must never come from policy. If your profile
 delivers only settings such as InstallerTimeout, any ClientIdentifier or
 SoftwareRepoURL under a Policies\Cimian key is stale by definition.

   - neither value present in either hive view -> healthy   (exit 0)
   - either value present in either hive view  -> remediate (exit 1)

 InstallerTimeout is legitimate policy and is left untouched.

 Runs as SYSTEM (deviceHealthScript runAsAccount=system).
 Exit 1 => script needed; Exit 0 => healthy.
================================================================
#>
$ErrorActionPreference = 'SilentlyContinue'

$PolicyKeys = @(
    'HKLM:\SOFTWARE\Policies\Cimian',
    'HKLM:\SOFTWARE\WOW6432Node\Policies\Cimian'
)
$StaleValues = @('ClientIdentifier', 'SoftwareRepoURL')

$found = @()
foreach ($keyPath in $PolicyKeys) {
    $key = Get-Item -Path $keyPath -ErrorAction SilentlyContinue
    if (-not $key) { continue }
    foreach ($name in $StaleValues) {
        if ($key.GetValueNames() -contains $name) {
            $found += "$keyPath\$name = '$($key.GetValue($name))'"
        }
    }
}

if ($found.Count -gt 0) {
    Write-Output ("Stale Cimian policy override(s) present: " + ($found -join '; '))
    exit 1
}

Write-Output 'No stale Cimian policy overrides - healthy'
exit 0
