# FRAME Ebook Flutter migration

Status: Flutter Web/macOS/Android shell, D1-backed bookshelf and Flutter-native reading statistics are implemented. The full legacy Reading Room and Cloud Manager remain available through embedded compatibility views while their Flutter-native replacements are built.

## Hard acceptance gate: pixel-level Reader parity

The Flutter Reader is not considered complete until it passes the mandatory visual and behavioural gate in [Reader parity acceptance](READER-PARITY-ACCEPTANCE.md). The legacy Reading Room is the single source of truth. Matching the broad layout is not enough: same-size screenshots must be compared, and every visible control and user flow must match. No cutover or "complete" status may be claimed before Web, macOS and Android acceptance. See the full viewport/state matrix and evidence requirements in that document.

## Non-negotiable parity rule

Reproduce the complete main-branch application across one Flutter codebase targeting Web, macOS and Android. Do not simplify or redesign established user flows, remove controls, replace data models, or add features taken only from the frozen Tauri development branch. When a behaviour is unclear, inspect the main-branch source and preserve it.

The exact product checklist is `docs/MAIN-PARITY-INVENTORY.md`. The feature source of truth is the repository main branch. The Flutter feature branch contains a byte-identical copy of all 92 main-branch source blobs; Flutter files, CI and migration docs are isolated additions.

The existing Legacy homepage and Reading Room remain the default production experience. The Pages output stays in `pages/`. User-approved Flutter Web builds may be published as an opt-in route under `/flutter-preview/` while migration continues; do not replace the homepage or default Reading Room until the cross-platform acceptance checklist passes and the user explicitly approves that separate cutover.

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
- Opt-in Flutter EPUB Preview reader: continuous scrolling and single-page and responsive two-page spread pagination; long rich-text paragraphs split at rendered line boundaries with original XHTML text offsets retained for CFI selection and annotations. Image loading triggers in-memory remeasurement. Inline widget content and custom padded/background blocks remain intact rather than being force-split; two-page spreads are supported on wide layouts and fall back to single-page pagination on narrow screens.
- Unified EPUB navigation drawer with nested TOC, separate bookmark and note tabs, annotation deletion/edit actions, CFI jump navigation, a bottom-sheet presentation on compact widths and a right-side drawer on wide layouts. Device-level visual and interaction parity remains pending.
- Fixed-layout EPUB comic reader now has paginated single-page mode, responsive two-page spreads (including RTL ordering), and a lazy vertical long-strip mode. It restores and saves the current spine page through the existing D1 progress fields; adjacent long-strip chapters are loaded on demand through the same Range-backed resource loader.
- Fixed-layout image fitting now supports fit-page and fit-width. The reader appearance sheet now exposes comic reading mode, page layout, image fit and wood/linen/slate backdrops, persisted using the existing Legacy appearance keys. CBZ remains intentionally out of scope; fixed-layout EPUB acceptance on actual manga files and all three targets is still pending.
- Flutter EPUB Preview now records reading sessions through the existing `/api/reading/events` API. A 30-second heartbeat accumulates only while the app is foregrounded and recently active, pauses at the five-minute idle limit or when the app backgrounds, resumes on activity/foreground, splits events at local midnight, and displays the live duration. Events remain bounded and are sent directly to the existing endpoint without a persistent local queue.
- Flutter EPUB Preview now has true cross-platform fullscreen/immersive mode using the fullscreen platform adapter. It hides the reader AppBar while immersive, toggles via the top 20% touch/mouse zone, exits via Escape or Android back, and restores system UI when leaving the reader. CI and actual Android/macOS/Web fullscreen behavior still require acceptance.
- Flutter EPUB reader bookmark controls now toggle the exact current CFI bookmark (add/remove) and reflect the current position; the navigation sidebar confirms annotation deletion, distinguishes highlight/underline labels and colors, and orders saved items newest-first. These are initial parity steps; full cross-platform reader acceptance remains open.\n- Initial Flutter-native Cloud Manager: four provider choices/readiness states, local OpenList login with URL-only saved settings, remembered local-source selection, and a shared in-memory authentication session. Local EPUB reading now resolves the authenticated raw URL and serves the Flutter ZIP reader through sequential 1 MiB Range requests, without persisting the token or downloading the complete archive; separate shared Books/Comics roots; source connection testing against the selected root; current-folder-to-root shortcuts; paginated live directory browsing, breadcrumbs and current-page search. Native D1 scanning traverses directories, writes bounded index batches through the existing index API, saves the existing D1 checkpoint format after every page, resumes incomplete scans and supports manual pause plus confirmed full rescan. A sequential Books/Comics scan-all runner resumes interrupted work at the unfinished library. The native scan-log panel shows checkpoint/counters/recent errors and supports copy, clear-error-details and resume. A native archive processor extracts EPUB OPF metadata and cover images through bounded ZIP Range requests, makes 512 px in-memory PNG thumbnails, computes SHA-256, uploads through the existing private R2 endpoint and records cover/metadata status in D1. Failed cover items can be retried. It never fetches a complete original archive. Remaining source configuration and full cross-platform acceptance remain open.
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
- Flutter statistics now exports JSON and CSV through the native save-file dialog on Android and macOS, and the browser download flow on Web. The bytes are generated in memory and no intermediate export file is created. Native device/window acceptance remains pending.

