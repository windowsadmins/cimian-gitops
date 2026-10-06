<#
.SYNOPSIS
Replace a Win32 LOB app in Intune from an .intunewin, assign it, and keep the
Enrollment Status Page pointing at it.

.DESCRIPTION
The whole Microsoft Graph flow for an MSI wrapped with IntuneWinAppUtil:

  1. Delete any existing win32LobApp with the same display name. The pipeline
     is the source of truth, so it replaces rather than stacks.
  2. Create the app shell from Detection.xml inside the .intunewin.
  3. Create a content version, register the file, wait for the upload URL,
     block-upload the encrypted payload, commit it, and wait for Intune to
     accept it.
  4. Point the app at the committed content version and assign it.
  5. Repair the ESP blocking list. Deleting the old app leaves its id in the
     ESP's selectedMobileAppIds, and a deleted id there means the ESP no
     longer waits for the bootstrapper at all. The old ids are swapped for
     the new one. A missing or ambiguous ESP, or a repair that does not read
     back, fails the run.

Every Graph call and every upload block is retried on throttling and transient
errors, because a long upload over a shared hosted agent hits both.

Needs DeviceManagementApps.ReadWrite.All, plus
DeviceManagementServiceConfig.ReadWrite.All when -EspName is given.

.EXAMPLE
$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
./pipelines/scripts/Publish-IntuneWin32App.ps1 -Token $token -IntuneWin ./out/BootstrapMate-x64-2026.10.05.1229.intunewin `
    -DisplayName BootstrapMate -Publisher 'Example Org' -AssignmentGroupId <group-object-id> -EspName 'Management Bootstrap'
#>
param(
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] [string] $IntuneWin,
    [Parameter(Mandatory)] [string] $DisplayName,
    [string] $Description = 'First-boot bootstrapper. Delivered once at the ESP; Cimian orchestrates everything else from the GitOps repo.',
    [string] $Publisher = '<your-org>',
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')] [string] $AssignmentGroupId,
    [ValidatePattern('^[A-Za-z0-9 ._()-]{0,128}$')] [string] $EspName,
    [string] $GraphBase = 'https://graph.microsoft.com/beta'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Token)) { throw 'Empty Graph token' }
$headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }

function Invoke-Graph {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [string] $Method = 'GET',
        $Body
    )
    $delays = @(5, 15, 30, 60, 90)
    for ($attempt = 1; ; $attempt++) {
        try {
            $req = @{ Uri = $Uri; Method = $Method; Headers = $headers }
            if ($null -ne $Body) { $req.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 } }
            return Invoke-RestMethod @req
        } catch {
            $code = $null
            try { $code = [int] $_.Exception.Response.StatusCode } catch {}
            $transient = ($null -eq $code) -or ($code -in 408, 429, 500, 502, 503, 504)
            if (-not $transient -or $attempt -gt $delays.Count) { throw }
            $wait = $delays[$attempt - 1]
            try { $ra = [int] $_.Exception.Response.Headers['Retry-After']; if ($ra -gt $wait) { $wait = $ra } } catch {}
            Write-Host "Graph $Method $Uri failed ($(if ($code) { "HTTP $code" } else { $_.Exception.Message })); retry $attempt in ${wait}s"
            Start-Sleep -Seconds $wait
        }
    }
}

function Wait-FileState {
    param([string] $FileUrl, [string] $Want, [int] $Minutes)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $f = Invoke-Graph -Uri $FileUrl
        if ($f.uploadState -eq $Want) { return $f }
        if ($f.uploadState -like '*Failed*' -or $f.uploadState -like '*TimedOut*') { throw "Upload state $($f.uploadState) while waiting for $Want" }
    }
    throw "Timed out after $Minutes minutes waiting for $Want"
}

# ── 1. Remove earlier copies, remembering their ids for the ESP repair ────────
$filter = [Uri]::EscapeDataString("isof('microsoft.graph.win32LobApp') and displayName eq '$($DisplayName.Replace("'", "''"))'")
$old = @((Invoke-Graph -Uri "$GraphBase/deviceAppManagement/mobileApps?`$filter=$filter&`$select=id").value | ForEach-Object { $_.id })
foreach ($id in $old) {
    Write-Host "Deleting earlier $DisplayName $id"
    Invoke-Graph -Uri "$GraphBase/deviceAppManagement/mobileApps/$id" -Method DELETE | Out-Null
}

# ── 2. Read the .intunewin and create the app shell ──────────────────────────
Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $IntuneWin).Path)
try {
    foreach ($pair in @(
            @('IntuneWinPackage/Metadata/Detection.xml', 'Detection.xml'),
            @('IntuneWinPackage/Contents/IntunePackage.intunewin', 'payload.bin'))) {
        $entry = $zip.Entries | Where-Object FullName -eq $pair[0] | Select-Object -First 1
        if (-not $entry) { throw "$($pair[0]) missing from $IntuneWin" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $work $pair[1]), $true)
    }
} finally { $zip.Dispose() }

[xml] $det = Get-Content (Join-Path $work 'Detection.xml')
$info = $det.ApplicationInfo
$enc = $info.EncryptionInfo
$setup = [string] $info.SetupFile
$productCode = [string] $info.MsiInfo.MsiProductCode
if (-not $productCode) { throw 'Detection.xml has no MSI product code; this script handles MSI payloads only.' }

$appBody = [ordered]@{
    '@odata.type'                  = '#microsoft.graph.win32LobApp'
    displayName                    = $DisplayName
    description                    = $Description
    publisher                      = $Publisher
    fileName                       = [IO.Path]::GetFileName($IntuneWin)
    setupFilePath                  = $setup
    installCommandLine             = "msiexec /i `"$setup`" /qn"
    uninstallCommandLine           = "msiexec /x `"$productCode`" /qn"
    installExperience              = @{ runAsAccount = 'system'; deviceRestartBehavior = 'suppress'; maxRunTimeInMinutes = 60 }
    minimumSupportedWindowsRelease = 'Windows11_22H2'
    allowedArchitectures           = 'x64'
    applicableArchitectures        = 'none'
    runAs32bit                     = $false
    detectionRules                 = @(@{
            '@odata.type'          = '#microsoft.graph.win32LobAppProductCodeDetection'
            productCode            = $productCode
            productVersionOperator = 'notConfigured'
        })
    returnCodes                    = @(
        @{ returnCode = 0; type = 'success' }, @{ returnCode = 1707; type = 'success' },
        @{ returnCode = 3010; type = 'softReboot' }, @{ returnCode = 1641; type = 'hardReboot' },
        @{ returnCode = 1618; type = 'retry' })
}
$app = Invoke-Graph -Uri "$GraphBase/deviceAppManagement/mobileApps" -Method POST -Body $appBody
$appId = $app.id
Write-Host "Created win32LobApp $appId"

# ── 3. Content version, file registration, block upload, commit ──────────────
$lob = "$GraphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp"
$cv = Invoke-Graph -Uri "$lob/contentVersions" -Method POST -Body '{}'
$payload = Join-Path $work 'payload.bin'
$file = Invoke-Graph -Uri "$lob/contentVersions/$($cv.id)/files" -Method POST -Body @{
    '@odata.type' = '#microsoft.graph.mobileAppContentFile'
    name          = [IO.Path]::GetFileName($IntuneWin)
    size          = [int64] $info.UnencryptedContentSize
    sizeEncrypted = (Get-Item $payload).Length
    isDependency  = $false
}
$fileUrl = "$lob/contentVersions/$($cv.id)/files/$($file.id)"
$sas = (Wait-FileState -FileUrl $fileUrl -Want 'azureStorageUriRequestSuccess' -Minutes 10).azureStorageUri

# iso-8859-1 maps bytes to chars 1:1, so the binary survives a string body.
# Azure Storage returns occasional AuthenticationFailed on single blocks of a
# valid upload URL; another attempt nearly always takes, so retry each block.
$chunkSize = 6MB
$latin1 = [Text.Encoding]::GetEncoding('iso-8859-1')
$ids = [System.Collections.Generic.List[string]]::new()
$stream = [IO.File]::OpenRead($payload)
try {
    $buf = New-Object byte[] $chunkSize
    $i = 0
    while (($read = $stream.Read($buf, 0, $chunkSize)) -gt 0) {
        $id = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('{0:D6}' -f $i))
        $ids.Add($id)
        $slice = if ($read -lt $chunkSize) { $buf[0..($read - 1)] } else { $buf }
        $body = $latin1.GetString([byte[]] $slice)
        for ($try = 1; ; $try++) {
            try {
                Invoke-WebRequest -Uri "$sas&comp=block&blockid=$([Uri]::EscapeDataString($id))" -Method PUT -UseBasicParsing `
                    -Headers @{ 'x-ms-blob-type' = 'BlockBlob'; 'content-type' = 'text/plain; charset=iso-8859-1' } -Body $body | Out-Null
                break
            } catch {
                if ($try -ge 8) { throw "Block $i failed after $try attempts: $($_.Exception.Message)" }
                $delay = Get-Random -Minimum 7 -Maximum 30
                Write-Host "Block $i attempt $try failed; retry in ${delay}s"
                Start-Sleep -Seconds $delay
            }
        }
        $i++
    }
} finally { $stream.Dispose() }
$blockList = '<?xml version="1.0" encoding="utf-8"?><BlockList>' + (($ids | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
for ($try = 1; ; $try++) {
    try {
        Invoke-RestMethod -Uri "$sas&comp=blocklist" -Method PUT -Headers @{ 'content-type' = 'text/plain; charset=UTF-8' } -Body $blockList | Out-Null
        break
    } catch {
        if ($try -ge 5) { throw "Block list commit failed after $try attempts: $($_.Exception.Message)" }
        Start-Sleep -Seconds (10 * $try)
    }
}
Write-Host "Uploaded $($ids.Count) block(s)"

Invoke-Graph -Uri "$fileUrl/commit" -Method POST -Body @{ fileEncryptionInfo = @{
        encryptionKey        = $enc.EncryptionKey
        macKey               = $enc.MacKey
        initializationVector = $enc.InitializationVector
        mac                  = $enc.Mac
        profileIdentifier    = $enc.ProfileIdentifier
        fileDigest           = $enc.FileDigest
        fileDigestAlgorithm  = $enc.FileDigestAlgorithm
    } } | Out-Null
Wait-FileState -FileUrl $fileUrl -Want 'commitFileSuccess' -Minutes 20 | Out-Null

# ── 4. Commit the content version and assign ─────────────────────────────────
Invoke-Graph -Uri "$GraphBase/deviceAppManagement/mobileApps/$appId" -Method PATCH -Body @{
    '@odata.type'           = '#microsoft.graph.win32LobApp'
    committedContentVersion = "$($cv.id)"
} | Out-Null

# The only targeting the MDM does: deliver the pipe to enrolled devices.
Invoke-Graph -Uri "$GraphBase/deviceAppManagement/mobileApps/$appId/assign" -Method POST -Body @{ mobileAppAssignments = @(@{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            intent        = 'required'
            target        = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $AssignmentGroupId }
            settings      = @{ '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings'; notifications = 'hideAll'; deliveryOptimizationPriority = 'foreground' }
        }) } | Out-Null
Write-Host "Assigned $DisplayName ($appId) to group $AssignmentGroupId"

# ── 5. ESP blocking list ─────────────────────────────────────────────────────
if ($EspName) {
    $espFilter = [Uri]::EscapeDataString("displayName eq '$($EspName.Replace("'", "''"))'")
    $esp = (Invoke-Graph -Uri "$GraphBase/deviceManagement/deviceEnrollmentConfigurations?`$filter=$espFilter").value |
        Where-Object { $_.'@odata.type' -eq '#microsoft.graph.windows10EnrollmentCompletionPageConfiguration' } |
        Select-Object -First 2
    if (@($esp).Count -ne 1) {
        # Fail, not warn: the app was just recreated under a new id, so an ESP
        # left unrepaired silently stops waiting for the bootstrapper.
        throw "Expected exactly one ESP named '$EspName', found $(@($esp).Count). The new app $appId is not in any ESP blocking list."
    }
    $current = @($esp.selectedMobileAppIds | Where-Object { $_ })
    $wanted = @(@($current | Where-Object { $_ -notin $old }) + $appId | Sort-Object -Unique)
    $dropped = @($current | Where-Object { $_ -in $old })
    # Send the full writable shape back; a sparse PATCH on this type has been
    # known to reset fields it leaves out.
    $patch = [ordered]@{ '@odata.type' = $esp.'@odata.type' }
    foreach ($p in 'displayName', 'description', 'showInstallationProgress', 'blockDeviceSetupRetryByUser',
        'allowDeviceResetOnInstallFailure', 'allowLogCollectionOnInstallFailure', 'customErrorMessage',
        'installProgressTimeoutInMinutes', 'allowDeviceUseOnInstallFailure', 'trackInstallProgressForAutopilotOnly',
        'disableUserStatusTrackingAfterFirstUser') {
        if ($esp.PSObject.Properties.Name -contains $p) { $patch[$p] = $esp.$p }
    }
    $patch.selectedMobileAppIds = $wanted
    Invoke-Graph -Uri "$GraphBase/deviceManagement/deviceEnrollmentConfigurations/$($esp.id)" -Method PATCH -Body $patch | Out-Null

    # Read it back: a PATCH that returns 2xx without persisting would otherwise
    # pass as a repair.
    $after = @((Invoke-Graph -Uri "$GraphBase/deviceManagement/deviceEnrollmentConfigurations/$($esp.id)").selectedMobileAppIds)
    $stale = @($after | Where-Object { $_ -in $old })
    if ($after -notcontains $appId -or $stale.Count -gt 0) {
        throw "ESP '$EspName' blocking list did not take: has $($after -join ', '), wanted $appId without $($old -join ', ')"
    }
    Write-Host "ESP '$EspName': blocking on $appId; dropped $($dropped.Count) deleted id(s)"
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
