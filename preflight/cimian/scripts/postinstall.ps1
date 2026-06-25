# postinstall.ps1 — run by cimipkg after the payload lands.
#
# The payload places preflight.ps1 at C:\Program Files\Cimian\preflight.ps1.
# Lock it down so only administrators/SYSTEM can edit a script that runs every
# managedsoftwareupdate cycle as SYSTEM.

$ErrorActionPreference = 'Stop'

$preflight = 'C:\Program Files\Cimian\preflight.ps1'
if (-not (Test-Path $preflight)) {
    Write-Error "preflight.ps1 missing at $preflight"
    exit 1
}

icacls $preflight /inheritance:r | Out-Null
icacls $preflight /grant:r 'SYSTEM:(RX)' 'Administrators:(F)' 'Users:(RX)' | Out-Null

Write-Host "Installed and secured $preflight"
exit 0
