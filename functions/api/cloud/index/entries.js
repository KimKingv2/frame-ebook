import { json, requireAuth, getDatabase, isSameOrigin, normalizePath, isWithinRoot } from "../../../_lib/common.js";

const PROVIDERS = new Set(["vps", "worker", "mobile", "local"]);
const LIBRARIES = new Set(["books", "comics"]);
const INSERT_SQL = [
  "INSERT INTO cloud_catalog",
  "(provider,library,root_path,path,parent_path,name,is_dir,format,size_bytes,modified_at,scan_id,indexed_at,cover_hash,cover_type,cover_status,cover_error,cover_updated_at)",
  "VALUES (?,?,?,?,?,?,?,?,?,?,?, ?,NULL,NULL,?,NULL,NULL)",
  "ON CONFLICT(provider,library,root_path,path) DO UPDATE SET",
  "parent_path=excluded.parent_path,name=excluded.name,is_dir=excluded.is_dir,",
  "format=excluded.format,size_bytes=excluded.size_bytes,modified_at=excluded.modified_at,",
  "scan_id=excluded.scan_id,indexed_at=excluded.indexed_at,",
  "cover_hash=CASE WHEN cloud_catalog.size_bytes<>excluded.size_bytes OR COALESCE(cloud_catalog.modified_at,'')<>COALESCE(excluded.modified_at,'') OR cloud_catalog.cover_status='error' THEN NULL ELSE cloud_catalog.cover_hash END,",
  "cover_type=CASE WHEN cloud_catalog.size_bytes<>excluded.size_bytes OR COALESCE(cloud_catalog.modified_at,'')<>COALESCE(excluded.modified_at,'') OR cloud_catalog.cover_status='error' THEN NULL ELSE cloud_catalog.cover_type END,",
  "cover_status=CASE WHEN cloud_catalog.size_bytes<>excluded.size_bytes OR COALESCE(cloud_catalog.modified_at,'')<>COALESCE(excluded.modified_at,'') OR cloud_catalog.cover_status='error' THEN CASE WHEN excluded.is_dir=1 THEN 'none' ELSE 'pending' END ELSE cloud_catalog.cover_status END,",
  "cover_error=CASE WHEN cloud_catalog.size_bytes<>excluded.size_bytes OR COALESCE(cloud_catalog.modified_at,'')<>COALESCE(excluded.modified_at,'') OR cloud_catalog.cover_status='error' THEN NULL ELSE cloud_catalog.cover_error END,",
  "cover_updated_at=CASE WHEN cloud_catalog.size_bytes<>excluded.size_bytes OR COALESCE(cloud_catalog.modified_at,'')<>COALESCE(excluded.modified_at,'') OR cloud_catalog.cover_status='error' THEN NULL ELSE cloud_catalog.cover_updated_at END"
].join(" ");

function validScope(provider, library, rootPath) {
  return PROVIDERS.has(provider) && LIBRARIES.has(library) && !!rootPath;
}

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源索引寫入。" }, 403);
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const db = getDatabase(env);
  if (!db || typeof db.batch !== "function") return json({ error: "FRAME_READER_DB 尚未綁定。" }, 503);

  let body;
  try { body = await request.json(); } catch { return json({ error: "索引資料格式無效。" }, 400); }
  const provider = String(body?.provider || "");
  const library = String(body?.library || "");
  const rootPath = normalizePath(body?.rootPath || "");
  const scanId = String(body?.scanId || "");
  const entries = body?.entries;
  if (!validScope(provider, library, rootPath) || !/^[a-zA-Z0-9_-]{12,100}$/.test(scanId)) {
    return json({ error: "索引來源、分類、根目錄或掃描識別碼無效。" }, 400);
  }
  if (!Array.isArray(entries) || entries.length < 1 || entries.length > 100) {
    return json({ error: "每批必須包含 1 至 100 筆索引項目。" }, 400);
  }

  const prefix = rootPath === "/" ? "/" : rootPath + "/";
  const now = new Date().toISOString();
  const statements = [];
  for (const item of entries) {
    const path = normalizePath(item?.path || "");
    const parentPath = normalizePath(item?.parentPath || "");
    const name = String(item?.name || "");
    const isDir = item?.isDir === true;
    const format = isDir ? "" : String(item?.format || "").toUpperCase();
    const size = Number(item?.size) || 0;
    const modified = item?.modified == null ? null : String(item.modified).slice(0, 120);
    if (!path || path === rootPath || !path.startsWith(prefix) ||
        !parentPath || !isWithinRoot(parentPath, rootPath) ||
        !name || name.length > 1024 || name.includes("/") || name.includes("\\") ||
        name.includes("\0") || !Number.isSafeInteger(size) || size < 0 ||
        (!isDir && !(library === "books" ? format === "EPUB" : format === "EPUB" || format === "CBZ"))) {
      return json({ error: "索引批次包含無效路徑、檔名或不支援的檔案格式；整批未寫入。" }, 400);
    }
    const slash = path.lastIndexOf("/");
    const expectedParent = slash <= 0 ? "/" : path.slice(0, slash);
    const expectedName = path.slice(slash + 1);
    if (expectedParent !== parentPath || expectedName !== name) {
      return json({ error: "索引項目的父目錄或檔名與完整路徑不一致；整批未寫入。" }, 400);
    }
    statements.push(db.prepare(INSERT_SQL).bind(
      provider, library, rootPath, path, parentPath, name,
      isDir ? 1 : 0, format, size, modified, scanId, now,
      isDir ? "none" : "pending"
    ));
  }

  try {
    await db.batch(statements);
    return json({ ok: true, saved: statements.length, provider, library, rootPath, scanId, indexedAt: now });
  } catch {
    return json({ error: "寫入雲端書庫索引失敗。請確認已執行 0002 與 0003 D1 migration。" }, 503);
  }
}
