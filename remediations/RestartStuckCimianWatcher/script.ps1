#Requires -Version 5.1
# Catalogs: [Development, Testing, Staging, Production]
<#
================================================================
 Intune proactive script - SCRIPT
 RestartStuckCimianWatcher

 Restarts CimianWatcher so it consumes a self-update that has been staged
 and left unconsumed. On a client predating windowsadmins/cimian 4a8eb41f
 (2026-08-30) the staged update is only ever read at service start, so the
 restart is the entire fix.

 What the restart triggers, in the service's own words:

     Self-update pending - launching detached installer and exiting
     Launching detached self-update: CimianTools v<version>
     Cleared self-update flag (pre-install)
     Detached installer process started. CimianWatcher will now exit.

 The service deliberately exits so the installer can replace its binary;
 Windows SCM restarts it once the MSI and its postinstall complete. A
 multi-hundred-megabyte MSI can take several minutes, during which the
 service is legitimately absent. This script therefore starts the restart
 and confirms the handoff happened - it does not wait for the install, and
 it does not treat a stopped service as failure once the installer has been
 launched, because stopping is the designed behaviour.

 The device self-heals permanently once it lands on a client carrying the
 periodic-poll fix, so this script stops firing on its own. It is a
 one-time rescue for machines that stayed powered on across the gap, not a
 standing workaround.

 Idempotent: detection gates on a staged update, and the flag is cleared by
 the watcher before the installer runs, so a second pass finds nothing to do.

 Runs as SYSTEM (deviceHealthScript runAsAccount=system).
 Exit 0 => restart issued and handoff confirmed; Exit 1 => could not restart.
================================================================
#>
$ErrorActionPreference = 'SilentlyContinue'

$FlagFile = Join-Path $env:ProgramData 'ManagedInstalls\.cimian.selfupdate'

$service = Get-Service -Name 'CimianWatcher' -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Output 'CimianWatcher service not present - nothing to restart'
    exit 1
}

if (-not (Test-Path -LiteralPath $FlagFile)) {
    Write-Output 'No staged self-update remains - nothing to do'
    exit 0
}

$before = (Get-Item -LiteralPath 'C:\Program Files\Cimian\managedsoftwareupdate.exe').VersionInfo.FileVersion

try {
    Restart-Service -Name 'CimianWatcher' -Force -ErrorAction Stop
} catch {
    # The service exits itself the moment it sees the staged update, so SCM can
    # report the restart as failed even though the handoff succeeded. Fall through
    # and judge by whether the flag was consumed rather than by this error.
    Write-Output "Restart-Service reported: $($_.Exception.Message)"
}

# Give the service time to start, read the flag, and launch the installer.
$consumed = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    if (-not (Test-Path -LiteralPath $FlagFile)) { $consumed = $true; break }
}

if ($consumed) {
    Write-Output "Staged self-update handed to the installer (client was $before). CimianWatcher will be restarted by SCM once the MSI completes."
    exit 0
}

Write-Output "CimianWatcher did not consume the staged self-update within 60s (client still $before)"
exit 1
