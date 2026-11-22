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
