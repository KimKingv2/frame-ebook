const COOKIE_NAME = "__Host-frame-reader";

export function json(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "same-origin",
      ...extraHeaders
    }
  });
}

export function getDatabase(env) {
  return env.FRAME_READER_DB || env.DB || null;
}

function base64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function fromBase64url(value) {
  const normalized = String(value).replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

async function hmac(payload, secret) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload)));
}

function safeEqual(left, right) {
  const a = new TextEncoder().encode(String(left || ""));
  const b = new TextEncoder().encode(String(right || ""));
  let difference = a.length === b.length ? 0 : 1;
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index++) {
    difference |= (a[index] || 0) ^ (b[index] || 0);
  }
  return difference === 0;
}

export async function verifyPassword(candidate, expected) {
  if (!expected || typeof candidate !== "string") return false;
  return safeEqual(candidate, expected);
}

export async function createSessionCookie(env, maxAgeSeconds = 60 * 60 * 24 * 30) {
  if (!env.FRAME_READER_SESSION_SECRET) throw new Error("FRAME_READER_SESSION_SECRET 尚未設定。");
  const now = Math.floor(Date.now() / 1000);
  const payload = base64url(new TextEncoder().encode(JSON.stringify({
    sub: "private-reader",
    iat: now,
    exp: now + maxAgeSeconds
  })));
  const signature = base64url(await hmac(payload, env.FRAME_READER_SESSION_SECRET));
  const token = payload + "." + signature;
  return COOKIE_NAME + "=" + token + "; Path=/; Max-Age=" + maxAgeSeconds + "; Secure; HttpOnly; SameSite=Lax";
}

export async function clearSessionCookie() {
  return COOKIE_NAME + "=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax";
}

function getCookie(request, name) {
  const raw = request.headers.get("Cookie") || "";
  for (const part of raw.split(";")) {
    const index = part.indexOf("=");
    if (index < 0) continue;
    if (part.slice(0, index).trim() === name) return part.slice(index + 1).trim();
  }
  return "";
}

export async function isAuthenticated(request, env) {
  const token = getCookie(request, COOKIE_NAME);
  const secret = env.FRAME_READER_SESSION_SECRET;
  if (!token || !secret) return false;
  const parts = token.split(".");
  if (parts.length !== 2) return false;
  try {
    const expected = base64url(await hmac(parts[0], secret));
    if (!safeEqual(parts[1], expected)) return false;
    const payload = JSON.parse(new TextDecoder().decode(fromBase64url(parts[0])));
    return payload && payload.sub === "private-reader" && Number(payload.exp) > Math.floor(Date.now() / 1000);
  } catch (_) {
    return false;
  }
}

export async function requireAuth(request, env) {
  if (!(await isAuthenticated(request, env))) return json({ error: "需要先登入 FRAME Reader 私人書庫。" }, 401);
  return null;
}

export function isSameOrigin(request) {
  const origin = request.headers.get("Origin");
  if (!origin) return false;
  try {
    return new URL(origin).origin === new URL(request.url).origin;
  } catch (_) {
    return false;
  }
}

export function normalizePath(value) {
  const raw = String(value || "/").replace(/\\/g, "/");
  if (raw.includes("\0")) return null;
  const parts = raw.split("/");
  if (parts.some(part => part === "..")) return null;
  const clean = parts.filter(part => part && part !== ".").join("/");
  return "/" + clean;
}

export function isWithinRoot(path, root) {
  if (!path || !root) return false;
  const normalizedRoot = normalizePath(root);
  if (!normalizedRoot) return false;
  if (normalizedRoot === "/") return path.startsWith("/");
  return path === normalizedRoot || path.startsWith(normalizedRoot + "/");
}

export function joinPath(parent, name) {
  const base = String(parent || "/").replace(/\/+$/, "");
  const child = String(name || "").replace(/^\/+/, "");
  return normalizePath((base || "") + "/" + child);
}

const OPENLIST_PROVIDERS = Object.freeze({
  vps: {
    label: "VPS Alist",
    baseUrl: env => env.ALIST_VPS_API_BASE_URL || env.OPENLIST_BASE_URL,
    username: env => env.ALIST_VPS_API_USERNAME,
    password: env => env.ALIST_VPS_API_PASSWORD
  },
  worker: {
    label: "OpenList Worker",
    baseUrl: env => env.ALIST_WORKER_API_BASE_URL || env.OPENLIST_WORKER_API_BASE_URL,
    username: env => env.ALIST_WORKER_API_USERNAME,
    password: env => env.ALIST_WORKER_API_PASSWORD
  },
  mobile: {
    label: "Mobile Device Alist",
    baseUrl: env => env.ALIST_MOBILE_DEVICE_API_BASE_URL,
    username: env => env.ALIST_MOBILE_DEVICE_API_USERNAME,
    password: env => env.ALIST_MOBILE_DEVICE_API_PASSWORD
  }
});