### F5 — Three-platform release
- [ ] Separate Flutter Web preview and browser Access validation.
- [ ] macOS arm64 install and full Reader tests.
- [ ] Android install and full Reader tests on target devices.
- [ ] Run the complete main-parity acceptance checklist on each platform.
- [ ] Cut over Web only after explicit user acceptance.


### Reader appearance parity update
- Flutter EPUB Preview now reads and writes the existing Legacy D1 appearance keys for font scale, font family, weight, paragraph spacing, text alignment, vertical and horizontal margins, reading mode, page layout and theme.
- The Flutter preview exposes these typography and margin settings in its appearance panel. Comic image-fit, backdrop and fullscreen parity remain open.


### EPUB note editor parity update
- The Flutter note editor now exposes a delete action while editing an existing note, matching the original reader's in-editor delete path. The editor returns an explicit delete intent; the reader asks for confirmation before deleting the annotation through the existing session/repository API.
- New widget tests cover the edit-only delete action, preserved quotation context, new-note mode without a delete action, and save-result handling. This does not change the D1 schema or the legacy reader.

### EPUB annotation refresh parity update
- The Flutter reader sidebar now has a refresh action that reloads bookmarks, highlights and notes through the existing `/api/reading/annotations` contract.
- Refreshes are guarded against stale responses: a refresh cannot overwrite a newer local save/delete, nor can an older overlapping refresh replace a newer one. Session and sidebar widget tests cover remote annotation reload and the refresh control.

### EPUB selection toolbar dismissal parity update
- Flutter now clears the active annotation selection whenever the renderer reports a collapsed/empty selection, a selection that cannot be mapped to a CFI, or an incompatible reader state. This prevents the toolbar from remaining attached to a previous quote after text selection is cancelled.

### EPUB annotation rendering verification
- Added a chapter-renderer widget regression test proving that yellow, violet, mint and rose highlights, plus the underline style, are restored from CFI-backed annotation records into the reflowable EPUB text layer. The test exercises actual rendered TextSpans rather than only checking saved JSON.

### Cross-chapter annotation restoration verification
- Added a two-spine EPUB widget test that creates a CFI annotation in chapter two, verifies it is not painted in chapter one, then navigates to chapter two and verifies the correct highlight is restored. This checks chapter scoping and text-layer rendering together.

- The cross-chapter test explicitly ignores the renderer's baseline `TextDecoration.none` style and asserts only that the chapter-one target text has no annotation highlight or underline.

### Cross-inline annotation range verification
- Added an EPUB renderer widget test where one CFI highlight begins in paragraph text, crosses a bold inline element, and ends in following paragraph text. All three underlying XHTML text nodes must receive the same restored highlight color.

### Navigator API scope propagation fix
- The legacy reading room's optional Flutter EPUB Preview route now explicitly inherits the current `FrameApiScope` and in-memory Local OpenList session. This fixes the route boundary where a newly pushed Navigator page did not inherit the old route's provider.
- The legacy EPUB/CBZ HTML reader itself remains unchanged. A widget regression test verifies that the API scope is available after pushing a nested route and that a missing scope produces a clear setup error.

### Reader UI parity and resilient TOC navigation

