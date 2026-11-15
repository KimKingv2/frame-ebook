# FRAME Reader V0.9 — Cloudflare setup

FRAME Reader uses the D1 catalog as its primary cloud bookshelf and mirrors completed catalog entries into the current browser's IndexedDB as metadata-only records. Original EPUB / CBZ files remain in OpenList and are fetched only when opened; they are not copied into IndexedDB by scanning or automatic shelf sync. Local imports retain their Blob in IndexedDB. Reading position, appearance preferences and annotation records remain local to the browser.

## 1. Create and bind D1 and private R2 cover storage

Create a D1 database named `frame-reader-db` in Cloudflare Dashboard → Storage & Databases → D1, or use Wrangler:

```sh
npx wrangler login
npx wrangler d1 create frame-reader-db
```

Apply the schema from the repository root if it has not already been applied:

```sh
npx wrangler d1 execute frame-reader-db --remote --file=migrations/0001_reading_events.sql
npx wrangler d1 execute frame-reader-db --remote --file=migrations/0002_cloud_catalog.sql
npx wrangler d1 execute frame-reader-db --remote --file=migrations/0003_cloud_covers.sql
```

In Workers & Pages → `frame-ebook` → Settings → Bindings, add a D1 database binding named `FRAME_READER_DB` and select `frame-reader-db`. Also create a private R2 bucket named `frame-reader-covers`, then add an R2 bucket binding named `FRAME_READER_COVERS` pointing to it. Do not enable public access for this bucket. Save and redeploy so both bindings are available to Pages Functions. Do not recreate or reset an existing database.

Also add a **KV namespace binding** named `MEDIA_AUTH_TOKEN_CACHE`. Bind Reader Production to the same Production KV namespace already used by FRAME Audio: `frame-series-auth-cache-production`. For Preview, bind the separate shared Preview namespace used by FRAME Audio Preview (currently `media-platform-auth-cache`); never bind Preview to the Production namespace. Do not create another Reader-only namespace, because the purpose is to share provider JWTs between trusted FRAME media apps. The KV namespace contains only short-lived OpenList login JWT cache records, not passwords, book data or reading history.

## 2. Configure server-side OpenList accounts

Under the Pages project's Settings → Variables and Secrets, add the following to Production. Add the same values to Preview only when you also intend to test private Preview deployments.

| Name | Type | Purpose |
|---|---|---|
| `ALIST_VPS_API_BASE_URL` | Variable | VPS Alist HTTPS API base URL |
| `ALIST_VPS_USERNAME` | Variable | Read-only VPS Alist account name |
| `ALIST_VPS_PASSWORD` | Secret | Password for the VPS Alist account |
| `OPENLIST_WORKER_API_BASE_URL` | Variable | OpenList Worker HTTPS API base URL (also accepts `ALIST_WORKER_API_BASE_URL`) |
| `OPENLIST_WORKER_USERNAME` | Secret | Read-only Worker account name (also accepts `ALIST_WORKER_USERNAME`) |
| `OPENLIST_WORKER_PASSWORD` | Secret | Password for the Worker account (also accepts `ALIST_WORKER_PASSWORD`) |
| `ALIST_MOBILE_DEVICE_API_BASE_URL` | Variable | Mobile Device Alist API base URL |
| `ALIST_MOBILE_DEVICE_USERNAME` | Variable | Read-only Mobile Device account name |
| `ALIST_MOBILE_DEVICE_PASSWORD` | Secret | Password for the Mobile Device account |

The three server-side profiles are independent. Configure only the sources you intend to use. The account and password names above intentionally omit `API_`; the server also accepts the older `*_API_USERNAME` / `*_API_PASSWORD` variants for compatibility. Use an Alist account with read-only access and grant it access only to the intended book and comic directories.

### How Alist authentication works

Pages Functions read each source's API URL, username and password from Cloudflare. They call `getProviderToken()` before `/api/fs/list` and `/api/fs/get`: a valid short-lived JWT is reused from the shared `MEDIA_AUTH_TOKEN_CACHE` KV namespace, and a new `POST /api/auth/login` is made only on a cache miss or refresh. The record uses the common prefix `media-platform:provider-auth:v1`, expiry-aware TTL and the same SHA-256 key derivation as FRAME Audio. Provider identities and `Client-Id` values are exactly `vps`, `worker` and `mobile-device` (`media-platform-server-{provider}`), so matching provider URL and username allow Audio and Reader to reuse the same cached JWT. When an upstream API rejects a cached token with HTTP/API code 401, Reader invalidates it, logs in again and retries once. A per-isolate memory cache and single-flight login guard reduce repeated KV reads and concurrent logins. If KV is unavailable or not bound, Reader remains functional using isolate-memory caching, but cold starts may log in again. JWTs are never sent to the browser or stored in D1/R2; account passwords remain in Pages Secrets.

