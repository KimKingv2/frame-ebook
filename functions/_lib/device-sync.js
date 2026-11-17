import { getDatabase, getOpenListConfig, sha256Hex, json } from "./common.js";

export function databaseOrError(env) {
  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function") {
    return { error: json({ error: "FRAME_READER_DB 尚未綁定。" }, 503) };
  }
  return { db };
}

export function randomUrlToken(byteLength = 32) {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export async function sha256Text(value) {
  return sha256Hex(String(value || ""));
}

export async function getDeviceContext(request, env) {
  const database = databaseOrError(env);
  if (database.error) return database;
  const authorization = String(request.headers.get("Authorization") || "");
  const match = authorization.match(/^Bearer\s+([A-Za-z0-9_-]{40,160})$/i);
  if (!match) return { error: json({ error: "缺少有效的 FRAME Ebook 設備授權。" }, 401) };
  const tokenHash = await sha256Text(match[1]);
  try {
    const row = await database.db.prepare(
      "SELECT device_id AS deviceId,user_id AS userId FROM reader_devices " +
      "WHERE token_hash=? AND revoked_at IS NULL LIMIT 1"
    ).bind(tokenHash).first();
    if (!row) return { error: json({ error: "設備授權不存在或已撤銷，請重新配對。" }, 401) };
    const now = Date.now();
    await database.db.prepare(
      "UPDATE reader_devices SET last_used_at=? WHERE device_id=? AND (last_used_at<? OR last_used_at IS NULL)"
    ).bind(now, row.deviceId, now - 5 * 60 * 1000).run();
    return { db: database.db, userId: String(row.userId), deviceId: String(row.deviceId) };
  } catch (error) {
    return { error: json({ error: "驗證設備授權失敗：" + String(error?.message || error).slice(0, 140) }, 503) };
  }
}

export async function getConfiguredSourceMap(env) {
  const output = {};
  for (const provider of ["vps", "worker", "mobile"]) {
    const config = getOpenListConfig(env, provider, "books");
    if (!config || !config.base || !config.username) continue;
    try {
      const origin = new URL(config.base).origin.toLowerCase();
      const username = String(config.username).trim().toLowerCase();
      const id = "webdav:" + await sha256Text(origin + "\n" + username);
      output[id] = provider;
    } catch (_) {}
  }
  return output;
}
