#!/usr/bin/env python3
"""Patch generated Flutter platform scaffolding for release networking.

Flutter's debug Android manifest can provide INTERNET during development, but
the release APK must declare it in the main manifest. Sandboxed macOS builds
must explicitly allow outgoing network connections for WKWebView and HTTP.
"""
from __future__ import annotations

import plistlib
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID_NS = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID_NS)


def patch_android_manifest(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"Generated Android manifest not found: {path}")
    tree = ET.parse(path)
    root = tree.getroot()
    permission_name = f"{{{ANDROID_NS}}}name"
    has_internet = any(
        node.tag.endswith("uses-permission")
        and node.attrib.get(permission_name) == "android.permission.INTERNET"
        for node in root
    )
    if not has_internet:
        permission = ET.Element(
            "uses-permission",
            {permission_name: "android.permission.INTERNET"},
        )
        application = next(
            (index for index, node in enumerate(list(root)) if node.tag.endswith("application")),
            len(root),
        )
        root.insert(application, permission)
        tree.write(path, encoding="utf-8", xml_declaration=True)


def patch_macos_entitlements(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"Generated macOS entitlements not found: {path}")
    with path.open("rb") as source:
        entitlements = plistlib.load(source)
    if entitlements.get("com.apple.security.app-sandbox") is True:
        entitlements["com.apple.security.network.client"] = True
        with path.open("wb") as target:
            plistlib.dump(entitlements, target, fmt=plistlib.FMT_XML, sort_keys=True)


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    patch_android_manifest(root / "android/app/src/main/AndroidManifest.xml")
    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        patch_macos_entitlements(root / "macos/Runner" / name)
    print("Platform network permissions configured: Android INTERNET; macOS outgoing network client.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Platform permission preparation failed: {error}", file=sys.stderr)
        raise
