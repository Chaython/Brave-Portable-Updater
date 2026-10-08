<#
.SYNOPSIS
Safely updates the portable Brave binaries without touching unrelated Brave processes.
#>
[CmdletBinding()]
param(
    [ValidateSet('nightly','beta','stable')][string]$Edition = 'nightly',
    [string]$OutDir = '',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $PSScriptRoot }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
$appDir = Join-Path $OutDir 'app'
$versionFile = Join-Path $appDir '.brave-portable-version'
$stagingDir = Join-Path $OutDir ('.app-staging-' + [guid]::NewGuid().ToString('N'))
$backupDir = Join-Path $OutDir ('.app-backup-' + [guid]::NewGuid().ToString('N'))
$zipFile = Join-Path $OutDir ('.brave-download-' + [guid]::NewGuid().ToString('N') + '.zip')
$mutex = $null
$mutexAcquired = $false
$committed = $false
$hashAlgorithm = $null
try {
    # Prevent two updater instances from interleaving their install/rollback.
    $mutexName = 'Local\BravePortableUpdater-' + ([Convert]::ToBase64String(
        ($hashAlgorithm = [Security.Cryptography.SHA256]::Create()).ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($OutDir.ToLowerInvariant())
        )).TrimEnd('=').Replace('+','-').Replace('/','_'))
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    try { $mutexAcquired = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }
    if (-not $mutexAcquired) { throw "Another Brave Portable update is running for '$OutDir'." }

    $release = $null
    $asset = $null
    $channelPattern = switch ($Edition) {
        'stable'  { '^Release\s+v' }
        'beta'    { '^Beta\s+v' }
        'nightly' { '^Nightly\s+v' }
    }
    for ($page = 1; $page -le 10 -and -not $asset; $page++) {
        $url = "https://api.github.com/repos/brave/brave-browser/releases?per_page=100&page=$page"
        $response = Invoke-RestMethod -Uri $url -Headers @{
            'User-Agent' = 'Brave-Portable-Updater'
            'Accept' = 'application/vnd.github+json'
        } -ErrorAction Stop
        # Invoke-RestMethod's array behavior differs from ordinary pipeline
        # enumeration. Explicitly normalize the top-level response.
        $releases = @()
        foreach ($item in $response) { $releases += $item }
        Write-Host "Release page $page : $($releases.Count) entries"
        if ($releases.Count -eq 0) { break }
        foreach ($candidate in $releases) {
            if ([string]$candidate.name -notmatch $channelPattern) { continue }
            if ($Edition -eq 'stable' -and ($candidate.prerelease -or
                    [string]$candidate.name -match '(?i)release candidate|\bRC\b')) { continue }
            foreach ($candidateAsset in @($candidate.assets)) {
                if ([string]$candidateAsset.name -match '^brave-v[\d.]+-win32-x64\.zip$') {
                    $release = $candidate
                    $asset = $candidateAsset
                    break
                }
            }
            if ($asset) { break }
        }
        if ($releases.Count -lt 100) { break }
    }
    if (-not $asset) { throw "No $Edition Windows x64 ZIP asset found in up to 1000 recent Brave releases." }
    $version = $release.tag_name -replace '^v', ''
    # Restore an interrupted swap BEFORE deciding that a version is current.
    # Otherwise a missing app directory could be mistaken for a completed update.
    $orphanBackups = @(Get-ChildItem -LiteralPath $OutDir -Directory -Filter '.app-backup-*' -ErrorAction Stop)
    if (-not (Test-Path -LiteralPath $appDir) -and $orphanBackups.Count -eq 1) {
        Move-Item -LiteralPath $orphanBackups[0].FullName -Destination $appDir -ErrorAction Stop
        Write-Warning 'Restored a previous installation after an interrupted update.'
    } elseif (-not (Test-Path -LiteralPath $appDir) -and $orphanBackups.Count -gt 1) {
        throw 'Multiple interrupted backups exist; refusing to guess which is valid.'
    }
    $installed = $null
    if (Test-Path -LiteralPath $versionFile) {
        $installed = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    }
    # Old single-version markers have no channel and must not be used to skip a different channel.
    if (-not $Force -and $installed -match '^(nightly|beta|stable)\|(.+)$') {
        $installedEdition = $Matches[1]
        $installedVersion = $Matches[2]
        if ($installedEdition -eq $Edition) {
            try {
                if ([version]$installedVersion -ge [version]$version -and
                    @(Get-ChildItem -LiteralPath $appDir -Filter brave.exe -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) {
                    Write-Host "Brave $Edition $installedVersion is already installed."
                    return
                }
            } catch { Write-Warning 'Cannot compare version tags; performing the update.' }
        }
    }

    Write-Host "Downloading Brave $Edition ($version)..."
    try {
        Start-BitsTransfer -Source $asset.browser_download_url -Destination $zipFile -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $zipFile) -or (Get-Item -LiteralPath $zipFile).Length -le 0) {
        throw 'The downloaded archive is empty or missing.'
    }
    # Prefer release asset SHA-256 when GitHub supplies one.
    if ($asset.digest -match '^sha256:([a-fA-F0-9]{64})$') {
        $expectedHash = $Matches[1]
        $actualHash = (Get-FileHash -LiteralPath $zipFile -Algorithm SHA256).Hash
        if ($actualHash -ine $expectedHash) { throw 'Downloaded ZIP SHA-256 does not match its GitHub release digest.' }
    }
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
    Expand-Archive -LiteralPath $zipFile -DestinationPath $stagingDir -ErrorAction Stop
    $executables = @(Get-ChildItem -LiteralPath $stagingDir -Filter brave.exe -Recurse -File -ErrorAction Stop)
    if ($executables.Count -ne 1) { throw "Expected one brave.exe in the archive; found $($executables.Count)." }
    Set-Content -LiteralPath (Join-Path $stagingDir '.brave-portable-version') -Value "$Edition|$version" -Encoding UTF8 -NoNewline

    # Never kill processes from a system-wide Brave installation.
    # Refuse to replace portable executables if any instance is using this app directory.
    $appPrefix = [IO.Path]::GetFullPath($appDir).TrimEnd([char]92) + [char]92
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='brave.exe'" -ErrorAction Stop)) {
        # Missing paths are ambiguous; fail closed rather than replace binaries in use.
        if ([string]::IsNullOrEmpty($process.ExecutablePath)) {
            throw "Cannot identify Brave process $($process.ProcessId). Close Brave and try again."
        }
        if ($process.ExecutablePath.StartsWith($appPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Portable Brave is still running (PID $($process.ProcessId)). Close it before updating."
        }
    }
    if (Test-Path -LiteralPath $appDir) {
        Move-Item -LiteralPath $appDir -Destination $backupDir -ErrorAction Stop
    }
    try {
        Move-Item -LiteralPath $stagingDir -Destination $appDir -ErrorAction Stop
        $committed = $true
    } catch {
        if (Test-Path -LiteralPath $backupDir) {
            if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $backupDir -Destination $appDir -ErrorAction Stop
        }
        throw
    }
    Write-Host "Installed Brave $Edition ($version) to '$appDir'."
    if (Test-Path -LiteralPath $backupDir) {
        try { Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning "Previous version retained at '$backupDir': $($_.Exception.Message)" }
    }
} catch {
    Write-Error "Brave update failed: $($_.Exception.Message)"
    throw
} finally {
    if (Test-Path -LiteralPath $zipFile) { Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
    if ($hashAlgorithm) { $hashAlgorithm.Dispose() }
}
