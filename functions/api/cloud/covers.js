import { json, requireAuth, getDatabase, isSameOrigin, normalizePath, isWithinRoot } from "../../_lib/common.js";

const PROVIDERS = new Set(["vps", "worker", "mobile", "local"]);
const LIBRARIES = new Set(["books", "comics"]);
const HASH_RE = /^[a-f0-9]{64}$/i;
const MIME_TYPES = new Set(["image/webp", "image/jpeg"]);
const MAX_COVER_BYTES = 2 * 1024 * 1024;

function validScope(provider, library, rootPath) {
  return PROVIDERS.has(provider) && LIBRARIES.has(library) && !!rootPath;
}

export async function onRequest({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const db = getDatabase(env);
  const bucket = env.FRAME_READER_COVERS;
  if (!db || typeof db.prepare !== "function") return json({ error: "FRAME_READER_DB 尚未綁定。" }, 503);
  if (!bucket || typeof bucket.get !== "function" || typeof bucket.put !== "function") {
    return json({ error: "R2 binding FRAME_READER_COVERS 尚未設定。" }, 503);
  }

  const url = new URL(request.url);
  if (request.method === "GET") {
    const hash = String(url.searchParams.get("hash") || "").toLowerCase();
    if (hash) {
      if (!HASH_RE.test(hash)) return json({ error: "封面 SHA-256 格式不正確。" }, 400);
      try {
        const referenced = await db.prepare(
          "SELECT 1 AS found FROM cloud_catalog WHERE cover_hash=? AND cover_status='ready' LIMIT 1"
        ).bind(hash).first();
        if (!referenced) return json({ error: "找不到封面索引。" }, 404);
        const object = await bucket.get("covers/" + hash);
        if (!object) return json({ error: "R2 中找不到封面檔案。" }, 404);
        const headers = new Headers();
        object.writeHttpMetadata(headers);
        headers.set("Cache-Control", "private, max-age=86400");
        headers.set("X-Content-Type-Options", "nosniff");
        headers.set("Content-Security-Policy", "default-src 'none'; sandbox");
        headers.set("Content-Disposition", "inline");
        headers.set("ETag", object.httpEtag);
        return new Response(object.body, { headers });
      } catch {
        return json({ error: "讀取 R2 封面失敗。" }, 503);
      }
    }

    const provider = url.searchParams.get("provider") || "";
    const library = url.searchParams.get("library") || "";
    const rootPath = normalizePath(url.searchParams.get("root_path") || "");
    const limit = Math.max(1, Math.min(30, Number(url.searchParams.get("limit")) || 12));
    if (!validScope(provider, library, rootPath)) return json({ error: "封面佇列來源、分類或根目錄無效。" }, 400);
    try {
      const [count, rows] = await Promise.all([
        db.prepare(
          "SELECT COUNT(*) AS count FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND is_dir=0 AND cover_status='pending'"
        ).bind(provider, library, rootPath).first(),
        db.prepare(
          "SELECT path,name,format,size_bytes,modified_at FROM cloud_catalog " +
          "WHERE provider=? AND library=? AND root_path=? AND is_dir=0 AND cover_status='pending' " +
          "ORDER BY path LIMIT ?"
        ).bind(provider, library, rootPath, limit).all()
      ]);
      return json({
        ok: true,
        total: Number(count?.count || 0),
        items: (rows.results || []).map(row => ({
          path: row.path, name: row.name, format: row.format,
          size: Number(row.size_bytes || 0), modified: row.modified_at || null
        }))
      });
    } catch {
      return json({ error: "讀取 D1 封面索引佇列失敗。請確認已執行 0003_cloud_covers.sql。" }, 503);
    }
  }

  if (request.method === "POST") {
    if (!isSameOrigin(request)) return json({ error: "不允許跨來源修改封面索引。" }, 403);
    const contentType = String(request.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
    if (MIME_TYPES.has(contentType)) {
      const provider = url.searchParams.get("provider") || "";
      const library = url.searchParams.get("library") || "";
      const rootPath = normalizePath(url.searchParams.get("root_path") || "");
      const path = normalizePath(url.searchParams.get("path") || "");
      const hash = String(request.headers.get("x-cover-hash") || "").toLowerCase();
      if (!validScope(provider, library, rootPath) || !path || !isWithinRoot(path, rootPath) || !HASH_RE.test(hash)) {
        return json({ error: "封面上傳來源、路徑或雜湊無效。" }, 400);
      }
      const declaredSize = Number(request.headers.get("content-length") || 0);
      if (declaredSize > MAX_COVER_BYTES) return json({ error: "封面超過 2 MiB 上限。" }, 413);
      const data = await request.arrayBuffer();
      if (!data.byteLength || data.byteLength > MAX_COVER_BYTES) return json({ error: "封面大小無效。" }, 413);
      const digest = await crypto.subtle.digest("SHA-256", data);
      const actual = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
      if (actual !== hash) return json({ error: "封面 SHA-256 不符。" }, 400);
      try {
        const row = await db.prepare(
          "SELECT 1 AS found FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND path=? AND is_dir=0"
        ).bind(provider, library, rootPath, path).first();
        if (!row) return json({ error: "找不到對應的雲端書籍索引項目。" }, 404);
        await bucket.put("covers/" + hash, data, {
          httpMetadata: { contentType, cacheControl: "private, max-age=86400" },
          customMetadata: { sha256: hash }
        });
        const now = new Date().toISOString();
        await db.prepare(
          "UPDATE cloud_catalog SET cover_hash=?,cover_type=?,cover_status='ready',cover_error=NULL,cover_updated_at=? " +
          "WHERE provider=? AND library=? AND root_path=? AND path=? AND is_dir=0"
        ).bind(hash, contentType, now, provider, library, rootPath, path).run();
        return json({ ok: true, hash, contentType, sizeBytes: data.byteLength });
      } catch {
        return json({ error: "保存封面至 R2 或更新 D1 封面索引失敗。" }, 503);
      }
    }

    let body;
    try { body = await request.json(); } catch { return json({ error: "封面索引資料格式無效。" }, 400); }
    const provider = String(body?.provider || "");
    const library = String(body?.library || "");
    const rootPath = normalizePath(body?.rootPath || "");
    if (!validScope(provider, library, rootPath)) return json({ error: "封面索引來源、分類或根目錄無效。" }, 400);
    try {
      if (body.action === "retry-errors") {
        const result = await db.prepare(
          "UPDATE cloud_catalog SET cover_status='pending',cover_error=NULL,cover_updated_at=NULL " +
          "WHERE provider=? AND library=? AND root_path=? AND is_dir=0 AND cover_status='error'"
        ).bind(provider, library, rootPath).run();
        return json({ ok: true, retried: Number(result?.meta?.changes || 0) });
      }

      const path = normalizePath(body.path || "");
      const status = String(body.status || "");
      if (!path || !isWithinRoot(path, rootPath) || !["missing", "error"].includes(status)) {
        return json({ error: "封面路徑或狀態無效。" }, 400);
      }
      const message = status === "error" ? String(body.error || "封面索引失敗").slice(0, 500) : null;
      const now = new Date().toISOString();
      const result = await db.prepare(
        "UPDATE cloud_catalog SET cover_hash=NULL,cover_type=NULL,cover_status=?,cover_error=?,cover_updated_at=? " +
        "WHERE provider=? AND library=? AND root_path=? AND path=? AND is_dir=0"
      ).bind(status, message, now, provider, library, rootPath, path).run();
      if (!Number(result?.meta?.changes || 0)) return json({ error: "找不到對應的雲端書籍索引項目。" }, 404);
      return json({ ok: true, path, status, updatedAt: now });
    } catch {
      return json({ error: "更新 D1 封面索引失敗。請確認已執行 0003_cloud_covers.sql。" }, 503);
    }
  }

  return json({ error: "Method Not Allowed" }, 405);
}
