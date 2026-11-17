import { json, getDatabase, requireAuth, isSameOrigin, getAccessIdentity } from "../../_lib/common.js";

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
    /^cloud:[a-f0-9]{64}$/.test(bookId) &&
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
  if (!db || typeof db.prepare !== "function") return json({ error: "Cloudflare D1 尚未綁定。" }, 503);
  let identity;
  try { identity = await getAccessIdentity(request, env); }
  catch (error) { return json({ error: error?.message || "Cloudflare Access 身分驗證失敗。", }, error?.status || 503); }

  let body;
  try { body = await request.json(); } catch (_) { return json({ error: "閱讀事件格式無效。" }, 400); }
  const events = Array.isArray(body && body.events) ? body.events : [];
  if (!events.length) return json({ accepted: 0, ignored: 0 });
  if (events.length > 100) return json({ error: "單次最多寫入 100 筆閱讀事件。" }, 400);
  if (events.some(event => !validEvent(event))) return json({ error: "閱讀事件欄位無效，這批資料未寫入。" }, 400);

  try {
    const now = Date.now();
    const statements = events.flatMap(event => [
      db.prepare(
        "INSERT OR IGNORE INTO reader_reading_events " +
        "(user_id,event_id,day_key,book_id,book_title,format,seconds,started_at,ended_at,local_hour,created_at) " +
        "VALUES (?,?,?,?,?,?,?,?,?,?,?)"
      ).bind(
        identity.userId, String(event.id), String(event.dayKey), String(event.bookId),
        String(event.bookTitle || "").slice(0, 240), String(event.format || "").toUpperCase().slice(0, 8),
        Number(event.seconds), Number(event.startedAt), Number(event.endedAt), Number(event.localHour), now
      ),
      db.prepare(
        "INSERT INTO reader_sync_changes (user_id,entity_type,entity_id,operation,payload_json,created_at) " +
        "SELECT ?,'event',?,'upsert',?,? WHERE changes()>0"
      ).bind(identity.userId,String(event.id),JSON.stringify(event),now)
    ]);
    const results = await db.batch(statements);
    const accepted = results.filter((result,index) => index % 2 === 0)
      .reduce((sum, result) => sum + (Number(result.meta && result.meta.changes) || 0), 0);
    return json({ accepted, ignored: events.length - accepted });
  } catch (error) {
    return json({ error: "雲端閱讀紀錄寫入失敗：" + String(error?.message || error).slice(0, 180) }, 503);
  }
}
