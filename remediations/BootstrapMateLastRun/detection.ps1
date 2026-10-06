#Requires -Version 5.1
<#
================================================================
 Intune proactive script - DETECTION
 BootstrapMateLastRun

 Reports how BootstrapMate's last run went, so the outcome of the daily
 Self-Heal run (skip / baseline / provisioning) is visible per device in the
 Intune remediation report without opening a session log.

 BootstrapMate writes C:\ProgramData\ManagedBootstrap\last-run.json at the
 start and end of every run; `managedbootstrapinstall.exe --last-run` prints
 it as one line:

   2026-10-04T10:04Z baseline completed v2026.10.04.1200 installed=0 skipped=9 failed=0

 That line is this script's output, which is what the report's "pre-
 remediation detection output" column shows.

   - no BootstrapMate, or no run recorded           -> exit 0
   - last run completed (or still running)           -> exit 0
   - last run ended partial_failure or failed        -> exit 1

 Builds older than --last-run never write last-run.json, so the file's
 absence is checked first and the CLI is not called: an old build would read
 --last-run as an unknown argument, and could wait on a running Self-Heal
 for its single-instance lock.

 The remediation (script.ps1) does nothing: this package reports, it does
 not repair. A failed run is retried by the next Self-Heal.

 Runs as SYSTEM (deviceHealthScript runAsAccount=system), daily.
================================================================
#>
$ErrorActionPreference = 'SilentlyContinue'

$Cli = 'C:\Program Files\BootstrapMate\managedbootstrapinstall.exe'
$LastRun = 'C:\ProgramData\ManagedBootstrap\last-run.json'

if (-not (Test-Path -LiteralPath $Cli)) {
    Write-Output 'not installed'
    exit 0
}

if (-not (Test-Path -LiteralPath $LastRun)) {
    Write-Output 'no run recorded'
    exit 0
}

$line = (& $Cli --last-run | Select-Object -First 1)
if (-not $line) {
    Write-Output 'no output from --last-run'
    exit 0
}
Write-Output $line

# <time> <run_type> <status> v<version> ...
$status = ($line -split ' ')[2]
if ($status -in 'partial_failure', 'failed') {
    exit 1
}
exit 0
