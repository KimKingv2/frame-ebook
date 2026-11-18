import {
  json, getDatabase, requireAuth, isSameOrigin, getAccessIdentity
} from "../../_lib/common.js";

const CONFIRMATION = "DELETE ALL FRAME EBOOK DATA";
const DATA_TABLES = [
  "cloud_catalog",
  "cloud_scan_state",
  "reader_book_state",
  "reader_annotations",
  "reader_reading_events",
  "reader_preferences",
  "reader_comic_metadata",
  "reader_sync_changes",
  "reader_devices",
  "reader_device_pairings",
  // Legacy tables are cleared only when they still exist in an older D1.
  "reading_events",
  "auth_attempts"
];

async function deleteAllCoverObjects(bucket) {
  let cursor = undefined;
  let deleted = 0;
  let pages = 0;
  do {
    pages += 1;
    if (pages > 1000) throw new Error("R2 封面清理超過安全頁數上限，請檢查是否有大量新物件持續寫入。");
    const listed = await bucket.list({
      prefix: "covers/",
      limit: 1000,
      ...(cursor ? { cursor } : {})
    });
    const keys = (listed.objects || [])
      .map(object => String(object.key || ""))
      .filter(key => key.startsWith("covers/"));
    if (keys.length) {
      await bucket.delete(keys);
      deleted += keys.length;
    }
    if (!listed.truncated) return deleted;
    if (!listed.cursor) throw new Error("R2 封面列表有後續頁面，但沒有回傳 cursor。");
    cursor = listed.cursor;
  } while (cursor);
  return deleted;
}

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) {
    return json({ error: "不允許跨來源執行雲端資料清除。" }, 403);
  }
  const denied = await requireAuth(request, env);
  if (denied) return denied;

  let identity;
  try {
    identity = await getAccessIdentity(request, env);
    if (!identity?.userId) throw new Error("Cloudflare Access 使用者識別資訊無效。");
  } catch (error) {
    return json({
      error: error?.message || "Cloudflare Access 身分驗證失敗。"
    }, error?.status || 401);
  }

  let body;
  try {
    body = await request.json();
  } catch (_) {
    return json({ error: "清除確認資料格式無效。" }, 400);
  }
  if (body?.confirmation !== CONFIRMATION) {
    return json({ error: "確認文字不正確，未執行任何清除。" }, 400);
  }

  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function" || typeof db.batch !== "function") {
    return json({ error: "FRAME_READER_DB 尚未正確綁定。" }, 503);
  }
  const bucket = env.FRAME_READER_COVERS;
  if (!bucket || typeof bucket.list !== "function" || typeof bucket.delete !== "function") {
    return json({ error: "R2 binding FRAME_READER_COVERS 尚未正確綁定；為避免只清除一半資料，已停止操作。" }, 503);
  }

  try {
    const tableResult = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type='table'"
    ).all();
    const existingTables = new Set((tableResult.results || []).map(row => String(row.name || "")));
    const targets = DATA_TABLES.filter(name => existingTables.has(name));
    const statements = targets.map(name => db.prepare('DELETE FROM "' + name + '"'));

    // D1 data deletion is executed as a single batch. The schema and migration
    // history are intentionally kept so the application can be used again.
    const results = statements.length ? await db.batch(statements) : [];
    const deletedTables = {};
    targets.forEach((name, index) => {
      deletedTables[name] = Number(results[index]?.meta?.changes || 0);
    });

    let deletedCoverObjects = 0;
    try {
      deletedCoverObjects = await deleteAllCoverObjects(bucket);
    } catch (error) {
      return json({
        ok: false,
        d1Cleared: true,
        deletedTables,
        deletedCoverObjects,
        error: "D1 資料已清除，但 R2 封面快取清理未完成：" +
          String(error?.message || error).slice(0, 180)
      }, 503);
    }

    return json({
      ok: true,
      d1Cleared: true,
      deletedTables,
      deletedCoverObjects,
      affectedScope: "global",
      message: "FRAME Ebook 雲端資料已清除。原始 Alist／OpenList 檔案與 Cloudflare Access 設定未修改。"
    });
  } catch (error) {
    return json({
      error: "清除 FRAME Ebook D1 資料失敗：" + String(error?.message || error).slice(0, 180)
    }, 503);
  }
}
