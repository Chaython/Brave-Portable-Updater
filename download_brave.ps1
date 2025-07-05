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

# --- GET GITHUB RELEASES ---
$releasesUrl = "https://api.github.com/repos/brave/brave-browser/releases?per_page=30"
try {
    $releases = Invoke-RestMethod -Uri $releasesUrl -Headers @{"User-Agent"="Brave-Updater"}
} catch {
    Write-Error "Failed to fetch releases from GitHub."
    exit 1
}

# Find the first release whose name/title contains the edition keyword
$release = $releases | Where-Object { $_.name -match $editionKeyword } | Select-Object -First 1

if (-not $release) {
    Write-Error "No release found with title containing '$editionKeyword'."
    exit 1
}

# Release version is like 'v1.82.54'; strip 'v'
$version = $release.tag_name.TrimStart("v")
Write-Host "Latest $Edition version: $version"

# --- CHECK IF LATEST IS ALREADY DOWNLOADED (by folder in app\ that ends with $version) ---
$currentVersionFolder = $null
if (Test-Path $appDir) {
    $dirs = Get-ChildItem -Path $appDir -Directory | Where-Object { $_.Name -like "*$version" }
    if ($dirs.Count -ge 1) {
        $currentVersionFolder = $dirs[0].FullName
        Write-Host "The latest version ($version) is already downloaded in $($dirs[0].Name)."
        exit 0
    } else {
        Write-Host "No matching version directory found, cleaning up any old versions."
        # Remove all subfolders in app\
        Get-ChildItem -Path $appDir -Directory | Remove-Item -Recurse -Force
    }
} else {
    New-Item -ItemType Directory -Path $appDir | Out-Null
    Write-Host "Created app directory."
}

# --- DOWNLOAD ZIP ASSET ---
$asset = $release.assets | Where-Object { $_.name -match "^brave-v.*-win32-x64\.zip$" } | Select-Object -First 1
if (-not $asset) {
    Write-Error "No Windows x64 zip asset found in release."
    exit 1
}

$downloadUrl = $asset.browser_download_url
$zipFile = "$OutDir\$($asset.name)"

# Delete any old archive file
if (Test-Path $zipFile) {
    Remove-Item $zipFile -Force
    Write-Host "Deleted old archive: $zipFile"
}

Write-Host "Downloading $downloadUrl ..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile

# --- EXTRACT NEW ZIP DIRECTLY TO app\ ---
Write-Host "Extracting $zipFile to $appDir ..."
Expand-Archive -Path $zipFile -DestinationPath $appDir -Force

# --- CLEAN UP ARCHIVE ---
Remove-Item $zipFile -Force
Write-Host "Removed archive: $zipFile"

Write-Host "Brave $Edition ($version) has been downloaded and extracted to $appDir."