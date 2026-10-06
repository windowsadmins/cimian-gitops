# Drives aws/pre-push-pr-packages.ps1 against a throwaway repo with a fake
# aws CLI on PATH (a POSIX shell script, so run it on macOS or Linux).
#   pwsh -NoProfile -File githooks/tests/test-pr-packages-aws.ps1
$ErrorActionPreference = 'Stop'
$hookDir = Split-Path -Parent $PSScriptRoot
$hook = Join-Path (Join-Path $hookDir 'aws') 'pre-push-pr-packages.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("cimian-hook-test-aws-" + [guid]::NewGuid())

try {
    New-Item -ItemType Directory -Path "$fixture/deployment/pkgsinfo/apps", "$fixture/bin", "$fixture/state" -Force | Out-Null
    git -C $fixture init -q -b main
    git -C $fixture config user.email hooks@example.invalid
    git -C $fixture config user.name 'Hook Test'
    git -C $fixture config core.hooksPath .disabled-hooks
    Set-Content -LiteralPath "$fixture/README" -Value 'initial' -NoNewline
    git -C $fixture add README
    git -C $fixture commit -qm initial
    $baseSha = (git -C $fixture rev-parse HEAD).Trim()

    # 2 KB, because pkgsinfo records installer size in KB.
    $packageBytes = [Text.Encoding]::UTF8.GetBytes('p' * 2048)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $expectedHash = [BitConverter]::ToString($sha256.ComputeHash($packageBytes)).Replace('-', '').ToLowerInvariant() } finally { $sha256.Dispose() }
    $md5 = [Security.Cryptography.MD5]::Create()
    try { $localMd5Hex = [BitConverter]::ToString($md5.ComputeHash($packageBytes)).Replace('-', '').ToLowerInvariant() } finally { $md5.Dispose() }
    $otherHash = '0' * 64
    @"
name: Test
installer:
  type: msi
  size: 2
  location: /apps/Test.msi
  hash: $expectedHash
"@ | Set-Content -LiteralPath "$fixture/deployment/pkgsinfo/apps/Test.yaml" -NoNewline
    git -C $fixture add deployment/pkgsinfo/apps/Test.yaml
    git -C $fixture commit -qm package
    $headSha = (git -C $fixture rev-parse HEAD).Trim()

    @'
#!/bin/sh
S="$HOOK_TEST_STATE"
case "$*" in
  *"sts get-caller-identity"*) exit 0 ;;
  *"s3api head-object"*)
    if [ "$(cat "$S/exists")" != "true" ]; then
      echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2
      exit 254
    fi
    sha=$(cat "$S/sha256")
    if [ -n "$sha" ]; then sha="\"$sha\""; else sha=null; fi
    printf '{"sha256":%s,"etag":"\\"%s\\""}\n' "$sha" "$(cat "$S/etag")"
    ;;
  *"s3api copy-object"*)
    for arg in "$@"; do
      case "$arg" in sha256=*) printf '%s' "${arg#sha256=}" > "$S/sha256" ;; esac
    done
    : > "$S/backfilled"
    ;;
  *"s3api put-object"*)
    printf '%s\n' "$*" >> "$S/put-args"
    if [ -f "$S/fail-upload" ]; then
      printf 'true' > "$S/exists"
      cat "$S/race-sha" > "$S/sha256"
      exit 254
    fi
    for arg in "$@"; do
      case "$arg" in sha256=*) printf '%s' "${arg#sha256=}" > "$S/sha256" ;; esac
    done
    printf 'true' > "$S/exists"
    : > "$S/uploaded"
    ;;
