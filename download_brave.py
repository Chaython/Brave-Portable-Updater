import subprocess
import sys

# Upgrade pip
subprocess.check_call([sys.executable, "-m", "pip", "install", "--upgrade", "pip"])

# Install the requests library
subprocess.check_call([sys.executable, "-m", "pip", "install", "requests"])

import zipfile
import os
import shutil
import requests

# Set the owner and repository
owner = "brave"
repo = "brave-browser"

# Set the URL for the releases
url = f"https://api.github.com/repos/{owner}/{repo}/releases"

# Get the releases information
response = requests.get(url)
releases = response.json()

# Find the most recent release with the required asset
latest_release = None
for release in releases:
    for a in release["assets"]:
        if a["name"].endswith("win32-x64.zip"):
            latest_release = release
            break
    if latest_release:
        break

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
        print("Downloading asset...")
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

        print("Extracting asset...")
        with zipfile.ZipFile(filename, "r") as zip_ref:
            zip_ref.extractall(extract_dir)

        # Delete the downloaded file
        os.remove(filename)

        print("Extraction completed successfully")
    else:
        print("Asset not found")
else:
    print("No releases found")
