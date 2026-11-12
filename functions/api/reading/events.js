import { json, getDatabase, requireAuth, isSameOrigin } from "../../_lib/common.js";

function validEvent(event) {
  if (!event || typeof event !== "object") return false;
  const id = String(event.id || "");
  const bookId = String(event.bookId || "");
  const dayKey = String(event.dayKey || "");
  const seconds = Number(event.seconds);
  const start = Number(event.startedAt);
  const end = Number(event.endedAt);
  const localHour = Number(event.localHour);
  return id.length >= 8 && id.length <= 120 &&
    bookId.length > 0 && bookId.length <= 180 &&
    /^\d{4}-\d{2}-\d{2}$/.test(dayKey) &&
    Number.isInteger(seconds) && seconds >= 1 && seconds <= 30 &&
    Number.isSafeInteger(start) && Number.isSafeInteger(end) &&
    end >= start && end - start <= 45000 &&
    Number.isInteger(localHour) && localHour >= 0 && localHour <= 23;
}

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源閱讀紀錄請求。" }, 403);
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const db = getDatabase(env);
  if (!db) return json({ error: "Cloudflare D1 尚未綁定。" }, 503);

  let body;
  try { body = await request.json(); } catch (_) { return json({ error: "閱讀事件格式無效。" }, 400); }
  const events = Array.isArray(body && body.events) ? body.events : [];
  if (!events.length) return json({ accepted: 0, ignored: 0 });
  if (events.length > 100) return json({ error: "單次最多同步 100 筆閱讀事件。" }, 400);

  const valid = events.filter(validEvent);
  if (valid.length !== events.length) return json({ error: "部分閱讀事件欄位無效，這批資料未寫入。" }, 400);

  try {
    const statements = valid.map(event => db.prepare(
      "INSERT OR IGNORE INTO reading_events " +
      "(event_id, day_key, book_id, book_title, format, seconds, started_at, ended_at, local_hour, created_at) " +
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    ).bind(
      String(event.id),
      String(event.dayKey),
      String(event.bookId),
      String(event.bookTitle || "").slice(0, 240),
      String(event.format || "").toUpperCase().slice(0, 8),
      Number(event.seconds),
      Number(event.startedAt),
      Number(event.endedAt),
      Number(event.localHour),
      Date.now()
    ));
    const results = await db.batch(statements);
    const accepted = results.reduce((sum, result) => sum + (Number(result.meta && result.meta.changes) || 0), 0);
    return json({ accepted, ignored: valid.length - accepted });
  } catch (error) {
    return json({ error: "閱讀紀錄同步失敗：" + (error && error.message ? error.message : "D1 error") }, 503);
  }
}
