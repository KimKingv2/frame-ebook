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
    token: env => env.ALIST_VPS_API_TOKEN || env.OPENLIST_TOKEN
  },
  worker: {
    label: "OpenList Worker",
    baseUrl: env => env.ALIST_WORKER_API_BASE_URL || env.OPENLIST_WORKER_API_BASE_URL,
    token: env => env.ALIST_WORKER_API_TOKEN
  },
  mobile: {
    label: "Mobile Device Alist",
    baseUrl: env => env.ALIST_MOBILE_DEVICE_API_BASE_URL,
    token: env => env.ALIST_MOBILE_DEVICE_API_TOKEN
  }
});

export function getOpenListRootPath(env, library = "books") {
  const key = library === "comics" ? "comics" : "books";
  const specific = key === "comics" ? env.OPENLIST_COMICS_ROOT_PATH : env.OPENLIST_BOOKS_ROOT_PATH;
  const legacy = env.OPENLIST_ROOT_PATH;
  const rootSetting = String(specific || legacy || "").trim();
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
  const token = String(profile.token(env) || "").trim();
  if (!base || !token) return null;
  return { provider: key, label: profile.label, base, token };
}

export function getOpenListConfig(env, provider = "vps", library = "books") {
  const credentials = getOpenListProviderCredentials(env, provider);
  const rootPath = getOpenListRootPath(env, library);
  if (!credentials || !rootPath) return null;
  return { ...credentials, library: library === "comics" ? "comics" : "books", rootPath };
}

export function getOpenListProfiles(env) {
  return Object.fromEntries(Object.entries(OPENLIST_PROVIDERS).map(([provider, profile]) => [
    provider,
    {
      label: profile.label,
      configured: !!getOpenListProviderCredentials(env, provider)
    }
  ]));
}

export async function openListPost(env, endpoint, body, provider = "vps", library = "books") {
  const config = getOpenListConfig(env, provider, library);
  if (!config) throw new Error((OPENLIST_PROVIDERS[provider]?.label || "OpenList") + " 尚未完成伺服器端設定。請檢查該來源的 Pages URL、Token Secret，以及對應的 OPENLIST_BOOKS_ROOT_PATH／OPENLIST_COMICS_ROOT_PATH。");
  const response = await fetch(config.base + endpoint, {
    method: "POST",
    headers: {
      "Authorization": config.token,
      "Content-Type": "application/json",
      "Accept": "application/json"
    },
    body: JSON.stringify(body)
  });
  if (!response.ok) throw new Error(config.label + " API HTTP " + response.status);
  const result = await response.json();
  if (!result || Number(result.code) !== 200) {
    const code = result && result.code ? String(result.code) : "unknown";
    throw new Error(config.label + " API 回報錯誤（" + code + "）。");
  }
  return result.data;
}
export async function sha256Hex(value) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(String(value))));
  return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
}
