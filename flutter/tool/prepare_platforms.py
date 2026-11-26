#!/usr/bin/env python3
"""Patch generated Flutter platform scaffolding for release networking.

Flutter's debug Android manifest can provide INTERNET during development, but
the release APK must declare it in the main manifest. Sandboxed macOS builds
must explicitly allow outgoing network connections for WKWebView and HTTP.
"""
from __future__ import annotations

import json
import plistlib
import re
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
        # User-selected save dialogs grant access only to the destination
        # chosen for this export; no broad Downloads-folder entitlement is
        # needed because the app never writes exports without user consent.
        entitlements["com.apple.security.files.user-selected.read-write"] = True
        with path.open("wb") as target:
            plistlib.dump(entitlements, target, fmt=plistlib.FMT_XML, sort_keys=True)



def _upsert_web_meta(html: str, name: str, content: str) -> str:
    pattern = re.compile(
        r"<meta\b(?=[^>]*\bname=['\"]" + re.escape(name) + r"['\"])[^>]*>",
        re.IGNORECASE,
    )
    tag = f'<meta name="{name}" content="{content}">'
    for match in pattern.finditer(html):
        comment_start = html.rfind("<!--", 0, match.start())
        comment_end = html.rfind("-->", 0, match.start())
        if comment_start > comment_end:
            continue
        return html[:match.start()] + tag + html[match.end():]
    if "</head>" not in html:
        raise ValueError("Generated Flutter Web index is missing </head>.")
    return html.replace("</head>", f"  {tag}\n</head>", 1)


