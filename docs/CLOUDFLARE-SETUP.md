# FRAME Reader V0.9 — Cloudflare setup

FRAME Reader is cloud-only. Books enter the shelf only after an Alist／OpenList scan has written their metadata into D1. Original EPUB／CBZ files remain in Alist／OpenList; they are read through the protected Pages Functions proxy only when opened. D1 stores each Access user's reading position, appearance preferences, book metadata, reading events and source/root preferences. D1 also stores cloud-book bookmarks, notes and highlights. Private cover thumbnails are stored in R2. The browser does not keep a persistent bookshelf, imported book files, reading progress, reading history or appearance settings.

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
npx wrangler d1 execute frame-reader-db --remote --file=migrations/0004_cloud_annotations.sql
npx wrangler d1 execute frame-reader-db --remote --file=migrations/0005_cloud_only_reader_data.sql
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

FRAME Reader uses Cloudflare Zero Trust Access as its website sign-in layer. Access must protect the complete hostname, including static pages and every `/api/*` route. In addition, user-owned reading data is partitioned by the verified Access identity. Configure the team-domain and application-AUD variables in Section 3. There is no second Reader password or custom session cookie.

This design relies on the Access edge policy. If the production hostname or any API route is left outside the Access application, the corresponding Reader content/API is not protected by an application-level JWT check. Confirm the hostname-wide Access application before deploying or changing its scope.

D1 stores reading events/statistics, the metadata-only cloud catalog, resumable scan state and cover hashes/status. The private R2 bucket stores normalized cover thumbnails only; original EPUB / CBZ files remain in OpenList. Cover extraction uses bounded HTTP Range reads from ZIP archives and does not intentionally download the full book. The app converts extracted covers to small WebP (JPEG fallback) thumbnails and deduplicates them by SHA-256. It never stores OpenList credentials in D1 or R2. The old `auth_attempts` table may remain in D1 and is no longer used.


## 3. Configure Cloudflare Access identity for cloud reading data

Cloud-book annotations, reading progress, appearance preferences, reading events, and source preferences are partitioned by the verified Cloudflare Access subject. Add these two **Variables** under Workers & Pages → `frame-ebook` → Settings → Variables and Secrets → Production:

| Name | Type | Value |
|---|---|---|
| `FRAME_READER_ACCESS_TEAM_DOMAIN` | Variable | Your Cloudflare Zero Trust team domain, for example `https://your-team.cloudflareaccess.com` |
| `FRAME_READER_ACCESS_AUD` | Variable | The Application Audience (AUD) tag of the Access application protecting the complete production hostname `frame-ebook.pages.dev` |

Find the team domain in the Cloudflare Zero Trust dashboard. Find the AUD tag in Zero Trust → Access → Applications → the Reader production application → Additional settings → Application Audience (AUD) Tag. Enter the full HTTPS team domain without a trailing slash. These values are not passwords or secrets, but the AUD must match the exact Access application protecting this hostname. They are required for every user-scoped reading-data API, not only annotations.

Add the same variables to Preview if you test the cloud-only reader on Preview. Use the Preview Access application's AUD if it has a separate application. A missing or mismatched value makes user-scoped reading APIs fail closed; the app never falls back to browser storage.

The reading-data APIs verify the `Cf-Access-Jwt-Assertion` signature against the team's published Access signing keys, check the issuer, expiry and AUD, then store only a SHA-256-derived owner ID in D1. Raw email addresses and Access tokens are not stored. The existing Access edge policy must still protect the full hostname and all `/api/*` routes.

## 4. Set the two library paths

The cloud page has two independent path fields:

- **Books root:** EPUB electronic books.
- **Comics root:** EPUB and CBZ comics.

You can type an absolute path directly, or browse folders and use the current folder as the Books or Comics root. The HTML input `value` attributes provide first-use defaults. Each server-side provider has independent Books and Comics roots. Saved paths are stored in the current Access user's D1 preferences and are restored after refresh or on another device.

The first-use default paths are seeded from `pages/cloud/index.html`. Once saved, the active provider, Books/Comics selection and each provider's root paths are stored in D1 under the Access user identity. The actual permission boundary is the Alist account: restrict each account to the intended read-only directories.

After Cloudflare Access authentication succeeds, the cloud page automatically reads the D1 index for the previously selected source, library and HTML-default root path. The first use of each source/library/root combination requires **手動掃描／續掃**. The recursive scan stores its folder queue and page cursor in D1 after each directory page, so a paused or interrupted scan can resume later. Once complete, normal page loads and folder navigation query D1 only; they do not list directories from OpenList. Run another manual scan after adding, removing or reorganizing cloud files. The next completed scan removes stale catalog entries only after the whole root has been traversed successfully. Each VPS, Worker and Mobile Device source, and each Books/Comics root, has an independent catalog and scan state.

