# FRAME Ebook 0.3.0 Multi-device Sync Architecture

Status: implementation foundation, not yet enabled in Production.

## Goals

- Keep each client local-first: the UI reads and writes its own IndexedDB immediately.
- Use Cloudflare Worker / Pages Functions plus D1 as the shared synchronization service.
- Keep original EPUB and CBZ archives in WebDAV / AList / OpenList. Never upload book archives as part of sync.
- Keep cover thumbnails as per-device IndexedDB cache. A future optional shared cover cache must not be required for sync.
- Never sync WebDAV passwords. Each device authenticates to its WebDAV source independently.

## Canonical book identity

The canonical book ID remains the existing Reader contract:

1. Take the complete filename, including extension.
2. Trim surrounding whitespace.
3. Normalize Unicode to NFC.
4. SHA-256 the UTF-8 filename.
5. Prefix with `cloud:`.

Provider, library, folder path, WebDAV profile ID, and device ID are not part of the canonical book ID. This intentionally preserves the web edition's existing IDs. Same-name files therefore intentionally collide under this contract; clients must detect and surface collisions rather than silently merge data.

Mac 0.2.7 previously used `profileId + path` for WebDAV IDs. The 0.3.0 foundation restores the shared filename ID and upgrades the local IndexedDB schema with a guarded migration. A collision is preserved under its old ID and marked for later resolution; state, annotations, and events are migrated only when the target ID is unambiguous.

## Stable source identity

A WebDAV source is identified separately from a book. The source key is a SHA-256 digest of the normalized URL origin only. It is not a credential and does not contain a username or WebDAV password. This lets a local WebDAV account differ from the Cloudflare server-side read-only API account. If multiple Cloudflare providers share the same origin, the server marks that source as ambiguous and refuses to guess. Local `profileId` remains device-local for native WebDAV operations.

Before a source can participate in cloud sync, the server must verify that its source identity maps to an authorized configured catalog provider or register an explicitly approved source mapping. The raw WebDAV URL and username must not be sent to D1 as sync secrets.

## Sync model

- Device authorization: short-lived user-approved device pairing code, followed by a revocable device token stored as a hash in D1.
- Client authorization: the device token is sent only to dedicated device-sync endpoints; it is never embedded in the app bundle.
- User data: D1 records are partitioned by the same hashed Access subject used by the web edition.
- Sync: push local mutations in bounded batches, then pull records after a per-device change cursor.
- Conflict handling: each mutation has a stable entity ID, client revision, update time, and originating device ID. Progress uses last-writer-wins with deterministic tie-breaking; annotations merge by ID; reading events are append-only and idempotent; deletions use tombstones.
- Offline behavior: local writes succeed without network; the sync queue retries after connectivity returns.
- Quota safety: no full-table poll per interaction. Pull uses an indexed per-user cursor and a bounded page size. Reading progress is coalesced before upload.

## Initial entities

- `shelf_item`: book ID, source ID, library, relative path, folder path, display overrides, ordering and deleted marker.
- `book_state`: progress, appearance and user metadata.
- `annotation`: bookmark, highlight or note, independently keyed by annotation ID.
- `reading_event`: immutable event ID and duration fields.
- `preference`: per-key value and revision.

## Rollout

1. Canonical ID + safe local migration.
2. D1 migrations, device pairing, token revocation, and bounded sync APIs.
3. Mac local mutation queue and cloud reconciliation.
4. Web local cache and the same sync protocol.
5. Multi-device conflict and offline acceptance tests.
6. Deploy schema first, then APIs, then clients. Never ship a client that requires a migration that has not been applied.