def patch_web_index(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"Generated Flutter Web index not found: {path}")
    html = path.read_text(encoding="utf-8")
    if not re.search(r"<html\b", html, re.IGNORECASE):
        raise ValueError("Generated Flutter Web index has no html element.")
    if not re.search(r"<body\b", html, re.IGNORECASE):
        raise ValueError("Generated Flutter Web index has no body element.")

    html = re.sub(
        r"<html\b[^>]*>",
        '<html lang="zh-Hant">',
        html,
        count=1,
        flags=re.IGNORECASE,
    )
    html = re.sub(
        r"<title\b[^>]*>.*?</title>",
        "<title>FRAME Reader</title>",
        html,
        count=1,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if "<title>FRAME Reader</title>" not in html:
        html = html.replace("</head>", "<title>FRAME Reader</title>\n</head>", 1)

    for name, content in (
        ("viewport", "width=device-width, initial-scale=1.0, viewport-fit=cover"),
        ("theme-color", "#12101a"),
        ("color-scheme", "dark"),
        ("description", "FRAME Reader，專屬的雲端電子書與漫畫閱讀空間。"),
        ("apple-mobile-web-app-capable", "yes"),
        ("apple-mobile-web-app-status-bar-style", "black-translucent"),
        ("apple-mobile-web-app-title", "FRAME Reader"),
    ):
        html = _upsert_web_meta(html, name, content)

    style = """<style id="frame-boot-style">
:root { color-scheme: dark; }
html, body {
  width: 100%;
  min-height: 100%;
  margin: 0;
  background: #12101a;
}
#frame-boot-message {
  position: fixed;
  inset: 0;
  z-index: 99999;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  padding: max(24px, env(safe-area-inset-top)) 24px
    max(24px, env(safe-area-inset-bottom));
  box-sizing: border-box;
  background: radial-gradient(ellipse at 50% 42%, #241a38 0%, #12101a 68%);
  color: #d8c8ff;
  font: 14px/1.7 -apple-system, BlinkMacSystemFont, sans-serif;
  text-align: center;
}
#frame-boot-message[hidden],
#frame-boot-hint[hidden],
#frame-boot-retry[hidden] { display: none; }
#frame-boot-mark {
  color: #b99bff;
  font-size: 22px;
  font-weight: 700;
  letter-spacing: .24em;
}
#frame-boot-title {
  margin: 8px 0 0;
  color: #f0eaff;
  font-size: 16px;
  font-weight: 600;
}
#frame-boot-detail, #frame-boot-hint {
  margin: 0;
  color: #a99bbf;
}
#frame-boot-retry {
  margin-top: 12px;
  padding: 9px 20px;
  border: 1px solid #7659a8;
  border-radius: 999px;
  background: #2a203b;
  color: #f0eaff;
  font: inherit;
  cursor: pointer;
}
</style>"""
    style_pattern = re.compile(
        r"<style\b(?=[^>]*\bid=['\"]frame-boot-style['\"])[^>]*>.*?</style>",
        re.IGNORECASE | re.DOTALL,
    )
    if style_pattern.search(html):
        html = style_pattern.sub(style, html, count=1)
    else:
        if "</head>" not in html:
            raise ValueError("Generated Flutter Web index is missing </head>.")
        html = html.replace("</head>", style + "\n</head>", 1)

    overlay = """<section id="frame-boot-message" role="status" aria-live="polite">
  <div id="frame-boot-mark" aria-hidden="true">FRAME</div>
  <p id="frame-boot-title">正在準備你的閱讀空間</p>
  <p id="frame-boot-detail">正在連線書架與同步閱讀狀態……</p>
  <p id="frame-boot-hint" hidden>啟動時間比預期長，請確認網路連線後重試。</p>
  <button id="frame-boot-retry" type="button" hidden>重新載入</button>
</section>"""
    section_pattern = re.compile(
        r"<section\b(?=[^>]*\bid=['\"]frame-boot-message['\"])[^>]*>.*?</section>",
        re.IGNORECASE | re.DOTALL,
    )
    legacy_div_pattern = re.compile(
        r"<div\b(?=[^>]*\bid=['\"]frame-boot-message['\"])[^>]*>.*?</div>",
        re.IGNORECASE | re.DOTALL,
    )
    if section_pattern.search(html):
        html = section_pattern.sub(overlay, html, count=1)
    elif legacy_div_pattern.search(html):
        html = legacy_div_pattern.sub(overlay, html, count=1)
    else:
        body_match = re.search(r"<body\b[^>]*>", html, re.IGNORECASE)
        if body_match is None:
            raise ValueError("Generated Flutter Web index has no body opening tag.")
        html = html[:body_match.end()] + "\n" + overlay + html[body_match.end():]

    boot_script = """(function () {
  var message = document.getElementById('frame-boot-message');
  if (!message) return;

  var hint = document.getElementById('frame-boot-hint');
  var retry = document.getElementById('frame-boot-retry');
  var firstFrameReceived = false;

  var timeoutId = window.setTimeout(function () {
    if (firstFrameReceived || !message.isConnected) return;
    if (hint) hint.hidden = false;
    if (retry) retry.hidden = false;
  }, 18000);

  if (retry) {
    retry.addEventListener('click', function () {
      window.location.reload();
    });
  }

  window.addEventListener('flutter-first-frame', function () {
    firstFrameReceived = true;
    window.clearTimeout(timeoutId);
    message.remove();
  }, { once: true });
}());"""
    (path.parent / "frame-boot.js").write_text(boot_script + "\n", encoding="utf-8")

    boot_tag = '<script src="frame-boot.js"></script>'
    html = re.sub(
        r"<script\b(?=[^>]*\bsrc=['\"]frame-boot\.js['\"])[^>]*>\s*</script>",
        "",
        html,
        flags=re.IGNORECASE,
    )
    bootstrap_match = re.search(
        r"<script\b(?=[^>]*\bsrc=['\"]flutter_bootstrap\.js['\"])[^>]*>",
        html,
        re.IGNORECASE,
    )
    if bootstrap_match is None:
        raise ValueError("Generated Flutter Web index has no flutter_bootstrap.js script.")
    html = html[:bootstrap_match.start()] + boot_tag + "\n  " + html[bootstrap_match.start():]
    path.write_text(html, encoding="utf-8")


def patch_web_manifest(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"Generated Flutter Web manifest not found: {path}")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    manifest.update({
        "name": "FRAME Reader",
        "short_name": "FRAME",
        "start_url": "/flutter-preview/",
        "scope": "/flutter-preview/",
        "display": "standalone",
        "background_color": "#12101a",
        "theme_color": "#12101a",
        "description": "FRAME Reader，專屬的雲端電子書與漫畫閱讀空間。",
        "orientation": "any",
        "prefer_related_applications": False,
    })
    path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


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
            "import io.flutter.embedding.android.FlutterActivity\n"
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
    patch_web_manifest(root / "web/manifest.json")
    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        patch_macos_entitlements(root / "macos/Runner" / name)
    print("Platform settings configured: Web dark startup fallback; Android INTERNET; macOS outgoing network client and user-selected file-save access.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Platform permission preparation failed: {error}", file=sys.stderr)
        raise
