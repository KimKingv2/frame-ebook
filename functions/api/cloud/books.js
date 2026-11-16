import { json, requireAuth, getDatabase, normalizePath, isWithinRoot } from "../../_lib/common.js";

const PROVIDERS = new Set(["vps", "worker", "mobile", "local"]);
const LIBRARIES = new Set(["books", "comics"]);
const CATALOG_PROVIDERS_SQL = "'vps','worker','mobile','local'";

async function scanStateKey(library, rootPath) {
  const input = "vps\n" + library + "\n" + rootPath;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input)));
  const hex = Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
  return "reader_scan_" + hex;
}

export async function onRequestGet({ request, env }) {
  let stage = "authenticate";
  try {
    const denied = await requireAuth(request, env);
    if (denied) return denied;
    stage = "resolve_database";
    const db = getDatabase(env);
    if (!db || typeof db.prepare !== "function") return json({ error: "FRAME_READER_DB 尚未綁定。請先設定 D1 binding。" }, 503);

    stage = "parse_request";
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
    const recursiveShelf = url.searchParams.get("recursive") === "1" && path === rootPath;
    const prefix = rootPath === "/" ? "/" : rootPath + "/";
    const where = recursiveShelf
      ? "library=? AND root_path=? AND ((is_dir=1 AND parent_path=?) OR (is_dir=0 AND substr(path,1,?)=?))"
      : "library=? AND root_path=? AND parent_path=?";

    stage = "prepare_queries";
    const countStatement = recursiveShelf
      ? db.prepare("SELECT COUNT(DISTINCT path) AS count FROM cloud_catalog WHERE provider IN (" + CATALOG_PROVIDERS_SQL + ") AND " + where)
          .bind(library, rootPath, rootPath, prefix.length, prefix)
      : db.prepare("SELECT COUNT(DISTINCT path) AS count FROM cloud_catalog WHERE provider IN (" + CATALOG_PROVIDERS_SQL + ") AND " + where)
          .bind(library, rootPath, path);

    const selectColumns = "path,parent_path,name,is_dir,format,size_bytes,modified_at,cover_hash,cover_type,cover_status,cover_error,indexed_at";
    const rowsStatement = recursiveShelf
      ? db.prepare(
          "WITH ranked AS (" +
          "SELECT " + selectColumns + ",ROW_NUMBER() OVER (PARTITION BY path ORDER BY indexed_at DESC,CASE WHEN provider='vps' THEN 1 ELSE 0 END DESC,provider DESC) AS rn " +
          "FROM cloud_catalog WHERE provider IN (" + CATALOG_PROVIDERS_SQL + ") AND " + where +
          ") SELECT " + selectColumns + " FROM ranked WHERE rn=1 " +
          "ORDER BY is_dir DESC,name COLLATE NOCASE,path LIMIT ? OFFSET ?"
        ).bind(library, rootPath, rootPath, prefix.length, prefix, perPage, offset)
      : db.prepare(
          "WITH ranked AS (" +
          "SELECT " + selectColumns + ",ROW_NUMBER() OVER (PARTITION BY path ORDER BY indexed_at DESC,CASE WHEN provider='vps' THEN 1 ELSE 0 END DESC,provider DESC) AS rn " +
          "FROM cloud_catalog WHERE provider IN (" + CATALOG_PROVIDERS_SQL + ") AND " + where +
          ") SELECT " + selectColumns + " FROM ranked WHERE rn=1 " +
          "ORDER BY is_dir DESC,name COLLATE NOCASE,path LIMIT ? OFFSET ?"
        ).bind(library, rootPath, path);

    stage = "count_and_rows";
    const [count, rows] = await Promise.all([
      countStatement.first(), rowsStatement.all()
    ]);

    stage = "read_scan_state";
    const stateRow = await db.prepare(
      "SELECT state_json,updated_at FROM cloud_scan_state WHERE library=? AND root_path=? ORDER BY updated_at DESC LIMIT 1"
    ).bind(library, rootPath).first();

    stage = "parse_scan_state";
    const scanState = stateRow ? { ...JSON.parse(stateRow.state_json), provider } : null;
    const total = Number(count?.count || 0);
    const items = (rows?.results || []).map(row => ({
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
        skippedCount: Number(scanState.skippedCount || 0),
        failedCount: Number(scanState.failedCount || 0),
        visitedFolderCount: Number(scanState.visitedFolderCount || 0),
        coverReadyCount: Number(scanState.coverReadyCount || 0),
        coverMissingCount: Number(scanState.coverMissingCount || 0),
        coverFailedCount: Number(scanState.coverFailedCount || 0),
        updatedAt: stateRow.updated_at || scanState.updatedAt || null
      } : null,
      path,rootPath,provider,library,page,perPage,total,items
    });
  } catch (error) {
    const name = typeof error?.name === "string" ? error.name.slice(0, 40) : "Error";
    const detail = String(error?.message || name).replace(/[\r\n\t]+/g, " ").slice(0, 180);
    return json({ error: "D1 書庫索引 API 發生例外（" + stage + " / " + name + "）：" + detail }, 503);
  }
}
