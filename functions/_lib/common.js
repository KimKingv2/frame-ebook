import { getProviderToken, invalidateProviderToken } from "./provider-auth.js";

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

// Cloudflare Zero Trust Access is the only website authentication boundary.
// The Access application must protect the complete hostname, including every
// /api/* route, before requests can reach Pages Functions. Do not duplicate
// Access JWT verification here: Pages Functions may not consistently expose
// Cf-Access-Jwt-Assertion even after the Access edge has authenticated a user.
//
// This guard intentionally trusts the Cloudflare Access edge. If the hostname
// is not protected at the edge, the API routes below are NOT private.
export async function requireAuth() {
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
    username: env => env.ALIST_VPS_USERNAME || env.ALIST_VPS_API_USERNAME,
    password: env => env.ALIST_VPS_PASSWORD || env.ALIST_VPS_API_PASSWORD
  },
  worker: {
    label: "OpenList Worker",
    baseUrl: env => env.OPENLIST_WORKER_API_BASE_URL || env.ALIST_WORKER_API_BASE_URL,
    username: env => env.OPENLIST_WORKER_USERNAME || env.ALIST_WORKER_USERNAME || env.ALIST_WORKER_API_USERNAME,
    password: env => env.OPENLIST_WORKER_PASSWORD || env.ALIST_WORKER_PASSWORD || env.ALIST_WORKER_API_PASSWORD
  },
  mobile: {
    label: "Mobile Device Alist",
    baseUrl: env => env.ALIST_MOBILE_DEVICE_API_BASE_URL,
    username: env => env.ALIST_MOBILE_DEVICE_USERNAME || env.ALIST_MOBILE_DEVICE_API_USERNAME,
    password: env => env.ALIST_MOBILE_DEVICE_PASSWORD || env.ALIST_MOBILE_DEVICE_API_PASSWORD
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
  return url.origin + url.pathname.replace(/\/+$/, "");
}

function getOpenListProviderCredentials(env, provider = "vps") {
  const key = Object.prototype.hasOwnProperty.call(OPENLIST_PROVIDERS, provider) ? provider : "vps";
  const profile = OPENLIST_PROVIDERS[key];
  const base = normalizeServerBaseUrl(profile.baseUrl(env));
  const username = String(profile.username(env) || "").trim();
  const password = String(profile.password(env) || "");
  if (!base || !username || !password) return null;
  return {
    provider: key,
    authProvider: key === "mobile" ? "mobile-device" : key,
    label: profile.label,
    base,
    username,
    password
  };
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
    try {
      payload = await response.json();
    } catch (_) {
      if (response.status === 401) {
        return { payload: null, status: response.status, ok: false };
      }
      throw new Error("OpenList API 回應不是有效 JSON（HTTP " + response.status + "）。");
    }
    return { payload, status: response.status, ok: response.ok };
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

  const authProvider = config.authProvider;
  let auth;
  try {
    auth = await getProviderToken(env, authProvider, config.base, config);
  } catch (cause) {
    throw new Error(config.label + " 自動登入或 Token 快取失敗：" + String(cause?.message || "請檢查服務帳號設定。").slice(0, 180));
  }

  const apiPath = String(endpoint || "").replace(/^\/+/, "");
  const apiUrl = new URL(apiPath, config.base + "/").href;
  const requestHeaders = {
    "Authorization": auth.token,
    "Client-Id": "media-platform-server-" + authProvider
  };

  let result = await postOpenListJson(apiUrl, body, 55000, requestHeaders);
  const authRejected = result.status === 401 || Number(result.payload?.code) === 401;
  if (auth.managed && authRejected) {
    await invalidateProviderToken(env, authProvider, config.base, config);
    try {
      auth = await getProviderToken(env, authProvider, config.base, config, { forceRefresh: true });
      result = await postOpenListJson(apiUrl, body, 55000, {
        "Authorization": auth.token,
        "Client-Id": "media-platform-server-" + authProvider
      });
    } catch (cause) {
      throw new Error(config.label + " Token 已失效，重新登入失敗：" + String(cause?.message || "請檢查服務帳號。").slice(0, 180));
    }
  }

  if (!result.ok) {
    const message = String(result.payload?.message || result.payload?.error || "");
    throw new Error(config.label + " API HTTP " + result.status + (message ? "：" + message : "。"));
  }
  const payload = result.payload;
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error(config.label + " API 回應格式不正確。");
  }
  if (Number(payload.code) !== 200) {
    const code = payload.code ? String(payload.code) : "unknown";
    const message = String(payload.message || payload.error || "");
    throw new Error(config.label + " API 回報錯誤（" + code + "）" + (message ? "：" + message : "。"));
  }
  return payload.data;
}
export async function sha256Hex(value) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(String(value))));
  return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
}
