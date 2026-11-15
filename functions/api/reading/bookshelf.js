import { json, getDatabase, requireAuth, getAccessIdentity, getOpenListRootPaths, normalizePath } from "../../_lib/common.js";
import { READER_PROVIDERS } from "../../_lib/reader-data.js";

const DEFAULT_ROOTS = {
  books: "/中國移動雲盤/Kim King/04 Boooooks/01 Books 歸檔",
  comics: "/中國移動雲盤/Kim King/11 Comic"
};

async function loadPreferences(db, userId) {
  const result = await db.prepare(
    "SELECT setting_key AS key,value_json AS valueJson FROM reader_preferences WHERE user_id=?"
  ).bind(userId).all();
  const output = {};
  for (const row of result.results || []) {
    try { output[row.key] = JSON.parse(row.valueJson); } catch (_) {}
  }
  return output;
}

function stripSlash(value) { return String(value || "").replace(/^\/+/, ""); }

export async function onRequestGet({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function") return json({ error: "FRAME_READER_DB 尚未綁定。" }, 503);
  let identity;
  try { identity = await getAccessIdentity(request, env); }
  catch (error) { return json({ error: error?.message || "Cloudflare Access 身分驗證失敗。", }, error?.status || 503); }

  try {
    const preferences = await loadPreferences(db, identity.userId);
    const provider = READER_PROVIDERS.has(preferences.activeProvider) ? preferences.activeProvider : "vps";
    const savedRoots = preferences.roots?.[provider] || {};
    const envRoots = getOpenListRootPaths(env);
    const roots = {
      books: normalizePath(savedRoots.books || envRoots.books || DEFAULT_ROOTS.books),
      comics: normalizePath(savedRoots.comics || envRoots.comics || DEFAULT_ROOTS.comics)
    };
    const rawRows = [];
    for (const library of ["books", "comics"]) {
      const rootPath = roots[library];
      if (!rootPath) continue;
      const rows = await db.prepare(
        "SELECT path,parent_path,name,format,size_bytes,modified_at,cover_hash,cover_type,cover_status " +
        "FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND is_dir=0 " +
        "AND format IN ("+(library === "books" ? "'EPUB'" : "'EPUB','CBZ'")+") ORDER BY path LIMIT 10000"
      ).bind(provider, library, rootPath).all();
      for (const row of rows.results || []) rawRows.push({ ...row, provider, library, rootPath });
    }

    const stateResult = await db.prepare(
      "SELECT book_id AS bookId,state_json AS stateJson FROM reader_book_state WHERE user_id=?"
    ).bind(identity.userId).all();
    const stateMap = new Map();
    for (const row of stateResult.results || []) {
      try { stateMap.set(String(row.bookId), JSON.parse(row.stateJson)); } catch (_) {}
    }

    const items = [];
    const groups = new Map();
    for (const row of rawRows) {
      const path = normalizePath(row.path);
      const rootPath = normalizePath(row.rootPath);
      const identityText = [row.provider, row.library, stripSlash(rootPath), stripSlash(path)].join("\n");
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(identityText));
      const id = "cloud:" + Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, "0")).join("");
      const prefix = rootPath === "/" ? "/" : rootPath + "/";
      const relative = path.startsWith(prefix) ? path.slice(prefix.length) : "";
      const parts = relative.split("/").filter(Boolean);
      const folderPath = parts.length > 1 ? prefix + parts[0] : "";
      const folderTitle = folderPath ? folderPath.slice(prefix.length) : "";
      const state = stateMap.get(id) || {};
      const metadata = state.metadata || {};
      const item = {
        id, sourceType: "cloud",
        provider: row.provider, library: row.library, rootPath, path,
        fileName: row.name, title: metadata.manualTitle && metadata.title ? metadata.title : (folderTitle || String(row.name).replace(/\.(epub|cbz)$/i,"")),
        author: metadata.manualAuthor ? String(metadata.author || "") : "",
        format: String(row.format || "").toUpperCase(),
        shelf: metadata.shelf === "comics" || metadata.shelf === "books" ? metadata.shelf : row.library,
        size: Number(row.size_bytes) || 0,
        modifiedAt: row.modified_at || null,
        lastModified: row.modified_at ? (Date.parse(row.modified_at) || 0) : 0,
        addedAt: 0,
        lastOpenedAt: Number(state.lastOpenedAt) || 0,
        progress: state.progress || { percent: 0, label: "尚未閱讀", cfi: "", index: null },
        manualTitle: !!metadata.manualTitle,
        manualAuthor: !!metadata.manualAuthor,
        cloudCoverHash: row.cover_hash || null,
        cloudCoverStatus: row.cover_status || "",
        cloudCoverHashes: row.cover_hash && row.cover_status === "ready" ? [row.cover_hash] : [],
        cloudSource: { provider: row.provider, library: row.library, rootPath, path, folderPath, files: [] }
      };
      item.folderTitle = folderTitle;
      item._state = state;
      items.push(item);
      if (folderPath) {
        const key = [row.provider,row.library,rootPath,folderPath].join("\n");
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(item);
      }
    }

    for (const group of groups.values()) {
      const files = group.map(item => ({
        path: item.path, name: item.fileName, format: item.format, size: item.size,
        modified: item.modifiedAt, coverHash: item.cloudCoverHash, coverStatus: item.cloudCoverStatus
      })).sort((a,b) => a.path.localeCompare(b.path,"zh-Hant",{numeric:true,sensitivity:"base"}));
      const hashes = [...new Set(files.filter(file => file.coverHash && file.coverStatus === "ready").map(file => file.coverHash))].slice(0,8);
      for (const item of group) {
        item.cloudSource.files = files;
        item.cloudCoverHashes = hashes;
        item.volumeCount = files.length;
      }
    }

    items.sort((a,b) => String(a.path).localeCompare(String(b.path),"zh-Hant",{numeric:true,sensitivity:"base"}));
    return json({ ok: true, provider, roots, items, count: items.length });
  } catch (error) {
    return json({ error: "載入雲端書架失敗：" + String(error?.message || error).slice(0, 180) }, 503);
  }
}
