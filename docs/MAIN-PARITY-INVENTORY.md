# FRAME Ebook main-branch feature parity inventory

This inventory is derived from the actual main-branch source. It is the migration checklist for the Flutter Web, macOS and Android clients. The existing main-branch Pages application remains the reference implementation until all checklist items have been reproduced and tested.

## 1. Home bookshelf

Source: pages/index.html, pages/assets/library.js, pages/assets/library-store.js and pages/assets/site.css.

- [ ] Preserve the FRAME Reader brand header, primary navigation, hero section and connection/scanning entry points.
- [ ] Preserve bookshelf statistics: total works, started works, EPUB count and comic count.
- [ ] Preserve the recent-reading row, including its current ordering and compact card treatment.
- [ ] Preserve folder-first grouping. Multiple files/volumes in a folder form one work card; opening a folder shows its contained volumes and each volume's own reading progress.
- [ ] Preserve separate Electronic Books and Comics shelves.
- [ ] Preserve cover artwork and fallback covers, original cover proportions, stacked-volume presentation, labels, author, format and progress indicator.
- [ ] Preserve search across title, author, filename, format, folder members and available comic metadata.
- [ ] Preserve sort modes: recently read, title, added time and reading progress.
- [ ] Preserve grid and list display modes.
- [ ] Preserve empty states, loading/error states, item counts and responsive behaviour.
- [ ] Preserve folder detail navigation and return-to-bookshelf flow.
- [ ] Preserve the work detail dialog: editable title/author/category, format, page count, size, added date, reading progress and extra metadata.
- [ ] Preserve EPUB metadata restoration from the embedded OPF data.
- [ ] Preserve comic Bangumi search, candidate selection, subject linking and metadata propagation to volumes in the same folder.
- [ ] Preserve linking old book data, candidate matching, moving reading progress/annotations and conflict reporting.
- [ ] Preserve open-reading action and the exact cloud-book descriptor passed to the reader.

## 2. OpenList connection, cloud library and scanner

