# EPUB Compatibility Test Log

## 2026-11-09 — Mac browser

User report: the Mac browser can open an EPUB in the V0.2 EPUB Lab.

## 2026-11-09 — Live desktop browser smoke test (V0.3)

After adding the missing Foliate first-navigation initialization:

- Bundled EPUB parsing and reader initialization: **PASS**.
- Actual chapter text visible in the reading viewport: **PASS**.
- Next-page navigation: **PASS**; progress changed from 0% to approximately 48%.
- Previous-page navigation: **PASS**; returned to the prior location.
- Table of contents jump to Chapter 2: **PASS**; progress reached 100%.
- Reload and automatic bundled-book reopen: **PASS**; Chapter 2 and 100% progress restored.
- Appearance controls (font scale, line height, margins, paper/sepia/night themes): **PASS**.
- Appearance preferences persisted after reload: **PASS**.

The test also exposed an integration requirement: Foliate's `view.open(book)` parses and prepares the renderer but does not display the first section by itself. The adapter must call `view.init({ showTextStart: true })`, or pass a saved CFI through `view.init({ lastLocation, showTextStart: true })`, to navigate to the initial reading location.

## Remaining device checks

The test above is a live desktop-browser smoke test, not a substitute for testing actual phones and tablets. On desktop, phone and tablet browsers, verify:

1. Bundled and user-selected EPUB files open without layout overflow.
2. Font size, line spacing, page margin and all three themes visibly affect reflowable text.
3. Appearance settings and CFI reading position survive reload in the same browser.
4. Previous/next controls and chapter navigation work.
5. Portrait/landscape changes and different screen widths keep controls usable.
6. Larger, image-heavy books remain responsive and do not exhaust browser memory.

Do not connect OpenList until the core reader is stable across the primary browsers and device sizes.


## 2026-11-09 — Appearance controls follow-up

User reported intermittent mismatch between the selected paper theme and some visible page backgrounds, plus no obvious effect from the page-margin control.

Fix applied:
- Expose the Foliate paginator's exported `filter` parts to the active page theme using inherited CSS custom properties. This keeps the paginator's outer page background in step with the selected theme, not just the EPUB document body.
- Force non-media EPUB element backgrounds to remain transparent so authored block backgrounds do not randomly leave white or colored patches in paper/sepia/night mode.
- Apply both paginator `margin` (top/bottom) and `gap` (left/right and spread gutter) from the page-margin control.
- Call the paginator's public `render()` after changing those attributes so its internal layout geometry is recalculated immediately.

Retest required: cycle paper → sepia → night → paper, then narrow → standard → wide → narrow. Confirm the page background changes on every switch and the text block / page margins visibly expand and contract without losing the current CFI.
