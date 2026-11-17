# FRAME Ebook for Android

This is the Android app shell for the existing FRAME Ebook Cloudflare Pages application.

## First milestone

The app keeps the existing website, Cloudflare Access login, D1 bookshelf, reading state and Foliate UI. It uses Android WebView as the embedded reader surface and adds one native network path:

1. The current comics reader calls the existing same-origin endpoint:
   \`/api/cloud/file?library=comics&delivery=redirect\`.
2. \`WebViewClient.shouldInterceptRequest\` catches only that exact production endpoint and only for the comics library.
3. The native transport sends the authenticated request to Pages using the WebView's Cloudflare Access cookie.
4. It receives the actual HTTP 302, follows the signed OpenList URL from Android, and streams the final upstream response back to the same-origin page request.
5. The Pages Function resolves the signed URL and validates the indexed file, but does not carry the comic body bytes.

The native transport forwards a single byte \`Range\` request when one is supplied. The current web reader still calls \`JSZip.loadAsync(file)\` and therefore downloads the whole EPUB before opening it. A later milestone will replace that full-archive reader path with ZIP central-directory and entry range reads. This first APK removes the Pages data relay; it does not yet promise instant page-by-page fetching.

## Security boundaries

- Cloudflare Access cookies are sent only to \`https://frame-ebook.pages.dev/api/cloud/file\`.
- Cookies are never forwarded to the signed storage URL.
- Redirects must use HTTPS, may not contain URL user-info, and are capped at six hops.
- Only \`library=comics\` requests with \`delivery=redirect\` are intercepted. Other site traffic remains in WebView's normal network stack.
- WebView file/content access and mixed content are disabled.

## Build

Open the \`android/\` folder in Android Studio, or build from a machine with JDK 17, Android SDK 35 and Gradle 8.11.1:

\`\`\`sh
gradle --no-daemon -p android :app:assembleDebug
\`\`\`

The GitHub Actions workflow also builds the debug APK and uploads it as the artifact \`frame-ebook-android-debug-apk\`.

The debug APK uses application ID \`com.kimkingv2.frameebook.debug\`. It can be installed alongside a future release build.

## First-use checklist

1. Install the debug APK on Android 8.0 or later.
2. Open FRAME Ebook and complete the Cloudflare Access email verification inside the app.
3. Open a scanned EPUB comic from the comics shelf.
4. Confirm the status line reports \`302 直連成功\`.
5. Confirm the reading room opens normally and that the file request's final response is from the cloud-storage host, not a Pages stream.

The build artifact is a test build. Device verification is still required before calling the direct-delivery path production-ready.
