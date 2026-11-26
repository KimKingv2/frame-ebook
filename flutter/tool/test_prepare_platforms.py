#!/usr/bin/env python3
"""Regression tests for generated FRAME Reader Web startup assets."""
from __future__ import annotations

import json
import re
import tempfile
import unittest
from pathlib import Path

from prepare_platforms import patch_web_index, patch_web_manifest


class PreparePlatformsWebTests(unittest.TestCase):
    def _write_generated_index(self, root: Path) -> Path:
        index = root / "index.html"
        index.write_text(
            """<!DOCTYPE html>
<html>
<head>
  <base href="/">
  <meta charset="UTF-8">
  <meta name="description" content="A new Flutter project.">
  <!-- <meta name="viewport" content="width=device-width, initial-scale=1.0"> -->
  <title>frame_ebook</title>
  <link rel="manifest" href="manifest.json">
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
""",
            encoding="utf-8",
        )
        return index

    def test_web_index_has_branding_recovery_and_sync_listener(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index = self._write_generated_index(root)
            patch_web_index(index)

            html = index.read_text(encoding="utf-8")
            boot = (root / "frame-boot.js").read_text(encoding="utf-8")

            for expected in (
                '<html lang="zh-Hant">',
                "<title>FRAME Reader</title>",
                'name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover"',
                'name="theme-color" content="#12101a"',
                'name="color-scheme" content="dark"',
                'name="apple-mobile-web-app-title" content="FRAME Reader"',
                'id="frame-boot-message"',
                'id="frame-boot-hint"',
                'id="frame-boot-retry"',
                'id="frame-boot-style"',
            ):
                self.assertIn(expected, html)

            uncommented_html = re.sub(r"<!--.*?-->", "", html, flags=re.DOTALL)
            self.assertIn(
                'name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover"',
                uncommented_html,
            )

            boot_position = html.index('<script src="frame-boot.js"></script>')
            flutter_position = html.index('<script src="flutter_bootstrap.js"')
            self.assertLess(boot_position, flutter_position)
            self.assertIn("18000", boot)
            self.assertIn("flutter-first-frame", boot)
            self.assertIn("window.location.reload()", boot)

    def test_web_index_patch_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index = self._write_generated_index(root)

            patch_web_index(index)
            patch_web_index(index)

            html = index.read_text(encoding="utf-8")
            self.assertEqual(html.count('id="frame-boot-message"'), 1)
            self.assertEqual(html.count('id="frame-boot-style"'), 1)
            self.assertEqual(html.count('<script src="frame-boot.js"></script>'), 1)
            self.assertEqual(html.count('<title>FRAME Reader</title>'), 1)
            uncommented_html = re.sub(r"<!--.*?-->", "", html, flags=re.DOTALL)
            self.assertEqual(
                len(re.findall(r'<meta\b(?=[^>]*\bname="description")', uncommented_html)),
                1,
            )

    def test_manifest_uses_frame_reader_identity_and_preserves_icons(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest_path = Path(directory) / "manifest.json"
            icons = [{"src": "icons/Icon-192.png", "sizes": "192x192"}]
            manifest_path.write_text(
                json.dumps({"name": "frame_ebook", "icons": icons}),
                encoding="utf-8",
            )

            patch_web_manifest(manifest_path)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

            self.assertEqual(manifest["name"], "FRAME Reader")
            self.assertEqual(manifest["short_name"], "FRAME")
            self.assertEqual(manifest["start_url"], "/flutter-preview/")
            self.assertEqual(manifest["scope"], "/flutter-preview/")
            self.assertEqual(manifest["background_color"], "#12101a")
            self.assertEqual(manifest["theme_color"], "#12101a")
            self.assertEqual(manifest["orientation"], "any")
            self.assertEqual(manifest["icons"], icons)


if __name__ == "__main__":
    unittest.main(verbosity=2)