Source: pages/cloud/index.html, pages/assets/cloud-library.js, pages/assets/cloud-library.css, pages/assets/local-openlist.js and functions/api/cloud/*.

- [ ] Preserve the four source choices: VPS Alist, OpenList Worker, Mobile Device Alist and local OpenList.
- [ ] Preserve server-configured source readiness indicators and the existing distinction between server-side credentials and local OpenList login.
- [ ] Preserve local OpenList URL validation, username/password login, in-memory access token, saved base URL, logout and expired-login handling. Do not persist the local OpenList password or token.
- [ ] Preserve the two independent root paths: Books and Comics. Both roots belong to the active source configuration; keep separate roots and selection state.
- [ ] Preserve root validation, current-root selection, root status and save/apply behaviour.
- [ ] Preserve connection test and source switching feedback.
- [ ] Preserve the manager's Connection and Library tabs and its embedded/standalone layouts.
- [ ] Preserve directory listing, breadcrumb/path navigation, parent-directory navigation, filename search, item count and pagination.
- [ ] Preserve file type filtering and the current allowed formats for each library.
- [ ] Preserve full and incremental scan modes, per-library scan and scan-all sequence.
- [ ] Preserve resumable scan checkpoints, pending-folder queue, seen-folder tracking, page cursors and stale-index reconciliation semantics.
- [ ] Preserve progress summaries, completed-scan details, pause requests and pause reasons.
- [ ] Preserve scan log severity, timestamp/order, copy, clear and visible log count.
- [ ] Preserve retry-failed-cover operations and pending-cover processing.
- [ ] Preserve bounded HTTP Range ZIP reads for EPUB metadata and cover extraction. Do not download complete archives merely to generate a cover.
- [ ] Preserve EPUB container.xml/OPF parsing, metadata updates, cover discovery and thumbnail normalization.
- [ ] Preserve CBZ cover discovery and cover status.
- [ ] Preserve cover hashing and private R2 upload/retrieval semantics.
- [ ] Preserve scan/index error handling and retry behaviour without creating duplicate catalog rows.

### Source-specific file delivery

- [ ] Preserve the current cloud file endpoint contract and authenticated source validation.
- [ ] Preserve Range request forwarding and the existing same-origin stream path.
- [ ] For comic files, preserve the direct 302 attempt and automatic same-origin stream fallback when browser CORS prevents the redirect target from being read.
- [ ] Preserve the local OpenList direct file path and its Range support.
- [ ] Do not expose server-side provider credentials, JWTs or signed upstream URLs to app persistence or logs.

## 3. EPUB and CBZ Reading Room

Source: pages/epub-lab/index.html, pages/assets/epub-lab-comics-20261112.js, pages/assets/epub-lab.css, pages/assets/epub-compat.js and pages/vendor/foliate-js.

- [ ] Preserve the reader workspace header, title/author, live progress, current-position text and status messages.
- [ ] Preserve previous/next page controls, keyboard navigation, tap-to-turn navigation and mobile touch behaviour.
- [ ] Preserve table of contents, nested chapter expansion, TOC navigation and compatibility select.
- [ ] Preserve footnote/reference detection and the footnote popover.
- [ ] Preserve bookmark toggle, bookmark count, bookmark list, navigation to a bookmark and deletion.
- [ ] Preserve text selection and annotation toolbar.
- [ ] Preserve highlight colors: yellow, violet, mint and rose.
- [ ] Preserve underline annotations.
- [ ] Preserve note creation, editing, quotation context, save and deletion.
- [ ] Preserve annotation list, count, type labels, jump-to-annotation, refresh and deletion.
- [ ] Preserve annotation restoration and drawing in the text layer after chapter/page rendering.
- [ ] Preserve EPUB CFI progress restoration and CBZ/fixed-layout page-index restoration.
- [ ] Preserve debounced progress saving and final flush when changing books or leaving the reader.
- [ ] Preserve reading-session start/stop and live reading duration indicator.
- [ ] Preserve sidebar show/hide, mobile TOC/notes/bookmarks tabs, drawer/backdrop and responsive controls.
- [ ] Preserve appearance panel and its open/close interactions.
- [ ] Preserve font size options: 0.9, 1.0, 1.1, 1.2 and 1.3.
- [ ] Preserve line-height options: 1.45, 1.65, 1.85 and 2.0.
- [ ] Preserve font families: original, serif and sans.
- [ ] Preserve font weight choices: original, normal and medium.
- [ ] Preserve paragraph spacing choices: original, compact, standard and loose.
- [ ] Preserve text alignment choices: original, left and justify.
- [ ] Preserve EPUB reading modes: paginated and continuous scrolling. The Flutter Preview now has an initial single-page mode and continuous-scroll switch; full Legacy parity is still pending.
- [ ] Preserve EPUB page layout: single-page and double-page preferred. Single-page pagination and responsive two-page spreads exist in the reflowable EPUB Flutter Preview; full Legacy parity remains pending.
- [ ] Preserve vertical margin options 8, 16, 24, 32, 40, 48 and 64 px.
- [ ] Preserve horizontal margin options 0, 2, 4, 7, 10, 13, 16 and 20 percent.
- [ ] Preserve comic reading modes: paginated and vertical long-strip scrolling.
- [ ] Preserve comic page layouts: single-page and double-page preferred.
- [ ] Preserve comic image fitting: fit-page and fit-width.
- [ ] Preserve themes: paper, sepia and night.
- [ ] Preserve reading backdrops: wood, linen and slate.
- [ ] Preserve fullscreen and immersive fullscreen action states.
- [ ] Preserve fixed-layout EPUB as well as CBZ comic behaviour.

## 4. Reading statistics and time tracking

Source: pages/reading-stats/index.html, pages/assets/reading-stats.js, pages/assets/reading-stats.css and pages/assets/reading-tracker.js.

- [ ] Preserve foreground-only reading-time tracking, including heartbeat, idle timeout, visibility, blur and focus handling.
- [ ] Preserve session persistence and aggregation from the existing reading events API.
- [ ] Preserve period selection and period summary.
- [ ] Preserve total reading time, reading days, daily average and books opened.
- [ ] Preserve daily goal selector, goal percentage/ring, today's time, goal-target label and goal-days count.
- [ ] Preserve current/best streak, all-time reading days and streak note.
- [ ] Preserve calendar month navigation, daily calendar heat map and calendar total.
- [ ] Preserve reading trend chart and unit selection.
- [ ] Preserve top books, time-of-day distribution and recent sessions.
- [ ] Preserve cloud account/session status and refresh actions.
- [ ] Preserve JSON and CSV export.

## 5. Existing API and data contracts

Source: functions/api, functions/_lib, migrations and docs/ARCHITECTURE.md.

- [ ] Reuse /api/auth/session for Cloudflare Access and service readiness.
- [ ] Reuse /api/reading/bookshelf for the catalog joined with the current user's reading state.
- [ ] Reuse /api/reading/preferences for provider, roots and daily goal.
- [ ] Reuse /api/reading/state for per-book progress, appearance and editable metadata.
- [ ] Reuse /api/reading/annotations for bookmarks, highlights and notes.
- [ ] Reuse /api/reading/events and /api/reading/stats for reading-time records and statistics.
- [ ] Reuse /api/reading/link for legacy book-data linking.
- [ ] Reuse /api/cloud/scan-list and /api/cloud/index/* for scanning and catalog updates.
- [ ] Reuse /api/cloud/file and /api/cloud/covers for original files and private cover thumbnails.
- [ ] Reuse /api/comics/bangumi/search and /api/comics/bangumi/link.
- [ ] Preserve stable cloud book IDs and the descriptor validation against the indexed catalog.
- [ ] Preserve the main-branch D1 migrations and per-Access-user data isolation.
- [ ] Preserve the main-branch R2 cover object format and private access rules.
- [ ] Do not introduce Tauri-only device pairing/sync APIs or alter the backend schema as part of the client rewrite.

## 6. Platform acceptance

Run the same applicable checks on Flutter Web, macOS and Android.

- [ ] Existing main-branch user can sign in through the existing Cloudflare Access boundary.
- [ ] Same source, roots, books, comic volumes and user data appear as on main.
- [ ] All home, cloud-manager, reader and statistics checklist items are covered.
- [ ] EPUB chapters, footnotes, CFI restore, font/theme/layout and annotations work.
- [ ] CBZ pages, page restore, single/double-page, long-strip, fit-page/fit-width and annotations work.
- [ ] Range, 302, signed URL, CORS and stream fallback paths match the main app's behaviour.
- [ ] No original archive, expanded archive directory or comic page cache is written to persistent disk.
- [ ] The main-branch Pages application remains available and unchanged until explicit cutover approval.
