# Architecture Notes

## Product shape

FRAME Reader is one responsive library with three presentation profiles:

1. Desktop: full library management, reading controls, search and annotations.
2. Tablet: touch-first reading, portrait/landscape layouts and optional two-page spreads.
3. Mobile: compact typography, one-hand controls and single-column reading.

All three profiles use the same book identity and reading-state model. Layout and pagination can adapt to the viewport without splitting the library into separate products.

Kindle is outside the online reader's support scope. Any future Kindle use should remain a separate offline-reading workflow; no Kindle-browser compatibility layer is planned.

## Visual system and bookshelf

The visual direction is an editorial reading room: deep ink backgrounds, muted violet light, warm paper surfaces and restrained motion. The homepage cover cards are SVG design previews, not records from the private library.

When OpenList is connected, each book record should expose a stable identifier, title, author, format, file path, and optional cover source. Resolve the display cover in this order:

1. Embedded EPUB cover image when available.
2. A sibling `cover.jpg` (or another explicitly supported image format) in the book folder.
3. A generated fallback cover using available title/author metadata.

Cover previews in the public repository must remain original artwork. Never copy private book covers or metadata exports into this repository.

Animation should remain decorative and lightweight: short entrance transitions, subtle cover movement and hover feedback. Honor `prefers-reduced-motion`, and avoid making navigation depend on animation.

## Format strategy

| Format | Candidate | Notes |
|---|---|---|
| EPUB | Foliate.js parser/renderer | Reflowable and fixed-layout books; CFI progress. |
| MOBI | Foliate.js | Legacy Mobipocket parsing; add after EPUB validation. |
| AZW3 / KF8 | Foliate.js | KF8 parsing; complex books may be expensive to decode. |
| PDF | PDF.js | Mature rendering core; optimize page loading for mobile. |
| Manga | Fixed-layout EPUB / CBZ | Test reading direction, spreads, images and pagination separately. |

Foliate.js supports EPUB, MOBI, KF8/AZW3 and CBZ. Its API is not stable, so the current source is pinned to an exact commit. See `docs/THIRD-PARTY.md`.

## EPUB Lab (V0.3)

The Reading Room prototype is at `/epub-lab/`.

- Foliate.js source snapshot: `78914aef4466eb960965702401634c2cb348e9b1` (MIT).
- JSZip 3.10.2 loads the small test archive for this compatibility experiment.
- The adapter supplies Foliate's EPUB loader interface (`loadText`, `loadBlob`, `getSize`).
- The view saves the current EPUB CFI to localStorage and restores it when the same book is reopened. After `view.open(book)`, the adapter must call `view.init({ showTextStart: true })` or initialize with a saved CFI; opening alone does not navigate to the first visible section.
- A tiny original two-chapter Traditional Chinese EPUB is included for repeatable tests.

### Reading appearance

For reflowable EPUB chapters, the adapter injects a small per-document style sheet when Foliate emits a chapter load event. User settings include:

- Font scale: 90–130%.
- Line spacing: 1.45–2.0.
- Typography controls: original / serif / sans family; original / 400 / 500 body weight; original / compact / standard / loose paragraph spacing; original / left / justified alignment.
- Independent paginator margins: top/bottom margin is 8, 16 or 24 CSS pixels (16 px by default); left/right page gap is 4%, 7% or 10% (7% by default). The adapter must pass a unit-bearing CSS length such as `16px` to Foliate's `margin` attribute and a percentage such as `7%` to `gap`. These settings must remain independent.
- Reading flow: the reflowable paginator uses its native `flow="scrolled"` attribute for continuous scroll; removing the attribute restores paginated mode.
- Page columns: `max-column-count` controls one or two columns. The pinned Foliate paginator's container query reduces the spread to one column in portrait orientation, even when two columns are preferred.
- Fixed-layout EPUBs use Foliate's separate fixed-layout renderer and retain the book's native spread and progression direction; flow and column controls are disabled for them.
- Paper white, warm sepia and night themes.

Settings are validated against a fixed allow-list and stored locally under `frame-reader-appearance-v1`. Fixed-layout EPUBs keep their authored layout rather than having text styling forced on them.

This is a prototype appearance layer. EPUB authors may use deeply nested styles or fixed pixel sizes that need more testing. A future settings layer should prefer stable engine APIs where available.

### Device test order

