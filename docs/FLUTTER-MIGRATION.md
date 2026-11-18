# FRAME Ebook: Flutter three-platform migration

Status: shared transport and WebDAV connection foundation implemented; reader UI and catalog migration remain in progress.

## Product decision

The final client target is one Flutter codebase for Web, macOS and Android.

The existing Web application remains online during the transition and is the feature and UI reference. It must not be deleted or replaced until the Flutter Web release has passed parity checks. The existing Tauri macOS implementation is frozen as a reference and is not the long-term native client.

The Flutter project lives in /flutter; the Cloudflare Pages output remains /pages for now. Do not point the production Pages deployment at flutter/build/web until a separate preview deployment has passed the acceptance checklist.

## Existing services to preserve

The rewrite is client-side. Keep these server resources and contracts unless a documented migration is required:

- Cloudflare Pages Functions in /functions
- D1 schema and migrations in /migrations
- Private R2 cover storage
- Shared MEDIA_AUTH_TOKEN_CACHE KV binding
- Cloudflare Access identity boundary
- Existing per-user bookshelf, reading state, reading preferences, annotations, reading events and statistics APIs
- Device pairing and Bearer-token device sync APIs

The current device pairing and sync API is separate from the Access identity used to approve a pairing. Native clients create a pairing request, the user approves it in the Access-protected Web flow, and the client redeems the approved pairing to obtain a device token. Device sync requests then use the device Bearer token. Never put the device token, WebDAV password or provider JWT into source control or diagnostic logs.

## File source model

Use one WebDAV connection profile with two independent library roots:

1. Books root: EPUB.
2. Comics root: CBZ and fixed-layout EPUB.

The profile is shared by both roots. Do not create separate book and comic connections.

### Credential handling

- macOS stores the WebDAV password in Keychain.
- Android stores it through the platform secure-storage implementation backed by Android Keystore encryption.
- Flutter Web keeps the password in memory for the current page session. The user must reconnect after a reload; it is not written to browser storage by this app.
- The base URL, username and two root paths are non-secret preferences. They do not include a password, token or authorization header.
- Never send WebDAV credentials to D1 or KV.

### macOS and Android

Native clients connect directly to WebDAV. The shared client supports PROPFIND directory listings, HEAD metadata, bounded Range reads and an in-memory EPUB read path. It follows 301, 302, 303, 307 and 308 for file requests, resolves relative Location values, sends credentials only on the configured origin's initial request, rejects redirect loops and HTTPS downgrade, validates 206 and Content-Range, and limits each comic Range request to 1 MiB.

Original EPUB / CBZ archives are never written to a temporary file. EPUB bytes are retained in memory for the active reading session. CBZ pages must be read through bounded Range requests and a bounded RAM page cache.

### Web

Flutter Web uses the browser Fetch API. The browser manages redirects and the final destination must pass browser CORS checks. A remote HTTPS Flutter Web page cannot assume it can connect to an arbitrary HTTP LAN WebDAV server: mixed-content, CORS and local-network access restrictions still apply.

## Existing Pages services to preserve

- Cloudflare Pages Functions in /functions
- D1 frame-reader-db
- Private R2 cover storage
- Shared MEDIA_AUTH_TOKEN_CACHE KV binding
- Cloudflare Access identity boundary
- Existing reading APIs under /api/reading/*
- Existing device pairing and Bearer-token device sync APIs

The existing /api/cloud/file route is for the three server-configured Alist/OpenList providers. It does not handle the direct WebDAV profile.

## Memory and storage rules

- Original EPUB / CBZ bytes stay in memory only while needed.
- CBZ pages use bounded RAM LRU caching; evicted pages are released.
- Do not persist full archives, expanded ZIP directories or page images to the internal SSD.
- A small local preference store may hold non-secret connection settings. It must not hold an original archive or extracted page images.
- D1 remains authoritative for the existing Cloudflare-backed Web reading data.
- WebDAV credentials remain device-local and are never synced through D1.

## Reader strategy

- Keep Foliate.js as the EPUB rendering engine in a Flutter WebView during the first migration phase if it provides the closest compatibility with the established Web reader.
- Keep CBZ page presentation native in Flutter where practical; ZIP reads should be range-backed and bounded.
- Preserve the current EPUB CFI and comic page progress format so Web and native clients can continue to sync where the source identity is compatible.
- Reproduce the current bookshelf grouping, cover aspect ratios, folder navigation, reading controls, appearance settings, bookmarks, annotations, reading statistics and daily goal before retiring the reference Web UI.

## Milestones

### F0 — Transport proof of concept

- [x] Create an isolated Flutter project directory.
- [x] Implement native redirect-aware HTTP range probe.
- [x] Implement browser-managed redirect and range probe.
- [x] Generate platform scaffolding with Flutter SDK in CI.
- [ ] Run a real 302 to signed URL to 206 test on macOS.
- [ ] Run the same test on Android.
- [ ] Run the browser CORS and exposed-header test.
- [ ] Verify no archive is written to disk.

### F1 — Shared app foundation and WebDAV

- [x] Add one WebDAV profile model with separate books and comics roots.
- [x] Add native secure-secret storage and Web session-only secret storage.
- [x] Add shared PROPFIND, HEAD, Range and in-memory EPUB transport.
- [ ] Add connection/profile UI and folder browser.
- [ ] Verify with the user's actual OpenList WebDAV server.

### F2 — Library and metadata

- [ ] Folder-first bookshelf matching the existing Web UI.
- [ ] Recursive source scanning and resumable progress.
- [ ] EPUB OPF and CBZ ComicInfo.xml metadata extraction.
- [ ] Cover extraction and bounded thumbnail cache.

### F3 — Reading engines

- [ ] EPUB rendering bridge and CFI navigation.
- [ ] Native CBZ reader with page-level Range access and RAM LRU.
- [ ] Appearance controls and reading-session lifecycle.

### F4 — Data parity

- [ ] Reading progress and preferences.
- [ ] Bookmarks, highlights and notes.
- [ ] Reading history, statistics and daily goal.
- [ ] Cloud device pairing, incremental sync and revoke handling.

### F5 — Three-platform release

- [ ] Flutter Web preview on a separate Pages target.
- [ ] macOS arm64 build and install test.
- [ ] Android APK install test on target devices.
- [ ] Full feature parity review against the old Web app.
- [ ] Cut over Web only after explicit acceptance.
