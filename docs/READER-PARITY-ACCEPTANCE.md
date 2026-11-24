# FRAME Ebook Reader parity acceptance

This document defines the mandatory release gate for the Flutter Reader. The legacy Reading Room is the visual and behavioural source of truth. "Close enough", a redesigned approximation, or passing unit tests alone does not constitute acceptance.

## Non-negotiable definition of done

- The Flutter Reader must match the legacy Reading Room at **pixel-level visual fidelity** for the same content, viewport, device-pixel ratio, appearance preferences and UI state.
- Every visible control and user flow must behave the same as the legacy Reading Room: same purpose, placement, labels, enabled/disabled state, state transitions, navigation outcome, dismissal behaviour and persistence.
- No control, option, interaction, responsive state or legacy behaviour may be removed or simplified to make the Flutter implementation easier.
- The old Reading Room remains unchanged and remains the reference implementation. The Flutter preview remains opt-in until this document's acceptance gates pass and the user explicitly approves cutover.

## Visual comparison protocol

Capture the legacy and Flutter Reader at identical viewport dimensions and device-pixel ratio, using the same EPUB fixture, chapter/CFI, scroll or page position, reader preferences, annotations and UI state. Load the same fonts and wait for images and layout to settle. Disable transitions/animations during capture.

Required viewport classes:
- Desktop wide: 1440 × 900 and 2560 × 1440.
- Tablet / intermediate: 1024 × 768 and 820 × 1180.
- Compact: 560 × 900 and 390 × 844.
- Fullscreen / immersive: repeat the relevant desktop and compact states without browser/app chrome.

Required visual states:
- Reader initial load, normal reading, page boundaries, previous/next navigation and current-position progress.
- Sidebar open/closed; nested TOC collapsed, expanded and current chapter; notes and bookmarks populated and empty.
- Appearance panel closed/open, every settings group, selected values, scrolling and dismissal.
- Text selection toolbar, highlight colours, underline, note editor, delete confirmation and empty states.
- Footnote/reference dialog, loading/error/retry states and fullscreen/immersive controls.
- Fixed-layout EPUB single/double page, RTL, long-strip, fit-page/fit-width and each backdrop.

Compare screenshots with an image-diff report and inspect overlays at 100%. Fix all meaningful geometry, spacing, typography, colour, border, radius, shadow, icon and responsive-flow deviations. Differences caused solely by unavoidable platform font rasterisation or subpixel antialiasing may be recorded as exceptions; they must not be used to excuse layout or styling differences. Each exception must identify the platform, affected pixels/region and reason.

## Interaction parity protocol

For every control, compare the legacy and Flutter flows side-by-side. Verify:
- Pointer, hover, focus, pressed, selected, disabled and loading states where applicable.
- Mouse, keyboard, touch and supported system-back/Escape behaviour.
- Exact action result, navigation target, scroll/page position and return path.
- Panel/drawer/dialog open and close behaviour, backdrop dismissal and focus restoration.
- Data persistence and restoration after refresh, reopening the same book and switching devices/platforms.
- Error, timeout, retry, cancellation and empty-state behaviour.

## Test evidence required before marking complete

- Golden screenshot baselines and image-diff evidence for every required viewport/state above.
- Automated interaction/widget tests for each control and important multi-step flow.
- Browser end-to-end regression on Web.
- Actual installed-app acceptance on macOS arm64 and Android target devices.
- EPUB fixtures covering reflowable text, long chapters, nested TOC, footnotes, annotations, RTL and fixed-layout artwork; CBZ fixtures remain part of the complete legacy parity gate.
- A completed issue list showing every visual and behavioural mismatch fixed or explicitly approved by the user.

A CI pass is necessary but not sufficient. Do not mark the Reader UI or interaction checklist complete based only on compilation, unit tests, or source-level inspection. Do not report a percentage as "pixel parity" without the screenshot comparison evidence. If the Flutter-native surface cannot meet the gate, prefer reusing the same legacy Reader surface inside the Flutter navigation container over shipping a knowingly divergent redesign.

## Acceptance record

