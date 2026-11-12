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
- Independent paginator margins: top/bottom margin is 8, 16 or 24 CSS pixels (16 px by default); left/right page gap is 4%, 7% or 10% (7% by default). The adapter must pass a unit-bearing CSS length such as `16px` to Foliate's `margin` attribute and a percentage such as `7%` to `gap`. These settings must remain independent.
- Paper white, warm sepia and night themes.

Settings are validated against a fixed allow-list and stored locally under `frame-reader-appearance-v1`. Fixed-layout EPUBs keep their authored layout rather than having text styling forced on them.

This is a prototype appearance layer. EPUB authors may use deeply nested styles or fixed pixel sizes that need more testing. A future settings layer should prefer stable engine APIs where available.

### Device test order

1. Mac Chrome and Safari: load the bundled demo, change each appearance setting, turn pages, jump chapters, reload and confirm location and appearance restore.
2. Android Chrome and iOS/iPadOS Safari: verify EPUB loading, appearance controls, portrait/landscape layout and local file selection.
3. A larger, image-heavy EPUB: measure load time and memory behavior on desktop, tablet and phone.
4. Only after the browser reader is stable, implement OpenList metadata lookup and Range-backed reading.

The current browser prototype is only a compatibility baseline. Test the actual parser, paginator and local-file flow on each target browser; feature detection alone is not sufficient.

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
