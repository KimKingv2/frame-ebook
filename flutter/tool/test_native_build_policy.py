#!/usr/bin/env python3
"""Regression tests for the Flutter native package rebuild policy."""
from __future__ import annotations

import unittest

from native_build_policy import native_targets


class NativeBuildPolicyTests(unittest.TestCase):
    def test_dart_and_web_changes_do_not_rebuild_native_apps(self) -> None:
        paths = [
            "flutter/lib/main.dart",
            "flutter/lib/core/frame_api_client.dart",
            "flutter/lib/reader/frame_reader_screen.dart",
            "flutter/web/index.html",
            "flutter/test/frame_reader_test.dart",
            "flutter/tool/native_build_policy.py",
            "docs/FLUTTER-THREE-PLATFORM-ARCHITECTURE.md",
            ".github/workflows/flutter-ci.yml",
        ]
        self.assertEqual(native_targets(paths), (False, False))

    def test_android_source_rebuilds_android_only(self) -> None:
        self.assertEqual(
            native_targets(["flutter/tool/android/FrameEbookDirectTransport.java"]),
            (True, False),
        )

    def test_macos_source_rebuilds_macos_only(self) -> None:
        self.assertEqual(
            native_targets(["flutter/macos/Runner/Release.entitlements"]),
            (False, True),
        )

    def test_shared_platform_configuration_rebuilds_both(self) -> None:
        paths = [
            "flutter/pubspec.yaml",
            "flutter/pubspec.lock",
            "flutter/tool/prepare_platforms.py",
            "flutter/tool/prepare_fonts.py",
            "flutter/assets/fonts/NotoSansTC-VF.ttf",
        ]
        self.assertEqual(native_targets(paths), (True, True))

    def test_mixed_platform_changes_rebuild_only_affected_platforms(self) -> None:
        paths = [
            "flutter/tool/android/NativeReader.java",
            "flutter/lib/library/frame_bookshelf_screen.dart",
        ]
        self.assertEqual(native_targets(paths), (True, False))


if __name__ == "__main__":
    unittest.main(verbosity=2)
