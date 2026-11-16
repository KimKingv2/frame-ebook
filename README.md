# FRAME Reader

**A private, cloud-only reading library for EPUB and comics.**

FRAME Reader only adds books through a recursive scan of a configured server-side Alist／OpenList source. It does not offer local file import or direct browser-to-LAN OpenList connections.

## Current architecture

| Data | Authoritative storage |
|---|---|
| Original EPUB / CBZ files | Alist／OpenList |
| Book and comic index, scan cursors | Cloudflare D1 |
| Cover thumbnails | Private Cloudflare R2 |
| Per-user bookshelf preferences and source/root selection | Cloudflare D1 |
| Reading position (EPUB CFI / comic page), per-book metadata and appearance | Cloudflare D1 |
| Bookmarks, highlights and notes | Cloudflare D1 |
| Reading history, statistics and daily goal | Cloudflare D1 |

The browser uses in-memory objects only for the active page and reading session. It does not create an IndexedDB bookshelf or persist personal reading state in localStorage. The opened archive is fetched through the protected Pages Functions proxy and held in memory while reading; the original file stays in Alist／OpenList.

All user-owned reading data is partitioned by a SHA-256-derived owner ID from the verified Cloudflare Access identity. Raw email addresses and Access tokens are not stored in D1.

## Routes

- `/` — bookshelf assembled directly from the D1 cloud catalog.
- `/epub-lab/` — Reading Room for EPUB and CBZ files that already exist in the scanned D1 index.
- `/reading-stats/` — D1-backed reading history, trends, goals and cloud export.
- `/cloud/` — Alist／OpenList source configuration, path settings, directory browsing, recursive scanning and resumable indexing. The page is labelled “檔案瀏覽”.
- `/health.json` — same-origin connectivity endpoint.

## Supported sources

Only server-side providers are supported:

- VPS Alist
- OpenList Worker
- Mobile Device Alist

Each source uses its own Cloudflare Pages Variables／Secrets for the API base URL and read-only account credentials. Pages Functions perform Alist authentication. Short-lived provider JWTs may be cached through the shared `MEDIA_AUTH_TOKEN_CACHE` KV binding; neither passwords nor JWTs reach browser JavaScript.

## Cloudflare resources

- D1: `frame-reader-db`, binding `FRAME_READER_DB`.
- Private R2: `frame-reader-covers`, binding `FRAME_READER_COVERS`.
- Shared KV: `MEDIA_AUTH_TOKEN_CACHE`. Production uses `frame-series-auth-cache-production`; Preview uses the separate Preview namespace.
- Cloudflare Access must protect the complete hostname and all Pages Functions routes.
- User-scoped reading data requires `FRAME_READER_ACCESS_TEAM_DOMAIN` and `FRAME_READER_ACCESS_AUD`.

Apply migrations in order for a new database. For an existing installation that already has migrations 0001 through 0004, apply only the new additive migration:

```sh
npx wrangler d1 execute frame-reader-db --remote --file=migrations/0005_cloud_only_reader_data.sql
```

See [Cloudflare setup](docs/CLOUDFLARE-SETUP.md) for the full binding, Access and provider configuration.

## Migration notes

The cloud catalog and cloud annotations from earlier releases remain in D1. Migration 0005 adds user-scoped preferences, per-book state and reading events. The old unscoped `reading_events` table is left untouched and is not included in the new per-user statistics because it cannot safely be attributed to an Access identity.

Older browser IndexedDB/localStorage records are no longer read by this version. They are not automatically deleted or uploaded. Export or review any legacy browser-only content before manually clearing old site data. Books that exist only as local imports must first be placed in an Alist／OpenList source and scanned before they can appear in this cloud-only Reader.

## Reader engine

The Reading Room uses the pinned Foliate.js reader and JSZip for EPUB / CBZ parsing. EPUB CFI and fixed-layout comic page index are saved to D1. Appearance options are validated against an allow-list before being written to D1. Reading duration is sent directly to the per-user D1 event table with idempotent event IDs.

See [Architecture](docs/ARCHITECTURE.md), [Cloudflare setup](docs/CLOUDFLARE-SETUP.md) and [third-party notices](docs/THIRD-PARTY.md).