// Legacy root variables are only first-run path suggestions. They are not
// server-side authorization boundaries; Alist account permissions are.
export function getOpenListRootPath(env, library = "books") {
  const key = library === "comics" ? "comics" : "books";
  const specific = key === "comics" ? env.OPENLIST_COMICS_ROOT_PATH : env.OPENLIST_BOOKS_ROOT_PATH;
  const rootSetting = String(specific || "").trim();
  return rootSetting ? normalizePath(rootSetting) : null;
}

export function getOpenListRootPaths(env) {
  return {
    books: getOpenListRootPath(env, "books"),
    comics: getOpenListRootPath(env, "comics")
  };
}

function normalizeServerBaseUrl(value) {
  const raw = String(value || "").trim().replace(/\/+$/, "");
  if (!raw) return null;
  let url;
  try { url = new URL(raw); } catch (_) { return null; }
  if (url.username || url.password || url.search || url.hash) return null;
  if (url.protocol !== "https:" && url.hostname !== "localhost" && url.hostname !== "127.0.0.1") return null;
  return url.origin;
}

function getOpenListProviderCredentials(env, provider = "vps") {
  const key = Object.prototype.hasOwnProperty.call(OPENLIST_PROVIDERS, provider) ? provider : "vps";
  const profile = OPENLIST_PROVIDERS[key];
  const base = normalizeServerBaseUrl(profile.baseUrl(env));
  const username = String(profile.username(env) || "").trim();
  const password = String(profile.password(env) || "");
  if (!base || !username || !password) return null;
  return { provider: key, label: profile.label, base, username, password };
}

export function getOpenListConfig(env, provider = "vps", library = "books") {
  const credentials = getOpenListProviderCredentials(env, provider);
  if (!credentials) return null;
  return { ...credentials, library: library === "comics" ? "comics" : "books" };
}

export function getOpenListProfiles(env) {
  return Object.fromEntries(Object.entries(OPENLIST_PROVIDERS).map(([provider]) => [
    provider,
    { label: OPENLIST_PROVIDERS[provider].label, configured: !!getOpenListProviderCredentials(env, provider) }
  ]));
}

async function postOpenListJson(url, body, timeoutMs = 45000, headers = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method: "POST",
      redirect: "manual",
      headers: { "Content-Type": "application/json", "Accept": "application/json", ...headers },
      body: JSON.stringify(body),
      signal: controller.signal
    });
    if (response.status >= 300 && response.status < 400) {
      throw new Error("OpenList API 回傳 HTTP " + response.status + " 重新導向；請檢查 Pages API Base URL。");
    }
    let payload;
    try { payload = await response.json(); }
    catch (_) { throw new Error("OpenList API 回應不是有效 JSON（HTTP " + response.status + "）。"); }
    if (!response.ok) {
      const message = String(payload?.message || payload?.error || "");
      throw new Error("OpenList API HTTP " + response.status + (message ? "：" + message : "。"));
    }
    return payload;
  } catch (cause) {
    if (cause?.name === "AbortError") throw new Error("OpenList API 請求逾時（" + Math.round(timeoutMs / 1000) + " 秒）。");
    throw cause;
  } finally {
    clearTimeout(timeout);
  }
}

export async function openListPost(env, endpoint, body, provider = "vps", library = "books") {
  const config = getOpenListConfig(env, provider, library);
  if (!config) {
    const profile = OPENLIST_PROVIDERS[provider] || OPENLIST_PROVIDERS.vps;
    throw new Error(profile.label + " 尚未完成伺服器端設定。請檢查 API Base URL、帳號 Variable 與密碼 Secret。");
  }

  const loginUrl = new URL("api/auth/login", config.base + "/").href;
  const login = await postOpenListJson(loginUrl, {
    username: config.username,
    password: config.password
  }, 20000);
  const shortLivedToken = String(login?.data?.token || "");
  if (Number(login?.code) !== 200 || !shortLivedToken) {
    const code = login?.code ? "（" + String(login.code) + "）" : "";
    const message = String(login?.message || login?.error || "");
    throw new Error(config.label + " 帳號密碼登入失敗" + code + (message ? "：" + message : "。"));
  }

  // Tokens expire. Use this freshly issued token for this request only.
  // Never persist it in D1, Pages storage, or send it to the browser.
  const apiPath = String(endpoint || "").replace(/^\/+/, "");
  const apiUrl = new URL(apiPath, config.base + "/").href;
  const result = await postOpenListJson(apiUrl, body, 55000, { "Authorization": shortLivedToken });
  if (Number(result?.code) !== 200) {
    const code = result?.code ? String(result.code) : "unknown";
    const message = String(result?.message || result?.error || "");
    throw new Error(config.label + " API 回報錯誤（" + code + "）" + (message ? "：" + message : "。"));
  }
  return result.data;
}
export async function sha256Hex(value) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(String(value))));
  return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
}
