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
  let difference = a.length ^ b.length;
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

export function getOpenListConfig(env) {
  const base = String(env.OPENLIST_BASE_URL || "").trim().replace(/\/+$/, "");
  const token = String(env.OPENLIST_TOKEN || "").trim();
  const rootPath = normalizePath(env.OPENLIST_ROOT_PATH || "/");
  if (!base || !token || !rootPath) return null;
  let url;
  try {
    url = new URL(base);
  } catch (_) {
    return null;
  }
  if (url.protocol !== "https:" && url.hostname !== "localhost" && url.hostname !== "127.0.0.1") return null;
  return { base: url.origin, token, rootPath };
}

export async function openListPost(env, endpoint, body) {
  const config = getOpenListConfig(env);
  if (!config) throw new Error("OpenList 尚未完成伺服器端設定。");
  const response = await fetch(config.base + endpoint, {
    method: "POST",
    headers: {
      "Authorization": config.token,
      "Content-Type": "application/json",
      "Accept": "application/json"
    },
    body: JSON.stringify(body)
  });
  if (!response.ok) throw new Error("OpenList API HTTP " + response.status);
  const result = await response.json();
  if (!result || Number(result.code) !== 200) {
    const code = result && result.code ? String(result.code) : "unknown";
    throw new Error("OpenList API 回報錯誤（" + code + "）。");
  }
  return result.data;
}

export async function sha256Hex(value) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(String(value))));
  return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
}
