import { json, requireAuth, getOpenListConfig, openListPost, normalizePath, isWithinRoot } from "../../_lib/common.js";

function isLocalHost(hostname) {
  const host = String(hostname || "").toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "::1" || host.endsWith(".localhost");
}

export async function onRequestGet({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const requestUrl = new URL(request.url);
  const provider = requestUrl.searchParams.get("provider") || "vps";
  if (!["vps", "worker", "mobile"].includes(provider)) return json({ error: "不支援的雲端來源。區域網路來源必須由目前裝置直接連線。" }, 400);
  const config = getOpenListConfig(env, provider);
  if (!config) return json({ error: "選取的來源尚未設定。請確認其 Cloudflare Pages URL／Token Secret 與共用 OPENLIST_ROOT_PATH。" }, 503);

  const path = normalizePath(requestUrl.searchParams.get("path") || "");
  if (!path || !isWithinRoot(path, config.rootPath)) return json({ error: "路徑無效，或超出設定的書庫根目錄。" }, 400);
  if (!/\.(epub|cbz)$/i.test(path)) return json({ error: "目前只允許讀取 EPUB 與 CBZ 檔案。" }, 415);

  try {
    const metadata = await openListPost(env, "/api/fs/get", {
      path,
      password: "",
      page: 1,
      per_page: 0,
      refresh: false
    }, provider);
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
