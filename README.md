# FRAME Reader

**Your Personal Digital Library**  
A private, multi-device ebook library with a Kindle-friendly web reader.

> Current status: **V0.1 foundation / Kindle browser compatibility test**. This is not yet a production ebook reader and does not connect to OpenList.

## Goals

- Read EPUB, MOBI, AZW3/KF8 and PDF in desktop and mobile browsers.
- Offer a dedicated, deliberately lightweight reader mode for older Kindle browsers.
- Support illustrated books and manga, including single-page, spread and vertical-scroll layouts where the source format permits.
- Keep book files in the user's private storage (initially OpenList), not in this public repository.
- Synchronize reading positions, bookmarks and annotations across supported web clients.

## V0.1 contents

- `/` — project landing page.
- `/kindle-test/` — old-browser feature probe and simple page-turning demo.
- `/health.json` — same-origin HTTPS/XHR test endpoint.
- No book files, OpenList credentials, user accounts or tracking code.

The Kindle test intentionally uses conservative HTML/CSS and ES5 JavaScript. It checks browser APIs without requiring a modern framework. The ES-module probe is isolated so that a browser which does not understand `type="module"` can still run the rest of the test.

## Local preview

No build step is required. From the project root:

```sh
python3 -m http.server 8080 --directory pages
```

Open `http://localhost:8080/` on a computer. The Kindle test is at `http://localhost:8080/kindle-test/`.

For a realistic Kindle test, deploy over HTTPS. A local HTTP server is not a substitute for the deployed Cloudflare Pages URL.

## Cloudflare Pages deployment

This repository is intended to connect directly to Cloudflare Pages:

1. In Cloudflare Dashboard, open **Workers & Pages** and create a Pages project.
2. Choose **Connect to Git** and select `KimKingv2/frame-ebook`.
3. Set production branch to `main`.
4. Choose **None** as the framework preset.
5. Leave the build command empty.
6. Set the build output directory to `pages`.
7. Deploy.

Future pushes to `main` will trigger production deployments; other branches can be used for previews.

### Important for the first Kindle test

Keep this compatibility-test deployment public until the browser test is complete. Do not put a real library, OpenList token, or private file behind this test project. Cloudflare Access and modern identity-provider login flows need a separate compatibility test on the Paperwhite 10 before they are used in the Kindle path.

## Architecture direction

- **Desktop/mobile reader:** a modern browser application. `foliate-js` is a candidate for EPUB/MOBI/KF8 and fixed-layout books; PDF.js is the PDF candidate. These are not bundled in V0.1.
- **Kindle reader:** separate lightweight page/profile. Do not assume the full desktop engine or modern JavaScript module support works on the Paperwhite 10.
- **Storage:** OpenList remains the private file source. The public GitHub repository contains application code only.
- **Sync:** Cloudflare Worker/Pages Functions + D1 are candidates for web-client reading state. Kindle compatibility, authentication and network behavior must be validated before finalizing the API.

## Security and privacy

- Never commit OpenList tokens, account credentials, private books, personal metadata exports or `.env` files.
- V0.1 sends no diagnostic data to a server. It makes one same-origin GET request to `/health.json` solely to verify HTTPS/XHR connectivity.
- Do not enable public directory listing or expose OpenList paths without an authenticated, short-lived access design.

## License

The original project files are licensed under MIT. Third-party dependencies will retain their own licenses and notices when introduced.
