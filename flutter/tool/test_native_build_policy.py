#!/usr/bin/env python3
"""Regression tests for the Flutter native package rebuild policy."""
from __future__ import annotations

import unittest

from native_build_policy import (
    lockfile_change_is_dart_only,
    native_targets,
    pubspec_change_is_dart_only,
)


BASE_PUBSPEC = """name: frame_ebook
version: 0.4.0+1
dependencies:
  flutter:
    sdk: flutter
  web: ^1.1.1
  webview_flutter: ^4.14.1
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0
flutter:
  uses-material-design: true
  assets:
    - assets/fonts/OFL.txt
"""

BASE_LOCK = """packages:
  flutter:
    dependency: direct main
    source: sdk
    version: "0.0.0"
  web:
    dependency: direct main
    source: hosted
    version: "1.1.1"
  webview_flutter:
    dependency: direct main
    source: hosted
    version: "4.14.1"
sdks:
  dart: ">=3.13.0 <4.0.0"
"""


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

    def test_pure_dart_dependency_additions_do_not_rebuild_apps(self) -> None:
        after = BASE_PUBSPEC.replace(
            "  web: ^1.1.1\n",
            "  web: ^1.1.1\n"
            "  koni_archive_core: ^0.9.0\n"
            "  koni_zip: ^0.9.0\n",
        )
        self.assertTrue(pubspec_change_is_dart_only(BASE_PUBSPEC, after))
        self.assertEqual(
            native_targets(
                ["flutter/pubspec.yaml"],
                dart_only_dependency_manifests=True,
            ),
            (False, False),
        )

    def test_sha256_dependency_is_dart_only(self) -> None:
        after = BASE_PUBSPEC.replace(
            "  web: ^1.1.1\n",
            "  web: ^1.1.1\n  crypto: ^3.0.6\n",
        )
        self.assertTrue(pubspec_change_is_dart_only(BASE_PUBSPEC, after))

    def test_xml_parser_dependency_is_dart_only(self) -> None:
        after = BASE_PUBSPEC.replace(
            "  web: ^1.1.1\n",
            "  web: ^1.1.1\n  xml: ^7.1.0\n",
        )
        self.assertTrue(pubspec_change_is_dart_only(BASE_PUBSPEC, after))

        after_lock = BASE_LOCK.replace(
            "  webview_flutter:\n",
            "  args:\n"
            "    dependency: transitive\n"
            "    source: hosted\n"
            '    version: "2.7.0"\n'
            "  petitparser:\n"
            "    dependency: transitive\n"
            "    source: hosted\n"
            '    version: "7.1.0"\n'
            "  xml:\n"
            "    dependency: direct main\n"
            "    source: hosted\n"
            '    version: "7.1.0"\n'
            "  webview_flutter:\n",
        )
        self.assertTrue(lockfile_change_is_dart_only(BASE_LOCK, after_lock))
        self.assertEqual(
            native_targets(
                ["flutter/pubspec.yaml", "flutter/pubspec.lock"],
                dart_only_dependency_manifests=True,
            ),
            (False, False),
        )

    def test_native_plugin_dependency_addition_still_rebuilds_apps(self) -> None:
        after = BASE_PUBSPEC.replace(
            "  web: ^1.1.1\n",
            "  web: ^1.1.1\n  new_native_plugin: ^1.0.0\n",
        )
        self.assertFalse(pubspec_change_is_dart_only(BASE_PUBSPEC, after))

    def test_packaged_resource_changes_still_rebuild_apps(self) -> None:
        after = BASE_PUBSPEC.replace(
            "    - assets/fonts/OFL.txt\n",
            "    - assets/fonts/OFL.txt\n    - assets/reader/\n",
        )
        self.assertFalse(pubspec_change_is_dart_only(BASE_PUBSPEC, after))

    def test_lockfile_allows_only_reviewed_dart_packages(self) -> None:
        after = BASE_LOCK.replace(
            "  webview_flutter:\n",
            "  koni_archive_core:\n"
            "    dependency: transitive\n"
            "    source: hosted\n"
            "    version: \"0.9.0\"\n"
            "  koni_zip:\n"
            "    dependency: direct main\n"
            "    source: hosted\n"
            "    version: \"0.9.0\"\n"
            "  webview_flutter:\n",
        )
        self.assertTrue(lockfile_change_is_dart_only(BASE_LOCK, after))

        native_after = after.replace(
            "  webview_flutter:\n",
            "  unreviewed_plugin:\n"
            "    dependency: transitive\n"
            "    source: hosted\n"
            "    version: \"1.0.0\"\n"
            "  webview_flutter:\n",
        )
        self.assertFalse(lockfile_change_is_dart_only(BASE_LOCK, native_after))

    def test_mixed_platform_changes_rebuild_only_affected_platforms(self) -> None:
        paths = [
            "flutter/tool/android/NativeReader.java",
            "flutter/lib/library/frame_bookshelf_screen.dart",
        ]
        self.assertEqual(native_targets(paths), (True, False))


if __name__ == "__main__":
    unittest.main(verbosity=2)
