<#
.SYNOPSIS
    Downloads and extracts the latest Brave Portable edition for Windows.

.DESCRIPTION
    Fetches the latest release of the specified Brave edition (nightly, beta, or
    stable) from the brave/brave-browser GitHub releases, downloads the Windows
    x64 portable zip, and extracts it into an "app" subdirectory next to this
    script. Skips the download if the same or a newer version is already present.

.PARAMETER Edition
    The Brave edition to download. Accepted values: nightly, beta, stable.
    Default: nightly.

.PARAMETER OutDir
    The working/output directory. The zip is downloaded here and extracted into
    an "app" subfolder beneath it. Defaults to the directory of this script
    ($PSScriptRoot), so the script is location-independent.

.PARAMETER Force
    Skip the "already up to date" version check and always download/extract.

.EXAMPLE
    .\download_brave.ps1
    Downloads the nightly edition.

.EXAMPLE
    .\download_brave.ps1 -Edition beta
    Downloads the beta edition.

.EXAMPLE
    .\download_brave.ps1 -Edition stable -Force
    Forces re-download of the stable edition even if already up to date.
#>
param(
    [ValidateSet("nightly", "beta", "stable")]
    [string]$Edition = "nightly",
    [string]$OutDir = "",
    [switch]$Force
)

 $ErrorActionPreference = "Stop"

# --- RESOLVE PATHS RELATIVE TO THE SCRIPT, NOT THE CURRENT WORKING DIRECTORY ---
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = $PSScriptRoot
}
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
 $OutDir  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
 $appDir  = Join-Path $OutDir "app"

# --- MAP EDITION TO TITLE KEYWORD (as used in GitHub release names) ---
 $editionTitleMap = @{
    "nightly" = "Nightly"
    "beta"    = "Beta"
    "stable"  = "Release"
}
 $editionKeyword = $editionTitleMap[$Edition.ToLower()]

Write-Host "Looking for Brave $editionKeyword releases..."

# --- CHECK EXECUTION POLICY ---
 $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser
if ($currentPolicy -eq "Restricted" -or $currentPolicy -eq "AllSigned") {
    Write-Warning "Current PowerShell execution policy ($currentPolicy) may prevent script execution. Consider running with: powershell -ExecutionPolicy Bypass -File .\download_brave.ps1"
}

# --- GET GITHUB RELEASES ---
 $releasesUrl = "https://api.github.com/repos/brave/brave-browser/releases?per_page=80"
try {
    $releases = Invoke-RestMethod -Uri $releasesUrl -Headers @{ "User-Agent" = "Brave-Updater" } -ErrorAction Stop
} catch {
    Write-Error "Failed to fetch releases from GitHub: $($_.Exception.Message)"
    exit 1
}

# Find all releases matching the edition keyword
 $matchingReleases = @($releases | Where-Object { $_.name -match $editionKeyword })

if ($matchingReleases.Count -eq 0) {
    Write-Error "No releases found with title containing '$editionKeyword'."
    exit 1
}

# Iterate through matching releases to find the first with a Windows x64 zip
 $selectedRelease = $null
 $version = $null
foreach ($release in $matchingReleases) {
    $asset = $release.assets | Where-Object { $_.name -match "^brave-v.*-win32-x64\.zip$" } | Select-Object -First 1
    if ($asset) {
        $selectedRelease = $release
        $version = $release.tag_name.TrimStart("v")
        Write-Host "Found $Edition version with Windows x64 asset: $version"
        break
    }
}

if (-not $selectedRelease) {
    Write-Error "No Windows x64 zip asset found in any $editionKeyword release."
    exit 1
}

# --- CHECK IF SELECTED VERSION IS ALREADY DOWNLOADED OR NEWER ---
# Brave changed their zip internals: the extracted folder now uses the Chromium
# version (e.g. 151.0.7922.34) instead of the Brave release version (e.g.
# 1.95.8). Since 151 > 1, naive folder-name parsing breaks version comparison
# and future updates are skipped.  We instead track the Brave release version in
# a marker file (app/.brave-portable-version) written after each extraction.
 $versionFile = Join-Path $appDir ".brave-portable-version"