1. Mac Chrome and Safari: load the bundled demo, change each appearance setting, turn pages, jump chapters, reload and confirm location and appearance restore.
2. Android Chrome and iOS/iPadOS Safari: verify EPUB loading, appearance controls, portrait/landscape layout and local file selection.
3. A larger, image-heavy EPUB: measure load time and memory behavior on desktop, tablet and phone.
4. Only after the browser reader is stable, implement OpenList metadata lookup and Range-backed reading.

The current browser prototype is only a compatibility baseline. Test the actual parser, paginator and local-file flow on each target browser; feature detection alone is not sufficient.

## Local library store (V0.5)

The homepage at \`/\` is backed by \`pages/assets/library-store.js\`, a same-origin IndexedDB store named \`frame-reader-library\`.

Each local book record uses a browser-generated stable \`id\` and stores:

- The original EPUB / CBZ \`Blob\` (or structured-cloned \`File\`).
- Original filename, byte size, last-modified timestamp and format.
- Display title, author, language, optional EPUB identifier and item/page count.
- Optional extracted cover image \`Blob\`.
- Added / updated / last-opened timestamps.
- Progress object: percentage, human-readable section/page label, EPUB CFI when available, and fixed-layout image index.
- Reserved manual title / author flags so user corrections are not overwritten by future metadata refreshes.

Import is local-only. The browser parses the archive to obtain its metadata and cover, then writes the original archive and extracted cover into IndexedDB. No API request uploads book content. If the browser storage quota is exceeded, the user receives an explicit error and the import is not presented as successful.

EPUB metadata is read from the OPF package metadata and manifest. The current implementation extracts the declared cover image (with format-specific fallbacks), title, creator, language, identifier and spine count. CBZ indexing enumerates supported image entries, sorts naturally, counts pages and selects a cover/front image candidate or the first image.

The Reading Room opens a shelf book by ID using \`/epub-lab/?book=<id>\`. It fetches the Blob from IndexedDB and passes it to the existing Foliate adapter. The same book ID scopes CFI / image-index persistence and the per-book appearance key (\`frame-reader-appearance-v1:<id>\`). A book opened from a direct local-file picker is first imported into the same store. The active book ID remains in the address bar so browser reload can reopen it.

The bookshelf supports title / author / filename search, recent / added / title / progress sorting, cover grid / list layout, recently opened books, metadata editing and local removal. Removing a book deletes only the browser's stored copy; it does not touch the original file on disk.

### Local storage boundaries

- IndexedDB is scoped to this browser origin and profile. Another browser, device, private window or cleared site data does not share the library.
- Browser quota is implementation- and device-dependent. Large archives can fail to import; do not assume unlimited local capacity.
- The EPUB metadata adapter currently uses JSZip, which may require extra memory while inspecting large EPUB archives.
- CBZ shelf indexing reads the archive directory and a cover image; the reader's existing image loading remains lazy.
- No OpenList API key, user credential or private book metadata is embedded in frontend source.
- The metadata-only OpenList cloud catalog and resumable D1 scan state are described below. Book files remain in OpenList until a user explicitly adds one to the local IndexedDB shelf.

## Sync data model (future)

A reading-state record should be keyed by stable book_id and include:

- user_id
- book_id
- format
- locator (EPUB CFI / PDF page / image index)
- progress (0..1)
- updated_at
- device_id

Use server timestamps and conflict resolution based on the latest valid update. Page numbers are not portable between reflowable layouts with different fonts or screen sizes. For EPUB, a CFI-like location is preferable to a page number.

## Authentication boundary

Never expose a long-lived OpenList administrator token in browser JavaScript. A future Worker should authenticate the reader and issue narrowly scoped, short-lived access to one file or range request. Validate the sign-in flow on desktop, tablet and mobile before enabling private-library access.


### Fixed-layout and comic reading

The Reading Room supports CBZ alongside fixed-layout EPUB. CBZ parsing uses the pinned Foliate.js makeBook() entry point, the comic archive adapter and Zip.js. The archive directory is read first; page image blobs are resolved lazily as the reader approaches them.

The fixed-layout renderer has two distinct presentation paths:
- Paginated mode uses the native spread map. Single-page preference disables spreads; double-page preference pairs pages and lets portrait screens fall back to one page. Image scaling can fit the full page or the available width.
- Continuous mode builds a vertical page strip and uses an IntersectionObserver to load nearby pages. The current page index is reported back to the shared progress model. On resize, loaded pages are re-scaled to the new reading width.

The UI does not provide a right-to-left override. It leaves the source book's original progression metadata intact. Comic background surfaces (wood desk, linen and slate) are rendered with CSS gradients and texture layers, so no remote images or third-party background assets are required. The background remains outside the page content; it must not tint or reduce contrast in the actual comic artwork.

The four-page demo is generated in the browser from original SVG panels and packed into a CBZ Blob. When the user chooses the demo, it is imported into the local IndexedDB bookshelf like any other book. No sample comic archive is committed to the public repository.


## V0.6 — Reading Insights and Cloud Library

### Foreground reading timer

The Reading Room starts the timer only after the Foliate view is initialized. The timer uses a 15-second heartbeat and records short event rows in the IndexedDB reading_events store. An event includes a stable event ID, local day key, local hour, book ID/title/format, seconds, and start/end timestamps.

Activity from pointer, key, wheel, touch and reader scrolling refreshes a five-minute idle deadline. The timer also requires the document to be visible and the browser window to have focus. Hidden tabs and blurred windows pause the clock. Each segment is split at local midnight so daily totals do not spill into the wrong day.

Adjacent heartbeat rows for the same book and local day are merged into a reading session for the recent-session UI. The underlying short rows stay separate for idempotent upload and reliable daily aggregation.

Reading-day counting uses a threshold of at least 60 seconds per local day, matching the public WeChat Reading data definition. Daily goal preference (default 30 minutes) remains local to each browser for now.

### Reading insights data

The /reading-stats/ route summarizes the local IndexedDB event store and offers weekly, monthly, yearly and all-time ranges. It renders total duration, natural-day average, reading days, books opened, a current/best streak, the daily goal ring, calendar heatmap, reading trend, top books, time-of-day distribution and recent reading sessions. Local JSON / CSV exports contain local browser event details.

When signed in, the page attempts to read the same aggregates from D1. The server returns daily totals, all-time daily totals for streaks, a distinct book count, top books, local-hour bands and recent events. The D1 data takes precedence for the selected period; unsynced / offline events remain in IndexedDB until upload succeeds.

### D1 event sync

The reading tracker batches up to 100 pending local events to POST /api/reading/events. Each D1 row uses event_id as the primary key and INSERT OR IGNORE so retrying a batch cannot double-count an event. The endpoint checks the signed session and same-origin POST, validates a small maximum duration per event, and stores no book file content.

The /api/reading/stats endpoint is read-only and returns aggregate statistics for the requested day range. The database migration is migrations/0001_reading_events.sql.

### Pages Functions and OpenList trust boundary

Cloudflare Pages serves static content from pages/, but the Pages Functions source directory is at the repository root as /functions/. The file-based routes are:

- POST /api/auth/login, GET /api/auth/session, POST /api/auth/logout.
- GET /api/cloud/books?library=books|comics&path=... for a directory listing scoped to the separate EPUB or CBZ root.
- GET /api/cloud/file?library=books|comics&path=... for a protected file download constrained to the matching root and extension.
- POST /api/reading/events and GET /api/reading/stats.

The session cookie is named __Host-frame-reader and is signed with HMAC using FRAME_READER_SESSION_SECRET. It is Secure, HttpOnly and SameSite=Lax. Login checks FRAME_READER_ACCESS_PASSWORD and applies a D1-backed per-IP rate limit. The intended deployment is one private library owner, not public multi-user authentication.

OpenList configuration is read only from the Pages Function environment. VPS Alist, OpenList Worker and Mobile Device Alist use their own base URL Variables and Token Secrets. `OPENLIST_BOOKS_ROOT_PATH` and `OPENLIST_COMICS_ROOT_PATH` define independent maximum directories for EPUB and CBZ access. All requested paths are normalized and constrained to the matching root; the browser may save a narrower preferred sub-root per device. The selected server token is sent in the Authorization header to OpenList and is never returned to frontend code.

The OpenList directory endpoint uses /api/fs/list. The file endpoint first calls /api/fs/get server-side to resolve raw_url, then streams the upstream body through the Pages Function and forwards valid Range requests and relevant response headers. Neither raw_url nor the OpenList token is exposed in the browser response.

The cloud shelf currently downloads a selected file through this protected proxy into IndexedDB before opening it. The proxy supports Range, but the Foliate loader is not yet adapted to consume remote HTTP ranges directly. Large EPUBs therefore still incur full-download memory / storage cost in the browser.

### Required deployment configuration

Before private cloud features work, bind a D1 database as FRAME_READER_DB, apply migrations/0001_reading_events.sql, and configure the five environment variables/secrets described in docs/CLOUDFLARE-SETUP.md. Until then, /api/auth/session correctly reports that the database and OpenList are not configured. Local reading history remains available without those bindings.

