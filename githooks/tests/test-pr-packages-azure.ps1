# Drives azure/pre-push-pr-packages.ps1 against a throwaway repo with fake
# az and azcopy on PATH (POSIX shell scripts, so run it on macOS or Linux).
#   pwsh -NoProfile -File githooks/tests/test-pr-packages-azure.ps1
$ErrorActionPreference = 'Stop'
$hookDir = Split-Path -Parent $PSScriptRoot
$hook = Join-Path (Join-Path $hookDir 'azure') 'pre-push-pr-packages.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("cimian-hook-test-" + [guid]::NewGuid())

try {
    New-Item -ItemType Directory -Path "$fixture/deployment/pkgsinfo/apps", "$fixture/bin", "$fixture/state" -Force | Out-Null
    git -C $fixture init -q -b main
    git -C $fixture config user.email hooks@example.invalid
    git -C $fixture config user.name 'Hook Test'
    Set-Content -LiteralPath "$fixture/README" -Value 'initial' -NoNewline
    git -C $fixture add README
    git -C $fixture commit -qm initial
    $baseSha = (git -C $fixture rev-parse HEAD).Trim()

    # 2 KB, because pkgsinfo records installer size in KB.
    $packageBytes = [Text.Encoding]::UTF8.GetBytes('p' * 2048)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $expectedHash = [BitConverter]::ToString($sha256.ComputeHash($packageBytes)).Replace('-', '').ToLowerInvariant() } finally { $sha256.Dispose() }
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
case "$*" in
  *"account get-access-token"*) exit 0 ;;
  *"storage blob exists"*) cat "$HOOK_TEST_STATE/exists" ;;
  *"storage blob show"*)
    sha=$(cat "$HOOK_TEST_STATE/sha256")
    md5=$(cat "$HOOK_TEST_STATE/md5")
    printf '{"sha256":"%s","md5":"%s","etag":"etag-1"}\n' "$sha" "$md5"
    ;;
  *"storage blob metadata update"*)
    for arg in "$@"; do
      case "$arg" in sha256=*) printf '%s\n' "${arg#sha256=}" > "$HOOK_TEST_STATE/sha256" ;; esac
    done
    : > "$HOOK_TEST_STATE/backfilled"
    ;;
esac
exit 0
'@ | Set-Content -LiteralPath "$fixture/bin/az" -NoNewline
    @'
#!/bin/sh
printf '%s\n' "$*" >> "$HOOK_TEST_STATE/azcopy-args"
if [ -f "$HOOK_TEST_STATE/fail-upload" ]; then
  printf 'true\n' > "$HOOK_TEST_STATE/exists"
  cat "$HOOK_TEST_STATE/race-sha" > "$HOOK_TEST_STATE/sha256"
  exit 1
fi
for arg in "$@"; do
  case "$arg" in --metadata=sha256=*) printf '%s\n' "${arg#--metadata=sha256=}" > "$HOOK_TEST_STATE/sha256" ;; esac
