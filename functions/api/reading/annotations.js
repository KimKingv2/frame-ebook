import {
  json, getDatabase, requireAuth, isSameOrigin, normalizePath, isWithinRoot,
  sha256Hex, getAccessIdentity
} from "../../_lib/common.js";

const PROVIDERS = new Set(["vps", "worker", "mobile", "local"]);
const LIBRARIES = new Set(["books", "comics"]);
const ANNOTATION_TYPES = new Set(["highlight", "note", "bookmark"]);

function cleanText(value, maxLength) {
  return String(value == null ? "" : value).slice(0, maxLength);
}

async function resolveBook(db, raw) {
  const provider = String(raw && raw.provider || "");
  const library = String(raw && raw.library || "");
  const rootPath = normalizePath(raw && raw.rootPath);
  const path = normalizePath(raw && raw.path);
  const bookId = String(raw && raw.id || "");

  if (!PROVIDERS.has(provider) || !LIBRARIES.has(library) || !rootPath || !path ||
      path === "/" || !isWithinRoot(path, rootPath) ||
      !/^cloud:[a-f0-9]{64}$/.test(bookId)) {
    return { error: json({ error: "雲端書籍識別資訊無效。" }, 400) };
  }

  // Keep this identity recipe exactly aligned with cloudBookId() in the browser.
  const stripLeadingSlash = value => value.replace(/^\/+/, "");
  const identity = [
    provider, library, stripLeadingSlash(rootPath), stripLeadingSlash(path)
  ].join("\\n");
  const expectedId = "cloud:" + await sha256Hex(identity);
  if (expectedId !== bookId) return { error: json({ error: "雲端書籍識別碼不相符。" }, 400) };

  const indexed = await db.prepare(
    "SELECT is_dir,format FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND path=? LIMIT 1"
  ).bind(provider, library, rootPath, path).first();
  if (!indexed) return { error: json({ error: "這本書不在目前的 OpenList 書庫索引中。請先重新掃描書庫。" }, 404) };

  if (Number(indexed.is_dir) === 1) {
    const prefix = path.replace(/\\/+$/, "") + "/";
    const descendants = await db.prepare(
      "SELECT COUNT(*) AS count FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND is_dir=0 " +
      "AND substr(path,1,?)=? AND ((?='books' AND format='EPUB') OR (?='comics' AND format IN ('EPUB','CBZ')))"
    ).bind(provider, library, rootPath, prefix.length, prefix, library, library).first();
    if (!Number(descendants?.count || 0)) {
      return { error: json({ error: "這個資料夾內沒有可閱讀的 EPUB／CBZ 書檔。" }, 415) };
    }
  } else {
    const format = String(indexed.format || "").toUpperCase();
    const validFormat = library === "books"
      ? format === "EPUB"
      : format === "EPUB" || format === "CBZ";
    if (!validFormat) return { error: json({ error: "這個檔案格式不屬於目前的書庫。" }, 415) };
  }

  return { provider, library, rootPath, path, bookId };
}

async function resolveContext(request, env, rawBook) {
  const denied = await requireAuth(request, env);
  if (denied) return { error: denied };
  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function") {
    return { error: json({ error: "FRAME_READER_DB 尚未綁定。" }, 503) };
  }

  let identity;
  try {
    identity = await getAccessIdentity(request, env);
  } catch (error) {
    return { error: json({ error: error && error.message ? error.message : "Cloudflare Access 身分驗證失敗。" }, error.status || 503) };
  }

  try {
    const book = await resolveBook(db, rawBook);
    if (book.error) return book;
    return { db, userId: identity.userId, book };
  } catch (error) {
    return { error: json({ error: "驗證雲端書籍失敗：" + cleanText(error && error.message, 180) }, 503) };
  }
}

