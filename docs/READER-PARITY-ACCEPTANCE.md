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

The sidebar cloud-sync footnote keeps its existing 25px footer content area and
11px top separation. Its text is now centered vertically inside that area for
both compact and desktop layouts. Widget tests assert the engine label's bottom
right alignment and verify that the footnote text and footer share the same
vertical center. These are geometry assertions, not screenshot pixel-diff
acceptance.