## 5. Verify the configuration

1. Confirm the D1 binding `FRAME_READER_DB` and private R2 binding `FRAME_READER_COVERS` exist. Apply `migrations/0001_reading_events.sql`, `migrations/0002_cloud_catalog.sql`, `migrations/0003_cloud_covers.sql`, `migrations/0004_cloud_annotations.sql` and `migrations/0005_cloud_only_reader_data.sql` to the `frame-reader-db` database.
2. Protect the complete production hostname `frame-ebook.pages.dev` with Cloudflare Access. Important: for Pages, the initial `Enable access policy` toggle protects Preview deployments only, not the root `*.pages.dev` production hostname. To protect Production as well:
   - In Workers & Pages → `frame-ebook` → Settings → General, enable Access policy.
   - In Zero Trust → Access → Applications, open the application created for this Pages project and select Configure.
   - Under Public hostname, make sure the application covers `frame-ebook.pages.dev` as a whole host, not only `/cloud/*` or another individual page. Remove the wildcard `*` from the Subdomain field if it is being used as the Pages wildcard, then save the production hostname.
   - Confirm the Access application/policy covers the entire hostname and therefore `/`, `/cloud/*`, `/reading-stats/*`, and `/api/*`. Do not add path exclusions for the API routes.
   - Return to the Pages project settings and enable the Preview access policy again if you also want Preview deployments protected. Preview uses a separate hostname/policy and must not be confused with Production.
   - If a custom domain is used, create a separate Access application for that hostname and protect the complete hostname too.
   **Security boundary:** Cloudflare Access must protect the complete hostname. All user-owned reading-data endpoints verify the Access JWT signature, issuer, expiry and application AUD using `FRAME_READER_ACCESS_TEAM_DOMAIN` and `FRAME_READER_ACCESS_AUD`. Cloud catalog scan/file endpoints rely on Access at the edge. If Access does not protect the full hostname, the API routes can be reached without Reader-level authentication.
3. Open the protected FRAME Reader site. Cloudflare Access should handle authentication before the page loads; there is no separate Reader password in Access mode.
4. The previously selected source and its D1 catalog load automatically. If no source has been selected yet, choose one and save it. Only server-side Alist／OpenList sources are supported: VPS Alist, OpenList Worker or Mobile Device Alist.
5. Set the Books and Comics root paths. For each source and each library, click **手動掃描／續掃** once and allow the recursive scan to finish. If interrupted, click it again to resume from the saved D1 cursor.
6. After the first completed scan, folder navigation reads D1. Re-run the scan when you want to synchronize new, modified or deleted OpenList files.
7. Open any scanned cloud book from the main bookshelf. Its original EPUB / CBZ is fetched from Alist／OpenList for the active reading session and remains in memory only. The cloud original is never changed or deleted.

## 6. Shared provider Token cache (2026-11-14)

The server-side VPS Alist, OpenList Worker and Mobile Device Alist providers now use the same short-lived JWT cache contract as FRAME Audio. Bind the existing shared KV namespace as `MEDIA_AUTH_TOKEN_CACHE` in this Pages environment before relying on cross-project reuse. Use `frame-series-auth-cache-production` for Production and the separate `media-platform-auth-cache` namespace for Preview. Never share a KV namespace across Preview and Production. After changing the binding, trigger a new deployment so the Pages Functions receive it. Without the binding, Reader falls back to isolate memory and may authenticate again after a cold start.

## 7. Existing data and current behavior

- Cloud catalog indexing requires `migrations/0002_cloud_catalog.sql`. Migration `0005_cloud_only_reader_data.sql` adds user-scoped preferences, book state and reading-event tables. The two Access identity Variables must be configured as described above.
- There is no local-file import path or browser-to-LAN OpenList path. A book can enter the shelf only through a completed D1 scan of a configured server-side Alist／OpenList source.
- `reader_preferences` and `reader_book_state` store per-user preferences and per-book progress/appearance/metadata in D1. `reader_reading_events` stores per-user reading history. The Reader frontend uses only in-memory objects for the active page; persistent user data is written to D1 and cover thumbnails to private R2.
- The old unscoped `reading_events` table is left untouched by migration 0005. New statistics use the user-scoped `reader_reading_events` table. Old events cannot safely be assigned to an Access identity automatically, so they are not included in new statistics.
- Legacy IndexedDB/localStorage data from older releases is not read by the cloud-only app and is not automatically deleted. This release does not transfer old browser-only progress or unscoped reading history into an Access identity. Leave those legacy records untouched until any needed information has been exported or deliberately discarded.
- Reader uses only the three server-side provider IDs: `vps`, `worker` and `mobile`. The cloud file proxy fetches the original archive on demand; the book blob exists in memory only for the active reading session.
