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

    $keyword = @{ nightly = 'Nightly'; beta = 'Beta'; stable = 'Release' }[$Edition]
    $release = $null
    $asset = $null
    for ($page = 1; $page -le 10 -and -not $asset; $page++) {
        $url = "https://api.github.com/repos/brave/brave-browser/releases?per_page=100&page=$page"
        $releases = @(Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'Brave-Portable-Updater'; 'Accept' = 'application/vnd.github+json' } -ErrorAction Stop)
        if ($releases.Count -eq 0) { break }
        foreach ($candidate in $releases) {
            if ($candidate.name -notmatch "(?i)\b$keyword\b") { continue }
            $found = @($candidate.assets | Where-Object { $_.name -match '^brave-v.*-win32-x64\.zip$' }) | Select-Object -First 1
            if ($found) { $release = $candidate; $asset = $found; break }
        }
        if ($releases.Count -lt 100) { break }
    }
    if (-not $asset) { throw "No $Edition Windows x64 zip asset found in up to 1000 recent releases." }
    $version = $release.tag_name -replace '^v', ''
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
                    exit 0
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

    # Detect an interrupted swap before touching the active installation.
    # A previous backup is intentionally not deleted automatically because it
    # might be the only working copy of the browser.
    $orphanBackups = @(Get-ChildItem -LiteralPath $OutDir -Directory -Filter '.app-backup-*' -ErrorAction Stop)
    if (-not (Test-Path -LiteralPath $appDir) -and $orphanBackups.Count -eq 1) {
        Move-Item -LiteralPath $orphanBackups[0].FullName -Destination $appDir -ErrorAction Stop
        Write-Warning 'Restored a previous installation left by an interrupted update.'
    } elseif (-not (Test-Path -LiteralPath $appDir) -and $orphanBackups.Count -gt 1) {
        throw 'Multiple interrupted update backups exist and app is missing. Manual recovery required; backups were preserved.'
    } elseif ($orphanBackups.Count -gt 0) {
        Write-Warning 'Previous update backups exist; inspect them after confirming Brave works.'
    }
    # Never kill processes from a system-wide Brave installation.
    # Refuse to replace portable executables if any instance is using this app directory.
    $appPrefix = [IO.Path]::GetFullPath($appDir).TrimEnd('\') + '\'
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
    exit 1
} finally {
    if (Test-Path -LiteralPath $zipFile) { Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
    if ($hashAlgorithm) { $hashAlgorithm.Dispose() }
}
