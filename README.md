# FRAME Reader

**Your Personal Digital Library**  
A private, multi-device ebook library for desktop, tablet and mobile.

> Current status: **V0.6 Reading Insights + Cloud Library scaffold**. Local reading-time tracking and the reading insights dashboard are deployed. Pages Functions for private OpenList access and D1 sync are in the repository; Cloudflare D1 bindings and private environment variables still need to be configured before cloud login, OpenList browsing and cross-device aggregation become active.

## Product scope

The web reader is designed for:
- **Desktop:** full library management, reading controls, search and annotations.
- **Tablet:** comfortable touch reading, flexible layouts and two-page spreads where appropriate.
- **Mobile:** responsive single-column reading and one-hand controls.

Kindle is outside the online reader's support scope. If used later, treat it as a separate offline-reading workflow rather than maintaining a Kindle-browser compatibility layer.

## Goals

- Read EPUB first, then add MOBI, AZW3/KF8 and PDF.
- Support illustrated EPUBs and manga, with single-page, spread and vertical-scroll layouts where the source format permits.
- Provide responsive reading experiences for desktop, tablet and phone.
- Keep book files in private storage (planned: OpenList), not in this public repository.
- Synchronize reading position, bookmarks and notes across supported web clients.

## Current routes

- `/` — local bookshelf with import, search, sort, recent reading, book details and grid/list views.
- `/epub-lab/` — EPUB / CBZ Reading Room with per-book progress, appearance settings and foreground reading-time tracking.
- `/reading-stats/` — daily goal, reading duration, active days, streaks, calendar, trends, top books, time-of-day preferences and local JSON / CSV export.
- `/cloud/` — private OpenList directory browser; requires Pages Functions, D1 and server-side credentials to be configured.
- `/demo/frame-reader-sample.epub` — small, original Traditional Chinese test book.
- `/health.json` — same-origin connectivity endpoint.

## Bookshelf and covers

The homepage is now a functional local bookshelf. Imported book files, extracted covers, Metadata and progress are stored in this browser's IndexedDB. Only the small bundled test EPUB and the original synthetic comic demo are used as public test fixtures; private books are not committed to the repository.

Planned cover lookup order:
1. Embedded EPUB cover image.
2. A sibling `cover.jpg` (or supported cover image) in the book's private folder.
3. A generated fallback cover based on book metadata.

## V0.3 Reading Room

The EPUB Lab adds local reading appearance controls:
- Font scale: 90% to 130%.
- Line spacing: 1.45 to 2.0.
- Typography: original / serif / sans font family, original / regular / medium weight, compact / standard / loose paragraph spacing, and original / left / justified alignment.
- Page margin: narrow, standard or wide.
- Paper themes: paper white, warm sepia and night reading, synchronized across the EPUB document and Foliate page background.
- Independent page-margin controls: top/bottom spacing (8, 16 or 24 px) and left/right spacing (4%, 7% or 10%). Changing one never changes the other. The vertical value is passed to Foliate with an explicit CSS `px` unit, then the paginator is re-laid out.
- Reading modes: paginated page turns or continuous vertical scrolling.
- Paginated layout: single page or double-page preference. The paginator automatically falls back to a single page in portrait orientation. Fixed-layout EPUBs preserve their native spread behavior.
- Appearance preferences persist in this browser's localStorage.

The controls are applied to reflowable EPUB content. Fixed-layout EPUBs retain their original page design. Settings are local to one browser and are not synchronized between devices.

**Prototype limitation:** JSZip currently reads the whole EPUB archive into browser memory. The production OpenList reader should use HTTP Range / partial reads for larger books, after validating CORS and Range behavior.

The bundled two-chapter test EPUB has passed a live desktop-browser smoke test for visible content, next/previous navigation, chapter navigation and CFI restoration after reload. Phone and tablet testing remains pending. The saved CFI and appearance preferences are currently local to one browser. Cross-device synchronization requires the future authenticated Worker + D1 service and is not implemented yet.

## Local preview

No build step is required.

```sh
python3 -m http.server 8080 --directory pages
```

Open `http://localhost:8080/`, then visit `/epub-lab/`.

## Cloudflare Pages

Connect `KimKingv2/frame-ebook` to Cloudflare Pages:

| Setting | Value |
|---|---|
| Production branch | `main` |
| Framework preset | None |
| Build command | Empty |
| Build output directory | `pages` |

New commits to `main` should trigger automatic deployment.

## Security and privacy

