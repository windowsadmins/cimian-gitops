# ──────────────────────────────────────────────────────────────────────────────
#  preflight.ps1 — runs before every managedsoftwareupdate check.
#
#  Cimian executes this file immediately before each "check" run, the same way
#  Munki runs its preflight on macOS. It looks in two places and runs the first
#  it finds: C:\Program Files\Cimian\preflight.ps1 (where this package puts it),
#  then C:\ProgramData\ManagedInstalls\sbin\preflight.ps1. Keep it FAST and
#  IDEMPOTENT — it runs on every cycle.
#
#  THIS IS A TEMPLATE. The body below is representative and harmless: it writes a
#  run marker to the Cimian log and (optionally) removes a conflicting Chocolatey
#  shim from PATH so Cimian-managed packages win. Replace it with your own logic
#  (repo URL switching, on-prem mirror selection, fact gathering, etc.).
# ──────────────────────────────────────────────────────────────────────────────

param(
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$LogDir  = 'C:\ProgramData\ManagedInstalls\logs'
$LogFile = Join-Path $LogDir 'preflight.log'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log([string]$Message) {
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -Path $LogFile -Value "[$ts] $Message"
}

Write-Log 'Preflight: run marker — managedsoftwareupdate check starting.'

# ── Optional: drop a conflicting Chocolatey shim so Cimian-managed packages are
#    the single source of truth. Harmless no-op if Chocolatey is not present.
$chocoShim = Join-Path $env:ChocolateyInstall 'bin'
if ($env:ChocolateyInstall -and (Test-Path $chocoShim)) {
    $machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    if ($machinePath -and ($machinePath -split ';' -contains $chocoShim)) {
        $newPath = ($machinePath -split ';' | Where-Object { $_ -ne $chocoShim }) -join ';'
        [Environment]::SetEnvironmentVariable('PATH', $newPath, 'Machine')
        Write-Log "Preflight: removed conflicting Chocolatey shim from machine PATH ($chocoShim)."
    }
}

Write-Log 'Preflight: complete.'

# A non-zero exit is a preflight failure, and what Cimian does next is set by
# PreflightFailureAction in Config.yaml: 'continue' (the default) logs it and
# carries on, 'warn' carries on with a warning, 'abort' stops the run. Exit
# non-zero only when the run genuinely should not go ahead.
exit 0
