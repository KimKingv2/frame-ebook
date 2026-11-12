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


## 2026-11-09 — Fix vertical margin unit regression

The follow-up browser check and user report showed that only horizontal spacing changed. Root cause: Foliate's paginator takes `margin` as a CSS length and assigns it directly to the CSS custom property `--_margin`, which is used by `grid-template-rows: minmax(var(--_margin), 1fr)`. The adapter supplied a unitless number (for example, `16`), making the grid track definition invalid. The horizontal `gap` remained functional because it already included a percentage unit.

Fix:
- Pass the vertical paginator margin with an explicit `px` suffix (for example, `16px`).
- Keep the page-margin options at 8 / 16 / 24 px and horizontal gap at 4% / 7% / 10%.
- Force a paginator re-layout after the unit-bearing margin and gap are updated.

The earlier live check only confirmed the control options and navigation presence; it did not validate vertical whitespace. Re-run a visual vertical-spacing regression check after deployment.


## 2026-11-12 — Split page margins into independent axes

User requested separate numerical controls for page height and width spacing.

Changes:
- Replace the combined page-margin selector with two independent selectors:
  - Top/bottom (`verticalMargin`): 8 / 16 / 24 px, default 16 px.
  - Left/right (`horizontalMargin`): 4 / 7 / 10%, default 7%.
- Apply them directly to Foliate as `margin: <value>px` and `gap: <value>%`.
- Persist both values independently in localStorage.
- Migrate old combined `margin` preferences to both axes once, preserving the previous narrow / standard / wide selection.
- Update the mobile settings layout so the additional control remains readable.

Regression checks required:
1. Change top/bottom spacing while holding left/right at 7%; verify only vertical whitespace changes.
2. Change left/right spacing while holding top/bottom at 16px; verify only horizontal spacing changes.
3. Reload and confirm both values restore independently.
4. Confirm themes, font size, line height, page navigation and TOC navigation still work.


## 2026-11-12 — Typography controls design

Add four independent reading typography controls for reflowable EPUB chapters:

- Font family: original book font, serif (明體), or sans-serif (黑體).
- Font weight: original book styling, regular 400, or medium 500. This affects body text only, leaving headings' authored emphasis intact.
- Paragraph spacing: original book spacing, compact (0.4em), standard (0.8em), or loose (1.2em).
- Text alignment: original book styling, left aligned, or justified.

Design rules:
- Every control defaults to the EPUB author's original style to avoid unexpectedly restyling books on first load.
- Each value is independently persisted in the existing local appearance object.
- Settings are validated against fixed allow-lists before being applied.
- The controls use the existing dark-violet select styling and responsive two-column mobile layout.
- Fixed-layout EPUBs remain untouched.

Regression checks required:
1. Verify each setting independently changes the rendered body text without changing the other settings.
2. Verify choosing 原書設定 restores publisher / book styling for each category.
3. Reload and verify settings persist.
4. Verify headings retain their authored bold emphasis when body font weight changes.
5. Verify theme, font scale, line height, both margin controls, TOC and page navigation remain functional.


## 2026-11-12 — Typography controls live regression test

Verified on the live desktop browser at `https://frame-ebook.pages.dev/epub-lab/` with the bundled two-chapter demo EPUB.

- Font family: original / serif / sans options were present and selectable.
- Font weight: original / 400 / 500 options were present and selectable.
- Paragraph spacing: original / compact / standard / loose options were present and selectable.
- Text alignment: original / left / justified options were present and selectable.
- Independent top/bottom and left/right margin controls remained available.
- Applied a non-default value to each typography control; all selections remained active and the book text stayed visible and readable.
- Reloaded the page; each typography value persisted independently.
- Reset all four typography controls to the original-book setting after the test.
- No reader error message was observed.

The live test confirms control interaction and local persistence. Device-specific typography appearance still requires separate checks on mobile browsers and with books using different publisher styles.
