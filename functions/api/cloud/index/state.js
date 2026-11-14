import { json, requireAuth, getDatabase, isSameOrigin, normalizePath } from "../../../_lib/common.js";

const PROVIDERS = new Set(["vps", "worker", "mobile", "local"]);
const LIBRARIES = new Set(["books", "comics"]);

function validScope(provider, library, rootPath) {
  return PROVIDERS.has(provider) && LIBRARIES.has(library) && !!rootPath;
}

async function stateKey(provider, library, rootPath) {
  const input = provider + "\\n" + library + "\\n" + rootPath;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input)));
  const hex = Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
  return "reader_scan_" + hex;
}

export async function onRequest({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function") return json({ error: "FRAME_READER_DB 尚未綁定。" }, 503);

  if (request.method === "GET") {
    const url = new URL(request.url);
    const provider = url.searchParams.get("provider") || "";
    const library = url.searchParams.get("library") || "";
    const rootPath = normalizePath(url.searchParams.get("root_path") || "");
    if (!validScope(provider, library, rootPath)) return json({ error: "索引來源、分類或根目錄無效。" }, 400);
    try {
      const key = await stateKey(provider, library, rootPath);
      const row = await db.prepare(
        "SELECT state_json,updated_at FROM cloud_scan_state WHERE scan_key=?"
      ).bind(key).first();
      return json({
        ok: true,
        state: row ? JSON.parse(row.state_json) : null,
        updatedAt: row?.updated_at || null
      });
    } catch {
      return json({ error: "讀取 D1 掃描進度失敗。請確認已執行 migrations/0002_cloud_catalog.sql。" }, 503);
    }
  }

  if (request.method === "POST") {
    if (!isSameOrigin(request)) return json({ error: "不允許跨來源保存索引進度。" }, 403);
    let body;
    try { body = await request.json(); } catch { return json({ error: "索引進度格式無效。" }, 400); }
    const provider = String(body?.provider || "");
    const library = String(body?.library || "");
    const rootPath = normalizePath(body?.rootPath || "");
    const state = body?.state;
    if (!validScope(provider, library, rootPath) || !state || typeof state !== "object" ||
        state.version !== 1 || state.rootPath !== rootPath ||
        !Array.isArray(state.pendingFolders) || !Array.isArray(state.seenFolders)) {
      return json({ error: "索引進度內容無效。" }, 400);
    }
    const value = JSON.stringify(state);
    if (value.length > 800000) return json({ error: "索引進度超過 800 KB 上限。" }, 413);
    try {
      const key = await stateKey(provider, library, rootPath);
      const now = new Date().toISOString();
      await db.prepare(
        "INSERT INTO cloud_scan_state (scan_key,provider,library,root_path,state_json,updated_at) VALUES (?,?,?,?,?,?) " +
        "ON CONFLICT(scan_key) DO UPDATE SET state_json=excluded.state_json,updated_at=excluded.updated_at"
      ).bind(key, provider, library, rootPath, value, now).run();
      return json({ ok: true, updatedAt: now });
    } catch {
      return json({ error: "保存 D1 掃描進度失敗。請保留目前畫面並重試。" }, 503);
    }
  }

  return json({ error: "Method Not Allowed" }, 405);
}