function annotationFromRow(row) {
  return {
    id: String(row.annotationId),
    bookId: String(row.bookId),
    type: String(row.type),
    cfi: String(row.cfi || ""),
    quote: String(row.quote || ""),
    text: String(row.text || ""),
    color: String(row.color || "yellow"),
    createdAt: Number(row.createdAt) || 0,
    updatedAt: Number(row.updatedAt) || 0
  };
}

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const context = await resolveContext(request, env, {
    id: url.searchParams.get("book_id"),
    provider: url.searchParams.get("provider"),
    library: url.searchParams.get("library"),
    rootPath: url.searchParams.get("root_path"),
    path: url.searchParams.get("path")
  });
  if (context.error) return context.error;

  try {
    const result = await context.db.prepare(
      "SELECT annotation_id AS annotationId, book_id AS bookId, type, cfi, quote, note_text AS text, color, created_at AS createdAt, updated_at AS updatedAt " +
      "FROM reader_annotations WHERE user_id=? AND book_id=? ORDER BY created_at ASC, annotation_id ASC"
    ).bind(context.userId, context.book.bookId).all();
    return json({
      ok: true,
      bookId: context.book.bookId,
      annotations: (result.results || []).map(annotationFromRow)
    });
  } catch (error) {
    return json({ error: "雲端標註讀取失敗：" + cleanText(error && error.message, 180) }, 503);
  }
}

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源寫入雲端標註。" }, 403);
  const length = Number(request.headers.get("Content-Length") || 0);
  if (length > 64 * 1024) return json({ error: "單筆標註內容過大。" }, 413);

  let body;
  try { body = await request.json(); } catch (_) {
    return json({ error: "雲端標註資料格式無效。" }, 400);
  }
  const context = await resolveContext(request, env, body && body.book);
  if (context.error) return context.error;

  const input = body && body.annotation;
  const id = cleanText(input && input.id, 120);
  const type = String(input && input.type || "note");
  const cfi = cleanText(input && input.cfi, 4000);
  const quote = cleanText(input && input.quote, 12000);
  const noteText = cleanText(input && input.text, 20000);
  const color = cleanText(input && input.color || "yellow", 32);
  if (!id || !ANNOTATION_TYPES.has(type) || !cfi) {
    return json({ error: "標註缺少有效識別碼、類型或 EPUB 定位資訊。" }, 400);
  }

  const now = Date.now();
  try {
    await context.db.prepare(
      "INSERT INTO reader_annotations " +
      "(user_id, book_id, annotation_id, provider, library, root_path, book_path, type, cfi, quote, note_text, color, created_at, updated_at) " +
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " +
      "ON CONFLICT(user_id, book_id, annotation_id) DO UPDATE SET " +
      "provider=excluded.provider, library=excluded.library, root_path=excluded.root_path, book_path=excluded.book_path, " +
      "type=excluded.type, cfi=excluded.cfi, quote=excluded.quote, note_text=excluded.note_text, color=excluded.color, updated_at=excluded.updated_at"
    ).bind(
      context.userId, context.book.bookId, id,
      context.book.provider, context.book.library, context.book.rootPath, context.book.path,
      type, cfi, quote, noteText, color, now, now
    ).run();

    return json({
      ok: true,
      annotation: {
        id, bookId: context.book.bookId, type, cfi, quote, text: noteText, color,
        createdAt: Number(input && input.createdAt) || now,
        updatedAt: now
      }
    });
  } catch (error) {
    return json({ error: "雲端標註儲存失敗：" + cleanText(error && error.message, 180) }, 503);
  }
}

export async function onRequestDelete({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源刪除雲端標註。" }, 403);
  let body;
  try { body = await request.json(); } catch (_) {
    return json({ error: "刪除標註資料格式無效。" }, 400);
  }
  const context = await resolveContext(request, env, body && body.book);
  if (context.error) return context.error;
  const id = cleanText(body && body.id, 120);
  if (!id) return json({ error: "缺少標註識別碼。" }, 400);

  try {
    const result = await context.db.prepare(
      "DELETE FROM reader_annotations WHERE user_id=? AND book_id=? AND annotation_id=?"
    ).bind(context.userId, context.book.bookId, id).run();
    return json({ ok: true, deleted: Number(result.meta && result.meta.changes) || 0 });
  } catch (error) {
    return json({ error: "雲端標註刪除失敗：" + cleanText(error && error.message, 180) }, 503);
  }
}