if (-not $Force) {
    $currentVersion = $null
    if ((Test-Path $appDir) -and (Test-Path $versionFile)) {
        $currentVersion = (Get-Content -Path $versionFile -Raw).Trim()
    }
    if ($currentVersion) {
        Write-Host "Current version in app folder: $currentVersion"
        try {
            $selectedVersionParsed = [Version]$version
            $currentVersionParsed  = [Version]$currentVersion
            if ($currentVersionParsed -ge $selectedVersionParsed) {
                Write-Host "The selected version ($version) is already downloaded or older than the current version ($currentVersion). Nothing to do."
                exit 0
            } else {
                Write-Host "Selected version ($version) is newer than current version ($currentVersion), proceeding with download."
            }
        } catch {
            Write-Warning "Could not parse version numbers for comparison. Proceeding with download."
        }
    }
} else {
    Write-Host "Force mode: skipping version check, will download $version."
}

# --- DOWNLOAD ZIP ASSET ---
 $asset = $selectedRelease.assets | Where-Object { $_.name -match "^brave-v.*-win32-x64\.zip$" } | Select-Object -First 1
 $downloadUrl = $asset.browser_download_url
 $zipFile = Join-Path $OutDir $asset.name

if (Test-Path $zipFile) {
    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    Write-Host "Deleted old archive: $zipFile"
}

Write-Host "Downloading $downloadUrl ..."
 $downloadSucceeded = $false

# Try BITS transfer first (supports resume/background), fall back to Invoke-WebRequest
try {
    Start-BitsTransfer -Source $downloadUrl -Destination $zipFile -DisplayName "Downloading Brave $Edition" -Description "Using BITS transfer" -ErrorAction Stop
    $downloadSucceeded = $true
    Write-Host "Download completed via BITS."
} catch {
    Write-Warning "BITS transfer failed: $($_.Exception.Message)"
    Write-Host "Falling back to Invoke-WebRequest..."
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
        $downloadSucceeded = $true
        Write-Host "Download completed via Invoke-WebRequest."
    } catch {
        Write-Error "Both BITS and Invoke-WebRequest failed to download the file: $($_.Exception.Message)"
        exit 1
    }
}

if (-not $downloadSucceeded) {
    Write-Error "Download failed."
    exit 1
}

# --- UNBLOCK DOWNLOADED ZIP TO PREVENT SMARTSCREEN PROMPTS ---
Write-Host "Unblocking downloaded file to prevent SmartScreen prompts..."
Unblock-File -Path $zipFile -ErrorAction SilentlyContinue

# --- CLEAN UP OLD VERSIONS ---
if (Test-Path $appDir) {
    Write-Host "Cleaning up old versions in app folder ($appDir)..."

    Write-Host "Terminating any running Brave processes..."
    Get-Process -Name "brave" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Host "Removing read-only attributes from files in app folder..."
    Get-ChildItem -Path $appDir -Recurse -File | ForEach-Object {
        if ($_.IsReadOnly) {
            Set-ItemProperty -Path $_.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        }
    }

    try {
        Get-ChildItem -Path $appDir -Directory | Remove-Item -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "Failed to delete some files in app folder: $($_.Exception.Message)"
        Write-Warning "Continuing with extraction, but old files may remain."
    }
} else {
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    Write-Host "Created app directory: $appDir"
}

# --- EXTRACT NEW ZIP DIRECTLY TO app\ ---
Write-Host "Extracting $zipFile to $appDir ..."
Expand-Archive -Path $zipFile -DestinationPath $appDir -Force

# --- RECORD DOWNLOADED VERSION ---
# Store the Brave release version from the GitHub tag, NOT the Chromium
# version from the extracted folder name.  This ensures future update
# comparisons stay correct even when Brave changes their folder naming.
Set-Content -Path $versionFile -Value $version -NoNewline -Encoding UTF8
Write-Host "Version marker written: $version"

# --- CLEAN UP ARCHIVE ---
Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
Write-Host "Removed archive: $zipFile"

Write-Host "Brave $Edition ($version) has been downloaded and extracted to $appDir."