done
printf 'true\n' > "$HOOK_TEST_STATE/exists"
: > "$HOOK_TEST_STATE/uploaded"
exit 0
'@ | Set-Content -LiteralPath "$fixture/bin/azcopy" -NoNewline
    chmod +x "$fixture/bin/az" "$fixture/bin/azcopy"

    $refLine = "refs/heads/test $headSha refs/heads/test $baseSha"
    $oldPath = $env:PATH
    $env:PATH = "$fixture/bin$([IO.Path]::PathSeparator)$oldPath"
    $env:HOOK_TEST_STATE = "$fixture/state"

    function Reset-Remote([bool]$Exists, [string]$Sha256 = '', [string]$Md5 = '') {
        Set-Content -LiteralPath "$fixture/state/exists" -Value $Exists.ToString().ToLowerInvariant() -NoNewline
        Set-Content -LiteralPath "$fixture/state/sha256" -Value $Sha256 -NoNewline
        Set-Content -LiteralPath "$fixture/state/md5" -Value $Md5 -NoNewline
        Remove-Item "$fixture/state/uploaded", "$fixture/state/backfilled", "$fixture/state/azcopy-args", `
            "$fixture/state/fail-upload", "$fixture/state/race-sha" -Force -ErrorAction SilentlyContinue
    }

    function Invoke-Hook {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = (Get-Command pwsh).Source
        $start.ArgumentList.Add('-NoProfile')
        $start.ArgumentList.Add('-NoLogo')
        $start.ArgumentList.Add('-File')
        $start.ArgumentList.Add($hook)
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
        $azcopyArgs = Get-Content "$fixture/state/azcopy-args" -Raw
        if ($azcopyArgs -notmatch '--overwrite=false') { throw 'expected overwrite=false' }
        if ($azcopyArgs -notmatch "--metadata=sha256=$expectedHash") { throw 'expected SHA-256 upload metadata' }

        Remove-Item "$fixture/deployment/pkgs/apps/Test.msi" -Force
        Reset-Remote -Exists $true -Sha256 $expectedHash
        if ((Invoke-Hook) -ne 0) { throw 'expected matching immutable blob to pass' }
        if (Test-Path "$fixture/state/uploaded") { throw 'matching remote blob should not upload' }

        [IO.File]::WriteAllBytes("$fixture/deployment/pkgs/apps/Test.msi", $packageBytes)
        Reset-Remote -Exists $true -Sha256 $otherHash
        if ((Invoke-Hook) -eq 0) { throw 'expected immutable-path hash collision to block' }
        if (Test-Path "$fixture/state/uploaded") { throw 'collision must not overwrite' }

        $md5 = [Security.Cryptography.MD5]::Create()
        try { $localMd5 = [Convert]::ToBase64String($md5.ComputeHash($packageBytes)) } finally { $md5.Dispose() }
        Reset-Remote -Exists $true -Md5 $localMd5
        if ((Invoke-Hook) -ne 0) { throw 'expected safe legacy metadata backfill' }
        if (-not (Test-Path "$fixture/state/backfilled")) { throw 'expected metadata backfill' }

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

        # Unsafe locations are refused before they become a path or a key,
        # even when a file really exists at the target.
        [IO.File]::WriteAllBytes("$fixture/outside.msi", $packageBytes)
        foreach ($bad in '../../outside.msi', '..\..\outside.msi', 'apps/../../../outside.msi', 'C:\Windows\outside.msi', '\\server\share\outside.msi', '//server/share/outside.msi') {
            @"
name: Test
installer:
  type: msi
  size: 2
  location: '$bad'
  hash: $expectedHash
"@ | Set-Content -LiteralPath "$fixture/deployment/pkgsinfo/apps/Test.yaml" -NoNewline
            git -C $fixture commit -qam "unsafe $bad"
            $refLine = "refs/heads/test $((git -C $fixture rev-parse HEAD).Trim()) refs/heads/test $baseSha"
            Reset-Remote -Exists $false
            if ((Invoke-Hook) -eq 0) { throw "expected unsafe location '$bad' to block" }
            if (Test-Path "$fixture/state/uploaded") { throw "unsafe location '$bad' must not upload" }
            if (Test-Path "$fixture/state/azcopy-args") { throw "unsafe location '$bad' must not reach the uploader" }
        }

        # A nopkg item has no payload and must pass with nothing in storage.
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

        $prePush = Get-Content (Join-Path (Join-Path $hookDir 'azure') 'pre-push.ps1') -Raw
        $lockAt = $prePush.IndexOf('(Lock-Hook -HookName')
        $helperAt = $prePush.IndexOf("Join-Path `$HookDir 'pre-push-pr-packages.ps1'")
        if ($lockAt -lt 0 -or $helperAt -lt 0 -or $lockAt -gt $helperAt) {
            throw 'PR helper must run after the shared lock is acquired'
        }
    } finally {
        $env:PATH = $oldPath
    }
    Write-Host 'PASS: azure PR package check (create-only upload, immutable paths, legacy backfill, races, nopkg)'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
