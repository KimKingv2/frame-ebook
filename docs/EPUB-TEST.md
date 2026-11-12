# EPUB Compatibility Test Log

## 2026-11-09 — Mac browser

User report: the Mac browser can open an EPUB in the V0.2 EPUB Lab.

## 2026-11-09 — Live desktop browser smoke test (V0.3)

After adding the missing Foliate first-navigation initialization:

- Bundled EPUB parsing and reader initialization: **PASS**.
- Actual chapter text visible in the reading viewport: **PASS**.
- Next-page navigation: **PASS**; progress changed from 0% to approximately 48%.
- Previous-page navigation: **PASS**; returned to the prior location.
- Table of contents jump to Chapter 2: **PASS**; progress reached 100%.
- Reload and automatic bundled-book reopen: **PASS**; Chapter 2 and 100% progress restored.
- Appearance controls (font scale, line height, margins, paper/sepia/night themes): **PASS**.
- Appearance preferences persisted after reload: **PASS**.

The test also exposed an integration requirement: Foliate's `view.open(book)` parses and prepares the renderer but does not display the first section by itself. The adapter must call `view.init({ showTextStart: true })`, or pass a saved CFI through `view.init({ lastLocation, showTextStart: true })`, to navigate to the initial reading location.

## Remaining device checks

The test above is a live desktop-browser smoke test, not a substitute for testing actual phones and tablets. On desktop, phone and tablet browsers, verify:

1. Bundled and user-selected EPUB files open without layout overflow.
2. Font size, line spacing, page margin and all three themes visibly affect reflowable text.
3. Appearance settings and CFI reading position survive reload in the same browser.
4. Previous/next controls and chapter navigation work.
5. Portrait/landscape changes and different screen widths keep controls usable.
6. Larger, image-heavy books remain responsive and do not exhaust browser memory.

Do not connect OpenList until the core reader is stable across the primary browsers and device sizes.


## 2026-11-09 — Appearance controls follow-up

User reported intermittent mismatch between the selected paper theme and some visible page backgrounds, plus no obvious effect from the page-margin control.

Fix applied:
- Expose the Foliate paginator's exported `filter` parts to the active page theme using inherited CSS custom properties. This keeps the paginator's outer page background in step with the selected theme, not just the EPUB document body.
- Force non-media EPUB element backgrounds to remain transparent so authored block backgrounds do not randomly leave white or colored patches in paper/sepia/night mode.
- Apply both paginator `margin` (top/bottom) and `gap` (left/right and spread gutter) from the page-margin control.
- Call the paginator's public `render()` after changing those attributes so its internal layout geometry is recalculated immediately.

Retest required: cycle paper → sepia → night → paper, then narrow → standard → wide → narrow. Confirm the page background changes on every switch and the text block / page margins visibly expand and contract without losing the current CFI.


## 2026-11-09 — Theme and page-margin regression test

User reported intermittent theme-color mismatch and a page-margin control that did not visibly work.

The fix was verified on the live desktop deployment:

- Switched paper → sepia → night → paper.
- The EPUB reading surface and its exported paginator filter surface followed the selected theme; text remained readable.
- No leftover colored patches or visible flicker were reported.
- Switched page margin standard (40) → narrow (24) → wide (60) → narrow (24).
- Narrow visibly expanded the content area; wide visibly reduced it; returning to narrow reproduced the earlier layout.
- Reading location remained at 48%, Chapter 1/2, through all appearance changes.

Implementation:
- Theme colors are propagated to Foliate's exported `filter` parts via CSS custom properties, in addition to styling the EPUB chapter document.
- Non-media EPUB child backgrounds are transparent under the selected paper theme, avoiding author-defined background blocks that conflict with the reader theme.
- Page margin updates both Foliate's vertical `margin` and horizontal `gap`, then explicitly calls the paginator's `render()` to recalculate layout.

The surrounding FRAME Reader application chrome intentionally remains dark violet. The selected paper theme applies to the EPUB reading surface and paginator page surface, not the entire website shell.

This was a live desktop-browser regression test. Phone and tablet browser verification remains pending.


## 2026-11-09 — Reduce vertical page margins

User reported that the top and bottom page margins felt too large.