FRAME Reader uses Cloudflare Zero Trust Access as its **only** website authentication layer. Cloudflare Access must authenticate requests at the edge before they reach Pages, and its application must protect the complete hostname, including static pages and every `/api/*` route. Pages Functions intentionally do not independently inspect or verify `Cf-Access-Jwt-Assertion`; there is no second Reader password, custom session cookie, Team Domain Variable or AUD Variable. Do not add `FRAME_READER_ACCESS_TEAM_DOMAIN` or `FRAME_READER_ACCESS_AUD`.

This design relies on the Access edge policy. If the production hostname or any API route is left outside the Access application, the corresponding Reader content/API is not protected by an application-level JWT check. Confirm the hostname-wide Access application before deploying or changing its scope.

D1 stores reading events/statistics, the metadata-only cloud catalog, resumable scan state and cover hashes/status. The private R2 bucket stores normalized cover thumbnails only; original EPUB / CBZ files remain in OpenList. Cover extraction uses bounded HTTP Range reads from ZIP archives and does not intentionally download the full book. The app converts extracted covers to small WebP (JPEG fallback) thumbnails and deduplicates them by SHA-256. It never stores OpenList credentials in D1 or R2. The old `auth_attempts` table may remain in D1 and is no longer used.

## 4. Configure the LAN-direct source (optional)

The fourth source is the OpenList instance reachable directly from the current device, such as a Mac or phone on the home network. On the cloud page, enter its URL, account name and password. The URL and username are saved in that browser's local storage. The password is kept only in the current tab's `sessionStorage`, so a page reload in that tab can reconnect, but closing the tab clears it. The credentials are sent directly to the LAN OpenList login and file-list endpoints; they do not pass through Pages, D1 or Worker APIs.

Use a separate read-only account. Plain HTTP does not encrypt the username/password or Authorization header over Wi-Fi. Use HTTPS when available, or a trusted private LAN / encrypted VPN such as Tailscale. Allow the exact FRAME Reader origin in the LAN OpenList CORS settings. The browser needs `Content-Type` and `Authorization` request headers permitted for the login and file API calls. The final file host returned in `raw_url` must also permit browser CORS.

Legacy local Token settings are not reused. On first open after this update, the old saved local Token is discarded; enter the LAN account and password once and save the source again.

## 5. Set the two library paths like FRAME Audio

The cloud page has two independent path fields:

- **Books root:** EPUB electronic books.
- **Comics root:** EPUB and CBZ comics.

You can type an absolute path directly, or browse folders and use the current folder as the Books or Comics root. The two HTML input `value` attributes are the defaults. Changes in the page apply only to the current page session; refreshing restores the HTML defaults. The current values are reused when switching between VPS Alist, OpenList Worker, Mobile Device Alist and LAN-direct OpenList.

All sources should expose the same absolute folder layout so the two HTML input paths work after switching sources. The default paths are the `value` attributes of `cloud-books-root` and `cloud-comics-root` in `pages/cloud/index.html`. Changes made in the browser apply only to the current page session; refreshing restores the HTML defaults. The previous `OPENLIST_BOOKS_ROOT_PATH` and `OPENLIST_COMICS_ROOT_PATH` variables are not used for path defaults or access control. The actual permission boundary is the Alist account: restrict each account to the intended read-only directories.

After Cloudflare Access authentication succeeds, the cloud page automatically reads the D1 index for the previously selected source, library and HTML-default root path. The first use of each source/library/root combination requires **手動掃描／續掃**. The recursive scan stores its folder queue and page cursor in D1 after each directory page, so a paused or interrupted scan can resume later. Once complete, normal page loads and folder navigation query D1 only; they do not list directories from OpenList. Run another manual scan after adding, removing or reorganizing cloud files. The next completed scan removes stale catalog entries only after the whole root has been traversed successfully. Each VPS, Worker, Mobile Device and LAN-direct source, and each Books/Comics root, has an independent catalog and scan state.

## 6. Verify the configuration