- The Flutter EPUB reader now follows the original Reading Room's main layout: book/title and progress header, quick actions, a persistent left navigation column on wide screens, a framed reading viewport, and bottom previous/next page controls with separate chapter and whole-book progress indicators.
- The desktop navigation column keeps the chapter TOC, expandable personal notes, and bookmarks visible together, matching the original Reading Room's information hierarchy. Compact layouts retain a left-side navigation drawer with separate TOC, notes, and bookmark tabs.
- EPUB 3 navigation parsing now accepts common real-world variations: explicitly marked TOC navigation, `role="doc-toc"`, `id="toc"`, nested ordered lists, and a generic navigation element when no TOC marker is present.
- When both EPUB 3 navigation and EPUB 2 NCX are absent or unusable, the reader synthesizes a usable chapter list from the OPF spine. These entries navigate to the original archive resources and do not modify or extract the EPUB.
- Parser and sidebar regression tests cover missing-TOC fallback, non-standard nested EPUB 3 navigation, and the desktop TOC/notes/bookmarks layout. Actual visual parity still requires Web, macOS and Android acceptance using the same books and viewport sizes as the legacy Reader.

### Reading Room interaction parity follow-up

- Both desktop and compact Flutter navigation now render the EPUB TOC as a recursive tree instead of a flattened list. Each node with children has its own disclosure control, independent of chapter selection, and can be expanded or collapsed.
- A single-root TOC opens its first level by default, matching the legacy Reading Room. When a saved/current reading path is nested in the tree, its ancestor nodes are opened automatically so the current chapter remains discoverable.
- Reading appearance settings now use a floating panel aligned to the upper-right on wide layouts, with a top-centered compact presentation on narrow layouts, rather than a bottom sheet. Existing font, layout, theme, comic and backdrop options, and all legacy D1 appearance keys remain intact.
- Regression coverage checks nested TOC expansion/collapse, selecting a nested entry, and automatically opening ancestors of the current chapter.


### Desktop Reading Room sidebar visual parity

- The Flutter desktop navigation column now uses the legacy `IN THIS BOOK` kicker and FRAME `F` mark, while retaining annotation refresh and sidebar visibility controls.
- Desktop TOC labels now follow the legacy compact single-line treatment and 9 px typography; section headings and English labels use the original sizing and tracking.
- Sidebar widget tests verify the restored brand header and preserve the existing TOC, notes, bookmark and selection interactions.


### Legacy appearance setting compatibility

- Flutter treats the shared Legacy `lineHeight`, `theme`, `readingMode` and `pageLayout` fields as authoritative when restoring reader appearance. Older Flutter-only duplicate fields are fallback-only for settings saved by earlier preview builds.
- The appearance panel now uses the Legacy line-height choices and keeps reading mode separate from the single-/double-page preference. The page-layout preference remains saved while continuous scrolling is active.
- Saving appearance writes the established shared keys instead of refreshing duplicate Flutter-only values that could become stale when the Legacy reader changes a setting.
- Unit tests cover Legacy-value precedence, supported line-height normalization, theme mapping and independent reading-mode/page-layout restoration.


### Reader responsive geometry correction
### Reader workspace and immersive layout correction
### Immersive state chrome parity correction

- The legacy immersive state collapses the book heading to zero height and hides the sidebar, quick actions, reading-session indicator and page controls. Flutter now expands only the reader viewport to the full immersive surface and removes those controls, instead of keeping the title row, sidebar and mobile action dock visible.
- This is distinct from ordinary browser fullscreen, which may retain the regular reader chrome. Escape / system-back and the existing top-zone listener remain the exit paths.
- The immersive state is source-aligned; same-viewport visual comparison and cross-platform exit/restore acceptance remain pending.

### Safe-area-aware reader drawers

- Both right appearance and left navigation drawers now include the device's stable Safe Area insets, matching the legacy safe-area CSS. Normal panels add 8 px; compact immersive panels add 6 px, while desktop fullscreen remains edge-to-edge.
- Tests cover notched-phone top/bottom insets in normal and fullscreen modes, in addition to the existing 320/390/820/1440 px width matrix.

### Compact left navigation drawer geometry

