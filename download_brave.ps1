param(
    [ValidateSet("nightly", "beta", "stable")]
    [string]$Edition = "nightly",
    [string]$OutDir = "."
)

$appDir = ".\app"

# --- MAP EDITION TO TITLE KEYWORD ---
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
$releasesUrl = "https://api.github.com/repos/brave/brave-browser/releases?per_page=30"
try {
    $releases = Invoke-RestMethod -Uri $releasesUrl -Headers @{"User-Agent"="Brave-Updater"}
} catch {
    Write-Error "Failed to fetch releases from GitHub."
    exit 1
}

# Find all releases matching the edition keyword
$matchingReleases = $releases | Where-Object { $_.name -match $editionKeyword }

if (-not $matchingReleases) {
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
$currentVersionFolder = $null
$currentVersion = $null
if (Test-Path $appDir) {
    $dirs = Get-ChildItem -Path $appDir -Directory | Where-Object { $_.Name -match "\d+\.\d+\.\d+\.\d+" }
    if ($dirs.Count -ge 1) {
        $currentVersion = ($dirs | ForEach-Object { 
            if ($_.Name -match "\d+\.(\d+\.\d+\.\d+)") { 
                [Version]$matches[1] 
            } 
        } | Sort-Object -Descending | Select-Object -First 1)
        
        $currentVersionFolder = ($dirs | Where-Object { $_.Name -match [regex]::Escape($currentVersion) }).FullName
        Write-Host "Current version in ${appDir}: $currentVersion"

        try {
            $selectedVersionParsed = [Version]$version
            if ($currentVersion -ge $selectedVersionParsed) {
                Write-Host "The selected version ($version) is already downloaded or older than the current version ($currentVersion)."
                exit 0
            } else {
                Write-Host "Selected version ($version) is newer than current version ($currentVersion), proceeding with download."
            }
        } catch {
            Write-Warning "Could not parse version numbers for comparison. Proceeding with download."
        }
    }
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
        Write-Error "Both BITS and Invoke-WebRequest failed to download the file."
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
    Write-Host "Cleaning up old versions in ${appDir}..."

    Write-Host "Terminating any running Brave processes..."
    Get-Process -Name "brave" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Host "Removing read-only attributes from files in ${appDir}..."
    Get-ChildItem -Path $appDir -Recurse -File | ForEach-Object {
        if ($_.IsReadOnly) {
            Set-ItemProperty -Path $_.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        }
    }

    try {
        Get-ChildItem -Path $appDir -Directory | Remove-Item -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "Failed to delete some files in ${appDir}: $($_.Exception.Message)"
        Write-Warning "Continuing with extraction, but old files may remain."
    }
} else {
    New-Item -ItemType Directory -Path $appDir | Out-Null
    Write-Host "Created app directory."
}

# --- EXTRACT NEW ZIP DIRECTLY TO app\ ---
Write-Host "Extracting $zipFile to ${appDir} ..."
Expand-Archive -Path $zipFile -DestinationPath $appDir -Force

# --- CLEAN UP ARCHIVE ---
Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
Write-Host "Removed archive: $zipFile"

Write-Host "Brave $Edition ($version) has been downloaded and extracted to ${appDir}."
