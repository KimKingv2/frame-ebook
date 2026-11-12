import { json, getDatabase, requireAuth } from "../../_lib/common.js";

function validDay(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(value || ""))) return false;
  const date = new Date(String(value) + "T00:00:00Z");
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

export async function onRequestGet({ request, env }) {
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const db = getDatabase(env);
  if (!db) return json({ error: "Cloudflare D1 尚未綁定。" }, 503);

  const url = new URL(request.url);
  const from = url.searchParams.get("from") || "";
  const to = url.searchParams.get("to") || "";
  if (!validDay(from) || !validDay(to) || from > to) {
    return json({ error: "統計日期範圍無效。" }, 400);
  }

  try {
    const [daysResult, allDaysResult, booksResult, booksCountResult, bandsResult, recentResult] = await Promise.all([
      db.prepare(
        "SELECT day_key AS dayKey, SUM(seconds) AS seconds " +
        "FROM reading_events WHERE day_key BETWEEN ? AND ? GROUP BY day_key ORDER BY day_key"
      ).bind(from, to).all(),
      db.prepare(
        "SELECT day_key AS dayKey, SUM(seconds) AS seconds " +
        "FROM reading_events GROUP BY day_key ORDER BY day_key"
      ).all(),
      db.prepare(
        "SELECT book_id AS bookId, MAX(book_title) AS title, SUM(seconds) AS seconds " +
        "FROM reading_events WHERE day_key BETWEEN ? AND ? GROUP BY book_id ORDER BY seconds DESC LIMIT 10"
      ).bind(from, to).all(),
      db.prepare(
        "SELECT COUNT(DISTINCT book_id) AS booksOpened FROM reading_events WHERE day_key BETWEEN ? AND ?"
      ).bind(from, to).first(),
      db.prepare(
        "SELECT " +
        "SUM(CASE WHEN local_hour >= 6 AND local_hour < 11 THEN seconds ELSE 0 END) AS morning, " +
        "SUM(CASE WHEN local_hour >= 11 AND local_hour < 17 THEN seconds ELSE 0 END) AS daytime, " +
        "SUM(CASE WHEN local_hour >= 17 AND local_hour < 23 THEN seconds ELSE 0 END) AS evening, " +
        "SUM(CASE WHEN local_hour < 6 OR local_hour >= 23 THEN seconds ELSE 0 END) AS night " +
        "FROM reading_events WHERE day_key BETWEEN ? AND ?"
      ).bind(from, to).first(),
      db.prepare(
        "SELECT book_id AS bookId, book_title AS bookTitle, format, day_key AS dayKey, " +
        "seconds, started_at AS startedAt, ended_at AS endedAt " +
        "FROM reading_events WHERE day_key BETWEEN ? AND ? ORDER BY ended_at DESC LIMIT 200"
      ).bind(from, to).all()
    ]);
    const days = daysResult.results || [];
    const totalSeconds = days.reduce((sum, row) => sum + (Number(row.seconds) || 0), 0);
    return json({
      from,
      to,
      totalSeconds,
      booksOpened: Number(booksCountResult && booksCountResult.booksOpened) || 0,
      days,
      allDays: allDaysResult.results || [],
      topBooks: booksResult.results || [],
      timeBands: [
        Number(bandsResult && bandsResult.morning) || 0,
        Number(bandsResult && bandsResult.daytime) || 0,
        Number(bandsResult && bandsResult.evening) || 0,
        Number(bandsResult && bandsResult.night) || 0
      ],
      recentEvents: recentResult.results || []
    });
  } catch (error) {
    return json({ error: "雲端統計讀取失敗：" + (error && error.message ? error.message : "D1 error") }, 503);
  }
}
