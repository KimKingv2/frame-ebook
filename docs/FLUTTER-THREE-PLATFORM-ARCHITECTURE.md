# FRAME Ebook three-platform Flutter architecture

## Decision

Flutter/Dart is the only feature and product-logic source for Web, Android and macOS. The three targets must not grow separate bookshelf, reading-state or reader implementations.

The shared Flutter core owns:

- EPUB package parsing and resource resolution, including reflowable books and fixed-layout comics.
- Bookshelf, folders, volume grouping and work details.
- Reader UI, navigation, appearance, fullscreen and reading controls.
- Bookmarks, highlights, notes, annotations and reading progress.
- Stable book descriptors and repository/domain logic.

A reader or repository must not branch on Web, Android or macOS to decide how a book is read or how reading state behaves.

## Layer boundaries

### 1. Shared Flutter feature and domain layer

Screens and reader state call repositories and a platform-neutral file-source contract. They do not create HTTP requests, inspect cookies, follow redirects or use platform checks to decide which reading engine to display.

A file source should expose a streaming response with the information the reader needs, such as:

- A byte stream with cancellation and close semantics.
- HTTP status and safe response headers.
- Content length, content type and content-range when present.
- Whether the response is a full response or a partial Range response.

The interface must support bounded Range reads for EPUB ZIP metadata, chapter XHTML, CSS, images, SVG and font resources, plus streaming for larger active-session resources.

### 2. One native transport core for Android and macOS

Android and macOS use the same Dart `dart:io HttpClient` implementation. Keep redirect handling, Range forwarding, response validation, cancellation and error mapping in that shared implementation.

Required native transport behaviour:

- Obtain the Cloudflare Access cookie from the authenticated native WebView cookie store through the smallest necessary platform bridge.
- Send that cookie only to the protected FRAME Ebook Pages origin.
- Disable automatic redirect following for file delivery. Inspect each redirect and follow it explicitly so credentials are never copied to a signed storage URL.
- Preserve valid Range headers across the redirect chain.
- Accept only HTTPS redirect targets, reject invalid targets and cap redirect hops.
- Stream the response body. Do not buffer an entire EPUB archive in a `Uint8List` just to hand it to the reader.
- Cancel the HTTP request and close the response stream when the reader changes books or closes.

Cookie acquisition is a platform boundary. The HTTP protocol and file-stream logic are not.

### 3. Separate browser transport adapter

Web uses the browser Fetch API and same-origin Cloudflare Pages Functions. It must not import `dart:io` or depend on native cookie bridges.

The browser adapter:

- Uses browser-managed Cloudflare Access cookies with same-origin credentials.
- Requests the Pages Functions same-origin streaming path for normal reading.
- Preserves Range requests for bounded reads and partial content.
- Consumes the Fetch response body as a stream instead of first collecting the entire archive.
- Does not expose signed storage URLs or provider credentials to Flutter feature code.
- Does not require cross-origin CORS access to a storage host simply to make reading work.

Do not force direct 302 delivery in the browser when CORS or browser policy makes the same-origin stream path more reliable. Browser compatibility takes priority over reproducing native redirect behaviour.

### 4. Minimal platform bridges

Keep platform-specific code limited to capabilities that Dart cannot safely obtain itself, primarily:

- Reading the existing authenticated WebView cookie store for native HTTP requests.
- System file selection or other operating-system capabilities only when a feature genuinely needs them.

Do not put EPUB parsing, reading UI, progress rules, annotation logic or general redirect logic in Kotlin, Swift or WebView JavaScript.

## Storage and backend boundaries

- Original EPUB archives remain in the configured Alist/OpenList source.
- Existing Cloudflare Pages Functions remain the authenticated boundary for catalog validation, provider credentials and same-origin Web streaming.
- D1 remains authoritative for user-specific reading progress, appearance, bookmarks, notes and reading events.
- Private R2 remains the cover-thumbnail store.
- Reuse the existing stable cloud book descriptor and APIs. Do not introduce a parallel catalogue, local-only reading-state model or D1 schema solely for the Flutter rewrite.
- Do not add persistent archive, extracted ZIP, page-image, font or response caches. Keep active-session buffers bounded and transient.
- Resolve chapter-relative XHTML, SVG and CSS references against their containing archive paths. External HTTP/data references remain references only and are never fetched by the archive loader.
- Enforce per-resource and total stylesheet read limits; CSS imports must be cycle-safe and bounded by depth and count.

