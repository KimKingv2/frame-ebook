import { json, getDatabase, requireAuth, isSameOrigin, getAccessIdentity, normalizePath } from "../../_lib/common.js";

const PROVIDERS = new Set(["vps", "worker", "mobile"]);
const LIBRARIES = new Set(["books", "comics"]);
const ALLOWED_KEYS = new Set(["activeProvider", "activeLibrary", "roots", "goalMinutes"]);

async function context(request, env) {
  const denied = await requireAuth(request, env);
  if (denied) return { error: denied };
  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function") return { error: json({ error: "FRAME_READER_DB 尚未綁定。" }, 503) };
  try {
    const identity = await getAccessIdentity(request, env);
    return { db, userId: identity.userId };
  } catch (error) {
    return { error: json({ error: error?.message || "Cloudflare Access 身分驗證失敗。", }, error?.status || 503) };
  }
}

function validate(key, value) {
  if (!ALLOWED_KEYS.has(key)) throw new Error("不支援的雲端偏好設定。");
  if (key === "activeProvider" && !PROVIDERS.has(String(value))) throw new Error("書庫來源無效。");
  if (key === "activeLibrary" && !LIBRARIES.has(String(value))) throw new Error("書庫分類無效。");
  if (key === "goalMinutes" && (!Number.isInteger(Number(value)) || Number(value) < 5 || Number(value) > 240)) throw new Error("每日閱讀目標必須介於 5 至 240 分鐘。");
  if (key === "roots") {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("書庫根目錄設定無效。");
    const clean = {};
    for (const [provider, pairValue] of Object.entries(value)) {
      if (!PROVIDERS.has(provider)) continue;
      const pair = pairValue && typeof pairValue === "object" && !Array.isArray(pairValue) ? pairValue : {};
      clean[provider] = {};
      for (const library of LIBRARIES) {
        if (!Object.prototype.hasOwnProperty.call(pair, library)) continue;
        const path = normalizePath(pair[library]);
        if (!path || path.length > 2048) throw new Error("書庫根目錄路徑無效。");
        clean[provider][library] = path;
      }
      if (!Object.keys(clean[provider]).length) delete clean[provider];
    }
    return clean;
  }
  if (key === "goalMinutes") return Number(value);
  if (key === "activeProvider") return String(value);
  return String(value);
}

export async function onRequestGet({ request, env }) {
  const ctx = await context(request, env);
  if (ctx.error) return ctx.error;
  try {
    const result = await ctx.db.prepare(
      "SELECT setting_key AS key, value_json AS valueJson FROM reader_preferences WHERE user_id=?"
    ).bind(ctx.userId).all();
    const preferences = {};
    for (const row of result.results || []) {
      try { preferences[row.key] = JSON.parse(row.valueJson); } catch (_) {}
    }
    return json({ ok: true, preferences });
  } catch (error) {
    return json({ error: "讀取雲端偏好設定失敗：" + String(error?.message || error).slice(0, 160) }, 503);
  }
}

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源修改雲端偏好設定。" }, 403);
  const ctx = await context(request, env);
  if (ctx.error) return ctx.error;
  let body;
  try { body = await request.json(); } catch (_) { return json({ error: "偏好設定格式無效。" }, 400); }
  const key = String(body?.key || "");
  let value;
  try { value = validate(key, body?.value); } catch (error) { return json({ error: error.message }, 400); }
  const now = Date.now();
  try {
    await ctx.db.batch([
      ctx.db.prepare(
        "INSERT INTO reader_preferences (user_id,setting_key,value_json,updated_at) VALUES (?,?,?,?) " +
        "ON CONFLICT(user_id,setting_key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at"
      ).bind(ctx.userId, key, JSON.stringify(value), now),
      ctx.db.prepare(
        "INSERT INTO reader_sync_changes (user_id,entity_type,entity_id,operation,payload_json,created_at) VALUES (?,'preference',?,'upsert',?,?)"
      ).bind(ctx.userId,key,JSON.stringify({key,value}),now)
    ]);
    return json({ ok: true, key, value, updatedAt: now });
  } catch (error) {
    return json({ error: "保存雲端偏好設定失敗：" + String(error?.message || error).slice(0, 160) }, 503);
  }
}
