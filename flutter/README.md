# FRAME Ebook Flutter

This is the Flutter client being built to reproduce the existing application in the repository's main branch across Web, macOS and Android.

The source of truth for product behaviour and visual parity is the current main branch:

- Home bookshelf: pages/index.html and pages/assets/library.js
- OpenList connection, browsing and scanning: pages/cloud/index.html and pages/assets/cloud-library.js
- Book metadata and bookshelf data: pages/assets/library-store.js and functions/api/reading/*
- EPUB / CBZ Reading Room: pages/epub-lab/index.html and pages/assets/epub-lab-comics-20261112.js
- Reading-time tracking and statistics: pages/assets/reading-tracker.js and pages/assets/reading-stats.js

The current Flutter screen is still a transport proof-of-concept. It is not the finished product and does not yet have feature parity. Do not remove or change the existing Pages application while porting the interface and features.

## Run

From this directory:

- flutter pub get
- flutter run -d macos
- flutter run -d chrome
- flutter run -d <Android device ID>

## Build

- flutter analyze
- flutter test
- flutter build web
- flutter build macos
- flutter build apk

The GitHub Actions workflow generates platform scaffolding for CI. The Flutter Web output is not wired to the production Cloudflare Pages deployment.
