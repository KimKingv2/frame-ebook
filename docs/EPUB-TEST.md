# EPUB Compatibility Test Log

## 2026-11-09 — Mac browser

User report: the Mac browser can open an EPUB in the V0.2 EPUB Lab.

Status:
- EPUB file opens and renders on Mac: **PASS (user-tested)**.
- Previous/next page navigation: not yet confirmed.
- Table of contents navigation: not yet confirmed.
- Reload and restore EPUB CFI: not yet confirmed.
- User-selected local EPUB file: not yet confirmed separately.

## Next device checks

On desktop, phone and tablet browsers, verify:
1. The bundled EPUB opens and renders without layout overflow.
2. Previous/next controls and table-of-contents navigation work.
3. Reloading restores the last CFI in the same browser.
4. A locally selected EPUB opens without being uploaded.
5. Portrait/landscape changes and different screen widths keep the reading controls usable.

Do not connect OpenList until the same-origin EPUB test is stable across the primary browsers and device sizes.