1. Confirm the D1 binding `FRAME_READER_DB` and private R2 binding `FRAME_READER_COVERS` exist. Apply `migrations/0001_reading_events.sql`, `migrations/0002_cloud_catalog.sql` and `migrations/0003_cloud_covers.sql` to the `frame-reader-db` database.
2. Protect the complete production hostname `frame-ebook.pages.dev` with Cloudflare Access. Important: for Pages, the initial `Enable access policy` toggle protects Preview deployments only, not the root `*.pages.dev` production hostname. To protect Production as well:
   - In Workers & Pages → `frame-ebook` → Settings → General, enable Access policy.
   - In Zero Trust → Access → Applications, open the application created for this Pages project and select Configure.
   - Under Public hostname, make sure the application covers `frame-ebook.pages.dev` as a whole host, not only `/cloud/*` or another individual page. Remove the wildcard `*` from the Subdomain field if it is being used as the Pages wildcard, then save the production hostname.
   - Confirm the Access application/policy covers the entire hostname and therefore `/`, `/cloud/*`, `/reading-stats/*`, and `/api/*`. Do not add path exclusions for the API routes.
   - Return to the Pages project settings and enable the Preview access policy again if you also want Preview deployments protected. Preview uses a separate hostname/policy and must not be confused with Production.
   - If a custom domain is used, create a separate Access application for that hostname and protect the complete hostname too.
   **Security boundary:** Pages Functions trust the Cloudflare Access edge and do not perform a second JWT verification. No Reader-specific Access Team Domain or AUD Variables are required. If Access does not protect the full hostname, the API routes can be reached without Reader-level authentication.
3. Open the protected FRAME Reader site. Cloudflare Access should handle authentication before the page loads; there is no separate Reader password in Access mode.
4. The previously selected source and its D1 catalog load automatically. If no source has been selected yet, choose one and save it; for LAN-direct, enter its URL, username and password first.
5. Set the Books and Comics root paths. For each source and each library, click **手動掃描／續掃** once and allow the recursive scan to finish. If interrupted, click it again to resume from the saved D1 cursor.
6. After the first completed scan, folder navigation reads D1. Re-run the scan when you want to synchronize new, modified or deleted OpenList files.
7. Open any cloud book from the main bookshelf. Its original EPUB / CBZ is fetched from OpenList for the active reading session and is not persisted as a second cloud-file copy in IndexedDB. The cloud original is never changed or deleted.

## 8. Shared provider Token cache (2026-11-14)

The server-side VPS Alist, OpenList Worker and Mobile Device Alist providers now use the same short-lived JWT cache contract as FRAME Audio. Bind the existing shared KV namespace as `MEDIA_AUTH_TOKEN_CACHE` in this Pages environment before relying on cross-project reuse. Use `frame-series-auth-cache-production` for Production and the separate `media-platform-auth-cache` namespace for Preview. Never share a KV namespace across Preview and Production. After changing the binding, trigger a new deployment so the Pages Functions receive it. Without the binding, Reader falls back to isolate memory and may authenticate again after a cold start.

## 7. Existing data and current behavior

- Cloud catalog indexing requires `migrations/0002_cloud_catalog.sql`. It is additive and does not alter existing reading events, local books, reading progress or appearance settings. The two Access verification Variables must be configured as described above.
- Existing local books, covers, reading progress and appearance settings remain in IndexedDB. The local store is version 3 and includes an `annotations` store for per-book highlights, notes and bookmarks. Cloud shelf sync stores metadata and source coordinates only, never the original cloud Blob.
- Books root supports EPUB. Comics root supports EPUB and CBZ. MOBI is not supported directly; convert it to EPUB before importing.
- Server-side account passwords remain in Cloudflare Variables / Secrets. The browser receives only source labels and configured-status flags. Only the optional LAN-direct URL, username and current-tab password are stored on the device. D1 cloud catalog rows contain directory/file names, paths, formats, sizes and modified timestamps, not book contents or credentials.
- Cloud browsing and file-info requests are read-only. The D1 catalog is automatically mirrored to the main bookshelf as metadata-only local records. The reader fetches a cloud original only when opened and keeps per-book reading position, appearance and annotations in local browser storage. The current Foliate adapter loads the opened archive in memory; it does not save that cloud archive Blob into IndexedDB.
- Reading duration is tracked locally first. Once authenticated through Cloudflare Access, pending events sync to D1. Reading statistics aggregate across devices after they sync.
- Cloud originals remain in OpenList. Removing a local copy does not delete the cloud original.

## References

- Cloudflare Pages Functions: https://developers.cloudflare.com/pages/functions/get-started/
- Cloudflare Pages D1 bindings: https://developers.cloudflare.com/pages/functions/bindings/
- D1 Wrangler commands: https://developers.cloudflare.com/d1/wrangler-commands/
- OpenList API: https://openlistteam.github.io/docs/guide/api/fs.html
