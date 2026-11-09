# EPUB Compatibility Test Log

## 2026-11-09 — Mac browser

User report: the Mac browser can open an EPUB in the V0.2 EPUB Lab.

Status:
- EPUB file opens and renders on Mac: **PASS (user-tested)**.
- Previous/next page navigation: not yet confirmed.
- Table of contents navigation: not yet confirmed.
- Reload and restore EPUB CFI: not yet confirmed.
- User-selected local EPUB file: not yet confirmed separately.

## V0.3 Reading Room checks

New controls:
- Font scale 90–130%.
- Line spacing 1.45–2.0.
- Page margin 24 / 40 / 60 CSS px.
- Paper, sepia and night themes.
- Appearance settings restore from localStorage on reload.

Implementation note: appearance styles are injected into reflowable EPUB content when each section emits a load event. Fixed-layout EPUBs are intentionally not restyled.

## Next device checks

On desktop, phone and tablet browsers, verify:
1. The bundled EPUB opens and renders without layout overflow.
2. Font size, line spacing, margin and all three themes visibly affect the text/page.
3. Appearance settings survive reload in the same browser.
4. Previous/next controls and table-of-contents navigation work.
5. Reloading restores the last CFI in the same browser.
6. A locally selected EPUB opens without being uploaded.
7. Portrait/landscape changes and different screen widths keep the reading controls usable.

Do not connect OpenList until the same-origin EPUB test is stable across the primary browsers and device sizes.
