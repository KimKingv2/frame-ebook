# Architecture Notes

## Product shape

FRAME Reader is one library with three presentation profiles:

1. Desktop: full library management and reading controls.
2. Mobile: touch-first reading and synchronized state.
3. Kindle: low-JavaScript, low-animation, low-bandwidth reading surface for the Paperwhite 10 browser.

The Kindle profile is a separate compatibility target, not a responsive shrink of the desktop UI.

## Format strategy

| Format | Candidate | Notes |
|---|---|---|
| EPUB | Foliate.js parser/renderer | Reflowable and fixed-layout books; CFI progress. |
| MOBI | Foliate.js | Legacy Mobipocket parsing; add after EPUB validation. |
| AZW3 / KF8 | Foliate.js | KF8 parsing; complex books may be expensive to decode. |
| PDF | PDF.js | Mature rendering core; optimize page loading for mobile. |
| Manga | Fixed-layout EPUB / CBZ | Test reading direction, spreads, images and pagination separately. |

Foliate.js supports EPUB, MOBI, KF8/AZW3 and CBZ. Its API is not stable, so the current source is pinned to an exact commit. See `docs/THIRD-PARTY.md`.

## EPUB Lab (V0.2)

The first real EPUB prototype is at `/epub-lab/`.

- Foliate.js source snapshot: `78914aef4466eb960965702401634c2cb348e9b1` (MIT).
- JSZip 3.10.2 loads the small test archive for this compatibility experiment.
- The adapter supplies Foliate's EPUB loader interface (`loadText`, `loadBlob`, `getSize`).
- The view saves the current EPUB CFI to localStorage and restores it when the same book is reopened.
- A tiny original two-chapter Traditional Chinese EPUB is included for repeatable tests.

This loader is deliberately not the final storage strategy: JSZip loads the complete archive into memory. The OpenList production path must use HTTP Range / partial archive reads and must never put a long-lived OpenList admin token in browser JavaScript.

### Device test order

1. Mac Chrome: load the bundled demo, turn pages, jump chapters, reload and confirm location restore.
2. Paperwhite 10: load the same-origin bundled demo and test next/previous, chapter select and reload.
3. A larger, image-heavy EPUB: measure load time and memory behavior on Mac and Kindle separately.
4. Only after parser compatibility is known, implement OpenList metadata lookup and Range-backed reading.

## Kindle compatibility principle

The initial Kindle test uses conservative CSS and ordinary click buttons. It probes:

- JavaScript and DOM event handling
- Cookies, localStorage and sessionStorage
- XMLHttpRequest and fetch
- Promise, ArrayBuffer, Blob and FileReader
- IndexedDB and Web Crypto
- ES modules
- Flexbox, Grid and touch events
- Same-origin HTTPS/XHR request to /health.json

Paperwhite 10 real-device testing confirmed finger taps work on the previous/next controls even though Touch Events API detection is false. Prefer click controls as the baseline; swipe gestures remain optional.

A successful capability probe does not prove the entire EPUB engine will run. The EPUB Lab now tests the actual parser and paginator on the device.

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

Never expose a long-lived OpenList administrator token in browser JavaScript. A future Worker should authenticate the reader and issue narrowly scoped, short-lived access to one file or range request. Cloudflare Access compatibility on Paperwhite 10 is not yet proven; keep the public compatibility probe free of private data.
