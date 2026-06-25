# postinstall.ps1 — register the SQS listener as a SYSTEM Scheduled Task that
# starts at boot. Run by cimipkg after the payload lands under C:\Program Files\.
#
# Queue URL, bucket, region, and AWS credentials are NOT set here — provide them
# as machine-level environment variables (or an instance profile) before the task
# starts. Nothing secret is baked into the package.

$ErrorActionPreference = 'Stop'

$base    = 'C:\Program Files\CimianCommitsListener'
$taskXml = Join-Path $base 'CimianCommitsListener.ScheduledTask.xml'
$taskName = 'com.domain.cimian.CommitsListener'

if (-not (Test-Path $taskXml)) { Write-Error "Task XML missing at $taskXml"; exit 1 }

if (Get-Command npm -ErrorAction SilentlyContinue) {
    Push-Location $base
    npm install --omit=dev 2>&1 | Out-Null
    Pop-Location
}

schtasks /Create /TN $taskName /XML "$taskXml" /F | Out-Null
schtasks /Run    /TN $taskName | Out-Null

Write-Host "Registered and started scheduled task $taskName"
exit 0
