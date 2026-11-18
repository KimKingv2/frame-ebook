# FRAME Ebook Flutter client

The shared Flutter client targets Web, macOS and Android. It is isolated from the existing Cloudflare Pages output in the sibling pages directory.

On the first setup, generate platform folders from the Flutter SDK in this directory with: flutter create --platforms=web,macos,android --org com.kimkingv2 --project-name frame_ebook .

## Current milestone: 302 / Range Lab

The first screen is a transport proof of concept. It sends GET with Range bytes=0-1023, accepts optional HTTP Basic Authentication in process memory only, and retains at most 4 KB of response bytes.

The native transport manually handles 301, 302, 303, 307 and 308. It resolves relative Location values, limits the redirect chain, blocks HTTPS-to-HTTP downgrade, and strips Authorization, Cookie and Proxy-Authorization on cross-origin hops.

The Web transport uses the browser Fetch API through package:http BrowserClient. Browsers follow redirects themselves. A cross-origin final response must pass CORS. Expose Content-Range and Accept-Ranges if Flutter Web needs to inspect those response headers.

## Run

From this directory, run flutter pub get, then flutter run -d macos, flutter run -d chrome, or flutter run -d followed by the Android device ID.

Use a file URL, not a WebDAV directory URL. The test does not persist the URL, credentials, response body or downloaded archive.

Before testing a device build, run flutter analyze and flutter test. Build targets are flutter build web, flutter build macos and flutter build apk.

## Deployment boundary

Do not change the existing Cloudflare Pages build output from pages during this milestone. The current Web application must remain available as the transition and reference version. Flutter Web will be deployed to a separate preview target until feature parity and CORS tests pass.
