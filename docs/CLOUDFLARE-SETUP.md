# FRAME Reader V0.6 — Cloudflare setup

V0.6 is deployed with the local reading tracker and reading insights page. The authenticated cloud API is present in the repository, but it deliberately stays unavailable until the D1 database, binding and server-side variables below are configured.

## 1. Create the D1 database

Create a D1 database named `frame-reader-db` in Cloudflare Dashboard > Storage & Databases > D1, or use Wrangler:

```sh
npx wrangler login
npx wrangler d1 create frame-reader-db
```

Apply the schema from the repository root:

```sh
npx wrangler d1 execute frame-reader-db --remote --file=migrations/0001_reading_events.sql
```

This migration creates `reading_events` (deduplicated reading-time segments) and `auth_attempts` (login rate limiting). The migration is safe to apply to a newly created database. Do not run it against an unrelated existing database without reviewing the SQL first.

## 2. Bind D1 to the Pages project

In Cloudflare Dashboard:

1. Open Workers & Pages and select the `frame-ebook` Pages project.
2. Go to **Settings → Bindings → Add → D1 database bindings**.
3. Set the variable name to `FRAME_READER_DB`.
4. Select the `frame-reader-db` database.
5. Save and redeploy the Pages project so the binding is available to Functions.

The Functions code accepts either `FRAME_READER_DB` or `DB`, but use `FRAME_READER_DB` for this project.

## 3. Add server-side variables and secrets

Under the Pages project's **Settings → Variables and Secrets**, add these to the Production environment. Add them to Preview only when you also intend to test private access on preview deployments.

| Name | Type | Value |
|---|---|---|
| `ALIST_VPS_API_BASE_URL` | Variable | VPS Alist origin, e.g. `https://drive.example.com` |
| `ALIST_VPS_API_TOKEN` | Secret | Read-only VPS Alist API token |
| `ALIST_WORKER_API_BASE_URL` | Variable | OpenList Worker API origin |
| `ALIST_WORKER_API_TOKEN` | Secret | Read-only OpenList Worker API token |
| `ALIST_MOBILE_DEVICE_API_BASE_URL` | Variable | Mobile Device Alist API origin |
| `ALIST_MOBILE_DEVICE_API_TOKEN` | Secret | Read-only Mobile Device Alist API token |
| `OPENLIST_BOOKS_ROOT_PATH` | Variable | Maximum allowed absolute path for the EPUB book library |
| `OPENLIST_COMICS_ROOT_PATH` | Variable | Maximum allowed absolute path for the EPUB / CBZ comic library |
| `FRAME_READER_ACCESS_PASSWORD` | Secret | A new private FRAME Reader login password; this is not the OpenList password |
| `FRAME_READER_SESSION_SECRET` | Secret | A long, random signing secret used for the HttpOnly session cookie |

Both `OPENLIST_BOOKS_ROOT_PATH` and `OPENLIST_COMICS_ROOT_PATH` are mandatory and independent. The book root lists EPUB files only; the comics root lists both EPUB and CBZ files. Set each to the narrowest suitable directory, not `/`. The server rejects paths outside the matching root, and the browser cannot use the book root to access comics or vice versa. The root inputs on the cloud page may narrow each root further on the current device; those selections are saved in that browser only. All four connection sources must expose the same absolute paths. Remove the old `OPENLIST_ROOT_PATH` variable if you previously added it; the new setup does not use it.

Generate a session secret locally, for example:

```sh
openssl rand -hex 32
```

Paste the generated output only into Cloudflare's Secret field. Do not put any secret in Git, frontend JavaScript, chat messages or URL query strings.

### Four connection profiles