- The compact Flutter navigation now matches the legacy left drawer: maximum 390 px, 91vw with an 18 px minimum outer-width reserve, 8 px top/bottom insets in normal mode, and 6 px in fullscreen.
- The drawer uses the legacy left-edge flush placement, 18 px right-side corners, dark surface, right-edge border and 70 px shadow. Its slide duration is aligned with the final 440 ms CSS transition.
- The mobile heading and close control now match the 46 px header / 42 px close target, without the legacy-hidden brand mark. Tabs and TOC horizontal inset are tightened to the original navigation.
- Geometry tests cover standard phone, drawer cap, narrow phone and fullscreen inset. Interaction and screenshot acceptance remain open.

### Appearance control grid and interaction styling

- Typography controls now follow the legacy three-column desktop / two-column compact grid. Reading mode, page layout and both margin controls share the original two-column PAGE LAYOUT group; comic controls use the two-column grid.
- Dropdowns now use the legacy dark field surface, 6 px radius, #4c425d border, 34 px desktop / 39 px compact control height, and 9/10 px label/value typography.
- These source-level measurements are based on the final legacy CSS declarations. Golden screenshot comparisons are still required to establish actual pixel parity.

### Appearance typography and section spacing

- Appearance group headings now use the legacy 10 px / 0.4 tracking treatment; English kickers use 7 px / 1.3 tracking and the original muted lavender colour.
- Layout/comic helper notes now use the legacy 8 px size, muted colour and 1.7 line height. Section spacing and the desktop drawer's bottom inset were aligned with the final CSS values.
- The autosave status retains visible feedback but uses the legacy 8 px text scale so it does not visually dominate the controls.

### Appearance button geometry and ordering

- Theme and backdrop choices now use the legacy outlined-button treatment rather than Material ChoiceChips: 6 px corner radius, matching selected/unselected border and fill colours, 34 px desktop / 37 px compact targets, 9/10 px text and 10 px theme swatches.
- The legacy order is restored: paper tone first, reading backdrop second. Select controls now stretch to the full width of their grid cell, including the three-column desktop typography grid.
- This corrects control geometry and interaction affordance; golden screenshot comparison is still required.

### Appearance drawer corrected against the final legacy CSS cascade

- The final legacy CSS rules define the appearance panel as a right-side full-height drawer: 440 px maximum on wide layouts, 420 px on compact layouts, a 91vw width cap, 8 px vertical inset, left-only rounded corners and a sticky 58 px header.
- Flutter's appearance panel now follows that final cascade, including the 820 px compact breakpoint and edge-to-edge fullscreen placement. It slides from the right with the legacy 480 ms easing, and the modal scrim uses the final darkened/blurred treatment.
- Appearance controls now apply immediately and save through the existing D1 keys on each change, matching the legacy interaction rather than waiting for a separate Save button. Sequential saves prevent an older rapid change from overwriting a newer selection.
- Geometry tests cover desktop, compact, breakpoint and fullscreen cases. Pixel comparison and actual platform acceptance remain outstanding.

### Compact Reading Room quick-action dock

- The four reader quick actions now move into a fixed bottom dock at the legacy 820 px breakpoint, both in normal and compact immersive layouts.
- The dock mirrors the legacy 360 px maximum width, viewport-edge insets, 34 px action targets, translucent surface, border, rounded corners and blurred backdrop.
- The normal book heading no longer duplicates mobile controls; wider layouts keep the controls beneath the chapter progress detail.
- A pure regression test pins the 820 px breakpoint. Full pointer/touch acceptance and same-viewport screenshot comparison remain outstanding.

### Legacy header hierarchy and app-shell geometry

- The Flutter preview now separates the legacy 72 px FRAME READER topbar from the 84 px NOW READING book heading instead of combining them into one toolbar.
- The topbar restores the engine-status role, READING ROOM · 0.6 label, Reading Time navigation and bookshelf return link. The book heading restores the chapter progress detail at the right and places icon-only reader actions beneath it.
- The full reader content now sits inside the legacy centred 1500 px shell with the original responsive horizontal insets at 1050, 820, 560 and 420 px.
- The immersive layout keeps the book heading visible while hiding its quick-action row, matching the legacy fullscreen chrome hierarchy more closely.
- Screenshot comparison and platform acceptance are still required before marking visual parity complete.


