# Third-party software notices

## Foliate.js

- Project: https://github.com/johnfactotum/foliate-js
- License: MIT
- Upstream source commit: `78914aef4466eb960965702401634c2cb348e9b1`
- Original license text: `pages/vendor/foliate-js/LICENSE`
- EPUB Lab files: `view.js`, `epub.js`, `epubcfi.js`, `progress.js`, `overlayer.js`, `text-walker.js`, `paginator.js`, `fixed-layout.js`, `comic-book.js`, and `vendor/zip.js`.
- Zip.js: BSD-3-Clause; license text is included at `pages/vendor/foliate-js/vendor/ZIPJS-LICENSE.txt`. The upstream bundle is pinned through the Foliate.js source snapshot listed above.

## JSZip

- Project: https://github.com/Stuk/jszip
- Version: 3.10.2
- License selected: MIT (the upstream project is dual licensed under MIT or GPLv3)
- MIT terms: `pages/vendor/jszip/LICENSE-MIT.txt`.
- The upstream bundle retains its original copyright and license banner.

These dependencies are included for static Cloudflare Pages deployment. Their licenses remain separate from original FRAME Reader code.

## public_file_saver

- Project: https://pub.dev/packages/public_file_saver
- Version: 1.2.2
- License: MIT
- Used by the Flutter reading statistics screen to export JSON and CSV through a user-selected system save dialog (Android Storage Access Framework, macOS save panel, and browser Save As/download fallback).
- The app passes export bytes directly from memory. It does not create an intermediate file or save without the user's explicit dialog action.
- Sandboxed macOS builds enable only the user-selected file read/write entitlement; the broader Downloads-folder entitlement is not enabled.
