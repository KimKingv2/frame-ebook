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

// Cloudflare Access authenticates users at the edge. Pages Functions also
// verify the signed assertion so an unprotected hostname or a forged header
// cannot be treated as an authenticated request.
const ACCESS_JWKS_CACHE_TTL_MS = 60 * 60 * 1000;
const ACCESS_JWKS_STALE_MAX_MS = 24 * 60 * 60 * 1000;
const accessJwksCache = new Map();

function getAccessVerifierConfig(env) {
  const rawDomain = String(env.FRAME_READER_ACCESS_TEAM_DOMAIN || "").trim();
  const audiences = String(env.FRAME_READER_ACCESS_AUD || "")
    .split(",")
    .map(value => value.trim())
    .filter(Boolean);
  if (!rawDomain || !audiences.length) return null;

  let domain;
  try {
    const candidate = /^https:\/\//i.test(rawDomain) ? rawDomain : "https://" + rawDomain;
    const parsed = new URL(candidate);
    if (
      parsed.protocol !== "https:" ||
      parsed.username ||
      parsed.password ||
      parsed.port ||
      parsed.pathname !== "/" ||
      parsed.search ||
      parsed.hash
    ) return null;
    domain = parsed.origin;
  } catch (_) {
    return null;
  }

  return { teamDomain: domain, audiences };
}

export function isAccessVerifierConfigured(env) {
  return !!getAccessVerifierConfig(env);
}

function decodeBase64UrlBytes(value) {
  const normalized = String(value).replace(/-/g, "+").replace(/_/g, "/");
  if (normalized.length % 4 === 1) throw new Error("Invalid base64url value");
  const binary = atob(normalized + "=".repeat((4 - normalized.length % 4) % 4));
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

function decodeBase64UrlJson(value) {
  return JSON.parse(new TextDecoder().decode(decodeBase64UrlBytes(value)));
}

async function getAccessJwks(teamDomain, forceRefresh = false) {
  const now = Date.now();
  const previous = accessJwksCache.get(teamDomain);

  if (previous?.pending) return previous.pending;
  if (!forceRefresh && previous?.keys && now - previous.fetchedAt < ACCESS_JWKS_CACHE_TTL_MS) {
    return previous.keys;
  }

  const entry = {
    keys: previous?.keys || null,
    fetchedAt: previous?.fetchedAt || 0,
    pending: null
  };

  const pending = (async () => {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 6000);
    try {
      const response = await fetch(teamDomain + "/cdn-cgi/access/certs", {
        method: "GET",
        headers: { "Accept": "application/json" },
        redirect: "error",
        signal: controller.signal
      });
      if (!response.ok) {
        const error = new Error("Cloudflare Access JWKS HTTP " + response.status);
        error.code = "jwks_http_error";
        error.httpStatus = response.status;
        error.contentType = response.headers.get("content-type") || "";
        throw error;
      }
      let payload;
      try {
        payload = await response.json();
      } catch (cause) {
        const error = new Error("Cloudflare Access JWKS response was not valid JSON");
        error.code = "jwks_invalid_json";
        error.contentType = response.headers.get("content-type") || "";
        error.cause = cause;
        throw error;
      }
      if (!Array.isArray(payload?.keys) || !payload.keys.some(key => key?.kid && key?.kty === "RSA")) {
        const error = new Error("Cloudflare Access JWKS has no usable RSA signing keys");
        error.code = "jwks_invalid_payload";
        error.contentType = response.headers.get("content-type") || "";
        throw error;
      }

      const keys = payload.keys.filter(key =>
        key &&
        key.kty === "RSA" &&
        typeof key.kid === "string" &&
        typeof key.n === "string" &&
        typeof key.e === "string" &&
        (!key.alg || key.alg === "RS256") &&
        (!key.use || key.use === "sig")
      );
      if (!keys.length) throw new Error("Cloudflare Access JWKS has no usable RS256 keys");

      accessJwksCache.set(teamDomain, { keys, fetchedAt: Date.now(), pending: null });
      return keys;
    } catch (error) {
      // A short-lived JWKS outage need not interrupt requests signed by a key
      // that was fetched recently. Unknown key IDs still trigger a fresh fetch.
      if (entry.keys && Date.now() - entry.fetchedAt <= ACCESS_JWKS_STALE_MAX_MS) {
        return entry.keys;
      }
      throw error;
    } finally {
      clearTimeout(timeout);
    }
  })();

  entry.pending = pending;
  accessJwksCache.set(teamDomain, entry);
  try {
    return await pending;
  } finally {
    const current = accessJwksCache.get(teamDomain);
    if (current === entry) {
      entry.pending = null;
      if (!entry.keys) accessJwksCache.delete(teamDomain);
    }
  }
}

