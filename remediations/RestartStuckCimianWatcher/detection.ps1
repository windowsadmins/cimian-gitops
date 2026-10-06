#Requires -Version 5.1
<#
================================================================
 Intune proactive script - DETECTION
 RestartStuckCimianWatcher

 CimianWatcher applies a staged self-update at two moments: once when the
 service starts, and — since windowsadmins/cimian 4a8eb41f (2026-08-30) —
 periodically from its polling loop via ApplyStagedSelfUpdateIfIdle().

 Clients built before that commit only ever check at service start. On a
 machine that stays powered on for days the service never restarts, so
 managedsoftwareupdate stages the self-update every hour, logs
 "Self-update scheduled successfully", and nothing ever consumes it. The
 client is pinned at its old build indefinitely while still checking in,
 which makes it look healthy in reporting while every install decision it
 makes comes from stale code.

 This is self-limiting by design but cannot self-heal: the fix that removes
 the restart requirement ships INSIDE the client, so a device stuck on a
 pre-fix build can only receive it via exactly the restart it eliminates.
 Machines that reboot on a normal cadence recovered on their own; the ones
 that do not are stranded.

 Detection is therefore narrow on purpose. It fires only when BOTH:
   - a self-update is actually staged and waiting, and
   - the running client predates the periodic-poll fix.

 A device on a current client is never touched, even if an update is
 staged, because the polling loop will apply it without help.

   - no staged update, or client already has the poll fix -> healthy   (exit 0)
   - staged update AND pre-fix client                     -> remediate (exit 1)

 Runs as SYSTEM (deviceHealthScript runAsAccount=system).
 Exit 1 => script needed; Exit 0 => healthy.
================================================================
#>
$ErrorActionPreference = 'SilentlyContinue'

# First build confidently carrying ApplyStagedSelfUpdateIfIdle(). The commit
# landed 2026-08-30, so a build cut earlier that same day may or may not
# include it. The threshold is deliberately set past that ambiguity rather
# than at it, because erring high is the safe direction here: a client that
# DOES have the polling fix consumes a staged update on its own within one
# poll interval, so it cannot still be sitting on an unconsumed flag when
# detection runs. The flag test below is what actually protects healthy
# devices; the version test only avoids pointless restarts.
$PollFixVersion = [version]'2026.08.31.0000'

$ClientExe  = 'C:\Program Files\Cimian\managedsoftwareupdate.exe'
$FlagFile   = Join-Path $env:ProgramData 'ManagedInstalls\.cimian.selfupdate'

if (-not (Test-Path -LiteralPath $ClientExe)) {
    Write-Output 'Cimian client not installed - not applicable'
    exit 0
}

$service = Get-Service -Name 'CimianWatcher' -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Output 'CimianWatcher service not present - not applicable'
    exit 0
}

$raw = (Get-Item -LiteralPath $ClientExe).VersionInfo.FileVersion
$running = $null
if (-not [version]::TryParse(($raw -replace '[^0-9.]', ''), [ref]$running)) {
    Write-Output "Cannot parse client version '$raw' - taking no action"
    exit 0
}

if ($running -ge $PollFixVersion) {
    Write-Output "Client $running applies staged updates from its polling loop - healthy"
    exit 0
}

# Pre-fix client. Only act if an update is genuinely staged and waiting.
$staged = Test-Path -LiteralPath $FlagFile
if (-not $staged) {
    Write-Output "Client $running predates the polling fix but no self-update is staged - healthy"
    exit 0
}

Write-Output "Client $running predates the polling fix and a self-update is staged and unconsumed - restart required"
exit 1
