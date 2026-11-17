# FRAME Ebook for macOS

FRAME Ebook 0.3.0 is a local-first Tauri reader for EPUB and CBZ archives stored on WebDAV / AList / OpenList. The reader UI and Foliate.js assets are bundled locally.

## Local-first reading

- Native WebDAV profile management and directory browsing use Rust `PROPFIND`.
- WebDAV passwords exist only in the running App's memory. They are not written to Keychain, the profile file, or Cloudflare. Profile URL, display name and username are saved in the app config directory.
- EPUB archives are fetched through the native WebDAV transport into RAM and passed to the reader as bytes. CBZ archives use native HTTP Range reads. The 0.3.0 reading path does not intentionally save original EPUB / CBZ archives to the Mac SSD.
- Cover thumbnails are extracted with bounded ZIP Range reads and saved locally in the app's IndexedDB database. Thumbnail writes are persistent local cache writes.
- Reading progress, annotations, bookmarks, reading events, preferences and the local bookshelf are stored in the local IndexedDB database. The application continues to work when Cloudflare is offline.

## Cloud sync

- Optional device pairing connects this Mac to the same Cloudflare Access account used by the web edition.
- After pairing, the app synchronizes the shared catalog and reading data through Cloudflare Pages Functions and D1.
- The local IndexedDB remains the working database; changes are queued locally and synchronized in bounded batches.
- The device token is stored in the app config directory in a file with Unix permissions `0600`; D1 stores only its SHA-256 hash. WebDAV passwords are never synchronized.
- A WebDAV source is matched to a Cloudflare provider by server origin. The same origin must be configured as one unambiguous server-side Alist / OpenList provider, and its corresponding book roots must have been scanned into D1.
- Apply D1 migrations `0010_device_sync.sql` and `0011_incremental_sync_changes.sql` before deploying the matching Cloudflare Functions. Configure the Access Public path overrides described in `docs/CLOUDFLARE-SETUP.md`.

## Build

```sh
cd macos
npm install
npm run tauri:build -- --target aarch64-apple-darwin
```

## Current limitations

- The first 0.3.0 synchronization implementation requires the Cloudflare catalog to be scanned before a Mac WebDAV source can synchronize books. A source hostname configured for more than one Cloudflare provider is treated as ambiguous and will not be synchronized.
- Same filename across different books still shares the established filename-derived Book ID. Local migration detects and preserves ambiguous records rather than automatically merging them.
- The build is ad-hoc signed for testing, not Developer ID signed or notarized. macOS may show a first-open security warning; this is not yet a public notarized release.
- macOS may write swap data under memory pressure. RAM delivery prevents intentional archive caching, but cannot guarantee zero SSD writes.
- WebDAV servers must allow PROPFIND and GET. HTTP is accepted only for localhost, `.local`, or private LAN addresses; public hosts must use HTTPS.