async function inspectCloudflareAccessJwt(token, config) {
  const checks = {
    assertionHeaderPresent: typeof token === "string" && token.length > 0,
    jwtStructureValid: null,
    algorithmValid: null,
    issuerMatches: null,
    audienceMatches: null,
    timeValid: null,
    jwksAvailable: null,
    signingKeyFound: null,
    signatureValid: null
  };
  const fail = failureReason => ({ authenticated: false, failureReason, checks });

  if (!config) return fail("verifier_not_configured");
  if (!checks.assertionHeaderPresent) return fail("access_jwt_header_missing");
  if (token.length > 32768) return fail("access_jwt_too_large");

  const parts = token.split(".");
  if (parts.length !== 3 || !parts[0] || !parts[1] || !parts[2]) {
    checks.jwtStructureValid = false;
    return fail("jwt_malformed");
  }

  let header;
  let payload;
  let signature;
  try {
    header = decodeBase64UrlJson(parts[0]);
    payload = decodeBase64UrlJson(parts[1]);
    signature = decodeBase64UrlBytes(parts[2]);
    if (!header || typeof header !== "object" || !payload || typeof payload !== "object") {
      throw new Error("Invalid JWT JSON structure");
    }
    checks.jwtStructureValid = true;
  } catch (_) {
    checks.jwtStructureValid = false;
    return fail("jwt_malformed");
  }

  // Cloudflare Access application tokens use RS256.
  checks.algorithmValid = header.alg === "RS256" && typeof header.kid === "string" && !!header.kid;
  if (!checks.algorithmValid) return fail("jwt_algorithm_or_key_id_invalid");

  checks.issuerMatches = payload.iss === config.teamDomain;
  if (!checks.issuerMatches) return fail("issuer_mismatch");

  const tokenAudiences = typeof payload.aud === "string"
    ? [payload.aud]
    : Array.isArray(payload.aud) ? payload.aud : [];
  checks.audienceMatches = config.audiences.some(audience => tokenAudiences.includes(audience));
  if (!checks.audienceMatches) return fail("audience_mismatch");

  const nowSeconds = Math.floor(Date.now() / 1000);
  const clockToleranceSeconds = 30;
  checks.timeValid =
    Number.isFinite(payload.exp) &&
    payload.exp > nowSeconds - clockToleranceSeconds &&
    (payload.nbf === undefined || (
      Number.isFinite(payload.nbf) && payload.nbf <= nowSeconds + clockToleranceSeconds
    )) &&
    (payload.iat === undefined || (
      Number.isFinite(payload.iat) && payload.iat <= nowSeconds + clockToleranceSeconds
    ));
  if (!checks.timeValid) return fail("jwt_expired_or_not_yet_valid");

  let keys;
  try {
    keys = await getAccessJwks(config.teamDomain);
    checks.jwksAvailable = Array.isArray(keys) && keys.length > 0;
  } catch (error) {
    checks.jwksAvailable = false;
    checks.jwksFailure = {
      errorName: typeof error?.name === "string" ? error.name.slice(0, 40) : "Error",
      errorCode: typeof error?.code === "string" ? error.code.slice(0, 80) : null,
      httpStatus: Number.isInteger(error?.httpStatus) ? error.httpStatus : null,
      contentType: typeof error?.contentType === "string" ? error.contentType.slice(0, 100) : null,
      message: typeof error?.message === "string" ? error.message.slice(0, 160) : "Unknown JWKS fetch error",
      causeCode: typeof error?.cause?.code === "string" ? error.cause.code.slice(0, 80) : null,
      causeMessage: typeof error?.cause?.message === "string" ? error.cause.message.slice(0, 160) : null
    };
    return fail("jwks_unavailable");
  }
  if (!checks.jwksAvailable) return fail("jwks_unavailable");

  let signingJwk = keys.find(key => key.kid === header.kid);
  if (!signingJwk) {
    try {
      keys = await getAccessJwks(config.teamDomain, true);
      signingJwk = keys.find(key => key.kid === header.kid);
    } catch (_) {
      checks.signingKeyFound = false;
      return fail("jwks_refresh_failed");
    }
  }
  checks.signingKeyFound = !!signingJwk;
  if (!signingJwk) return fail("signing_key_not_found");

  try {
    const publicKey = await crypto.subtle.importKey(
      "jwk",
      signingJwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"]
    );
    const signingInput = new TextEncoder().encode(parts[0] + "." + parts[1]);
    checks.signatureValid = await crypto.subtle.verify(
      { name: "RSASSA-PKCS1-v1_5" },
      publicKey,
      signature,
      signingInput
    );
  } catch (_) {
    checks.signatureValid = false;
    return fail("signature_check_error");
  }

  if (!checks.signatureValid) return fail("signature_invalid");
  return { authenticated: true, failureReason: null, checks };
}

export async function getAccessAuthDiagnostics(request, env) {
  const config = getAccessVerifierConfig(env);
  const result = await inspectCloudflareAccessJwt(
    request.headers.get("Cf-Access-Jwt-Assertion"),
    config
  );
  return {
    authenticated: result.authenticated,
    jwtValidationConfigured: !!config,
    failureReason: result.failureReason,
    checks: result.checks
  };
}

export async function isAuthenticated(request, env) {
  const config = getAccessVerifierConfig(env);
  if (!config) return false;
  const token = request.headers.get("Cf-Access-Jwt-Assertion");
  return verifyCloudflareAccessJwt(token, config);
}

export async function requireAuth(request, env) {
  if (!isAccessVerifierConfigured(env)) {
    return json({
      error: "Cloudflare Access JWT 驗證尚未設定。請在 Pages Variables 新增 FRAME_READER_ACCESS_TEAM_DOMAIN 與 FRAME_READER_ACCESS_AUD。"
    }, 503);
  }
  if (!(await isAuthenticated(request, env))) {
    return json({ error: "Cloudflare Access 身分驗證失敗，請重新登入後再試。" }, 401);
  }
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
    baseUrl: env => env.ALIST_WORKER_API_BASE_URL || env.OPENLIST_WORKER_API_BASE_URL,
    username: env => env.ALIST_WORKER_USERNAME || env.ALIST_WORKER_API_USERNAME,
    password: env => env.ALIST_WORKER_PASSWORD || env.ALIST_WORKER_API_PASSWORD
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
