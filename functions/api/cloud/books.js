import { json, requireAuth, getOpenListConfig, openListPost, normalizePath, isWithinRoot, joinPath } from "../../_lib/common.js";

function getFormat(name) {
  const ext = String(name || "").split(".").pop().toLowerCase();
  return ext === "epub" ? "EPUB" : ext === "cbz" ? "CBZ" : "";
}

export async function onRequestGet({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const url = new URL(request.url);
  const provider = url.searchParams.get("provider") || "vps";
  if (!["vps", "worker", "mobile"].includes(provider)) return json({ error: "不支援的雲端來源。區域網路來源必須由目前裝置直接連線。" }, 400);
  const config = getOpenListConfig(env, provider);
  if (!config) return json({ error: "選取的來源尚未設定。請確認其 Cloudflare Pages URL／Token Secret 與共用 OPENLIST_ROOT_PATH。" }, 503);

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
    }, provider);
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
      provider,
      page,
      perPage,
      total: Number(data && data.total) || items.length,
      items
    });
  } catch (error) {
    return json({ error: error && error.message ? error.message : "OpenList 目錄讀取失敗。" }, 502);
  }
}
