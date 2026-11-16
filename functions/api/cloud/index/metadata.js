import {
  json, requireAuth, isSameOrigin, getDatabase, normalizePath, isWithinRoot
} from "../../../_lib/common.js";

const PROVIDERS = new Set(["vps", "worker", "mobile"]);
const MAX_ITEMS = 50;

function clean(value, max) {
  return String(value == null ? "" : value).replace(/\0/g, "").trim().slice(0, max);
}

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源寫入 EPUB metadata。" }, 403);
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const db = getDatabase(env);
  if (!db || typeof db.batch !== "function") return json({ error: "FRAME_READER_DB 尚未綁定。" }, 503);

  let body;
  try { body = await request.json(); } catch (_) { return json({ error: "EPUB metadata 格式無效。" }, 400); }
  const provider = String(body?.provider || "");
  const rootPath = normalizePath(body?.rootPath || "");
  const entries = body?.entries;
  if (!PROVIDERS.has(provider) || !rootPath || !Array.isArray(entries) ||
      entries.length < 1 || entries.length > MAX_ITEMS) {
    return json({ error: "EPUB metadata 批次參數無效。" }, 400);
  }

  const statements = [];
  for (const entry of entries) {
    const path = normalizePath(entry?.path || "");
    const metadata = entry?.metadata;
    if (!path || path === rootPath || !isWithinRoot(path, rootPath) ||
        !metadata || typeof metadata !== "object" || Array.isArray(metadata)) {
      return json({ error: "EPUB metadata 項目包含無效路徑或資料。" }, 400);
    }
    const row = await db.prepare(
      "SELECT name,format,is_dir FROM cloud_catalog WHERE provider=? AND library='books' AND root_path=? AND path=?"
    ).bind(provider, rootPath, path).first();
    if (!row || Number(row.is_dir) !== 0 || String(row.format || "").toUpperCase() !== "EPUB") {
      return json({ error: "EPUB metadata 目標不在目前電子書索引中：" + path.slice(-120) }, 404);
    }

    const creators = Array.isArray(metadata.creators)
      ? metadata.creators.slice(0, 12).map(value => clean(value, 120)).filter(Boolean)
      : [];
    const subjects = Array.isArray(metadata.subjects)
      ? metadata.subjects.slice(0, 40).map(value => clean(value, 120)).filter(Boolean)
      : [];
    const title = clean(metadata.title, 240);
    const creator = creators.join("、").slice(0, 600);
    const language = clean(metadata.language, 64);
    const description = clean(metadata.description, 8000);
    const publisher = clean(metadata.publisher, 240);
    const date = clean(metadata.date, 120);
    const identifier = clean(metadata.identifier, 500);
    statements.push(db.prepare(
      "UPDATE cloud_catalog SET book_title=?,book_creator=?,book_language=?,book_description=?," +
      "book_publisher=?,book_date=?,book_identifier=?,book_subjects_json=?," +
      "book_metadata_status='ready',book_metadata_updated_at=? " +
      "WHERE provider=? AND library='books' AND root_path=? AND path=?"
    ).bind(
      title, creator, language, description, publisher, date, identifier,
      JSON.stringify(subjects), Date.now(), provider, rootPath, path
    ));
  }

  try {
    await db.batch(statements);
    return json({ ok: true, updated: statements.length });
  } catch (error) {
    return json({ error: "保存 EPUB metadata 失敗。請先執行 0007 migration。" }, 503);
  }
}
