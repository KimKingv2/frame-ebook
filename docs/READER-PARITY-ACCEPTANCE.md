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
