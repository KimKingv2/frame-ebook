import { json, requireAuth, getDatabase, isSameOrigin, normalizePath } from "../../../_lib/common.js";

const PROVIDERS = new Set(["vps", "worker", "mobile", "local"]);
const LIBRARIES = new Set(["books", "comics"]);

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源完成索引。" }, 403);
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function") return json({ error: "FRAME_READER_DB 尚未綁定。" }, 503);

  let body;
  try { body = await request.json(); } catch { return json({ error: "索引完成資料格式無效。" }, 400); }
  const provider = String(body?.provider || "");
  const library = String(body?.library || "");
  const rootPath = normalizePath(body?.rootPath || "");
  const scanId = String(body?.scanId || "");
  if (!PROVIDERS.has(provider) || !LIBRARIES.has(library) || !rootPath ||
      !/^[a-zA-Z0-9_-]{12,100}$/.test(scanId)) {
    return json({ error: "索引來源、分類、根目錄或掃描識別碼無效。" }, 400);
  }

  try {
    const result = await db.prepare(
      "DELETE FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND scan_id<>?"
    ).bind(provider, library, rootPath, scanId).run();
    return json({
      ok: true,
      removed: Number(result?.meta?.changes || 0),
      provider,
      library,
      rootPath,
      scanId
    });
  } catch {
    return json({ error: "清理已不存在的索引項目失敗。掃描進度仍保留，可重新完成清理。" }, 503);
  }
}
