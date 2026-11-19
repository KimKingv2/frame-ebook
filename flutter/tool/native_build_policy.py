#!/usr/bin/env python3
"""Map changed Flutter files to native app rebuild targets.

Dart feature code is delivered through Web deployment and Shorebird OTA.
Only native sources/configuration and packaged dependencies/resources require
a rebuilt Android or macOS application.
"""
from __future__ import annotations

import sys
from collections.abc import Iterable

ANDROID_PREFIXES = (
    "flutter/android/",
    "flutter/tool/android/",
)
MACOS_PREFIXES = (
    "flutter/macos/",
    "flutter/tool/macos/",
)
SHARED_NATIVE_FILES = {
    "flutter/pubspec.yaml",
    "flutter/pubspec.lock",
    "flutter/tool/prepare_platforms.py",
    "flutter/tool/prepare_fonts.py",
}


def native_targets(paths: Iterable[str]) -> tuple[bool, bool]:
    android = False
    macos = False

    for raw_path in paths:
        path = raw_path.strip()
        if not path:
            continue

        if path.startswith(ANDROID_PREFIXES):
            android = True
        if path.startswith(MACOS_PREFIXES):
            macos = True
        if path in SHARED_NATIVE_FILES or path.startswith("flutter/assets/"):
            android = True
            macos = True

    return android, macos


def main() -> None:
    android, macos = native_targets(sys.stdin)
    print(f"android={'true' if android else 'false'}")
    print(f"macos={'true' if macos else 'false'}")


if __name__ == "__main__":
    main()