- The normal reader now keeps page navigation outside the framed reading viewport, matching the legacy DOM hierarchy. Desktop navigation uses the legacy three-column layout; compact screens place previous/next controls above the full-width progress panel at the 720 px breakpoint.
- Desktop immersive mode now retains the legacy left navigation column at 220 px when the sidebar is enabled. The reader frame drops its border, radius, padding and shadow while immersive, keeping the page surface flush with the fullscreen workspace.
- The reading-time indicator has moved from the author line to the footer below page navigation, matching the legacy Reading Room information hierarchy. Compact immersive mode remains drawer-based and does not force-open the sidebar.


- Flutter now uses the legacy 820 px breakpoint for the persistent desktop sidebar, and the legacy 220 px sidebar width through 1050 px before returning to 250 px on wider layouts.
- The appearance panel now follows the original CSS placement rules: top-right from 561 px upward (82 px top offset and the centered 1500 px shell's right inset), and bottom-right at 560 px and below (8 px outer inset, viewport width minus 16 px, and an 84% viewport-height ceiling).
- Pure layout tests pin the desktop, compact and ultra-wide geometry to the legacy CSS values. This is a targeted responsive correction, not pixel-level acceptance of the full Reader.

### Annotation list parity refinement

- Flutter note, highlight, underline and bookmark rows now present the original selected quotation separately from the saved note preview, with the matching annotation marker and a text delete action.
- Bookmark rows use the Legacy star marker and the original empty-state guidance. Existing notes open their editor after the reader successfully returns to the saved CFI.
- The appearance panel now uses the Legacy paper-tone labels and visual swatches, and labels the comic settings group with its original `COMIC READING` kicker.
- Sidebar widget coverage checks separate quotation/note rendering, bookmark markers and the existing jump/delete interactions.

- The Flutter preview now separates the legacy 72 px FRAME READER topbar from the 84 px NOW READING book heading instead of combining them into one toolbar.
- The topbar restores the engine-status role, READING ROOM · 0.6 label, Reading Time navigation and bookshelf return link. The book heading restores the chapter progress detail at the right and places icon-only reader actions beneath it.
- The full reader content now sits inside the legacy centred 1500 px shell with the original responsive horizontal insets at 1050, 820, 560 and 420 px.
- The immersive layout keeps the book heading visible while hiding its quick-action row, matching the legacy fullscreen chrome hierarchy more closely.
- Screenshot comparison and platform acceptance are still required before marking visual parity complete.


- The normal reader now keeps page navigation outside the framed reading viewport, matching the legacy DOM hierarchy. Desktop navigation uses the legacy three-column layout; compact screens place previous/next controls above the full-width progress panel at the 720 px breakpoint.
- Desktop immersive mode now retains the legacy left navigation column at 220 px when the sidebar is enabled. The reader frame drops its border, radius, padding and shadow while immersive, keeping the page surface flush with the fullscreen workspace.
- The reading-time indicator has moved from the author line to the footer below page navigation, matching the legacy Reading Room information hierarchy. Compact immersive mode remains drawer-based and does not force-open the sidebar.


- Flutter now uses the legacy 820 px breakpoint for the persistent desktop sidebar, and the legacy 220 px sidebar width through 1050 px before returning to 250 px on wider layouts.
- The appearance panel now follows the original CSS placement rules: top-right from 561 px upward (82 px top offset and the centered 1500 px shell's right inset), and bottom-right at 560 px and below (8 px outer inset, viewport width minus 16 px, and an 84% viewport-height ceiling).
- Pure layout tests pin the desktop, compact and ultra-wide geometry to the legacy CSS values. This is a targeted responsive correction, not pixel-level acceptance of the full Reader.

### Annotation list parity refinement

- Flutter note, highlight, underline and bookmark rows now present the original selected quotation separately from the saved note preview, with the matching annotation marker and a text delete action.
- Bookmark rows use the Legacy star marker and the original empty-state guidance. Existing notes open their editor after the reader successfully returns to the saved CFI.
- The appearance panel now uses the Legacy paper-tone labels and visual swatches, and labels the comic settings group with its original `COMIC READING` kicker.
- Sidebar widget coverage checks separate quotation/note rendering, bookmark markers and the existing jump/delete interactions.
