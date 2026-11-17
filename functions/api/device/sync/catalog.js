import { json, getOpenListRootPaths, normalizePath } from "../../../_lib/common.js";
import { getDeviceContext, getConfiguredSourceMap } from "../../../_lib/device-sync.js";
import { readerBookIdForFilename } from "../../../_lib/reader-data.js";

const DEFAULT_ROOTS = {
  books: "/中國移動雲盤/Kim King/04 Boooooks/01 Books 歸檔",
  comics: "/中國移動雲盤/Kim King/11 Comic"
};

function parseJson(value, fallback = {}) {
  try { return JSON.parse(value); } catch (_) { return fallback; }
}

export async function onRequestGet({ request, env }) {
  const context = await getDeviceContext(request, env);
  if (context.error) return context.error;
  const sourceId = String(new URL(request.url).searchParams.get("source_id") || "");
  const provider = (await getConfiguredSourceMap(env))[sourceId];
  if (!provider) {
    return json({ error: "這個 WebDAV 來源尚未對應到 Cloudflare 已設定的伺服器端書庫。請確認 Mac WebDAV 主機與 Cloudflare AList 設定使用相同網域。" }, 403);
  }

  try {
    const prefResult = await context.db.prepare(
      "SELECT setting_key AS key,value_json AS valueJson FROM reader_preferences WHERE user_id=?"
    ).bind(context.userId).all();
    const preferences = {};
    for (const row of prefResult.results || []) preferences[row.key] = parseJson(row.valueJson);
    const rootsConfig = preferences.roots || {};
    const envRoots = getOpenListRootPaths(env);
    const rootCandidates = { books: [], comics: [] };
    for (const library of ["books", "comics"]) {
      const values = [
        rootsConfig.shared?.[library],
        rootsConfig[provider]?.[library],
        ...Object.values(rootsConfig).map(value => value?.[library]),
        envRoots[library],
        DEFAULT_ROOTS[library]
      ];
      for (const value of values) {
        if (value == null || String(value).trim() === "") continue;
        const normalized = normalizePath(value);
        if (normalized && !rootCandidates[library].includes(normalized)) rootCandidates[library].push(normalized);
      }
    }

    const items = [];
    const seen = new Set();
    let truncated = false;
    for (const library of ["books", "comics"]) {
      for (const rootPath of rootCandidates[library]) {
        const remaining = 10001 - items.length;
        if (remaining <= 0) { truncated = true; break; }
        const result = await context.db.prepare(
          "SELECT provider,library,root_path AS rootPath,path,parent_path AS parentPath,name,format," +
          "size_bytes AS size,modified_at AS modifiedAt,cover_hash AS coverHash,cover_type AS coverType," +
          "cover_status AS coverStatus,book_title AS bookTitle,book_creator AS bookCreator," +
          "book_language AS language,book_description AS description,book_publisher AS publisher," +
          "book_date AS publishedAt,book_identifier AS identifier,book_subjects_json AS subjectsJson " +
          "FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND is_dir=0 " +
          "AND format IN (" + (library === "books" ? "'EPUB'" : "'EPUB','CBZ'") + ") " +
          "ORDER BY path LIMIT ?"
        ).bind(provider, library, rootPath, remaining).all();

        for (const row of result.results || []) {
          const key = [row.library, row.rootPath, row.path].join("\n");
          if (seen.has(key)) continue;
          seen.add(key);
          const id = await readerBookIdForFilename(row.name);
          items.push({
            id, provider: row.provider, sourceId, library: row.library,
            rootPath: row.rootPath, path: row.path, parentPath: row.parentPath,
            fileName: row.name,
            title: row.bookTitle || String(row.name).replace(/\.(epub|cbz)$/i, ""),
            author: row.bookCreator || "", format: row.format, size: Number(row.size) || 0,
            modifiedAt: row.modifiedAt || null, coverHash: row.coverHash || null,
            coverType: row.coverType || "", coverStatus: row.coverStatus || "",
            language: row.language || "", description: row.description || "",
            publisher: row.publisher || "", publishedAt: row.publishedAt || "",
            identifier: row.identifier || "",
            subjects: parseJson(row.subjectsJson, [])
          });
          if (items.length > 10000) { truncated = true; break; }
        }
        if (truncated) break;
      }
      if (truncated) break;
    }
    return json({
      ok: true, provider, sourceId, items: items.slice(0, 10000),
      count: Math.min(items.length, 10000), truncated
    });
  } catch (error) {
    return json({ error: "讀取雲端書架索引失敗：" + String(error?.message || error).slice(0, 160) }, 503);
  }
}
