import { json, requireAuth, isSameOrigin } from "../../../_lib/common.js";

const API = "https://api.bgm.tv/v0";
const USER_AGENT = "FRAME-Ebook/1.0 (+https://github.com/KimKingv2/frame-ebook)";

function text(value, max = 240) {
  return String(value == null ? "" : value).replace(/[\r\n\t]+/g, " ").trim().slice(0, max);
}

export async function onRequestPost({ request }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源搜尋 Bangumi。" }, 403);
  const denied = await requireAuth(request);
  if (denied) return denied;
  let body;
  try { body = await request.json(); } catch (_) { return json({ error: "搜尋資料格式無效。" }, 400); }
  const keyword = text(body?.keyword, 100);
  if (keyword.length < 1) return json({ error: "請輸入漫畫名稱。" }, 400);

  try {
    const response = await fetch(API + "/search/subjects?limit=12", {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT
      },
      body: JSON.stringify({
        keyword,
        sort: "match",
        filter: { type: [1] }
      })
    });
    if (!response.ok) return json({ error: "Bangumi 搜尋服務回應 HTTP " + response.status + "。" }, 502);
    const payload = await response.json();
    const items = (Array.isArray(payload?.data) ? payload.data : []).map(item => ({
      id: Number(item.id) || 0,
      type: Number(item.type) || 0,
      name: text(item.name, 240),
      nameCn: text(item.name_cn, 240),
      summary: text(item.short_summary || item.summary, 500),
      date: text(item.date, 40),
      categoryLabel: "Bangumi 書籍候選",
      image: text(item.images?.medium || item.images?.common || item.images?.small, 1000),
      score: Number(item.rating?.score ?? item.score) || 0,
      ratingCount: Number(item.rating?.total) || 0,
      rank: Number(item.rank) || 0,
      tags: (Array.isArray(item.tags) ? item.tags : []).slice(0, 8)
        .map(tag => text(tag?.name, 60)).filter(Boolean)
    })).filter(item => item.id > 0 && item.type === 1);
    return json({ ok: true, keyword, items, total: Number(payload?.total) || items.length });
  } catch (error) {
    return json({ error: "連接 Bangumi 搜尋服務失敗：" + text(error?.message || error, 180) }, 502);
  }
}
