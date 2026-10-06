#Requires -Version 5.1
# Catalogs: [Development, Testing, Staging, Production]
<#
================================================================
 Intune proactive script - SCRIPT
 BootstrapMateLastRun

 Intentionally a no-op. Proactive Remediations need both a detection and a
 remediation script, and this package exists to report BootstrapMate's last
 run, not to repair it. A failed run is
 retried by BootstrapMate's own daily Self-Heal task.
================================================================
#>
Write-Output 'Report only - no remediation'
exit 0
