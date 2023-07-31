const fetch = require('node-fetch');
const fs = require('fs');
const AdmZip = require('adm-zip');

// Set the owner and repository
const owner = "brave";
const repo = "brave-browser";

// Set the URL for the releases
const url = `https://api.github.com/repos/${owner}/${repo}/releases`;

// Get the releases information
fetch(url)
    .then(response => response.json())
    .then(releases => {
        // Find the most recent release with the required asset
        let latestRelease = null;
        for (let release of releases) {
            for (let a of release["assets"]) {
                if (a["name"].endsWith("win32-x64.zip")) {
                    latestRelease = release;
                    break;
                }
            }
            if (latestRelease) {
                break;
            }
        }

        if (latestRelease) {
            // Find the asset with a name ending in win32-x64.zip
            let asset = null;
            for (let a of latestRelease["assets"]) {
                if (a["name"].endsWith("win32-x64.zip")) {
                    asset = a;
                    break;
                }
            }

            if (asset) {
                // Get the download URL for the asset
                const downloadUrl = asset["browser_download_url"];

                // Download the asset
                console.log("Downloading asset...");
                fetch(downloadUrl)
                    .then(response => response.buffer())
                    .then(buffer => {
                        // Save the asset to a file
                        const filename = downloadUrl.split("/").pop();
                        fs.writeFileSync(filename, buffer);

                        // Extract the asset to the specified directory
                        const extractDir = "./app";

                        // Delete existing data in the specified directory
                        if (fs.existsSync(extractDir)) {
                            fs.rmdirSync(extractDir, { recursive: true });
                        }

                        console.log("Extracting asset...");
                        const zip = new AdmZip(filename);
                        zip.extractAllTo(extractDir);

                        // Delete the downloaded file
                        fs.unlinkSync(filename);

                        console.log("Extraction completed successfully");
                    });
            } else {
                console.log("Asset not found");
            }
        } else {
            console.log("No releases found");
        }
    });