Preliminary screenshot inspection was performed on 2026-11-22 using the user's supplied pair. The source images are 4096 × 1832 (legacy) and 4096 × 1826 (Flutter). The dominant paper-colour bounds were measured as legacy x=570..4049, y=132..1602 (3480 × 1471 px) and Flutter x=1102..3525, y=508..1591 (2424 × 1084 px). This establishes a major geometry mismatch, but is not a valid final pixel-diff baseline because browser viewport, device-pixel ratio, zoom, exact fullscreen state and font rasterisation were not confirmed identical. The Flutter desktop layout was then changed to remove the 1500 px centred cap, compact the reader identity/actions into one toolbar and align the sidebar and page in one full-width workspace. This source-level/widget-test correction is not a claim of pixel-level acceptance. Formal acceptance still requires fresh captures with the identical viewport/DPR, fixture, EPUB CFI, preferences and UI state, then image-diff evidence for the full matrix. Record platform, tested commit, fixture and remaining exceptions here.


## Source-level comparison review · 2026-11-22

Compared the legacy reference in `pages/epub-lab/index.html`,
`pages/assets/epub-lab.css` and
`pages/assets/epub-lab-comics-20261112.js` against the Flutter preview.

Confirmed desktop differences and corrections in this revision:

- Navigation behaviour: legacy desktop uses a two-column grid. Above 1050px it reserves a 250px sidebar and 16px gap; at 1050px and below it reserves 220px and 12px. Closing the sidebar removes that column and gap so the reading surface expands. At 820px and below it switches to an overlay drawer. Flutter now uses the same breakpoints and reserved-column behaviour.
- Reader frame: legacy desktop frame uses 10px inner padding, 14px corner radius and a 1px low-opacity border; the inner reading viewport uses an 8px radius. Flutter now uses those desktop values. Compact and immersive padding remain separately constrained.
- Desktop sidebar surface: legacy uses a low-contrast two-stop violet-black gradient, a 13px radius and a soft shadow. Flutter now uses the corresponding treatment and restores the legacy top/content gutters.
- Book heading: legacy uses an 84px minimum heading block, 12px/4px/16px outer insets, an 18px title and a right-aligned current-chapter label above the action row. Flutter now follows that hierarchy and geometry.

Remaining source-level differences to review in a subsequent pass include the exact chapter-progress panel composition, the original topbar/engine-status row, typography and row density inside the annotation cards, and the text-flow renderer (Foliate.js versus the Flutter-native renderer). These areas cannot be certified as pixel-identical from CSS inspection alone.

No pixel-parity acceptance is claimed. A valid image-diff still requires fresh legacy and Flutter captures using the same EPUB fixture, CFI/page, preferences, annotations, viewport, device-pixel ratio, browser zoom and loaded fonts. The previous acceptance note already records that a historical screenshot pair did not meet this controlled-capture requirement.


## Visual correction follow-up · 2026-11-22

Compared the sidebar, progress controls, status region and quick-action
dimensions against the legacy Reading Room HTML, CSS and JavaScript.

- Desktop sidebar Material is now transparent, allowing the parent’s original
  dark violet-black gradient to show through instead of an opaque lighter
  panel. The TOC content restores 14px horizontal inset above 1050px and 11px
  at/below that breakpoint. The sync footnote retains its bottom position and
  restores the legacy subtle top rule, muted `#776d85` colour, 8px font and
  1.7 line-height.
- The reading-position save status and dynamic reading-time status now appear
  below the entire sidebar-plus-reader row. The timer text switches between
  `正在記錄本次閱讀` and `本次閱讀已暫停`; the idle hint remains at the far right.
- Previous/next controls now use the original text labels `← 上一頁` and
  `下一頁 →`, natural button widths, 37px height and 14px horizontal padding.
  The centre progress panel restores the 220–300px width and 10px inner inset.
- The four top-right actions restore the 72px bookmark width and responsive
  104px / 92px / 86px widths for the remaining controls. The group has enough
  width to remain in one row on desktop and is right-aligned close to the
  reading viewport.

Widget and geometry regressions now cover the sidebar background, TOC inset,
footnote palette, action dimensions and status placement. These are source and
automated-widget corrections, not pixel-level acceptance. Screenshot evidence
still requires controlled legacy and Flutter captures using the same viewport,
DPR, EPUB CFI, appearance settings and loaded fonts.


## Legacy action toolbar restoration · 2026-11-23

Re-read the final effective rules in `pages/assets/epub-lab.css` (including
the late icon-only override at the end of the file) and the original SVG paths
in `pages/epub-lab/index.html`. The effective action row is four circular,
icon-only controls, not the earlier rectangular 72/104px interpretation:

