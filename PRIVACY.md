# FRAME Reader privacy notes

FRAME Reader is a cloud-only reading application.

## Where data is stored

- Original EPUB／CBZ files remain in the user's configured Alist／OpenList storage.
- The D1 database stores the cloud index, scan checkpoints, per-user source/root preferences, book metadata, reading position, appearance preferences, annotations and reading-time events.
- The private R2 bucket stores generated cover thumbnails.
- The browser does not persist a personal bookshelf, imported files, reading progress, appearance settings, annotations or reading-history queue in IndexedDB, localStorage or sessionStorage. Active page state and the currently opened archive exist in memory only.

## Access and isolation

Cloudflare Access protects the complete site and all API endpoints. User-owned reading records are keyed by a SHA-256-derived identifier from the verified Access identity. Raw email addresses and Access JWTs are not stored in D1.

Alist／OpenList account passwords remain in Cloudflare Pages Secrets. Provider JWTs are short-lived and may be cached in the configured shared KV namespace. Neither passwords nor provider JWTs are returned to browser JavaScript.

## Book files

Opening a book requests its original archive through the protected Pages Functions proxy. The archive is held in browser memory for the active reading session and is not written to persistent browser storage. FRAME Reader does not modify or delete the original cloud file.

## Legacy browser data

Previous FRAME Reader versions used IndexedDB and localStorage. The cloud-only release no longer reads or updates those legacy records and does not delete them automatically. Users should review or export any legacy local-only books or reading history before manually clearing the site's old browser data.
