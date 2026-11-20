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

## file_picker

- Project: https://pub.dev/packages/file_picker
- Version: 13.4.0
- License: MIT
- Used by the Flutter reading statistics screen to save in-memory JSON and CSV bytes using the platform save-file dialog on Android and macOS, with a browser download fallback on Web.
- The app does not create an intermediate export file. The save operation is initiated only after the user selects the export action.
- The macOS app sandbox grants only user-selected file read/write access for the save panel; it does not receive broad Downloads-folder access.
