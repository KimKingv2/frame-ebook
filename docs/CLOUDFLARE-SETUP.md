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
| `ALIST_VPS_API_USERNAME` | Variable | Read-only VPS Alist account name |
| `ALIST_VPS_API_PASSWORD` | Secret | Password for the VPS Alist account |
| `ALIST_WORKER_API_BASE_URL` | Variable | OpenList Worker HTTPS API base URL |
| `ALIST_WORKER_API_USERNAME` | Variable | Read-only Worker account name |
| `ALIST_WORKER_API_PASSWORD` | Secret | Password for the Worker account |
| `ALIST_MOBILE_DEVICE_API_BASE_URL` | Variable | Mobile Device Alist API base URL |
| `ALIST_MOBILE_DEVICE_API_USERNAME` | Variable | Read-only Mobile Device account name |
| `ALIST_MOBILE_DEVICE_API_PASSWORD` | Secret | Password for the Mobile Device account |
| `FRAME_READER_ACCESS_PASSWORD` | Secret | Separate password used to enter the private FRAME Reader |
| `FRAME_READER_SESSION_SECRET` | Secret | Random signing secret for the HttpOnly session cookie |

The three server-side profiles are independent. Configure only the sources you intend to use. Use an Alist account with read-only access and grant it access only to the intended book and comic directories.

### How Alist authentication works

Pages Functions read each source's API URL, username and password from Cloudflare. Before each `/api/fs/list` or `/api/fs/get` operation, the server calls `POST /api/auth/login`, obtains the short-lived Alist Token, and immediately uses it for that operation. The Token is request-scoped: it is not stored in D1, browser storage, source settings or Git, and is never returned to the browser. This avoids manually replacing an expiring Token.

The FRAME Reader private password is a separate login gate. It is not an Alist account password. The existing `FRAME_READER_SESSION_SECRET` signs a Secure, HttpOnly session cookie. Login attempts are rate-limited in D1.

## 3. Configure the LAN-direct source (optional)

The fourth source is the OpenList instance reachable directly from the current device, such as a Mac or phone on the home network. On the cloud page, enter its URL, account name and password. The URL and username are saved in that browser's local storage. The password is kept only in the current tab's `sessionStorage`, so a page reload in that tab can reconnect, but closing the tab clears it. The credentials are sent directly to the LAN OpenList login and file-list endpoints; they do not pass through Pages, D1 or Worker APIs.

Use a separate read-only account. Plain HTTP does not encrypt the username/password or Authorization header over Wi-Fi. Use HTTPS when available, or a trusted private LAN / encrypted VPN such as Tailscale. Allow the exact FRAME Reader origin in the LAN OpenList CORS settings. The browser needs `Content-Type` and `Authorization` request headers permitted for the login and file API calls. The final file host returned in `raw_url` must also permit browser CORS.

Legacy local Token settings are not reused. On first open after this update, the old saved local Token is discarded; enter the LAN account and password once and save the source again.

## 4. Set the two library paths like FRAME Audio

The cloud page has two independent path fields:

- **Books root:** EPUB electronic books.
- **Comics root:** EPUB and CBZ comics.

You can type an absolute path directly, or browse folders and use the current folder as the Books or Comics root. Save the two paths. Each path is stored separately in the current browser and reused when switching between VPS Alist, OpenList Worker, Mobile Device Alist and LAN-direct OpenList.

All sources should expose the same absolute folder layout so the two HTML input paths work after switching sources. The default paths are the `value` attributes of `cloud-books-root` and `cloud-comics-root` in `pages/cloud/index.html`. Changes made in the browser apply only to the current page session; refreshing restores the HTML defaults. The previous `OPENLIST_BOOKS_ROOT_PATH` and `OPENLIST_COMICS_ROOT_PATH` variables are not used for path defaults or access control. The actual permission boundary is the Alist account: restrict each account to the intended read-only directories.

After the Reader private login succeeds, the cloud page automatically opens the previously selected source and the last saved path for the selected library. Use **重新連線／讀取書架** to retry manually. Changing the source or switching between Books and Comics also reloads the corresponding saved path.

## 5. Verify the configuration

1. Confirm the D1 binding and the two FRAME Reader login Secrets exist.
2. Confirm at least one server-side source has its API URL, username and password configured.
3. Open `https://frame-ebook.pages.dev/cloud/` and sign in with `FRAME_READER_ACCESS_PASSWORD`.
4. The previously selected, configured source should connect automatically. If no source has been selected yet, choose one and save it; for LAN-direct, enter its URL, username and password first.
5. Browse to the book directory and save it as the Books root. Switch to Comics, browse to its directory and save it as the Comics root.
6. Add a file to the local shelf. The original cloud file is not changed or deleted.

## 6. Existing data and current behavior

- No D1 migration is required for the account/password change or for per-device path settings. Existing reading events and authentication-attempt records remain intact.
- Existing local books, covers, reading progress and appearance settings remain in IndexedDB.
- Books root supports EPUB. Comics root supports EPUB and CBZ. MOBI is not supported directly; convert it to EPUB before importing.
- Server-side account passwords remain in Cloudflare Variables / Secrets. The browser receives only source labels and configured-status flags. Only the optional LAN-direct URL, username and current-tab password are stored on the device.
- Cloud browsing and file-info requests are read-only. The file proxy forwards valid HTTP Range headers, but the current cloud shelf downloads a selected EPUB / CBZ fully into IndexedDB before opening it. Range-backed reading is a later optimization.
- Reading duration is tracked locally first. Once authenticated, pending events sync to D1. Reading statistics aggregate across devices using the same FRAME Reader private login after they sync.
- Cloud originals remain in OpenList. Removing a local copy does not delete the cloud original.

## References

- Cloudflare Pages Functions: https://developers.cloudflare.com/pages/functions/get-started/
- Cloudflare Pages D1 bindings: https://developers.cloudflare.com/pages/functions/bindings/
- D1 Wrangler commands: https://developers.cloudflare.com/d1/wrangler-commands/
- OpenList API: https://openlistteam.github.io/docs/guide/api/fs.html
