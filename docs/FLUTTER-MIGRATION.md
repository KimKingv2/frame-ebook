# FRAME Ebook Flutter migration

Status: Flutter project and transport proof-of-concept exist. Full feature migration has not started. The feature source of truth is the repository main branch at migration start, commit 650d4fac99dded2e2c75fad9921a7ae7597cf90c.

## Non-negotiable parity rule

Reproduce the complete main-branch application across one Flutter codebase targeting Web, macOS and Android. Do not simplify or redesign established user flows, remove controls, replace data models, or add features taken only from the frozen Tauri development branch. When a behaviour is unclear, inspect the main-branch source and preserve it.

The existing main-branch Web application remains deployed and unchanged during migration. The Pages output stays in pages/. Do not point production Pages at Flutter build output until all three targets pass the same feature acceptance checklist and the user explicitly approves cutover.

The detailed feature inventory and acceptance checklist are in docs/MAIN-PARITY-INVENTORY.md.

## Existing main-branch backend to preserve

Reuse the existing Cloudflare Pages Functions, D1 database, R2 cover storage, Cloudflare Access boundary and current API contracts. Do not add Tauri-only pairing/sync endpoints or new database tables as part of a UI port.

Existing API groups:

- Authentication/session readiness: /api/auth/session
- Cloud library source and files: /api/cloud/books, /api/cloud/file, /api/cloud/covers, /api/cloud/scan-list
- Incremental cloud index: /api/cloud/index/state, /api/cloud/index/entries, /api/cloud/index/metadata, /api/cloud/index/complete
- Bangumi comic metadata: /api/comics/bangumi/search, /api/comics/bangumi/link
- User bookshelf and reading data: /api/reading/bookshelf, /api/reading/preferences, /api/reading/state, /api/reading/annotations, /api/reading/events, /api/reading/stats, /api/reading/link

Do not recreate or reset D1, change the migrations, or move original archives to Cloudflare storage. Preserve Cloudflare Access user isolation and the existing stable cloud book identifiers.

## Reader engine

The existing Reading Room uses the vendored Foliate.js engine for EPUB and fixed-layout/CBZ content, with JSZip/ZIP readers and custom reading controls. The first Flutter implementation should retain this engine through a carefully designed platform bridge unless parity tests demonstrate an equivalent implementation. The Web target, macOS and Android must preserve EPUB CFI progress and fixed-layout page-index progress.

Original EPUB/CBZ archives are read-only source files. Do not create full-archive temporary files or persist archive contents/page images to the internal SSD. Keep active archive bytes in memory and use bounded range/page caching where the source and engine permit it. A transport success is not proof that memory-only behaviour has been achieved; inspect and test actual filesystem writes.

## Milestones

### F0 — Flutter engineering baseline
- [x] Isolated Flutter project and three-target CI.
- [x] Native HTTP 302 / Range proof-of-concept.
- [x] Browser-managed HTTP redirect / Range proof-of-concept.
- [ ] Add regression tests for all existing main-branch API and data contracts.

### F1 — Exact application shell
- [ ] Reproduce the main bookshelf layout, theme, typography, responsive breakpoints and navigation.
- [ ] Reproduce recent reading, folder grouping, search, sorting, grid/list modes and book detail dialog.
- [ ] Reproduce the OpenList connection and library manager flows without changing backend contracts.

### F2 — Library and metadata parity
- [ ] Reproduce provider selection, local OpenList login and separate books/comics roots.
- [ ] Reproduce browsing, path navigation, filtering, pagination, scan progress, pause/resume, logs and cover retry.
- [ ] Preserve EPUB OPF metadata, cover extraction, ComicInfo/Bangumi metadata, folder/volume grouping and metadata editing.

### F3 — Reader parity
- [ ] Integrate the existing Foliate.js EPUB and fixed-layout/CBZ engine.
- [ ] Reproduce the full TOC, footnote, page navigation, bookmark, highlight, underline and note flows.
- [ ] Reproduce all text appearance, layout, comic layout, theme, backdrop and fullscreen controls.
- [ ] Preserve progress restoration and save lifecycle.

### F4 — Personal reading data parity
- [ ] Preserve reading preferences, bookmarks, annotations and metadata through existing APIs.
- [ ] Preserve foreground/idle reading-time tracking, daily goals, history, streaks and statistics.
- [ ] Preserve JSON and CSV export.

### F5 — Three-platform release
- [ ] Flutter Web preview separate from the existing production Pages app.
- [ ] macOS arm64 build, install and full reading tests.
- [ ] Android APK install and full reading tests on the target devices.
- [ ] Run the complete main-parity acceptance checklist on each platform.
- [ ] Only cut over Web after explicit user acceptance.