- Desktop: 48 × 48px targets, 24 × 24px SVG glyphs, 2px horizontal gaps.
- At 820px and below: 44 × 44px targets, zero horizontal gap.
- The visual gap below the chapter label is 10px on desktop and 6px in compact
  layout after combining the parent column gap with the action row top margin.
- Controls are transparent and borderless by default. The active bookmark alone
  receives the legacy translucent violet circle; the appearance glyph uses
  `#eee6ff`; hover uses the legacy translucent violet wash.
- The four SVG path geometries are reproduced in the Flutter painter. The
  compact heading returns to the legacy left-identity/right-progress split.

Widget and geometry tests assert target sizes, gaps, row width, and progress
spacing at desktop and compact widths. This is source-level and automated
layout evidence, not final pixel-diff acceptance. A controlled screenshot pair
at identical viewport/DPR/zoom and reader state is still required for that gate.


## Action button size and reader-frame spacing adjustment · 2026-11-23

Following the user's visual feedback, the round 48/44px icon-only treatment
introduced in the previous revision was rolled back. The reader now uses the
earlier dark rectangular icon-button treatment, with narrower practical sizes:

- Desktop buttons: 36 × 31px.
- Compact phone buttons (<=560px): 32 × 27px.
- Four-button row: 156px desktop / 140px compact, with 4px gaps.
- Button row remains right-aligned, and the progress/action column is capped
  at 260px instead of a wide 420px box.
- Desktop heading bottom inset and reading-frame top inset were reduced, so the
  button row sits close to the reading frame rather than floating far above it.
- Compact heading bottom spacing was also reduced.

The widget tests assert per-button dimensions, inter-button gaps, total row
width, chapter-label spacing and desktop distance to the reading frame. This
remains source/test geometry evidence; controlled screenshot comparison is
still required for formal pixel-level acceptance.


## Center the current chapter title over the reading surface · 2026-11-23

The desktop current-chapter label (`currentChapterLabel`, with the existing
fallback text before a book is ready) now sits centered above the actual reading
frame. Its horizontal anchor is calculated from the main reading-column bounds,
after subtracting the visible navigation sidebar and its gap. This keeps the
label aligned with the reading surface when the desktop sidebar is expanded or
collapsed. The four compact rectangular action buttons remain right-aligned and
retain their current dimensions.

The title's left anchor also accounts for the desktop heading's 4px horizontal
inset so its center remains aligned with the reading frame's actual edges. The
widget test checks that the chapter-title center and reading-frame center share
the same horizontal coordinate. This is a layout-geometry assertion, not a
screenshot pixel-diff claim.


## Remove the Reading Time interface and tighten the reader header · 2026-11-23

The Flutter Reader no longer exposes the legacy "閱讀時光" route or its
in-reader reading-session indicator. The preview screen also stops starting the
reading-time tracker, so removing the interface does not leave background
reading-time calls running. This change does not alter reading-position,
bookmark or annotation synchronization.

The wide desktop heading is reduced from 84px to 40px, approximately halving
the heading's contribution to the screen-top-to-reader spacing while retaining
the 36px inner layout needed by the controls. The book identity is compacted to a two-line title/author block so it fits
without overflow; the four compact action buttons remain 36 × 31px and keep
their existing 4px gaps. The current chapter title is
centered both horizontally over the reading column and vertically within the
heading. Compact layouts also reduce the top navigation bar and heading insets.
Widget tests assert the 40px heading, 42px heading-to-frame offset, and both
axes of title centering. These are geometry assertions, not screenshot
pixel-diff acceptance.


## Lower reader spacing and restore visible page-turn controls · 2026-11-23

Following the user's request, the lower workspace inset is reduced from 4px
to 2px, the status-line top inset from 7px to 4px, and the page-control
container vertical padding from 12px/4px to 6px/2px. The compact progress
separator is reduced from 10px to 6px. This gives the reading frame more
vertical room while preserving the page-progress information and status line.

Previous/next controls now use explicit enabled and disabled foreground,
background and border colours. Their labels and chevrons remain visible at
book boundaries; only the action is disabled. Each control has a stable test
key and a minimum 104px × 37px target. Widget coverage checks both rendered
labels, both directional chevrons, disabled-state contrast values, target
geometry and the enabled next-page callback. Desktop layout coverage asserts
the reduced bottom inset and status-line spacing.

