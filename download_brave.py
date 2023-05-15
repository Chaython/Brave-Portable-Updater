import requests
import zipfile
import os
import shutil

# Set the owner and repository
owner = "brave"
repo = "brave-browser"

# Set the URL for the releases
url = f"https://api.github.com/repos/{owner}/{repo}/releases"

# Get the releases information
response = requests.get(url)
releases = response.json()

# Find the release with the highest build number
latest_release = None
for release in releases:
    if not latest_release or release["tag_name"] > latest_release["tag_name"]:
        latest_release = release

if latest_release:
    # Find the asset with a name ending in win32-x64.zip
    asset = None
    for a in latest_release["assets"]:
        if a["name"].endswith("win32-x64.zip"):
            asset = a
            break

    if asset:
        # Get the download URL for the asset
        download_url = asset["browser_download_url"]

        # Download the asset
        response = requests.get(download_url)

        # Save the asset to a file
        filename = download_url.split("/")[-1]
        with open(filename, "wb") as f:
            f.write(response.content)

        # Extract the asset to the specified directory
        extract_dir = r".\app"

        # Delete existing data in the specified directory
        if os.path.exists(extract_dir):
            shutil.rmtree(extract_dir)

        with zipfile.ZipFile(filename, "r") as zip_ref:
            zip_ref.extractall(extract_dir)

        # Delete the downloaded file
        os.remove(filename)

        print("Extraction completed successfully")
    else:
        print("Asset not found")
else:
    print("No releases found")