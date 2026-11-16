# FRAME Ebook for macOS

The macOS desktop edition is a standalone Tauri application. It bundles the reader UI and Foliate.js assets locally; it does not load `frame-ebook.pages.dev` and does not call Cloudflare Pages Functions, Workers, D1, R2 or KV.

## First milestone

- Native WebDAV profile management and directory browsing using Rust `PROPFIND`.
- Supports WebDAV Basic Authentication. Passwords are stored in the macOS Keychain; profile metadata is stored in the app config directory.
- Follows WebDAV HTTP redirects in the native transport. Credentials are sent only to the configured WebDAV host, never to a redirected signed-file host.
- EPUB and CBZ files can be added to the local bookshelf and opened in the existing Foliate reading room.
- Reading position, appearance, bookmarks, highlights, notes, reading-time events and preferences use the local WebView store rather than D1.
- Original books stay on the WebDAV server. The first milestone downloads the selected archive to a short-lived app-cache file before loading it into the existing JSZip reader; the temporary copy is deleted after it is loaded into memory.

## Build

```sh
cd macos
npm install
npm run tauri:build
```

## Current limitations

- The first version downloads the complete EPUB/CBZ into a short-lived local cache before parsing it. It follows server-side 302 redirects natively but does not yet perform lazy ZIP central-directory and per-resource Range reads.
- The build is ad-hoc signed for testing, not Developer ID signed or notarized. macOS may show a first-open security warning; this is not yet a public notarized release.
- WebDAV servers must allow PROPFIND and GET. HTTP is accepted only for localhost, `.local`, or private LAN addresses; public hosts must use HTTPS.
