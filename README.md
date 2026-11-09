# FRAME Reader

**Your Personal Digital Library**  
A private, multi-device ebook library for desktop, tablet and mobile.

> Current status: **V0.3 Reading Room**. This is an engineering prototype, not yet a production ebook library. OpenList and cloud sync are not connected yet.

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

- `/` — visual home and bookshelf layout preview.
- `/epub-lab/` — EPUB parsing, navigation, local progress and reading appearance prototype.
- `/demo/frame-reader-sample.epub` — small, original Traditional Chinese test book.
- `/health.json` — same-origin connectivity endpoint.

## Bookshelf and covers

The homepage currently uses original SVG artwork to preview the visual bookshelf. Only the bundled test EPUB is a real book in this repository; the other cover cards are explicitly marked as design previews.

Planned cover lookup order:
1. Embedded EPUB cover image.
2. A sibling `cover.jpg` (or supported cover image) in the book's private folder.
3. A generated fallback cover based on book metadata.

## V0.3 Reading Room

The EPUB Lab adds local reading appearance controls:
- Font scale: 90% to 130%.
- Line spacing: 1.45 to 2.0.
- Page margin: narrow, standard or wide.
- Paper themes: paper white, warm sepia and night reading, synchronized across the EPUB document and Foliate page background.
- Page margin controls outer top/bottom breathing room (8, 16 or 24 px) and horizontal page/spread gap, followed by an explicit paginator re-layout. The default is 16 px.
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
