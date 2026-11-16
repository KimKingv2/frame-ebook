import { json, requireAuth, getDatabase, getOpenListConfig, openListPost, normalizePath } from "../../_lib/common.js";

function isLocalHost(hostname) {
  const host = String(hostname || "").toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "::1" || host.endsWith(".localhost");
}

const FILE_LINK_RETRY_DELAYS_MS = [700, 1500];
const TRANSIENT_FILE_LINK_ERROR = /(?:i\/o timeout|client\.timeout exceeded|context deadline exceeded|dial tcp[^\n]*(?:timeout|network is unreachable)|tls handshake timeout|connection timed out|operation timed out|temporary failure in name resolution|server misbehaving|no such host|network is unreachable|connection reset by peer|unexpected eof)/i;

function isTransientFileLinkError(error) {
  const message = String(error && error.message || error || "");
  const causeMessage = String(error && error.cause && error.cause.message || "");
  const causeCode = String(error && error.cause && error.cause.code || error && error.code || "");
  return TRANSIENT_FILE_LINK_ERROR.test(message + " " + causeMessage) ||
    /^(?:ECONNRESET|ECONNREFUSED|ETIMEDOUT|EHOSTUNREACH|ENETUNREACH|EAI_AGAIN|EPIPE)$/i.test(causeCode);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function getRangeHeader(request) {
  const range = request.headers.get("Range");
  return range && /^bytes=\d*-\d*(?:,\d*-\d*)*$/.test(range) ? range : "";
}

function buildDownloadHeaders(upstream, path, metadata, isComics) {
  const headers = new Headers({
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
    if (value) headers.set(name, value);
  });
  if (!headers.has("Content-Type")) {
    headers.set("Content-Type", isComics && /\.cbz$/i.test(path)
      ? "application/vnd.comicbook+zip"
      : "application/epub+zip");
  }
  return headers;
}

export async function onRequestGet({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const requestUrl = new URL(request.url);
  const provider = requestUrl.searchParams.get("provider") || "vps";
  const library = requestUrl.searchParams.get("library") === "comics" ? "comics" : "books";
  const delivery = requestUrl.searchParams.get("delivery") || "stream";
  if (!["vps", "worker", "mobile"].includes(provider)) {
    return json({ error: "不支援的雲端來源。請選擇已設定的伺服器端 Alist／OpenList 來源。" }, 400);
  }
  if (!["stream", "redirect"].includes(delivery)) {
    return json({ error: "不支援的檔案傳輸模式。" }, 400);
  }
  const config = getOpenListConfig(env, provider, library);
  if (!config) return json({ error: "選取的來源尚未設定。請確認 Pages API Base URL、帳號 Variable 與密碼 Secret。" }, 503);

  const path = normalizePath(requestUrl.searchParams.get("path") || "");
  const rootPath = normalizePath(requestUrl.searchParams.get("root_path") || "");
  if (!path || path === "/" || !rootPath) return json({ error: "檔案路徑或書庫根目錄無效。" }, 400);
  const allowedExtension = library === "comics" ? /\.(epub|cbz)$/i : /\.epub$/i;
  if (!allowedExtension.test(path)) {
    return json({ error: library === "comics" ? "漫畫來源只允許 EPUB 或 CBZ 檔案。" : "電子書來源只允許 EPUB 檔案。" }, 415);
  }

  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function") return json({ error: "FRAME_READER_DB 尚未綁定。" }, 503);
  try {
    const indexed = await db.prepare(
      "SELECT is_dir,format FROM cloud_catalog WHERE provider IN ('vps','worker','mobile','local') AND library=? AND root_path=? AND path=? ORDER BY CASE WHEN provider='vps' THEN 1 ELSE 0 END DESC,indexed_at DESC LIMIT 1"
    ).bind(library, rootPath, path).first();
    const expectedFormat = path.toLowerCase().endsWith(".cbz") ? "CBZ" : "EPUB";
    if (!indexed || Number(indexed.is_dir) !== 0 || indexed.format !== expectedFormat) {
      return json({ error: "這個檔案不在目前來源的書庫索引中。請先完成或更新索引，再重新載入書架。" }, 404);
    }
  } catch {
    return json({ error: "讀取 D1 書庫索引失敗。請確認已執行 migrations/0002_cloud_catalog.sql。" }, 503);
  }

  try {
    // Match FRAME Audio's /api/fs/get request shape. Only path and password
    // are required to resolve the temporary raw_url.
    let metadata = null;
    let lastLinkError = null;
    let retryCount = 0;

    for (let attempt = 1; attempt <= FILE_LINK_RETRY_DELAYS_MS.length + 1; attempt += 1) {
      try {
        metadata = await openListPost(env, "/api/fs/get", {
          path,
          password: ""
        }, provider, library);
        lastLinkError = null;
        break;
      } catch (error) {
        lastLinkError = error;
        if (!isTransientFileLinkError(error) || attempt > FILE_LINK_RETRY_DELAYS_MS.length) break;
        const delayMs = FILE_LINK_RETRY_DELAYS_MS[attempt - 1];
        retryCount += 1;
        console.warn("[FRAME Ebook] retrying transient OpenList file-link failure", {
          provider,
          attempt,
          nextAttempt: attempt + 1,
          delayMs,
          reason: "temporary provider network failure"
        });
        await sleep(delayMs);
      }
    }

    if (lastLinkError) {
      const message = String(lastLinkError.message || "OpenList 檔案讀取失敗。");
      throw new Error(
        retryCount > 0 && isTransientFileLinkError(lastLinkError)
          ? message + "（已自動重試 " + retryCount + " 次，仍未成功）"
          : message
      );
    }

    if (!metadata || metadata.is_dir || !metadata.raw_url) {
      return json({ error: "OpenList 沒有提供這個檔案的下載位址。" }, 502);
    }

    let target;
    try {
      target = new URL(metadata.raw_url, config.base);
    } catch (_) {
      return json({ error: "OpenList 回傳的檔案位址無效。" }, 502);
    }
    if (target.protocol !== "https:" && target.protocol !== "http:") {
      return json({ error: "OpenList 回傳了不支援的下載協定。" }, 502);
    }
    if (isLocalHost(target.hostname)) {
      target = new URL(target.pathname + target.search, config.base);
    }
    if (target.username || target.password) {
      return json({ error: "OpenList 回傳的檔案位址不可包含 URL 帳密。" }, 502);
    }

    // Optional direct redirect for ordinary browser navigation or clients
    // whose destination explicitly permits CORS. The Foliate reader must use
    // same-origin streaming below because fetch()->302 requires CORS on the
    // final 139/cloud-storage host, unlike a native audio/video media element.
    if (delivery === "redirect") {
      return new Response(null, {
        status: 302,
        headers: {
          "Location": target.toString(),
          "Cache-Control": "private, no-store",
          "Referrer-Policy": "no-referrer",
          "X-Content-Type-Options": "nosniff"
        }
      });
    }

    // Stream the upstream response through Pages without buffering the whole
    // EPUB/CBZ in the Function. This keeps the browser request same-origin and
    // avoids cross-origin CORS restrictions while preserving HTTP Range.
    const upstreamHeaders = new Headers();
    const range = getRangeHeader(request);
    if (range) upstreamHeaders.set("Range", range);

    const upstream = await fetch(target.toString(), {
      method: "GET",
      headers: upstreamHeaders,
      redirect: "follow"
    });

    if (![200, 206, 416].includes(upstream.status)) {
      try { await upstream.body?.cancel(); } catch (_) {}
      return json({ error: "OpenList 檔案來源回應 HTTP " + upstream.status + "。" }, 502);
    }

    return new Response(upstream.body, {
      status: upstream.status,
      headers: buildDownloadHeaders(upstream, path, metadata, library === "comics")
    });
  } catch (error) {
    return json({ error: error && error.message ? error.message : "OpenList 檔案讀取失敗。" }, 502);
  }
}
