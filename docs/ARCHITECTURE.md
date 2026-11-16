# FRAME Reader architecture

**Current model: cloud-only bookshelf and cloud-only personal reading data.**

The only route for adding a book is a recursive scan of a configured server-side Alist／OpenList source. The browser cannot import local EPUB／CBZ files and cannot connect directly to a LAN OpenList instance.

## 1. Data ownership

| Data | Authoritative location | Notes |
|---|---|---|
| Original EPUB／CBZ archives | Alist／OpenList | Read-only from FRAME Reader; never copied into D1 or R2 |
| Directory and file catalog | D1 `cloud_catalog` | Provider, library, root, path, format, size, modified time and cover state |
| Recursive scan progress | D1 `cloud_scan_state` | Per provider/library/root checkpoint, queue and cursor |
| Extracted cover thumbnails | Private R2 `FRAME_READER_COVERS` | Normalized WebP/JPEG objects; hashes/status in D1 |
| Source, root path and reading-goal preferences | D1 `reader_preferences` | Partitioned by verified Access user |
| Book metadata, EPUB CFI, comic page index and appearance | D1 `reader_book_state` | Per Access user and stable cloud book ID |
| Bookmarks, highlights and notes | D1 `reader_annotations` | Per Access user, book and annotation |
| Reading-time events and statistics | D1 `reader_reading_events` | Per Access user; idempotent event IDs |

The Reader frontend does not persist personal or library data in IndexedDB, localStorage or sessionStorage. JavaScript objects and the current book archive exist in browser memory only for the active page/session. They disappear when the page closes or reloads; the authoritative state remains in D1/R2 and the original archive remains in Alist／OpenList.

Older releases used IndexedDB and localStorage. Migration 0005 does not delete or silently import those legacy browser records. The cloud-only version no longer reads them. Any legacy local-only books must be moved into an Alist／OpenList source and scanned before they are available here. Legacy reading events in the old unscoped `reading_events` table are not merged into user-specific statistics because they cannot safely be assigned to a Cloudflare Access identity.

## 2. Stable cloud book identity

A cloud book ID is:

```text
cloud:SHA256(provider + "\n" + library + "\n" + stripLeadingSlash(rootPath) + "\n" + stripLeadingSlash(path))
```

The same identity recipe is used in the browser client and Pages Functions. User-state APIs additionally verify that the descriptor matches a non-directory item in `cloud_catalog`. A file that is not indexed cannot be opened or receive a user-state record. The ID changes if the provider, library, configured root or file path changes.

## 3. Bookshelf and scanner

- `GET /api/reading/bookshelf` reads the active provider and per-provider root preferences for the current Access user, queries D1 catalog rows, and joins that user's `reader_book_state`.
- Folder-level grouping combines sibling EPUB/CBZ files into one visual work card, but each archive keeps its own stable ID and reading position.
- The scanner recursively calls the server-side Alist/OpenList API through Pages Functions. Every page writes metadata and scan cursor state to D1. A paused or interrupted scan can resume from its stored checkpoint.
- A completed scan reconciles stale catalog rows only after the entire root was traversed successfully.
- Scanning extracts covers using bounded HTTP Range reads and stores normalized thumbnails in private R2. It does not upload original book archives.

## 4. Reading Room

The Reading Room accepts a descriptor from a D1-backed bookshelf or the file browser. It first calls `GET /api/reading/state`, which confirms Cloudflare Access identity, stable book ID and D1 catalog membership. It then obtains the original file through `GET /api/cloud/file` using the server-side Alist/OpenList provider credentials.

The archive is passed to Foliate.js/JSZip in memory for the active reading session. No local file picker, demo-import flow, IndexedDB Blob or localStorage fallback is present.

For EPUB, the current CFI, progress percentage and section label are written to `reader_book_state`. For fixed-layout CBZ, the current image/page index and progress are written to the same record. Per-book appearance settings are validated against an allow-list and saved there too. Updates are debounced to reduce D1 write volume and use same-origin requests with `keepalive` for final page-exit writes.

