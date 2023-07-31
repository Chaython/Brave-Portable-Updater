# Set the owner and repository
$owner = "brave"
$repo = "brave-browser"

# Set the URL for the releases
$url = "https://api.github.com/repos/$owner/$repo/releases"

# Get the releases information
$response = Invoke-RestMethod -Uri $url
$releases = $response

# Find the most recent release with the required asset
$latestRelease = $null
foreach ($release in $releases) {
    foreach ($a in $release.assets) {
        if ($a.name.EndsWith("win32-x64.zip")) {
            $latestRelease = $release
            break
        }
    }
    if ($latestRelease -ne $null) {
        break
    }
}

if ($latestRelease -ne $null) {
    # Find the asset with a name ending in win32-x64.zip
    $asset = $null
    foreach ($a in $latestRelease.assets) {
        if ($a.name.EndsWith("win32-x64.zip")) {
            $asset = $a
            break
        }
    }

    if ($asset -ne $null) {
        # Get the download URL for the asset
        $downloadUrl = $asset.browser_download_url

        # Download the asset
        Write-Host "Downloading asset..."
        $response = Invoke-WebRequest -Uri $downloadUrl

        # Save the asset to a file
        $filename = [System.IO.Path]::GetFileName($downloadUrl)
        [System.IO.File]::WriteAllBytes($filename, $response.Content)

        # Extract the asset to the specified directory
        $extractDir = ".\app"

        # Delete existing data in the specified directory
        if (Test-Path -Path $extractDir) {
            Remove-Item -Path $extractDir -Recurse -Force
        }

        Write-Host "Extracting asset..."
        Expand-Archive -Path $filename -DestinationPath $extractDir

        # Delete the downloaded file
        Remove-Item -Path $filename

        Write-Host "Extraction completed successfully"
    } else {
        Write-Host "Asset not found"
    }
} else {
    Write-Host "No releases found"
}
