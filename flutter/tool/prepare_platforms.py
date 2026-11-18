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



def patch_web_index(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"Generated Flutter Web index not found: {path}")
    html = path.read_text(encoding="utf-8")
    style = """<style>
html, body { margin: 0; min-height: 100%; background: #12101a; }
#frame-boot-message {
  position: fixed; inset: 0; z-index: 99999; display: flex;
  align-items: center; justify-content: center; padding: 24px;
  box-sizing: border-box; background: #12101a; color: #c5adff;
  font: 14px/1.7 -apple-system, BlinkMacSystemFont, sans-serif;
  text-align: center;
}
</style>"""
    if 'id="frame-boot-message"' not in html:
        if "</head>" not in html or "<body" not in html:
            raise ValueError("Generated Flutter Web index has an unexpected structure.")
        html = html.replace("</head>", style + "\n</head>", 1)
        body_start = html.index(">", html.index("<body")) + 1
        boot_script = """window.addEventListener('flutter-first-frame', function () {
  var message = document.getElementById('frame-boot-message');
  if (message) message.remove();
}, { once: true });
"""
        (path.parent / "frame-boot.js").write_text(boot_script, encoding="utf-8")
        boot = """<div id="frame-boot-message">FRAME Ebook 正在啟動……</div>
<script src="frame-boot.js" defer></script>"""
        html = html[:body_start] + "\n" + boot + html[body_start:]
        path.write_text(html, encoding="utf-8")



def patch_android_reader_view(root: Path) -> None:
    source_dir = Path(__file__).resolve().parent / "android"
    package_dir = root / "android/app/src/main/java/com/kimkingv2/frame_ebook"
    package_dir.mkdir(parents=True, exist_ok=True)
    for name in (
        "FrameEbookDirectTransport.java",
        "FrameEbookNativeReaderFactory.java",
        "FrameEbookNativeReaderView.java",
    ):
        source = source_dir / name
        if not source.is_file():
            raise FileNotFoundError(f"Native Android reader source not found: {source}")
        (package_dir / name).write_text(source.read_text(encoding="utf-8"), encoding="utf-8")

    candidates = list((root / "android/app/src/main").rglob("MainActivity.kt"))
    if len(candidates) != 1:
        raise FileNotFoundError("Expected exactly one generated Flutter MainActivity.kt.")
    activity = candidates[0]
    content = activity.read_text(encoding="utf-8")
    if "FrameEbookNativeReaderFactory" not in content:
        content = content.replace(
            "import io.flutter.embedding.android.FlutterActivity",
            "import io.flutter.embedding.android.FlutterActivity\\n"
            "import io.flutter.embedding.engine.FlutterEngine",
        )
        content = content.replace(
            "class MainActivity : FlutterActivity()",
            """class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "frame_ebook/native_reader",
            FrameEbookNativeReaderFactory(flutterEngine.dartExecutor.binaryMessenger)
        )
    }
}""",
        )
        if "FrameEbookNativeReaderFactory" not in content:
            raise ValueError("Could not register the native Android Reader WebView.")
        activity.write_text(content, encoding="utf-8")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    patch_android_manifest(root / "android/app/src/main/AndroidManifest.xml")
    patch_android_reader_view(root)
    patch_web_index(root / "web/index.html")
    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        patch_macos_entitlements(root / "macos/Runner" / name)
    print("Platform boot and network settings configured: Web dark startup fallback; Android INTERNET; macOS outgoing network client.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Platform permission preparation failed: {error}", file=sys.stderr)
        raise