- Never commit OpenList tokens, credentials, private books, private metadata exports or `.env` files.
- The included sample EPUB is original demonstration content.
- Local EPUB file selection stays in the browser and is not transmitted.
- Do not connect a public reader directly to OpenList using a long-lived administrator token. A future Worker should provide authenticated, short-lived, narrowly scoped file access.
- See [PRIVACY.md](PRIVACY.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Third-party software

- Foliate.js — MIT, source snapshot pinned to `78914aef4466eb960965702401634c2cb348e9b1`.
- JSZip 3.10.2 — MIT option selected from its dual MIT/GPLv3 license.
- Notices are included under `pages/vendor/` and `docs/THIRD-PARTY.md`.

## License

Original FRAME Reader project files are MIT-licensed. Third-party components retain their respective licenses and notices.


## V0.4 Comic Reading Room

The Reading Room now accepts local EPUB and CBZ files. CBZ archives are parsed through Foliate.js' comic-book adapter and Zip.js; individual comic pages are loaded as they approach the visible area rather than eagerly opening every page image.

For fixed-layout books (including CBZ):
- **Reading flow:** paginated pages or continuous vertical Webtoon-style scrolling.
- **Page composition:** single-page mode or automatic double-page spreads. Double-page preference becomes a single page in portrait orientation; wide desktop/tablet layouts can show a spread.
- **Image scale:** fit page or fit width in paginated mode. Continuous mode always fits the page width.
- **Reading progress:** the current image-page index is stored locally in this browser.
- **Reading surface:** CSS-rendered wood desk, warm linen and dark slate backdrops, with page shadows. The page artwork itself is not recolored by the surface texture.
- A four-page original comic demo is generated locally in the browser for repeatable layout testing; it is not uploaded.

Reflowable EPUBs continue using their own typography and pagination controls. The comic controls are enabled only for fixed-layout books. Right-to-left navigation controls are not exposed; the source book's native progression metadata remains untouched.

The comic demo is a synthetic four-page fixture. Real-world CBZ archives with large page counts, unusual image formats, very tall pages and physical phone/tablet browsers still need broader compatibility testing. EPUB loading in this prototype still uses JSZip and reads the archive into browser memory; production OpenList integration must use partial HTTP Range reads.


## V0.5 Local Bookshelf

The homepage is a working local library rather than a static design preview.

- Import multiple EPUB and CBZ files from the browser.
- Extract EPUB title, author, language, identifier, spine item count and embedded cover image from the OPF package metadata.
- Extract CBZ page count and a cover candidate from the archive directory.
- Store the original archive Blob, cover Blob, book metadata and reading progress in IndexedDB.
- Search by title, author, filename or format; sort by recent reading, recently added, title or progress.
- Switch between cover-grid and compact-list layouts; recently opened books appear in a separate resume section.
- Edit a book's display title and author, inspect format / file size / page count / reading progress, or remove it from this browser's library.
- The Reading Room accepts a book ID in its URL, retrieves the original Blob from IndexedDB, and restores the book after a reload.
- EPUB CFI and CBZ page index are saved against the local book ID. Appearance preferences are stored independently per book in localStorage.

The bookshelf and reading history work locally in the current browser profile and origin. The original archive is not uploaded to GitHub or Cloudflare. Clearing this site's browser storage, using a different browser profile or changing devices will not carry the local library and unsynced reading events over. V0.6 adds the authenticated Pages Functions and D1/OpenList integration scaffold; the remote side remains inactive until Cloudflare is configured as described in docs/CLOUDFLARE-SETUP.md.

### Current limitations

- IndexedDB capacity depends on the browser and available device storage. Very large archives may fail to import when quota is insufficient.
- EPUB metadata extraction currently uses the vendored JSZip parser. Very large EPUB files can temporarily require additional browser memory.
- CBZ indexing reads the ZIP central directory and one cover image for shelf display; the Reading Room retains its lazy page-image loading behavior.
- The current test coverage is a synthetic two-chapter EPUB and four-page CBZ demo. Test large personal libraries, unusually large CBZ archives and physical phone/tablet browsers before treating this as production-ready.


## V0.6 Reading Insights and Cloud Library

### Reading habits and statistics

The Reading Room starts a local foreground timer for the active book. It counts only while the reader tab is visible and the browser window has focus. Pointer, key, touch and scroll activity refresh a five-minute idle timeout; the timer pauses while the tab is hidden, the window is unfocused or the reader remains idle.

- A heartbeat writes short reading-time segments to IndexedDB. The event ID makes retries safe when uploading to D1.
- Reading days count after at least 60 seconds, following the public WeChat Reading data definition.
- The insights page includes weekly / monthly / yearly / all-time views, total time, natural-day average, reading days, current and longest streak, daily target, monthly calendar, reading trends, most-read books, time-of-day distribution and recent reading sessions.
- Session cards combine adjacent short heartbeat records for the same book and local day.
- Daily goals are currently stored per browser. Local JSON / CSV exports include local event details; cloud-account export of all remote devices is not included yet.

### Cloud architecture

- The root-level functions directory is the Cloudflare Pages Functions source directory. It is separate from the static pages output directory.
- /api/auth/* provides password-based private login and a signed HttpOnly, Secure, SameSite=Lax session cookie.
- /api/cloud/books lists EPUB / CBZ files and folders below the mandatory OPENLIST_ROOT_PATH.
- /api/cloud/file proxies an authenticated OpenList download and forwards valid HTTP Range requests. The OpenList token and raw download URL remain server-side.
- /api/reading/events stores unique short reading-time events in D1; duplicate retries do not double-count.
- /api/reading/stats returns D1 daily totals, streak calendar source data, most-read books, time-of-day totals and recent events.
- migrations/0001_reading_events.sql creates the D1 tables for reading events and login rate limiting.

The current cloud shelf imports a selected OpenList file through the protected proxy into this browser's IndexedDB. It does not yet mount a remote book directly into Foliate; very large books still download fully into browser storage before opening. The backend proxy is Range-capable so a later reader-loader integration can stream partial requests.

See docs/CLOUDFLARE-SETUP.md before enabling cloud features. Do not paste passwords or API tokens into chat or commit them to Git.
