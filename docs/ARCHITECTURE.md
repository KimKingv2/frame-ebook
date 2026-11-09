# Architecture Notes

## Product shape

FRAME Reader is one library with three presentation profiles:

1. Desktop: full library management and reading controls.
2. Mobile: touch-first reading and synchronized state.
3. Kindle: low-JavaScript, low-animation, low-bandwidth reading surface for the Paperwhite 10 browser.

The Kindle profile is a separate compatibility target, not a responsive shrink of the desktop UI.

## Format strategy (candidates, not yet integrated)

| Format | Candidate | Notes |
|---|---|---|
| EPUB | foliate-js | Reflowable and fixed-layout books; test CFI/progress persistence. |
| MOBI | foliate-js | Legacy Mobipocket parsing. |
| AZW3 / KF8 | foliate-js | KF8 parsing; complex books may be expensive to decode. |
| PDF | PDF.js | Mature rendering core; optimize page loading for mobile. |
| Manga | Format-aware fixed-layout/image handling | Test reading direction, spreads, embedded images and pagination separately. |

foliate-js is modular and supports EPUB, MOBI, KF8/AZW3 and CBZ, but its API is not stable. Pin an exact commit and retain its license notice when integrating it. It uses native ES modules, so do not assume it works in the Kindle 10 browser.

## Kindle compatibility principle

The first test uses ES5 JavaScript, conservative CSS and ordinary click buttons. It probes:

- JavaScript and DOM event handling
- Cookies, localStorage and sessionStorage
- XMLHttpRequest and fetch
- Promise, ArrayBuffer, Blob and FileReader
- IndexedDB and Web Crypto
- ES modules
- Flexbox, Grid and touch events
- Same-origin HTTPS/XHR request to /health.json

A successful feature probe does not prove that a large ebook engine will run. Test a small EPUB chapter-loading prototype on the actual device before choosing a parsing strategy.

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