These are automated widget/layout checks, not screenshot pixel-diff
acceptance.


## Draw page-turn labels independently of Material button defaults · 2026-11-23

The user reported that the previous/next controls still rendered as empty
outlined boxes in the deployed Web reader. The previous implementation
verified that Text widgets existed in the widget tree, but did not verify
that their foreground style was visibly painted by the Material button.

The controls are now rendered as a fixed-size decorated surface with a direct
Text widget and an explicit TextStyle colour, avoiding OutlinedButton and its
inherited disabled-state styling. The directional chevrons are text glyphs
rather than Material icon-font glyphs. Disabled controls retain a muted but
high-contrast label and border; enabled controls retain the brighter label.
Widget tests check the exact painted Text child, explicit colours, non-zero
layout bounds, button dimensions and tap behaviour.

This remains widget/layout evidence rather than browser screenshot pixel-diff
evidence. A live browser visual check is still required to close the report.


## Increase the reader frame top breathing room · 2026-11-23

The user requested a little more distance between the top screen edge and
the reader frame. In normal desktop layout, the content row's top inset is
increased from 2px to 10px, shifting the frame down by 8px. In compact/mobile
layout it increases from 4px to 8px, shifting the frame down by 4px.
Immersive mode retains its 2px top inset. The lower inset remains 2px so the
previously requested bottom spacing is unchanged.

Regression tests assert the desktop frame is now 50px below the desktop
toolbar top (previously 42px), and assert the compact top and bottom insets.
Chapter-title centering and toolbar placement are otherwise unchanged.


## Center toolbar contents in the screen-to-frame top band · 2026-11-23

The desktop gap above the reading frame is now a single 50px toolbar band.
The desktop toolbar minimum height is 50px and the separate frame-row top
inset is zero, preserving the frame's existing top coordinate. The book title
and author block, centered chapter label, back button and all four action
buttons are vertically centered on the same axis within that band.

Widget regression coverage checks the center coordinate of each group/control,
and confirms the toolbar bottom meets the frame top with no second hidden gap.
Compact layout and immersive-mode insets are unchanged. These are automated
layout checks, not screenshot pixel-diff acceptance.


## Match desktop annotation-card density to the legacy Reading Room · 2026-11-23

The Flutter desktop sidebar annotation cards now follow the effective legacy
sidebar CSS: 9px vertical / 7px horizontal card padding, 7px card separation,
5px marker rail, 9px quote text at 1.65 line-height, 8px note preview at 1.6
line-height, and the 25px / 8px-horizontal delete control. The kind label uses
the legacy 0.5px letter spacing. Note markers now use separated dash segments
instead of a continuous solid rule. Mobile card padding and target sizing stay
unchanged.

Widget tests assert the desktop card padding, margin, border radius/colour,
marker rail width, quote and note typography, line clamps, and delete button
geometry. This is source and widget-layout evidence, not screenshot
pixel-diff acceptance.


## Restore progress-meter states and engine-status visibility · 2026-11-23

The reading progress dock is being split into a reusable, independently
testable widget so its desktop and compact geometry, percentage labels,
accessibility semantics, and fixed-layout visibility can be verified without
opening a cloud EPUB session. The legacy chapter row is conditional for
reflowable EPUB; fixed-layout comics keep only the whole-book meter.

The target styling is the 4px violet chapter gradient and 3px muted-violet
whole-book gradient, with 9px tabular percentage labels and the original 8px
row gap. This is automated widget evidence, not screenshot pixel-diff
acceptance.


Desktop engine status is placed in the upper strip of the existing 50px book
toolbar, while the quick-action row remains vertically centered on the toolbar
axis. The compact and tablet top bars always reserve a flexible, ellipsized
slot for the engine status; the removed Reading Time link stays absent.


## Move engine status to the bottom-right and vertically center the cloud-sync footnote · 2026-11-23

The engine status no longer occupies the desktop action-toolbar strip or the
compact top bar. It now shares the existing bottom status line, aligned to the
right edge, while the reading-position save/error message remains on the left.
The status line keeps its existing 18px content height and 4px top inset; no
additional row or vertical space is introduced. The reader frame therefore
retains its existing 2px gap above the status line and the same bottom-of-screen
spacing.

