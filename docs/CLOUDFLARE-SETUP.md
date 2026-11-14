# FRAME Reader V0.7 — Cloudflare setup

FRAME Reader keeps local books, reading positions, appearance preferences and reading statistics. The cloud shelf reads original EPUB / CBZ files from OpenList; adding a cloud file copies it into the current browser's IndexedDB.

## 1. Create and bind the D1 database

Create a D1 database named `frame-reader-db` in Cloudflare Dashboard → Storage & Databases → D1, or use Wrangler:

```sh
npx wrangler login
npx wrangler d1 create frame-reader-db
```

Apply the schema from the repository root if it has not already been applied:

```sh
npx wrangler d1 execute frame-reader-db --remote --file=migrations/0001_reading_events.sql
```

In Workers & Pages → `frame-ebook` → Settings → Bindings, add a D1 database binding named `FRAME_READER_DB` and select `frame-reader-db`. Save and redeploy so the binding is available to Pages Functions. Do not recreate or reset an existing database.

## 2. Configure server-side OpenList accounts

Under the Pages project's Settings → Variables and Secrets, add the following to Production. Add the same values to Preview only when you also intend to test private Preview deployments.

| Name | Type | Purpose |
|---|---|---|
| `ALIST_VPS_API_BASE_URL` | Variable | VPS Alist HTTPS API base URL |
| `ALIST_VPS_USERNAME` | Variable | Read-only VPS Alist account name |
| `ALIST_VPS_PASSWORD` | Secret | Password for the VPS Alist account |
| `ALIST_WORKER_API_BASE_URL` | Variable | OpenList Worker HTTPS API base URL |
| `ALIST_WORKER_USERNAME` | Variable | Read-only Worker account name |
| `ALIST_WORKER_PASSWORD` | Secret | Password for the Worker account |
| `ALIST_MOBILE_DEVICE_API_BASE_URL` | Variable | Mobile Device Alist API base URL |
| `ALIST_MOBILE_DEVICE_USERNAME` | Variable | Read-only Mobile Device account name |
| `ALIST_MOBILE_DEVICE_PASSWORD` | Secret | Password for the Mobile Device account |

The three server-side profiles are independent. Configure only the sources you intend to use. The account and password names above intentionally omit `API_`; the server also accepts the older `*_API_USERNAME` / `*_API_PASSWORD` variants for compatibility. Use an Alist account with read-only access and grant it access only to the intended book and comic directories.

### How Alist authentication works

Pages Functions read each source's API URL, username and password from Cloudflare. Before each `/api/fs/list` or `/api/fs/get` operation, the server calls `POST /api/auth/login`, obtains the short-lived Alist Token, and immediately uses it for that operation. The Token is request-scoped: it is not stored in D1, browser storage, source settings or Git, and is never returned to the browser. This avoids manually replacing an expiring Token.

FRAME Reader uses Cloudflare Zero Trust Access as its website login, and Pages Functions independently verify the signed `Cf-Access-Jwt-Assertion` JWT on every protected API request. This second check validates the RS256 signature against Cloudflare's live JWKS endpoint, as well as the issuer, audience and token time claims. Do not rely on the presence of the header alone.

Add these two non-secret Variables to Production, and to Preview when Preview deployments are protected:

| Name | Type | Purpose |
|---|---|---|
| `FRAME_READER_ACCESS_TEAM_DOMAIN` | Variable | Your Cloudflare Zero Trust team domain, for example `https://your-team.cloudflareaccess.com` |
| `FRAME_READER_ACCESS_AUD` | Variable | Application Audience (AUD) tag for each Access application protecting this Reader |

Find the Team Domain in Zero Trust settings. Find each AUD in Zero Trust → Access controls → Applications → select the application → Additional settings → Application Audience (AUD) Tag. The `FRAME_READER_ACCESS_AUD` value accepts one or more AUD tags separated by commas, with no quotes required. This supports separate Access applications for Production, Preview and custom hostnames. Use the same Team Domain for all applications in the same Zero Trust account.

