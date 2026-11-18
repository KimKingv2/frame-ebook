# FRAME Ebook Flutter migration

Status: Flutter Web/macOS/Android shell, D1-backed bookshelf and Flutter-native reading statistics are implemented. The full legacy Reading Room and Cloud Manager remain available through embedded compatibility views while their Flutter-native replacements are built.

## Non-negotiable parity rule

Reproduce the complete main-branch application across one Flutter codebase targeting Web, macOS and Android. Do not simplify or redesign established user flows, remove controls, replace data models, or add features taken only from the frozen Tauri development branch. When a behaviour is unclear, inspect the main-branch source and preserve it.

The exact product checklist is `docs/MAIN-PARITY-INVENTORY.md`. The feature source of truth is the repository main branch. The Flutter feature branch contains a byte-identical copy of all 92 main-branch source blobs; Flutter files, CI and migration docs are isolated additions.

The existing main-branch Pages application remains deployed and unchanged during migration. The Pages output stays in `pages/`. Do not point production Pages at Flutter build output until all three targets pass the same feature acceptance checklist and the user explicitly approves cutover.

## Existing main-branch backend to preserve

Reuse the existing Cloudflare Pages Functions, D1 database, R2 cover storage, Cloudflare Access boundary and current API contracts. Do not add Tauri-only pairing/sync endpoints or new database tables as part of a UI port.

Existing API groups:

- Authentication/session readiness: `/api/auth/session`
- Cloud library source and files: `/api/cloud/books`, `/api/cloud/file`, `/api/cloud/covers`, `/api/cloud/scan-list`
- Incremental cloud index: `/api/cloud/index/state`, `/entries`, `/metadata`, `/complete`
- Bangumi comic metadata: `/api/comics/bangumi/search`, `/link`
- User bookshelf and reading data: `/api/reading/bookshelf`, `/preferences`, `/state`, `/annotations`, `/events`, `/stats`, `/link`

Do not recreate or reset D1, change migrations, or move original archives to Cloudflare storage. Preserve Cloudflare Access user isolation and the existing stable cloud book identifiers.

## Access session model

- Web uses the current browser's same-origin Cloudflare Access session.
- macOS and Android complete Access authentication in the native WebView. The app API client reads cookies from the same WebView cookie store and sends them only to the configured FRAME API origin.
- Do not add a separate Reader password, custom login table, Tauri device pairing flow, or second identity system.
- Keep request and credential values out of logs.

## Reader and compatibility bridge

The main Reading Room currently uses the vendored Foliate.js engine for EPUB and fixed-layout/CBZ content, with JSZip/ZIP readers and custom controls. The current Flutter integration embeds the original same-origin Pages Reader inside Flutter navigation: Web uses a same-origin iframe and native targets use the app's WebView. This bridge preserves all existing Reader controls while the Flutter reader is built; it is a transition mechanism, not a completed Flutter-native reader implementation.

Original EPUB/CBZ archives are read-only source files. Do not create full-archive temporary files or persist archive contents/page images to the internal SSD. Keep active archive bytes in memory and use bounded memory/page caching where the source and engine permit it. A transport success is not proof that memory-only behaviour has been achieved; inspect and test actual filesystem writes.

## Current Flutter implementation

- Cloudflare Access session gate and native WebView login bridge.
- Shared existing Pages API client for Web and native targets.
- D1-backed home bookshelf and main's folder-volume grouping.
- Flutter-native reading statistics backed by the existing D1 stats/preferences APIs, including period summaries, daily goal, reading streaks, calendar, trends, top books, time bands, recent sessions and JSON/CSV data export.
- Recent reading, four sort modes, search, grid/list, books/comics categories and folder detail navigation.
- R2 cover retrieval with bounded in-memory cache.
- Basic title, author and shelf metadata editing.
- Main Reader, Cloud Manager and Statistics routes remain available through a compatibility bridge while each feature is being ported.

These items must still pass CI and device verification before being treated as complete. Other checklist items remain open.

## Milestones

### F0 — Flutter engineering baseline
- [x] Isolated Flutter project and three-target CI.
- [x] Native HTTP 302 / Range proof-of-concept.
- [x] Browser-managed HTTP redirect / Range proof-of-concept.
- [ ] Run real provider redirect/Range tests on macOS and Android.
- [ ] Run browser CORS and exposed-header tests.
- [ ] Verify original archives and page cache never write to persistent storage.

### F1 — Exact application shell and first bookshelf pass
- [x] Main-branch source inventory and feature acceptance checklist.
- [x] Cloudflare Access session gate and native WebView login bridge.
- [x] Shared API client for main Pages Functions.
- [x] First D1-backed bookshelf rendering and folder grouping.
- [x] Main sort, search, grid/list, recent reading and Books/Comics shelf controls.
- [x] R2 cover endpoint integration with RAM-only bounded cache.
- [x] Basic book metadata edit using the existing reading-state API.
- [ ] Port the full home detail dialog including Bangumi and legacy-data linking.
- [ ] Port the Cloud Manager and all source/scanning workflows.
- [ ] Verify the full bookshelf against the live main site.

### F2 — Library and metadata parity
- [ ] Reproduce all four providers and local OpenList login/token lifecycle.
- [ ] Reproduce two independent Books/Comics roots and all connection controls.
- [ ] Reproduce listing, pagination, scanning, pause/resume, logs and cover retry.
- [ ] Reproduce EPUB OPF metadata, cover extraction, CBZ metadata and Bangumi propagation.

### F3 — Reader parity
- [ ] Port all EPUB, fixed-layout EPUB and CBZ behaviour from the main reader.
- [ ] Preserve TOC, footnotes, bookmarks, highlights, underline, notes and progress.
- [ ] Preserve every typography, pagination, comic layout, theme, backdrop and fullscreen control.
- [ ] Retain compatibility with existing EPUB CFI and comic page-index progress.

### F4 — Personal reading data parity
- [ ] Preserve reading preferences, annotations, reading-time events, history and statistics.
- [x] Flutter statistics screen reads the existing D1 stats/preferences APIs and renders period summaries, goal, streaks, calendar, trends, top books, time-of-day and recent sessions.
- [ ] Validate foreground/idle event aggregation against the original tracker on all three targets.
- [ ] Preserve native file-based JSON and CSV export on Web, macOS and Android. Current Flutter statistics screen copies JSON/CSV text to the clipboard.

### F5 — Three-platform release
- [ ] Separate Flutter Web preview and browser Access validation.
- [ ] macOS arm64 install and full Reader tests.
- [ ] Android install and full Reader tests on target devices.
- [ ] Run the complete main-parity acceptance checklist on each platform.
- [ ] Cut over Web only after explicit user acceptance.
