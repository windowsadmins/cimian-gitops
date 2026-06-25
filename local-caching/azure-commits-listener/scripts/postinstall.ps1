# postinstall.ps1 — register the listener as a SYSTEM Scheduled Task that starts
# at boot. Run by cimipkg after the payload lands under C:\Program Files\.
#
# Connection strings, queue names, blob URL + SAS are NOT set here — provide them
# as machine-level environment variables (or edit the task XML) before the task
# starts. Nothing secret is baked into the package.

$ErrorActionPreference = 'Stop'

$base    = 'C:\Program Files\CimianCommitsListener'
$taskXml = Join-Path $base 'CimianCommitsListener.ScheduledTask.xml'
$taskName = 'com.domain.cimian.CommitsListener'

if (-not (Test-Path $taskXml)) { Write-Error "Task XML missing at $taskXml"; exit 1 }

# Install Node deps if npm is available on the caching server.
if (Get-Command npm -ErrorAction SilentlyContinue) {
    Push-Location $base
    npm install --omit=dev 2>&1 | Out-Null
    Pop-Location
}

schtasks /Create /TN $taskName /XML "$taskXml" /F | Out-Null
schtasks /Run    /TN $taskName | Out-Null

Write-Host "Registered and started scheduled task $taskName"
exit 0