esac
exit 0
'@ | Set-Content -LiteralPath "$fixture/bin/aws" -NoNewline
    chmod +x "$fixture/bin/aws"

    $refLine = "refs/heads/test $headSha refs/heads/test $baseSha"
    $oldPath = $env:PATH
    $env:PATH = "$fixture/bin$([IO.Path]::PathSeparator)$oldPath"
    $env:HOOK_TEST_STATE = "$fixture/state"

    function Reset-Remote([bool]$Exists, [string]$Sha256 = '', [string]$ETag = 'multipart-etag-2') {
        Set-Content -LiteralPath "$fixture/state/exists" -Value $Exists.ToString().ToLowerInvariant() -NoNewline
        Set-Content -LiteralPath "$fixture/state/sha256" -Value $Sha256 -NoNewline
        Set-Content -LiteralPath "$fixture/state/etag" -Value $ETag -NoNewline
        Remove-Item "$fixture/state/uploaded", "$fixture/state/backfilled", "$fixture/state/put-args", `
            "$fixture/state/fail-upload", "$fixture/state/race-sha" -Force -ErrorAction SilentlyContinue
    }

    function Invoke-Hook {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = (Get-Command pwsh).Source
        foreach ($a in '-NoProfile', '-NoLogo', '-File', $hook) { $start.ArgumentList.Add($a) }
        $start.WorkingDirectory = $fixture
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.Environment['PATH'] = $env:PATH
        $start.Environment['HOOK_TEST_STATE'] = $env:HOOK_TEST_STATE
        $process = [Diagnostics.Process]::Start($start)
        $process.StandardInput.WriteLine($refLine)
        $process.StandardInput.Close()
        $null = $process.StandardOutput.ReadToEnd()
        $null = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return $process.ExitCode
    }

    try {
        Reset-Remote -Exists $false
        if ((Invoke-Hook) -eq 0) { throw 'expected missing package to block' }

        New-Item -ItemType Directory -Path "$fixture/deployment/pkgs/apps" -Force | Out-Null
        [IO.File]::WriteAllBytes("$fixture/deployment/pkgs/apps/Test.msi", $packageBytes)
        Reset-Remote -Exists $false
        if ((Invoke-Hook) -ne 0) { throw 'expected create-only upload to succeed' }
        if (-not (Test-Path "$fixture/state/uploaded")) { throw 'expected create-only upload' }
        $putArgs = Get-Content "$fixture/state/put-args" -Raw
        if ($putArgs -notmatch '--if-none-match \*') { throw 'expected --if-none-match *' }
        if ($putArgs -notmatch "sha256=$expectedHash") { throw 'expected SHA-256 upload metadata' }

        Remove-Item "$fixture/deployment/pkgs/apps/Test.msi" -Force
        Reset-Remote -Exists $true -Sha256 $expectedHash
        if ((Invoke-Hook) -ne 0) { throw 'expected matching immutable object to pass' }
        if (Test-Path "$fixture/state/uploaded") { throw 'matching remote object should not upload' }

        [IO.File]::WriteAllBytes("$fixture/deployment/pkgs/apps/Test.msi", $packageBytes)
        Reset-Remote -Exists $true -Sha256 $otherHash
        if ((Invoke-Hook) -eq 0) { throw 'expected immutable-path hash collision to block' }
        if (Test-Path "$fixture/state/uploaded") { throw 'collision must not overwrite' }

        Reset-Remote -Exists $true -ETag $localMd5Hex
        if ((Invoke-Hook) -ne 0) { throw 'expected legacy backfill proven by single-part ETag' }
        if (-not (Test-Path "$fixture/state/backfilled")) { throw 'expected metadata backfill' }

        Reset-Remote -Exists $true
        if ((Invoke-Hook) -eq 0) { throw 'expected an unprovable multipart legacy object to block' }

        Remove-Item "$fixture/deployment/pkgs/apps/Test.msi" -Force
        git -C $fixture update-ref refs/remotes/origin/main $headSha
        Reset-Remote -Exists $true
        if ((Invoke-Hook) -ne 0) { throw 'expected authoritative main metadata backfill' }
        if (-not (Test-Path "$fixture/state/backfilled")) { throw 'expected authoritative main backfill' }

        [IO.File]::WriteAllBytes("$fixture/deployment/pkgs/apps/Test.msi", $packageBytes)
        Reset-Remote -Exists $false
        New-Item -ItemType File -Path "$fixture/state/fail-upload" | Out-Null
        Set-Content "$fixture/state/race-sha" -Value $expectedHash -NoNewline
        if ((Invoke-Hook) -ne 0) { throw 'expected identical concurrent race winner to pass' }

        Reset-Remote -Exists $false
        New-Item -ItemType File -Path "$fixture/state/fail-upload" | Out-Null
        Set-Content "$fixture/state/race-sha" -Value $otherHash -NoNewline
        if ((Invoke-Hook) -eq 0) { throw 'expected differing concurrent race winner to block' }

        @"
name: Test
installer:
  type: nopkg
installcheck_script: exit 1
"@ | Set-Content -LiteralPath "$fixture/deployment/pkgsinfo/apps/Test.yaml" -NoNewline
        git -C $fixture commit -qam nopkg
        $refLine = "refs/heads/test $((git -C $fixture rev-parse HEAD).Trim()) refs/heads/test $baseSha"
        Reset-Remote -Exists $false
        if ((Invoke-Hook) -ne 0) { throw 'expected nopkg to be skipped' }
        if (Test-Path "$fixture/state/uploaded") { throw 'nopkg must not upload' }

        $prePush = Get-Content (Join-Path (Join-Path $hookDir 'aws') 'pre-push.ps1') -Raw
        $lockAt = $prePush.IndexOf('(Lock-Hook -HookName')
        $helperAt = $prePush.IndexOf("Join-Path `$HookDir 'pre-push-pr-packages.ps1'")
        if ($lockAt -lt 0 -or $helperAt -lt 0 -or $lockAt -gt $helperAt) {
            throw 'PR helper must run after the shared lock is acquired'
        }
    } finally {
        $env:PATH = $oldPath
    }
    Write-Host 'PASS: aws PR package check (create-only upload, immutable keys, legacy backfill, races, nopkg)'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
