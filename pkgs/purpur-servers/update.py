#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3Packages.requests

import json
import requests
import hashlib
from pathlib import Path
from requests.adapters import HTTPAdapter, Retry

ENDPOINT = "https://api.purpurmc.org/v2/purpur"

TIMEOUT = 5
RETRIES = 5

class TimeoutHTTPAdapter(HTTPAdapter):
    def __init__(self, *args, **kwargs):
        self.timeout = TIMEOUT
        if "timeout" in kwargs:
            self.timeout = kwargs["timeout"]
            del kwargs["timeout"]
        super().__init__(*args, **kwargs)

    def send(self, request, **kwargs):
        timeout = kwargs.get("timeout")
        if timeout is None:
            kwargs["timeout"] = self.timeout
        return super().send(request, **kwargs)


def make_client():
    http = requests.Session()
    retries = Retry(total=RETRIES, backoff_factor=1, status_forcelist=[429, 500, 502, 503, 504])
    http.mount('https://', TimeoutHTTPAdapter(max_retries=retries))
    return http


def get_game_versions(client):
    print("Fetching game versions")
    response = client.get(ENDPOINT)
    
    if response.status_code != 200:
        print(f"Failed to fetch versions: {response.status_code}")
        print(response.text)
        return []
    
    data = response.json()
    print(json.dumps(data, indent=2))
    
    if "versions" in data:
        return data["versions"][-3:]
    
    print("Key 'versions' not found in response")
    return []


def get_builds(version, client):
    print(f"Fetching builds for {version}")
    data = client.get(f"{ENDPOINT}/{version}").json()

    print(json.dumps(data, indent=2))
    return data["builds"]["all"][-3:]


def download_file(url, client, download_path):
    print(f"Downloading {url}")
    response = client.get(url, stream=True)
    
    if response.status_code != 200:
        print(f"Failed to download file: {response.status_code}")
        return None

    with open(download_path, 'wb') as f:
        for chunk in response.iter_content(1024):
            f.write(chunk)

    return download_path


def compute_sha256(file_path):
    print(f"Computing SHA-256 for {file_path}")
    sha256_hash = hashlib.sha256()
    with open(file_path, "rb") as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()


def main(lock, client):
    output = {}
    print("Starting fetch")

    download_dir = Path("downloads")
    download_dir.mkdir(exist_ok=True)

    for version in get_game_versions(client):
        output[version] = {}
        for build in get_builds(version, client):
            build_url = f"{ENDPOINT}/{version}/{build}/download"
            
            # Download the file
            download_path = download_file(build_url, client, download_dir / f"{version}_{build}.jar")
            if download_path is None:
                continue  # Skip if the download failed
            
            # Compute the SHA-256 hash
            sha256_hash = compute_sha256(download_path)
            
            output[version][build] = {
                "url": build_url,
                "sha256": sha256_hash,
            }

    json.dump(output, lock, indent=2)
    lock.write("\n")


if __name__ == "__main__":
    folder = Path(__file__).parent
    lock_path = folder / "lock.json"
    main(open(lock_path, "w"), make_client())