Adjustment:
- Reduce Foliate's paginator `margin` options from 24 / 40 / 60 px to 8 / 16 / 24 px.
- Change the default from 40 px to 16 px.
- Keep the horizontal `gap` scale unchanged (4% / 7% / 10%), so this adjustment specifically tightens top/bottom whitespace without making the page columns wider.
- Old saved margin values are rejected by the allow-list and fall back to the new 16 px default.

Live verification pending: confirm the new default is active and the narrow / standard / wide settings produce visibly tighter top and bottom spacing while page navigation remains functional.


## 2026-11-09 — Fix vertical margin unit regression

The follow-up browser check and user report showed that only horizontal spacing changed. Root cause: Foliate's paginator takes `margin` as a CSS length and assigns it directly to the CSS custom property `--_margin`, which is used by `grid-template-rows: minmax(var(--_margin), 1fr)`. The adapter supplied a unitless number (for example, `16`), making the grid track definition invalid. The horizontal `gap` remained functional because it already included a percentage unit.

Fix:
- Pass the vertical paginator margin with an explicit `px` suffix (for example, `16px`).
- Keep the page-margin options at 8 / 16 / 24 px and horizontal gap at 4% / 7% / 10%.
- Force a paginator re-layout after the unit-bearing margin and gap are updated.

The earlier live check only confirmed the control options and navigation presence; it did not validate vertical whitespace. Re-run a visual vertical-spacing regression check after deployment.


## 2026-11-12 — Split page margins into independent axes

User requested separate numerical controls for page height and width spacing.

Changes:
- Replace the combined page-margin selector with two independent selectors:
  - Top/bottom (`verticalMargin`): 8 / 16 / 24 px, default 16 px.
  - Left/right (`horizontalMargin`): 4 / 7 / 10%, default 7%.
- Apply them directly to Foliate as `margin: <value>px` and `gap: <value>%`.
- Persist both values independently in localStorage.
- Migrate old combined `margin` preferences to both axes once, preserving the previous narrow / standard / wide selection.
- Update the mobile settings layout so the additional control remains readable.

Regression checks required:
1. Change top/bottom spacing while holding left/right at 7%; verify only vertical whitespace changes.
2. Change left/right spacing while holding top/bottom at 16px; verify only horizontal spacing changes.
3. Reload and confirm both values restore independently.
4. Confirm themes, font size, line height, page navigation and TOC navigation still work.


## 2026-11-12 — Typography controls design

Add four independent reading typography controls for reflowable EPUB chapters:

- Font family: original book font, serif (明體), or sans-serif (黑體).
- Font weight: original book styling, regular 400, or medium 500. This affects body text only, leaving headings' authored emphasis intact.
- Paragraph spacing: original book spacing, compact (0.4em), standard (0.8em), or loose (1.2em).
- Text alignment: original book styling, left aligned, or justified.

Design rules:
- Every control defaults to the EPUB author's original style to avoid unexpectedly restyling books on first load.
- Each value is independently persisted in the existing local appearance object.
- Settings are validated against fixed allow-lists before being applied.
- The controls use the existing dark-violet select styling and responsive two-column mobile layout.
- Fixed-layout EPUBs remain untouched.

Regression checks required:
1. Verify each setting independently changes the rendered body text without changing the other settings.
2. Verify choosing 原書設定 restores publisher / book styling for each category.
3. Reload and verify settings persist.
4. Verify headings retain their authored bold emphasis when body font weight changes.
5. Verify theme, font scale, line height, both margin controls, TOC and page navigation remain functional.


## 2026-11-12 — Typography controls live regression test

Verified on the live desktop browser at `https://frame-ebook.pages.dev/epub-lab/` with the bundled two-chapter demo EPUB.

- Font family: original / serif / sans options were present and selectable.
- Font weight: original / 400 / 500 options were present and selectable.
- Paragraph spacing: original / compact / standard / loose options were present and selectable.
- Text alignment: original / left / justified options were present and selectable.
- Independent top/bottom and left/right margin controls remained available.
- Applied a non-default value to each typography control; all selections remained active and the book text stayed visible and readable.
- Reloaded the page; each typography value persisted independently.
- Reset all four typography controls to the original-book setting after the test.
- No reader error message was observed.

The live test confirms control interaction and local persistence. Device-specific typography appearance still requires separate checks on mobile browsers and with books using different publisher styles.


## 2026-11-12 — Reading modes and page layout

Implementation based on the documented layout patterns in Readest and Thorium Reader, using the already vendored Foliate paginator rather than introducing a second reading engine.

