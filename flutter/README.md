# FRAME Ebook Flutter

The Flutter client is being rebuilt against the exact product behaviour in the repository's main branch. Main is the sole feature and visual reference. The three targets are Web, macOS and Android.

## Main-branch source map

- Home bookshelf: `pages/index.html`, `pages/assets/library.js`, `pages/assets/library-store.js`
- Cloud connection, directory browser and scanner: `pages/cloud/index.html`, `pages/assets/cloud-library.js`, `pages/assets/local-openlist.js`
- EPUB / CBZ Reading Room: `pages/epub-lab/index.html`, `pages/assets/epub-lab-comics-20261112.js`
- Reading statistics: `pages/reading-stats/index.html`, `pages/assets/reading-stats.js`, `pages/assets/reading-tracker.js`
- Existing backend contracts: `functions/api/**`, `functions/_lib/**`, `migrations/**`

The required feature-by-feature acceptance list is `docs/MAIN-PARITY-INVENTORY.md`.

The agreed three-platform target architecture and migration sequence are documented in `docs/FLUTTER-THREE-PLATFORM-ARCHITECTURE.md`.

## Font assets

All three Flutter targets bundle **Noto Sans TC** so Traditional Chinese, Latin text and UI labels render consistently without runtime font requests to Google Fonts. The font is fetched by `tool/prepare_fonts.py` from a pinned revision of the official `notofonts/noto-cjk` repository and checked against its Git blob SHA before use. Its SIL Open Font License is included as `assets/fonts/OFL.txt`.

Before dependency resolution or a local build, run:

```sh
python3 tool/prepare_fonts.py
flutter pub get
```

## Current implementation stage

The Flutter shell checks the existing Cloudflare Access session, retrieves the real D1 bookshelf, groups folder volumes using the main-branch key, renders separate EPUB and Comics shelves, recent reading, search, sort, grid/list modes, folder navigation, cover thumbnails from the private R2 endpoint and basic metadata editing.

Until a feature is ported and parity-tested, the existing same-origin main page remains available as a compatibility bridge for the original Cloud Manager, Reading Room and Reading Statistics. These bridges do not change the backend or create a second data model. They are transitional, not a claim that the feature has already been rewritten in Flutter.

The home shelf reads only existing APIs. The original EPUB/CBZ files remain in Alist/OpenList. Cover responses are retained only in a bounded in-memory cache. Do not add persistent archive, expanded ZIP or page-image caches.

## Run

From this directory:

- `python3 tool/prepare_fonts.py`
- `flutter pub get`
- `flutter run -d macos`
- `flutter run -d chrome`
- `flutter run -d <Android device ID>`

For a non-production Pages preview, pass its API origin only when that origin serves the existing Pages Functions:

`--dart-define=FRAME_EBOOK_API_BASE_URL=https://your-preview-host.example`

Native self-use defaults to `https://frame-ebook.pages.dev`; this can also be overridden with the same dart-define.

## Build

- `flutter analyze`
- `flutter test`
- `flutter build web`
- `flutter build macos`
- `flutter build apk`

GitHub Actions generates platform scaffolding and verifies the pinned font asset in each CI job. It applies the Android release INTERNET permission plus the macOS App Sandbox outgoing-network entitlement. Changes to Flutter source on `main` build and publish the Web artifact to `pages/flutter-preview/`; the default root page remains a separate legacy route until a deliberate root-path cutover. Do not open the Web artifact's `index.html` directly with `file://`: the Web app must be served over HTTPS from the same protected hostname as the existing Pages Functions, so Cloudflare Access cookies and same-origin `/api/*` calls work.

### Android Reading Room transport

The Android legacy Reading Room bridge uses a native WebView with an HTTP resource interceptor. It converts the existing same-origin `/api/cloud/file` stream/redirect request into the protected Pages 302 lookup, follows the signed HTTPS storage redirect with the Access cookie only on the Pages request, strips credentials on cross-origin hops, and returns the upstream response as a native streaming `InputStream`. This avoids relaying large archives through Pages and avoids creating a disk cache or temporary archive. The original Reader JS still owns EPUB/CBZ parsing and its normal D1 progress/annotation APIs.
