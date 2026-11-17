import { json, isSameOrigin } from "../../_lib/common.js";
import { getReaderContext, requestBookDescriptor } from "../../_lib/reader-data.js";

const APPEARANCE_KEYS = new Set([
  "fontScale","lineHeight","verticalMargin","horizontalMargin","fontFamily","fontWeight",
  "paragraphSpacing","textAlign","readingMode","pageLayout","comicReadingMode",
  "comicPageLayout","comicImageFit","backdrop","theme"
]);

function cleanText(value, max) { return String(value == null ? "" : value).slice(0, max); }

function cleanState(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("書籍狀態格式無效。");
  const output = {};
  if (Object.prototype.hasOwnProperty.call(input, "progress")) {
    const p = input.progress;
    if (!p || typeof p !== "object" || Array.isArray(p)) throw new Error("閱讀進度格式無效。");
    const percent = Number(p.percent);
    const index = p.index == null ? null : Number(p.index);
    if (!Number.isFinite(percent) || percent < 0 || percent > 100 ||
        (index !== null && (!Number.isSafeInteger(index) || index < 0))) throw new Error("閱讀進度數值無效。");
    output.progress = {
      percent: Math.round(percent),
      label: cleanText(p.label || "", 160),
      cfi: cleanText(p.cfi || "", 4000),
      index
    };
  }
  if (Object.prototype.hasOwnProperty.call(input, "appearance")) {
    const a = input.appearance;
    if (!a || typeof a !== "object" || Array.isArray(a)) throw new Error("閱讀外觀設定格式無效。");
    const clean = {};
    for (const [key, value] of Object.entries(a)) {
      if (!APPEARANCE_KEYS.has(key)) continue;
      clean[key] = typeof value === "string" ? value.slice(0, 32) : value;
    }
    output.appearance = clean;
  }
  if (Object.prototype.hasOwnProperty.call(input, "metadata")) {
    const m = input.metadata;
    if (!m || typeof m !== "object" || Array.isArray(m)) throw new Error("書籍自訂資訊格式無效。");
    output.metadata = {
      title: cleanText(m.title || "", 240),
      author: cleanText(m.author || "", 240),
      shelf: ["books","comics"].includes(m.shelf) ? m.shelf : undefined,
      manualTitle: !!m.manualTitle,
      manualAuthor: !!m.manualAuthor,
      language: cleanText(m.language || "", 64),
      pageCount: Math.max(0, Math.min(1000000, Number(m.pageCount) || 0))
    };
  }
  if (Object.prototype.hasOwnProperty.call(input, "lastOpenedAt")) {
    const value = Number(input.lastOpenedAt);
    if (!Number.isSafeInteger(value) || value < 0) throw new Error("最後閱讀時間無效。");
    output.lastOpenedAt = value;
  }
  return output;
}

async function readState(context) {
  const row = await context.db.prepare(
    "SELECT state_json AS stateJson FROM reader_book_state WHERE user_id=? AND book_id=?"
  ).bind(context.userId, context.book.bookId).first();
  try { return row ? JSON.parse(row.stateJson) : {}; } catch (_) { return {}; }
}

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const context = await getReaderContext(request, env, requestBookDescriptor(url));
  if (context.error) return context.error;
  try {
    return json({ ok: true, bookId: context.book.bookId, state: await readState(context) });
  } catch (error) {
    return json({ error: "讀取雲端閱讀狀態失敗：" + String(error?.message || error).slice(0, 160) }, 503);
  }
}

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源寫入閱讀狀態。" }, 403);
  const length = Number(request.headers.get("Content-Length") || 0);
  if (length > 32 * 1024) return json({ error: "閱讀狀態資料過大。" }, 413);
  let body;
  try { body = await request.json(); } catch (_) { return json({ error: "閱讀狀態格式無效。" }, 400); }
  const context = await getReaderContext(request, env, body?.book);
  if (context.error) return context.error;
  let patch;
  try { patch = cleanState(body?.state); } catch (error) { return json({ error: error.message }, 400); }
  try {
    const previous = await readState(context);
    const next = { ...previous, ...patch };
    const now = Date.now();
    const stateJson = JSON.stringify(next);
    if (stateJson.length > 24 * 1024) return json({ error: "單本書的閱讀狀態超過保存上限。" }, 413);
    const storedProvider = context.book.provider === "local" ? "vps" : context.book.provider;
    await context.db.batch([
      context.db.prepare(
        "INSERT INTO reader_book_state (user_id,book_id,provider,library,root_path,book_path,state_json,created_at,updated_at) " +
        "VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(user_id,book_id) DO UPDATE SET " +
        "provider=excluded.provider,library=excluded.library,root_path=excluded.root_path,book_path=excluded.book_path," +
        "state_json=excluded.state_json,updated_at=excluded.updated_at"
      ).bind(
        context.userId, context.book.bookId, storedProvider, context.book.library,
        context.book.rootPath, context.book.path, stateJson, now, now
      ),
      context.db.prepare(
        "INSERT INTO reader_sync_changes (user_id,entity_type,entity_id,operation,payload_json,created_at) VALUES (?,'state',?,'upsert',?,?)"
      ).bind(context.userId,context.book.bookId,JSON.stringify({
        book:{id:context.book.bookId,provider:storedProvider,library:context.book.library,rootPath:context.book.rootPath,path:context.book.path},
        state:next
      }),now)
    ]);
    return json({ ok: true, bookId: context.book.bookId, state: next, updatedAt: now });
  } catch (error) {
    return json({ error: "保存雲端閱讀狀態失敗：" + String(error?.message || error).slice(0, 160) }, 503);
  }
}
