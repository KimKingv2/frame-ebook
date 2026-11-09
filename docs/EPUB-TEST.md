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


## 2026-11-09 — Theme and page-margin regression test

User reported intermittent theme-color mismatch and a page-margin control that did not visibly work.

The fix was verified on the live desktop deployment:

- Switched paper → sepia → night → paper.
- The EPUB reading surface and its exported paginator filter surface followed the selected theme; text remained readable.
- No leftover colored patches or visible flicker were reported.
- Switched page margin standard (40) → narrow (24) → wide (60) → narrow (24).
- Narrow visibly expanded the content area; wide visibly reduced it; returning to narrow reproduced the earlier layout.
- Reading location remained at 48%, Chapter 1/2, through all appearance changes.

Implementation:
- Theme colors are propagated to Foliate's exported `filter` parts via CSS custom properties, in addition to styling the EPUB chapter document.
- Non-media EPUB child backgrounds are transparent under the selected paper theme, avoiding author-defined background blocks that conflict with the reader theme.
- Page margin updates both Foliate's vertical `margin` and horizontal `gap`, then explicitly calls the paginator's `render()` to recalculate layout.

The surrounding FRAME Reader application chrome intentionally remains dark violet. The selected paper theme applies to the EPUB reading surface and paginator page surface, not the entire website shell.

This was a live desktop-browser regression test. Phone and tablet browser verification remains pending.


## 2026-11-09 — Reduce vertical page margins

User reported that the top and bottom page margins felt too large.

Adjustment:
- Reduce Foliate's paginator `margin` options from 24 / 40 / 60 px to 8 / 16 / 24 px.
- Change the default from 40 px to 16 px.
- Keep the horizontal `gap` scale unchanged (4% / 7% / 10%), so this adjustment specifically tightens top/bottom whitespace without making the page columns wider.
- Old saved margin values are rejected by the allow-list and fall back to the new 16 px default.

Live verification pending: confirm the new default is active and the narrow / standard / wide settings produce visibly tighter top and bottom spacing while page navigation remains functional.
