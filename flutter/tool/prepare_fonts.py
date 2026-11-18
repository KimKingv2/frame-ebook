#!/usr/bin/env python3
"""Fetch and verify the pinned Noto Sans TC font used by all FRAME Ebook targets."""

from __future__ import annotations

import hashlib
import urllib.request
from pathlib import Path

SOURCE_REVISION = "f8d157532fbfaeda587e826d4cd5b21a49186f7c"
BASE_URL = f"https://raw.githubusercontent.com/notofonts/noto-cjk/{SOURCE_REVISION}"
FONT = {
    "path": "Sans/Variable/TTF/Subset/NotoSansTC-VF.ttf",
    "name": "NotoSansTC-VF.ttf",
    "size": 11_942_800,
    "git_blob_sha1": "fa89e00d41bf1894f03a3e8f775b7a362cafdfd4",
}
LICENSE = {
    "path": "Sans/LICENSE",
    "name": "OFL.txt",
    "size": 4_301,
    "git_blob_sha1": "d952d62c065f3f35fb83a173496e90b21525aef3",
}


def git_blob_sha1(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode("ascii")
    return hashlib.sha1(header + data).hexdigest()


def fetch_verified(spec: dict[str, object], destination: Path) -> None:
    expected_size = int(spec["size"])
    expected_sha = str(spec["git_blob_sha1"])

    if destination.is_file():
        existing = destination.read_bytes()
        if len(existing) == expected_size and git_blob_sha1(existing) == expected_sha:
            print(f"Verified existing {destination.name}")
            return

    url = f"{BASE_URL}/{spec['path']}"
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "FRAME-Ebook-font-asset-builder/1.0"},
    )
    print(f"Downloading {spec['name']} from pinned Noto CJK revision...")
    with urllib.request.urlopen(request, timeout=180) as response:
        data = response.read()

    actual_sha = git_blob_sha1(data)
    if len(data) != expected_size or actual_sha != expected_sha:
        raise SystemExit(
            f"Verification failed for {spec['name']}: "
            f"size={len(data)} sha1={actual_sha}"
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(destination)
    print(f"Verified and saved {destination}")


def main() -> None:
    project = Path(__file__).resolve().parents[1]
    font_dir = project / "assets" / "fonts"
    fetch_verified(FONT, font_dir / FONT["name"])
    fetch_verified(LICENSE, font_dir / LICENSE["name"])


if __name__ == "__main__":
    main()
