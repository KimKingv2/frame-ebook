# FRAME Reader

**Your Personal Digital Library**  
A private, multi-device ebook library for desktop, tablet and mobile.

> Current status: **V0.2 EPUB Lab**. This is an engineering prototype, not yet a production ebook library. OpenList and cloud sync are not connected yet.

## Product scope

The web reader is designed for:
- **Desktop:** full library management, reading controls, search and annotations.
- **Tablet:** comfortable touch reading, flexible layouts and two-page spreads where appropriate.
- **Mobile:** responsive single-column reading and one-hand controls.

Kindle is outside the online reader's support scope. If it is used later, treat it as a separate offline-reading workflow rather than maintaining a Kindle-browser compatibility layer.

## Goals

- Read EPUB first, then add MOBI, AZW3/KF8 and PDF.
- Support illustrated EPUBs and manga, with single-page, spread and vertical-scroll layouts where the source format permits.
- Provide responsive reading experiences for desktop, tablet and phone.
- Keep book files in private storage (planned: OpenList), not in this public repository.
- Synchronize reading position, bookmarks and notes across supported web clients.

## Current routes

- `/` — project home.
- `/epub-lab/` — real EPUB parsing, navigation and local progress prototype.
- `/demo/frame-reader-sample.epub` — small, original Traditional Chinese test book.
- `/health.json` — same-origin connectivity endpoint.

## V0.2 EPUB Lab

The EPUB Lab uses a pinned Foliate.js EPUB parser and renderer snapshot, with JSZip used as a compatibility-oriented archive loader for this small prototype.

It supports:
- Open the included sample EPUB.
- Select a local EPUB file on desktop. The file is read in the browser and is not uploaded.
- Chapter navigation via the EPUB table of contents.
- Previous/next page controls.
- Save and restore an EPUB CFI in this browser's localStorage.

**Important:** this prototype reads the entire EPUB archive into browser memory. It is only for parser and browser compatibility validation. The production OpenList reader should use HTTP Range / partial reads for larger books, after validating the storage server's CORS and Range behavior.

The saved CFI is currently local to one browser. Cross-device synchronization requires the future authenticated Worker + D1 service and is not implemented yet.

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
