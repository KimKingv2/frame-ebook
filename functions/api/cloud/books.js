import { json, requireAuth, getOpenListConfig, openListPost, normalizePath, isWithinRoot, joinPath } from "../../_lib/common.js";

function getFormat(name) {
  const ext = String(name || "").split(".").pop().toLowerCase();
  return ext === "epub" ? "EPUB" : ext === "cbz" ? "CBZ" : "";
}

export async function onRequestGet({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const config = getOpenListConfig(env);
  if (!config) return json({ error: "OpenList 尚未設定。請在 Cloudflare Pages Variables / Secrets 設定 OPENLIST_BASE_URL、OPENLIST_TOKEN 與 OPENLIST_ROOT_PATH。" }, 503);

  const url = new URL(request.url);
  const path = normalizePath(url.searchParams.get("path") || config.rootPath);
  if (!path || !isWithinRoot(path, config.rootPath)) return json({ error: "路徑無效，或超出設定的書庫根目錄。" }, 400);
  const page = Math.max(1, Math.min(100000, Number(url.searchParams.get("page")) || 1));
  const perPage = Math.max(1, Math.min(100, Number(url.searchParams.get("per_page")) || 80));

  try {
    const data = await openListPost(env, "/api/fs/list", {
      path,
      password: "",
      page,
      per_page: perPage,
      refresh: false
    });
    const content = Array.isArray(data && data.content) ? data.content : [];
    const items = content.map(item => {
      const itemPath = joinPath(path, item.name);
      if (!itemPath || !isWithinRoot(itemPath, config.rootPath)) return null;
      const isDir = !!item.is_dir;
      const format = isDir ? "" : getFormat(item.name);
      return {
        name: String(item.name || ""),
        path: itemPath,
        isDir,
        format,
        size: Number(item.size) || 0,
        modified: item.modified || item.created || null,
        supported: isDir || !!format
      };
    }).filter(Boolean).filter(item => item.isDir || item.supported);

    return json({
      path,
      rootPath: config.rootPath,
      page,
      perPage,
      total: Number(data && data.total) || items.length,
      items
    });
  } catch (error) {
    return json({ error: error && error.message ? error.message : "OpenList 目錄讀取失敗。" }, 502);
  }
}
