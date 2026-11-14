import { json, requireAuth, getDatabase, normalizePath, isWithinRoot } from "../../_lib/common.js";

const PROVIDERS = new Set(["vps", "worker", "mobile", "local"]);
const LIBRARIES = new Set(["books", "comics"]);

async function scanStateKey(provider, library, rootPath) {
  const input = provider + "\n" + library + "\n" + rootPath;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input)));
  const hex = Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
  return "reader_scan_" + hex;
}

export async function onRequestGet({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function") {
    return json({ error: "FRAME_READER_DB 尚未綁定。請先設定 D1 binding。" }, 503);
  }

  const url = new URL(request.url);
  const provider = url.searchParams.get("provider") || "vps";
  const library = url.searchParams.get("library") === "comics" ? "comics" : "books";
  const rootPath = normalizePath(url.searchParams.get("root_path") || "/");
  const path = normalizePath(url.searchParams.get("path") || "/");
  if (!PROVIDERS.has(provider)) return json({ error: "不支援的書庫來源。" }, 400);
  if (!LIBRARIES.has(library) || !rootPath || !path || !isWithinRoot(path, rootPath)) {
    return json({ error: "目錄路徑無效或超出目前書庫根目錄。" }, 400);
  }

  const page = Math.max(1, Math.min(100000, Number(url.searchParams.get("page")) || 1));
  const perPage = Math.max(1, Math.min(100, Number(url.searchParams.get("per_page")) || 80));
  const offset = (page - 1) * perPage;

  try {
    const [count, rows, scanKey] = await Promise.all([
      db.prepare(
        "SELECT COUNT(*) AS count FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND parent_path=?"
      ).bind(provider, library, rootPath, path).first(),
      db.prepare(
        "SELECT path,parent_path,name,is_dir,format,size_bytes,modified_at,cover_hash,cover_type,cover_status,cover_error " +
        "FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND parent_path=? " +
        "ORDER BY is_dir DESC,name COLLATE NOCASE,path LIMIT ? OFFSET ?"
      ).bind(provider, library, rootPath, path, perPage, offset).all(),
      scanStateKey(provider, library, rootPath)
    ]);
    const stateRow = await db.prepare(
      "SELECT state_json,updated_at FROM cloud_scan_state WHERE scan_key=?"
    ).bind(scanKey).first();
    const scanState = stateRow ? JSON.parse(stateRow.state_json) : null;
    const total = Number(count?.count || 0);
    const items = (rows.results || []).map(row => ({
      name: row.name,
      path: row.path,
      parentPath: row.parent_path,
      isDir: Number(row.is_dir) === 1,
      format: row.format || "",
      size: Number(row.size_bytes || 0),
      modified: row.modified_at || null,
      coverHash: row.cover_hash || null,
      coverType: row.cover_type || null,
      coverStatus: row.cover_status || (Number(row.is_dir) === 1 ? "none" : "pending"),
      coverError: row.cover_error || null,
      supported: true
    }));
    return json({
      ok: true,
      indexed: !!scanState?.completed,
      scanState: scanState ? {
        completed: !!scanState.completed,
        scannedCount: Number(scanState.scannedCount || 0),
        indexedCount: Number(scanState.indexedCount || 0),
        visitedFolderCount: Number(scanState.visitedFolderCount || 0),
        updatedAt: stateRow.updated_at || scanState.updatedAt || null
      } : null,
      path,
      rootPath,
      provider,
      library,
      page,
      perPage,
      total,
      items
    });
  } catch {
    return json({
      error: "雲端書庫索引尚未初始化或查詢失敗。請先執行 migrations/0002_cloud_catalog.sql 與 0003_cloud_covers.sql。"
    }, 503);
  }
}
