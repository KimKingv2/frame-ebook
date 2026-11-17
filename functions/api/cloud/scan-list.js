import { json, requireAuth, getOpenListConfig, openListPost, normalizePath, isWithinRoot, joinPath } from "../../_lib/common.js";

function getFormat(name) {
  const extension = String(name || "").split(".").pop().toLowerCase();
  return extension === "epub" ? "EPUB" : extension === "cbz" ? "CBZ" : "";
}

export async function onRequestGet({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;

  const url = new URL(request.url);
  const provider = url.searchParams.get("provider") || "vps";
  const library = url.searchParams.get("library") === "comics" ? "comics" : "books";
  if (!["vps", "worker", "mobile"].includes(provider)) {
    return json({ error: "伺服器掃描只支援 VPS、Worker 或 Mobile Device；區域網路來源由目前裝置直接掃描。" }, 400);
  }

  const rootPath = normalizePath(url.searchParams.get("root_path") || "/");
  const path = normalizePath(url.searchParams.get("path") || "/");
  if (!rootPath || !path || !isWithinRoot(path, rootPath)) {
    return json({ error: "掃描目錄無效或超出目前書庫根目錄。" }, 400);
  }

  const page = Math.max(1, Math.min(100000, Number(url.searchParams.get("page")) || 1));
  const perPage = Math.max(1, Math.min(100, Number(url.searchParams.get("per_page")) || 100));
  const config = getOpenListConfig(env, provider, library);
  if (!config) {
    return json({ error: "選取的來源尚未設定。請確認 Pages API Base URL、帳號 Variable 與密碼 Secret。" }, 503);
  }

  try {
    const data = await openListPost(env, "/api/fs/list", {
      path,
      password: "",
      page,
      per_page: perPage,
      refresh: false
    }, provider, library);
    const content = Array.isArray(data?.content) ? data.content : [];
    const items = content.map(item => {
      const name = String(item?.name || "");
      if (!name || name.includes("/") || name.includes("\\") || name.includes("\0")) return null;
      const itemPath = joinPath(path, name);
      if (!itemPath || !isWithinRoot(itemPath, rootPath)) return null;
      const isDir = !!item.is_dir;
      const format = isDir ? "" : getFormat(name);
      if (!isDir && !(library === "books" ? format === "EPUB" : format === "EPUB" || format === "CBZ")) return null;
      return {
        name,
        path: itemPath,
        parentPath: path,
        isDir,
        format,
        size: Math.max(0, Number(item.size) || 0),
        modified: item.modified || item.created || null
      };
    }).filter(Boolean);

    return json({
      ok: true,
      provider,
      library,
      rootPath,
      path,
      page,
      perPage,
      total: Math.max(0, Number(data?.total) || items.length),
      items
    });
  } catch (error) {
    return json({ error: error?.message || "OpenList 目錄讀取失敗。" }, 502);
  }
}
