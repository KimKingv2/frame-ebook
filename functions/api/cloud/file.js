import { json, requireAuth, getDatabase, getOpenListConfig, openListPost, normalizePath } from "../../_lib/common.js";

function isLocalHost(hostname) {
  const host = String(hostname || "").toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "::1" || host.endsWith(".localhost");
}

export async function onRequestGet({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const requestUrl = new URL(request.url);
  const provider = requestUrl.searchParams.get("provider") || "vps";
  const library = requestUrl.searchParams.get("library") === "comics" ? "comics" : "books";
  if (!["vps", "worker", "mobile"].includes(provider)) return json({ error: "不支援的雲端來源。區域網路來源必須由目前裝置直接連線。" }, 400);
  const config = getOpenListConfig(env, provider, library);
  if (!config) return json({ error: "選取的來源尚未設定。請確認 Pages API Base URL、帳號 Variable 與密碼 Secret。" }, 503);

  const path = normalizePath(requestUrl.searchParams.get("path") || "");
  const rootPath = normalizePath(requestUrl.searchParams.get("root_path") || "");
  if (!path || path === "/" || !rootPath) return json({ error: "檔案路徑或書庫根目錄無效。" }, 400);
  const allowedExtension = library === "comics" ? /\.(epub|cbz)$/i : /\.epub$/i;
  if (!allowedExtension.test(path)) return json({ error: library === "comics" ? "漫畫來源只允許 EPUB 或 CBZ 檔案。" : "電子書來源只允許 EPUB 檔案。" }, 415);

  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function") return json({ error: "FRAME_READER_DB 尚未綁定。" }, 503);
  try {
    const indexed = await db.prepare(
      "SELECT is_dir,format FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND path=?"
    ).bind(provider, library, rootPath, path).first();
    const expectedFormat = path.toLowerCase().endsWith(".cbz") ? "CBZ" : "EPUB";
    if (!indexed || Number(indexed.is_dir) !== 0 || indexed.format !== expectedFormat) {
      return json({ error: "這個檔案不在目前來源的書庫索引中。請先完成或更新索引，再重新載入書架。" }, 404);
    }
  } catch {
    return json({ error: "讀取 D1 書庫索引失敗。請確認已執行 migrations/0002_cloud_catalog.sql。" }, 503);
  }

  try {
    const metadata = await openListPost(env, "/api/fs/get", {
      path,
      password: "",
      page: 1,
      per_page: 0,
      refresh: false
    }, provider, library);
    if (!metadata || metadata.is_dir || !metadata.raw_url) return json({ error: "OpenList 沒有提供這個檔案的下載位址。" }, 502);

    let target;
    try {
      target = new URL(metadata.raw_url, config.base);
    } catch (_) {
      return json({ error: "OpenList 回傳的檔案位址無效。" }, 502);
    }
    if (target.protocol !== "https:" && target.protocol !== "http:") return json({ error: "OpenList 回傳了不支援的下載協定。" }, 502);
    if (isLocalHost(target.hostname)) {
      target = new URL(target.pathname + target.search, config.base);
    }

    const headers = new Headers();
    const range = request.headers.get("Range");
    if (range && /^bytes=\d*-\d*(,\d*-\d*)*$/.test(range)) headers.set("Range", range);
    const upstream = await fetch(target.toString(), {
      method: "GET",
      headers,
      redirect: "follow"
    });

    if (![200, 206, 416].includes(upstream.status)) {
      return json({ error: "OpenList 檔案來源回應 HTTP " + upstream.status + "。" }, 502);
    }

    const responseHeaders = new Headers({
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "Content-Disposition": "inline; filename*=UTF-8''" + encodeURIComponent(String(metadata.name || path.split("/").pop()))
    });
    [
      "Content-Type",
      "Content-Length",
      "Content-Range",
      "Accept-Ranges",
      "ETag",
      "Last-Modified"
    ].forEach(name => {
      const value = upstream.headers.get(name);
      if (value) responseHeaders.set(name, value);
    });
    if (!responseHeaders.has("Content-Type")) {
      responseHeaders.set("Content-Type", /\.cbz$/i.test(path) ? "application/vnd.comicbook+zip" : "application/epub+zip");
    }
    return new Response(upstream.body, {
      status: upstream.status,
      headers: responseHeaders
    });
  } catch (error) {
    return json({ error: error && error.message ? error.message : "OpenList 檔案讀取失敗。" }, 502);
  }
}