- Add a mode selector: paginated or continuous scroll.
- Add a paginated layout selector: single page or double-page preference.
- Double-page preference applies on sufficiently wide landscape layouts; Foliate's own portrait container query automatically reduces it to one page in portrait.
- Apply modes through Foliate's public paginator attributes: `flow="scrolled"` for continuous scroll and `max-column-count="1|2"` for page columns. The current reading anchor is retained by calling the paginator's normal re-layout path.
- Persist both values in the existing local appearance object.
- Fixed-layout EPUBs retain the native fixed-layout renderer, spread arrangement and book progression direction. Mode and column selectors are disabled for fixed-layout books.

Live regression required:
1. Switch paginated → scrolled → paginated and verify the visible reading location remains stable.
2. Verify single-page and double-page behavior at landscape desktop and portrait viewport widths.
3. Verify switching to scrolled and back retains the selected page-column preference.
4. Reload and verify mode and page layout persist.
5. Verify page navigation and TOC navigation in both flows.
6. Confirm fixed-layout books do not expose unsupported flow / column overrides.


## 2026-11-12 — Reading mode and page layout live regression test

Verified on the live desktop browser at `https://frame-ebook.pages.dev/epub-lab/` with the bundled two-chapter demo EPUB.

- Reading mode control exposed paginated page turns and continuous vertical scrolling.
- Page layout control exposed single page and double-page preference.
- Double-page preference reported that portrait orientation falls back to single page.
- Switched to single page, then back to double-page preference; the selected preference updated correctly.
- Switched from paginated to scrolled flow; the text remained visible and the viewport became vertically scrollable.
- Used the next-page control in scroll mode; reading progress advanced from the opening page to approximately 48% / Chapter 2 of 2.
- Switched back to paginated mode; content and progress remained visible.
- Reloaded, reopened the bundled EPUB, and confirmed reading mode, page layout, margins and typography selections persisted. Saved reading location restored when the EPUB was reopened.
- TOC navigation to Chapter 2 succeeded without a blank page or UI error.
- Final view settings restored to paginated + double-page preference.

The demo verifies reflowable EPUB behavior on a desktop browser. Portrait-device fallback is implemented by Foliate's own container query; a physical phone/tablet test and a fixed-layout/CBZ manga test remain outstanding.


## 2026-11-12 — V0.5 IndexedDB bookshelf and book-scoped state

The homepage was changed from a static cover preview into a functional local bookshelf. The local store is same-origin IndexedDB; book content is not uploaded.

Live desktop-browser checks:

- Homepage loaded with the V0.5 library header, four book counters, search, four sorting modes, grid/list controls and a local-only privacy notice.
- The built-in sample EPUB was imported into IndexedDB. It appeared on the shelf with extracted title, author, cover and EPUB format.
- Opening the shelf card navigated to /epub-lab/?book=BOOK_ID. The Reading Room retrieved the book Blob from IndexedDB and displayed its metadata and table of contents.
- Returning to the shelf showed the last-read progress. The detail dialog opened and closed. Grid → list → grid switching worked.
- Reloading the Reading Room with the same book ID reopened the EPUB from IndexedDB and preserved the 48% / Chapter 1 of 2 progress.
- The original CBZ demo was updated to import itself into the same local bookshelf. The browser showed FRAME Reader Comic Demo and the CBZ engine-ready state.
- CBZ progress moved from 25% / Chapter 1 of 4 to 50% / Chapter 2 of 4. Reloading /epub-lab/?book=BOOK_ID reopened the CBZ and restored the 50% position.
- The generated demo CBZ contains four original SVG page images. The shelf metadata parser counts image entries and extracts a cover candidate.
- Reader appearance preferences use a per-book key (frame-reader-appearance-v1:BOOK_ID). The appearance object is reset to defaults before a new book is loaded, preventing a new book from inheriting the previous book's in-memory choices.

Test limitations / not yet verified:

- The CBZ details dialog's displayed 4-page value was not independently confirmed in the browser.
- One browser run confirmed the EPUB card and another confirmed the CBZ card. A complete test with both books imported into the same browser library and visible together was not conclusively completed.
- The full visual sequence of changing an EPUB to a non-default theme and backdrop, opening a different book, and reopening the EPUB to confirm its previous custom settings was not completed end to end.
- One automation run could not inspect the theme/backdrop button data attributes, even though the repository HTML includes data-theme, data-backdrop and aria-pressed attributes. Treat that selector-based inspection as inconclusive rather than a confirmed UI defect.
- Physical iPhone / iPad / Android device testing, large personal archives, IndexedDB quota handling and browser storage eviction remain pending.