## 5. Annotations and reading statistics

- `GET/POST/DELETE /api/reading/annotations` stores bookmarks, highlights and notes in `reader_annotations`.
- `POST /api/reading/events` validates and writes short foreground-reading intervals to `reader_reading_events`. Events must refer to a cloud book ID and have a unique event ID.
- `GET /api/reading/stats` aggregates daily totals, all-time streak data, books opened, top books, time bands and recent sessions for the current user.
- Daily goal preference is stored in `reader_preferences`.
- JSON/CSV export reads from the same user-scoped D1 table; there is no local event queue or local-only statistics fallback.

## 6. Per-user isolation and Access boundary

Cloudflare Access is the website sign-in boundary and must cover the entire hostname, every static page and every `/api/*` endpoint.

For user-owned reading data, Pages Functions also verify the `Cf-Access-Jwt-Assertion` signature against the configured Access team signing keys, and validate issuer, expiry and application AUD using:

- `FRAME_READER_ACCESS_TEAM_DOMAIN`
- `FRAME_READER_ACCESS_AUD`

A SHA-256-derived owner ID is stored in D1. Raw email addresses and Access JWTs are not persisted. Each user-scoped query includes this owner ID. The cloud catalog itself is a shared read-only index of the server-side source contents; per-user progress, appearance, annotations, preferences and events are isolated.

## 7. OpenList provider trust boundary

Only three server-side provider IDs are accepted:

- `vps`: VPS Alist
- `worker`: OpenList Worker
- `mobile`: Mobile Device Alist

Provider API base URLs and read-only credentials are configured in Cloudflare Pages Variables/Secrets. Frontend JavaScript receives only provider labels and configured-status flags. Pages Functions obtain short-lived JWTs through Alist `/api/auth/login` and cache them in the shared `MEDIA_AUTH_TOKEN_CACHE` KV namespace plus isolate memory. The cache contract is shared with FRAME Audio. Passwords, JWTs and upstream raw download URLs are not returned to the browser.

The file endpoint resolves the upstream download URL server-side and proxies the response, including valid Range requests. Original book archives remain in Alist/OpenList.

## 8. Pages Functions routes

- `GET /api/auth/session` — reports Access-edge and service readiness.
- `GET /api/reading/bookshelf` — per-user D1 bookshelf.
- `GET/POST /api/reading/preferences` — per-user source, root and goal preferences.
- `GET/POST /api/reading/state` — per-user per-book reading state.
- `GET/POST/DELETE /api/reading/annotations` — per-user annotations.
- `POST /api/reading/events` — per-user reading-time events.
- `GET /api/reading/stats` — per-user statistics.
- `GET /api/cloud/scan-list`, `POST /api/cloud/index/entries`, index state/completion endpoints — scan and D1 catalog management.
- `GET /api/cloud/file` — authenticated server-side original-file proxy.
- `GET /api/cloud/covers` — private R2 thumbnail retrieval.

Cloudflare Pages serves static content from `pages/`; the Pages Functions source directory is the repository-root `functions/` folder.

## 9. Cloudflare bindings and migrations

- D1 `frame-reader-db`, binding `FRAME_READER_DB`.
- Private R2 `frame-reader-covers`, binding `FRAME_READER_COVERS`.
- Shared KV `MEDIA_AUTH_TOKEN_CACHE`: Production uses `frame-series-auth-cache-production`; Preview uses its separate Preview namespace.

Schema migrations:

1. `0001_reading_events.sql` — legacy unscoped reading-event table.
2. `0002_cloud_catalog.sql` — cloud catalog and resumable scan state.
3. `0003_cloud_covers.sql` — cover metadata.
4. `0004_cloud_annotations.sql` — user-scoped cloud annotations.
5. `0005_cloud_only_reader_data.sql` — user-scoped preferences, book state and reading events.

For an existing deployment that already applied migrations 0001–0004, apply only migration 0005. Do not recreate or reset the database. See `docs/CLOUDFLARE-SETUP.md` for environment configuration and deployment steps.