## Update and packaging policy

| Change | Expected delivery |
|---|---|
| Flutter/Dart feature code | Web CI and Cloudflare Pages deployment; Android/macOS Dart changes use Shorebird OTA |
| Web-only adapter or Web assets | Web CI and Cloudflare Pages deployment |
| Android native source or Android permission/configuration | Rebuild Android package |
| macOS native source or macOS entitlement/configuration | Rebuild macOS package |
| Flutter plugin dependency, shared app-bundled asset or shared platform-preparation script | Rebuild both native packages |
| Documentation or test-only changes | No native package rebuild |

The Flutter CI native-change detector follows this policy and reports Android and macOS independently. A Dart-only change must not trigger an Android APK or macOS app build.

**Shorebird status:** Shorebird is the chosen Android/macOS OTA channel, but this repository's automated Shorebird release/patch workflow and required credentials/app configuration still need to be connected and verified. Until that is done, do not describe an OTA patch as published. Native package builds remain available for the changes listed above.

## Current migration state

The app is not yet at the final architecture:

- The native API factory currently uses `package:http` and the WebView cookie manager.
- Android's legacy direct-file path currently has a Java `HttpURLConnection` transport.
- The current Reader shell still uses the legacy Reading Room through an iframe on Web and a WebView on native platforms.
- The Flutter bookshelf and work-details UI are already using shared Dart feature code and the existing APIs.
- The shared EPUB reader session now coordinates Range-backed archive access, package parsing, chapter/resource loading, TOC navigation, chapter-index progress restoration, and the existing D1 state/annotation APIs.
- The reader session deliberately does not synthesize EPUB CFI values. Fine-grained CFI persistence must come from a standards-compliant renderer, and the existing CFI is not treated as a chapter index.
- The legacy Reading Room remains the default Reader route. An opt-in `FrameEpubReaderPreviewScreen` is now reachable from the legacy Web Reader toolbar, using the same injected file-source factory, existing D1 repository, and shared EPUB session/renderer. This preview does not replace the legacy route.
- The preview provides spine-chapter navigation, EPUB TOC navigation, read-only display of existing notes/bookmarks, and persisted reader font size, line height and theme.
- The shared reader now creates publication-level EPUB CFIs from visible reflowable XHTML text, validates the spine item against the EPUB package, and debounces progress updates into the existing `progress.cfi` and `progress.index` fields. It restores point CFIs and the start of legacy Foliate range CFIs, with chapter-index fallback when a CFI cannot be resolved.
- Reflowable chapter restoration uses the resolved text block plus a document-text fraction to bring the saved position back into view. TOC and internal fragment links use the same block-anchor mechanism. The current renderer reports the first text point of the visible block rather than a character-precise viewport intersection; this is an initial standards-based position layer, not pixel-perfect pagination parity.
- Fixed-layout EPUB comics continue to use spine/page-index progression and the existing interactive viewport. CFI progress generation is disabled for fixed-layout content. Text selection, annotation editing/overlay restoration and the rest of the legacy parity inventory remain follow-up work.
- The renderer supports common text blocks, headings, inline emphasis, lists, basic internal links, raster images, bounded static SVG from inline XHTML and internal EPUB resources, common Presentation MathML constructs (tokens, rows, fractions, roots, scripts, under/over limits, fenced groups and small matrices), bounded embedded TTF/OTF fonts through CSS `@font-face` (including IDPF and Adobe font obfuscation), and XHTML tables with header cells, column spans and vertically merged row spans. The custom table grid measures row-span height across covered rows, including late-loading images and rich cell contents, and keeps long tables bounded in paginated pages. SVG rendering is limited to sanitized, self-contained markup: external resource references and executable content are removed, inline SVG is capped at 1 MiB, and archive SVG reads are capped at 8 MiB. MathML rendering is local and bounded to 512 nodes / 32 levels; annotations and annotation-XML payloads are not executed or displayed. This is not a browser-complete CSS or MathML engine: advanced MathML constructs, WOFF/WOFF2 font sources, CSS float text-wrapping, complex positioning, layered gradients, and standards-based CFI generation remain follow-up work. Raster XHTML images now honor `object-fit` (`fill`, `contain`, `cover`, `none`, `scale-down`), keyword/percentage `object-position`, and bounded `max-width` / `max-height`. Inline raster images, SVG objects and MathML use CSS `vertical-align` keyword placement (`baseline`, `sub`, `super`, `text-top`, `text-bottom`, `top`, `bottom`, `middle`) mapped to Flutter inline placeholders; SVG viewport-specific sizing and full replaced-element sizing semantics remain limited. Reflowable pagination also honors forced `break-before` / `break-after` page boundaries and the legacy `page-break-before` / `page-break-after` aliases; `break-inside: avoid` (and `page-break-inside: avoid`) keeps the styled block together, with oversized blocks placed on a vertically scrollable page. CSS `orphans` and `widows` line counts are applied when splitting selectable paragraph text; when those constraints cannot be met safely, the paragraph remains one intact fragment. `left` / `right` break values currently mean a forced page break only and do not enforce recto/verso page-side parity. Internal raster CSS backgrounds are now supported for a single `url(...)` layer, with stylesheet-relative archive resolution, bounded in-memory reads, repeat modes, keyword/percentage positions, and `cover` / `contain` sizing; external/data/SVG background URLs and full CSS background shorthand parsing remain unsupported. The preview is an integration checkpoint, not evidence of full EPUB layout parity. Embedded TTF/OTF data is read from bounded ZIP entries, deobfuscated in memory when the EPUB declares a supported IDPF or Adobe algorithm, and registered through Flutter's runtime font loader. Each static CSS `@font-face` weight/style is registered under a separate private family so chapter text can select the matching regular, bold, or italic face using CSS weight matching. Variable font weight ranges and WOFF/WOFF2 remain unsupported. The reader does not persist font files; it caps each font at 8 MiB, total font reads per publication at 24 MiB, and runtime font registration at 64 faces / 64 MiB per isolate.