The successful runs confirm local EPUB import, shelf persistence, reopening by stable book ID, CBZ reading progress persistence after reload and the core bookshelf controls on a desktop browser. This remains a local prototype, not a cloud-synced or OpenList-backed production library.


## 2026-11-12 — V0.6 reading insights and Pages Functions deployment check

Implemented:

- Added a 15-second foreground reading timer. It requires a visible tab and focused window; user activity refreshes a five-minute idle deadline. Hidden tabs, blurred windows and idle sessions pause the timer.
- Added short IndexedDB reading events, local-hour data, day-boundary splitting, and event IDs for idempotent cloud retries.
- Added an insights dashboard with week / month / year / all-time periods, total duration, natural-day average, 60-second reading-day threshold, current and longest streak, a configurable daily target, calendar heatmap, trend chart, top books, time-of-day bands, recent sessions and local JSON / CSV export.
- Consecutive 15-second event rows are merged into reading sessions for display. All-time daily average starts at the first day with reading data; streak date arithmetic uses calendar-day ordinals so daylight-saving transitions do not break a consecutive streak.
- Added Pages Functions for password login / session / logout, OpenList directory listing, a protected file proxy with Range forwarding, D1 reading-event ingestion and D1 reading-stat queries.
- Added D1 SQL migration 0001_reading_events.sql and the Cloudflare setup guide.
- The cloud browser imports a selected OpenList EPUB / CBZ into the browser's local IndexedDB. It does not currently stream the book directly from OpenList into Foliate.

Static checks:

- JavaScript syntax parsing passed for library-store.js, reading-tracker.js, reading-stats.js, cloud-library.js, the Reading Room adapter, and every Pages Function module.
- Cloudflare Pages static routes /reading-stats/ and /cloud/ were retrievable after deployment.
- GET /api/auth/session returned a JSON session status with authenticated=false, openListConfigured=false and databaseConfigured=false. This confirms that the Pages Function route is deployed, and also confirms the D1 / OpenList bindings are not configured yet.
- Unauthenticated GET requests to /api/reading/stats and /api/cloud/books returned HTTP 401, as intended.

Not yet verified / blocked on configuration:

- D1 has not been created or bound to the Pages project in Cloudflare.
- The migration has not been applied to a remote D1 database.
- FRAME_READER_ACCESS_PASSWORD, FRAME_READER_SESSION_SECRET, OPENLIST_BASE_URL, OPENLIST_TOKEN and OPENLIST_ROOT_PATH have not been configured as Pages variables / secrets.
- Therefore, successful private login, live OpenList directory browsing, protected Range download, D1 write / read, and cross-device aggregation have not yet been tested.
- The reading timer and stats UI have static syntax checks and the routes have been fetched, but an interactive end-to-end reading-duration test has not been completed in this run.
- Direct Range-backed loading into Foliate, large-file memory use, and physical phone / tablet verification remain future work.

Use docs/CLOUDFLARE-SETUP.md for the exact D1 binding, migration and Pages secret names. Do not put any password or token in Git.


## 2026-11-12 — V0.6 final route and access-control verification

- The deployed /reading-stats/ and /cloud/ static routes were retrieved successfully.
- The deployed GET /api/auth/session route returned authenticated=false, databaseConfigured=false and openListConfigured=false. This is the expected state before the owner adds the D1 binding and server-side settings.
- Unauthenticated GET /api/reading/stats and GET /api/cloud/books returned HTTP 401. No private reading aggregates or OpenList directory content were returned.
- The cloud directory UI now requests 80 items per page and exposes previous / next controls; successful cloud login also attempts to sync pending local reading events.
- When the session endpoint reports that D1 is not configured, the cloud login button is disabled and the stats page explains that the feature is not enabled yet.
- A final syntax pass succeeded for the local store, library page, reading tracker, insights page, cloud library, Reading Room adapter and all Pages Functions modules.

Still pending after owner configuration: D1 creation / binding / SQL migration, private login, OpenList real-folder listing, protected download / Range behavior, D1 event writes and cross-device aggregate reads. No end-to-end browser timer test was completed in this run.