These are ordinary Variables, not Secrets. Do not add email addresses here. Adding or removing allowed email addresses in an existing Access policy does not change the Team Domain or AUD. An application's AUD changes only if that Access application is deleted and recreated; when that happens, replace the old AUD with the new one.

Pages Functions fetch and cache the public signing keys automatically from `https://<team-name>.cloudflareaccess.com/cdn-cgi/access/certs`. If a JWT contains a previously unseen key ID, the verifier refreshes the JWKS. Cloudflare's signing-key rotation therefore does not require manual Variable updates or scheduled maintenance.

D1 remains necessary for reading history and statistics, but not for authentication. The old `auth_attempts` table may remain in D1 and is no longer used.

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

After Cloudflare Access authentication succeeds, the cloud page automatically opens the previously selected source and the HTML-default path for the selected library. Use **重新連線／讀取書架** to retry manually. Changing the source or switching between Books and Comics also reloads the corresponding saved path.

## 6. Verify the configuration

1. Confirm the D1 binding exists for reading-history synchronization and statistics.
2. Protect the complete production hostname `frame-ebook.pages.dev` with Cloudflare Access. Important: for Pages, the initial `Enable access policy` toggle protects Preview deployments only, not the root `*.pages.dev` production hostname. To protect Production as well:
   - In Workers & Pages → `frame-ebook` → Settings → General, enable Access policy.
   - In Zero Trust → Access → Applications, open the application created for this Pages project and select Configure.
   - Under Public hostname, remove the wildcard `*` from the Subdomain field and save. This secures `frame-ebook.pages.dev`.
   - Return to the Pages project settings and enable the Preview access policy again if you also want Preview deployments protected. Confirm the two policies cover Production `frame-ebook.pages.dev` and Preview `*.frame-ebook.pages.dev`.
   - If a custom domain is used, add that hostname to its own Access application/policy too.
   This is configured in Cloudflare Access, not under Pages Variables or Secrets. Access must cover the whole hostname, including `/api/*`. Confirm at least one server-side source has its API URL, username and password configured.
3. Open the protected FRAME Reader site. Cloudflare Access should handle authentication before the page loads; there is no separate Reader password in Access mode.
4. The previously selected, configured source should connect automatically. If no source has been selected yet, choose one and save it; for LAN-direct, enter its URL, username and password first.
5. Browse to the book directory and save it as the Books root. Switch to Comics, browse to its directory and save it as the Comics root.
6. Add a file to the local shelf. The original cloud file is not changed or deleted.

## 7. Existing data and current behavior

- No D1 migration is required for Cloudflare Access authentication or HTML-default paths. Existing reading events remain intact. The old authentication-attempt table may remain unused. The two Access verification Variables must be configured as described above.
- Existing local books, covers, reading progress and appearance settings remain in IndexedDB.
- Books root supports EPUB. Comics root supports EPUB and CBZ. MOBI is not supported directly; convert it to EPUB before importing.
- Server-side account passwords remain in Cloudflare Variables / Secrets. The browser receives only source labels and configured-status flags. Only the optional LAN-direct URL, username and current-tab password are stored on the device.
- Cloud browsing and file-info requests are read-only. The file proxy forwards valid HTTP Range headers, but the current cloud shelf downloads a selected EPUB / CBZ fully into IndexedDB before opening it. Range-backed reading is a later optimization.
- Reading duration is tracked locally first. Once authenticated through Cloudflare Access, pending events sync to D1. Reading statistics aggregate across devices after they sync.
- Cloud originals remain in OpenList. Removing a local copy does not delete the cloud original.

## References

- Cloudflare Pages Functions: https://developers.cloudflare.com/pages/functions/get-started/
- Cloudflare Pages D1 bindings: https://developers.cloudflare.com/pages/functions/bindings/
- D1 Wrangler commands: https://developers.cloudflare.com/d1/wrangler-commands/
- OpenList API: https://openlistteam.github.io/docs/guide/api/fs.html