The sidebar cloud-sync footnote keeps its 11px top separation. Its text is now
centered vertically inside a 22px compact footer area and a 25px desktop footer
area, preserving the original footprint of each layout. Widget tests assert the engine label's bottom
right alignment and verify that the footnote text and footer share the same
vertical center. These are geometry assertions, not screenshot pixel-diff
acceptance.


## Reuse EPUB stylesheet graphs between chapter navigations · 2026-11-23

The resource loader now caches parsed CSS dependency graphs in bounded memory,
and coalesces concurrent requests for the same graph. This avoids repeatedly
reading and scanning the same linked stylesheets when navigating between
chapters that share a book theme, and also avoids duplicate work when one
chapter links the same stylesheet more than once. Cache entries are keyed by
stylesheet path and parsing limits; entries larger than 512 KiB are not kept,
and the shared cache is capped at eight graphs / approximately 2 MiB. Disposing
the EPUB session clears both completed and in-flight graph references. No CSS
or book content is written to disk, and this does not trigger whole-book
prefetching.

Widget-level resource-loader tests verify concurrent request coalescing,
subsequent in-memory reuse with no extra Range reads, and separation between
default and stricter parsing limits. This is bounded-cache and request-count
evidence; real-book navigation timing still needs device/browser measurement.

## Re-measure page width when a two-page spread collapses to one page · 2026-11-23

When a wide viewport crossed below the 760px two-page threshold, the reader
could switch back to single-page presentation while retaining the narrower
page width measured for the previous spread. The spread-mode comparison was
being overwritten before it was checked, so widening-only geometry changes
could skip the required pagination pass.

The renderer now compares the previous spread state before recording the new
state. A change between spread and single-page presentation invalidates the
old measurement even when the new page width is larger. A widget regression
starts at 820px, crosses to 759px, and verifies that the text column expands
from the spread width to the single-page width. This is automated layout
evidence, not a browser screenshot or pixel-diff claim.

## Restore CFI positions across inline XHTML text nodes · 2026-11-23

Paginated text fragments previously recorded only the first XHTML text node
inside each rendered fragment. If a saved CFI pointed into a later inline node
(such as text inside `<strong>` or `<em>`) that shared a page fragment with
preceding text, the fragment lookup could miss the target node and fall back
to the chapter's first page.

Each fragment now retains its complete list of source text ranges, including
the original UTF-16 offsets. Restore lookup selects the fragment whose source
range contains the CFI offset, with a nearest-range fallback for offsets
affected by whitespace normalization. Exact page-boundary offsets are
assigned to the following fragment, while the terminal end of a text node
remains addressable. Live progress still uses the first source range in
reading order so the saved CFI stays at the start of the visible fragment.

A widget regression restores to a CFI in a later `<strong>` node after a long
paragraph prefix and verifies that the reader opens beyond page zero. This is
automated widget evidence; browser-level visual and real-book restore timing
remain part of acceptance.


## Preserve the active CFI across typography and viewport reflow · 2026-11-23

The paginated renderer now invalidates its measured fragments whenever the
effective page width or available page height changes, whether the viewport
grows or shrinks. It no longer carries narrower/shorter page measurements into
a larger window. Before remeasurement, the latest visible text node and its
original UTF-16 offset remain in the chapter state; the restore scheduler now
uses that internal CFI anchor even when the parent has not supplied a new
initial-position property. Explicit initialTextNode / initialTextOffset
restores are also recognized independently of the optional scroll-fraction
fallback.

Widget regressions navigate to a later page, record the emitted CFI, then
compare the live reader's restored page with a fresh reader restored from that
same node and offset under the new viewport height or new font size / line
height. This verifies source-position-to-page mapping after reflow, rather
than merely checking that the reader remains on a non-zero page. These are
automated widget tests; browser pixel comparison and real-book timing remain
part of the acceptance gate.


## Keep first-line-indented long paragraphs eligible for pagination · 2026-11-23

Chinese EPUB books commonly apply CSS `text-indent` to paragraphs. The Flutter
renderer represents this first-line indent as a `WidgetSpan` containing a
childless `SizedBox(width: indent, height: 0)`. The paginator previously
treated every non-ruby `WidgetSpan` as an unknown-size widget and returned the
entire paragraph as one fragment. A long indented paragraph could therefore
turn into a vertically scrollable single page instead of flowing across
reader pages.

