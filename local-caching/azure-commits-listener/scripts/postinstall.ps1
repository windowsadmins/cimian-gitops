# postinstall.ps1 — register the listener as a SYSTEM Scheduled Task that starts
# at boot. Run by cimipkg after the payload lands in
# C:\Program Files\CimianCommitsListener.
#
# Connection strings, queue names, blob URL + SAS are NOT set here — provide them
# as machine-level environment variables (or edit the task XML) before the task
# starts. Nothing secret is baked into the package.

$ErrorActionPreference = 'Stop'

$base    = 'C:\Program Files\CimianCommitsListener'
$taskXml = Join-Path $base 'CimianCommitsListener.ScheduledTask.xml'
$taskName = 'com.example.cimian.CommitsListener'

if (-not (Test-Path $taskXml)) { Write-Error "Task XML missing at $taskXml"; exit 1 }

# The listener cannot start without its Node dependencies, so a missing npm or
# a failed install fails the package instead of registering a task that will
# crash on every boot.
foreach ($tool in 'node', 'npm') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool is not on PATH; install Node.js LTS before this package."
        exit 1
    }
}
Push-Location $base
# npm writes progress to stderr; under 'Stop' Windows PowerShell would treat
# that as a terminating error, so judge the install on its exit code alone.
$ErrorActionPreference = 'Continue'
try {
    $npmArgs = if (Test-Path (Join-Path $base 'package-lock.json')) { 'ci' } else { 'install' }
    & npm $npmArgs --omit=dev --no-audit --no-fund 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "npm $npmArgs failed with exit code $LASTEXITCODE"
        exit 1
    }
} finally {
    Pop-Location
    $ErrorActionPreference = 'Stop'
}

schtasks /Create /TN $taskName /XML "$taskXml" /F | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "schtasks /Create failed ($LASTEXITCODE)"; exit 1 }
schtasks /Run    /TN $taskName | Out-Null

Write-Host "Registered and started scheduled task $taskName"
exit 0