Keep those bridges until the shared Dart transport and Flutter reader have passed the acceptance checks below. Do not remove a working legacy route merely to make the architecture look complete.

## Migration sequence

1. **Build and update policy:** keep Web deployment automatic, make Android/macOS build gating native-change-only, and document the accepted boundaries.
2. **File-source contract:** add a platform-neutral streaming file-source interface and tests for response metadata, Range semantics, cancellation and errors.
3. **Native adapter:** implement one Dart `HttpClient` adapter for Android/macOS, with the minimal cookie-store bridge and explicit credential-safe redirect handling.
4. **Web adapter:** implement a Fetch-based same-origin streaming adapter with Range support and no native imports.
5. **EPUB package parser:** parse container.xml, OPF metadata, manifest, spine, EPUB 3 navigation and EPUB 2 NCX on top of the generic Range-backed ZIP reader.
6. **EPUB resource loader:** resolve chapter-relative XHTML, CSS, SVG, image, font and internal-link references with bounded per-entry reads and no persistent content cache.
7. **Flutter reader core:** the shared session, initial CSS cascade, XHTML/fixed-layout Flutter chapter renderer, and initial EPUB CFI generation/restoration are integrated in an opt-in preview screen. Next expand layout coverage, improve character-precise position capture, and wire editing/rendering of annotations and reading events.
8. **Parity and retirement:** test the preview with representative reflowable books and fixed-layout EPUB comics on Web, Android and macOS. Keep the legacy Reader route until the complete main-branch parity inventory passes. Only then retire the legacy iframe/WebView reader bridges.
9. **OTA release automation:** connect Shorebird app configuration and protected CI credentials, then verify a Dart-only patch on both native targets before relying on it as the normal update route.

Local OpenList Flutter EPUB reading uses the current in-memory client only to obtain the file URL, then reads the original archive in bounded 1 MiB Range requests. Never persist the local token or forward it to the raw file host.

## Acceptance checks for the transport layer

- A valid byte range is forwarded and a server `206` response retains its `Content-Range` semantics.
- Native 302 handling forwards Range but never forwards Cloudflare Access cookies or other origin credentials to a signed storage host.
- Non-HTTPS, malformed, looping or excessive redirects are rejected safely.
- Cancellation closes the active HTTP response and does not leave a background download running.
- Web requests stay on the protected same-origin Pages Functions path and consume the response body incrementally.
- Authentication errors, expired sessions, upstream errors and unsupported Range responses map to consistent reader-facing errors.
- No original archive or extracted book content is written to persistent local storage.
- Both adapters pass the same contract tests wherever the platform permits, plus adapter-specific security tests.