The paginator now supplies TextPainter with dimensions for this narrowly
defined, fixed-size childless `SizedBox` placeholder and keeps its logical
placeholder position in the text ranges. Ruby annotations retain their
existing measured dimensions. Images, SVG, and interactive widgets remain
intact because their actual render-box dimensions cannot safely be inferred
from the span tree.

Unit coverage verifies contiguous ranges around a fixed-size placeholder and
continues to verify that unknown widget placeholders are not split. An EPUB
widget regression uses a long XHTML paragraph with `text-indent: 2em`, checks
that it spans multiple reader pages, and confirms the complete text occurs
exactly once in the rendered selectable text. This is automated test evidence,
not yet a browser screenshot comparison or a survey of real-world EPUBs.


## Align table columns when rowspans and colspans overlap · 2026-11-23

Table grid construction now accounts for occupied columns before placing each
row's next cell. Previously, the global column count was estimated from the
sum of colspans in each source row, without adding columns pushed to the right
by an active rowspan. A row containing a rowspan in its first column followed
by a two-column colspan and another cell could therefore render four flex
tracks while calculating cell text widths against a three-column table. That
made widths inconsistent between rows.

The table layout is extracted into `frame_epub_table_layout.dart`. It resolves
cell start columns against active rowspans, expands the final grid width when
needed, and emits explicit empty placements so every row uses the same total
number of tracks. The renderer uses those placements for both flex allocation
and text-width measurement. Source cell order and the existing bounded
vertical scrolling for long tables are preserved.

A widget regression covers a two-row table where a rowspan forces a following
row's colspan to the right, then asserts the merged cell is exactly twice the
width of the adjacent single-column cell. Unit tests verify the final track
count and row placement maps independently. This is automated layout evidence,
not a screenshot pixel-diff or a complete HTML table conformance claim.


## Render real vertical geometry for EPUB rowspan cells · 2026-11-23

The table renderer now lays out cells in one shared grid rather than building
each source row as an independent Flutter Row. It measures ordinary cells to
establish the initial row heights, then expands the covered rows when a
rowspanning cell's natural content height is greater than their combined
height. The spanning cell is laid out once more at the sum of those row heights,
so its background, border and vertical alignment occupy the full merged area.
Column spans, header flags, source cell order, horizontal overflow and the
existing bounded long-table scroll container remain in place.

The layout helper now retains each source cell's bounded rowSpan in its grid
placement. A render-object geometry test verifies exact start/end alignment
across two rows with independently sized content, and an EPUB widget
regression uses a long multi-line cell next to short cells in both rows. These
automated checks establish table geometry for the covered fixture; they do
not claim full browser-equivalent HTML table conformance or close the
screenshot/device acceptance gate.


## Verify overlapping rowspan constraints and rich cell content · 2026-11-23

The shared table grid now has additional geometry coverage for five rows with
five intersecting row-span constraints. The regression checks the outer edges
of each merged cell against the independently measured row markers, including
spans that begin inside rows already enlarged by other spans. A separate XHTML
fixture places multiple paragraphs and a long text run in one spanning cell,
with unordered/ordered lists in its adjacent rows and a tappable footnote link
inside the merged cell. It verifies the final cell geometry and that the
footnote callback remains reachable after the shared-grid layout.

These fixtures exercise overlapping row-height constraints and mixed textual
cell children. Image intrinsic-size and asynchronous image-load behaviour in
tables still require their own fixture and device/browser measurement; this
does not claim complete table conformance or replace visual parity acceptance.


## Reflow spanning cells after embedded images load · 2026-11-24

The EPUB widget suite now includes an image resource inside a two-row merged
cell. The fixture uses a real 60 × 140 PNG stored inside the EPUB archive,
not a mocked render box. The regression waits for asynchronous archive reads
and image decoding, verifies the decoded image's dimensions, then checks that
the spanning cell still begins and ends exactly with the two adjacent rows.
This covers the transition from the fixed-height loading placeholder to the
decoded image's intrinsic dimensions in the shared table grid.

The test establishes the supported inline-image path for a non-paginated
table. Paginated late-image remeasurement, explicit CSS width/height semantics,
and additional formats such as SVG remain separate acceptance items.