- **VPS Alist**, **OpenList Worker** and **Mobile Device Alist** are server-side profiles. Each uses its own Pages URL Variable and Token Secret. Copy the values into the frame-ebook Pages project; environment settings from frame-audio are not shared automatically between Pages projects.
- **LAN OpenList** is configured inside the cloud page on each device. Its URL and read-only Token are saved in that browser's local storage and sent directly to the configured LAN host. Add the exact FRAME Reader production origin https://frame-ebook.pages.dev to that OpenList instance's CORS allowlist, including Authorization and Content-Type. Add the Preview origin only when testing Preview.
- All four sources must expose the same absolute directory paths for OPENLIST_BOOKS_ROOT_PATH and OPENLIST_COMICS_ROOT_PATH. The comics root may contain both EPUB and CBZ files; the books root is EPUB-only. The cloud page does not connect automatically; click 測試目前來源並讀取書庫 to initiate the selected source.
- For LAN direct downloads, the final host returned as raw_url must also permit browser CORS. Plain HTTP does not encrypt traffic by itself; use a trusted LAN, an encrypted VPN such as Tailscale, or HTTPS.

## 4. Verify the configuration

After saving the binding and variables, trigger a new deployment. Then check:

- `https://frame-ebook.pages.dev/api/auth/session` should report `databaseConfigured: true`, `openListConfigured: true`, and (after login) separate `rootPaths.books` / `rootPaths.comics` values. Before login, `authenticated` is `false` and root paths are hidden.
- Open `https://frame-ebook.pages.dev/cloud/`, sign in with `FRAME_READER_ACCESS_PASSWORD`, choose a source and either 電子書 or 漫畫, then browse the matching configured root.
- Open `https://frame-ebook.pages.dev/reading-stats/`, sign in to enable D1 statistics sync. Locally stored reading events are uploaded with unique event IDs; duplicate retries are ignored by D1.
- Read a book for at least one minute, then revisit the stats page and check the daily total. A reading day is counted at 60 seconds.

## 5. What V0.6 does and does not do

- Four interchangeable read-only sources are supported: VPS Alist, OpenList Worker, Mobile Device Alist and device-local LAN OpenList. The first three are configured as Pages Variables / Secrets and called server-side; the fourth stores its URL and Token only in the current browser's local storage.
- The Pages Functions hold server-side tokens and proxy the API calls. Server tokens and the OpenList `raw_url` are not returned to the browser. A local-direct request sends only that device's own token directly to its configured LAN OpenList.
- The file proxy forwards valid HTTP Range headers, but the current cloud shelf still downloads a selected EPUB / CBZ fully into IndexedDB before opening it. Direct Range-backed streaming into Foliate is a later optimization.
- The bookshelf file itself remains in OpenList. Adding it to the local shelf copies it into this browser's IndexedDB; removing the local copy does not delete the cloud original.
- Reading duration is tracked locally first. Once authenticated, pending events are sent to D1. Reading statistics aggregate across devices that use the same private account after they sync.
- Daily reading goal settings are currently per browser, and JSON / CSV export currently contains the local browser's raw event details.
- The current private login is intended for a single personal library owner, not a multi-user public service. The password is verified at the edge, the session cookie is HttpOnly / Secure, and login attempts are rate-limited in D1.
- The cloud page does not contact OpenList automatically on page load. Select a provider and the **電子書** or **漫畫** library, then press the explicit connection test button before any directory request. Each library has its own root input; a folder chosen from the browser can become that device's preferred sub-root, but the server-side maximum root remains authoritative. For LAN direct, configure a least-privilege Token and the exact site origin in OpenList CORS. Plain HTTP is not encrypted by itself; use trusted LAN or an encrypted VPN, or HTTPS.

## References

- Cloudflare Pages Functions must live in a `/functions` directory at the root of the Pages project, not inside the static output directory: https://developers.cloudflare.com/pages/functions/get-started/
- Cloudflare Pages D1 binding setup and redeployment: https://developers.cloudflare.com/pages/functions/bindings/
- D1 create / execute commands: https://developers.cloudflare.com/d1/wrangler-commands/
- OpenList FS list / get APIs and the Authorization header: https://openlistteam.github.io/docs/guide/api/fs.html

