import { json, requireAuth, isSameOrigin, getDatabase, getAccessIdentity } from "../../../_lib/common.js";
import { resolveReaderBook, readerBookIdForFilename } from "../../../_lib/reader-data.js";

const API = "https://api.bgm.tv/v0";
const USER_AGENT = "FRAME-Ebook/1.0 (+https://github.com/KimKingv2/frame-ebook)";

function clean(value, max = 1000) {
  return String(value == null ? "" : value).replace(/[\r\n\t]+/g, " ").trim().slice(0, max);
}

function infoboxText(infobox, keys) {
  if (!Array.isArray(infobox)) return "";
  const values = [];
  for (const item of infobox) {
    const key = clean(item?.key, 80).toLowerCase();
    if (!keys.some(candidate => key.includes(candidate))) continue;
    const rawValue = item?.value;
    const value = Array.isArray(rawValue)
      ? rawValue.map(part => {
          if (typeof part === "string" || typeof part === "number") return String(part);
          if (part && typeof part === "object") return [part.k, part.v].filter(Boolean).join("：");
          return "";
        }).filter(Boolean).join("、")
      : rawValue && typeof rawValue === "object"
        ? [rawValue.k, rawValue.v].filter(Boolean).join("：")
        : rawValue;
    const normalized = clean(value, 240);
    if (normalized && !values.includes(normalized)) values.push(normalized);
  }
  return values.join("、").slice(0, 600);
}

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源關聯 Bangumi 作品。" }, 403);
  const denied = await requireAuth(request, env);
  if (denied) return denied;
  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function" || typeof db.batch !== "function") {
    return json({ error: "FRAME_READER_DB 尚未正確綁定。" }, 503);
  }
  let identity;
  try {
    identity = await getAccessIdentity(request, env);
  } catch (error) {
    return json({ error: error?.message || "Cloudflare Access 身分驗證失敗。" }, error?.status || 503);
  }

  let body;
  try { body = await request.json(); } catch (_) { return json({ error: "Bangumi 關聯資料格式無效。" }, 400); }
  const subjectId = Number(body?.subjectId);
  if (!Number.isSafeInteger(subjectId) || subjectId < 1 || subjectId > 2147483647) {
    return json({ error: "Bangumi 作品 ID 無效。" }, 400);
  }

  try {
    const target = await resolveReaderBook(db, body?.book);
    if (target.error) return target.error;
    if (target.library !== "comics") return json({ error: "Bangumi 作品只能關聯到漫畫書架。" }, 400);

    const response = await fetch(API + "/subjects/" + subjectId, {
      headers: { "Accept": "application/json", "User-Agent": USER_AGENT }
    });
    if (!response.ok) return json({ error: "Bangumi 作品詳細資料回應 HTTP " + response.status + "。" }, 502);
    const subject = await response.json();
    if (Number(subject?.id) !== subjectId || Number(subject?.type) !== 1) {
      return json({ error: "選取的 Bangumi 條目不是有效的書籍類作品。" }, 400);
    }
    const bookCategory = Number(subject?.platform) || 0;
    if (bookCategory && bookCategory !== 1001) {
      return json({ error: "這個 Bangumi 條目屬於小說或其他書籍分類，不是漫畫。請選擇漫畫類條目。" }, 400);
    }

    const folderPath = target.path.slice(0, target.path.lastIndexOf("/")) || "/";
    let rows;
    if (folderPath === target.rootPath) {
      rows = [{ name: target.fileName }];
    } else {
      const result = await db.prepare(
        "SELECT name FROM cloud_catalog WHERE provider=? AND library='comics' AND root_path=? " +
        "AND parent_path=? AND is_dir=0 AND format IN ('CBZ','EPUB') ORDER BY path LIMIT 500"
      ).bind(target.provider, target.rootPath, folderPath).all();
      rows = result.results || [];
      if (!rows.some(row => row.name === target.fileName)) rows.push({ name: target.fileName });
    }
    const uniqueRows = [...new Map(rows.map(row => [String(row.name), row])).values()];
    const now = Date.now();
    const infobox = Array.isArray(subject.infobox) ? subject.infobox.slice(0, 60) : [];
    const tags = (Array.isArray(subject.tags) ? subject.tags : []).slice(0, 80)
      .map(tag => ({ name: clean(tag?.name, 100), count: Number(tag?.count) || 0 }))
      .filter(tag => tag.name);
    const metadata = {
      source: "Bangumi",
      subjectId,
      name: clean(subject.name, 240),
      nameCn: clean(subject.name_cn, 240),
      summary: clean(subject.summary, 8000),
      date: clean(subject.date, 80),
      platform: bookCategory === 1001 ? "漫畫" : clean(subject.platform, 120),
      image: clean(subject.images?.large || subject.images?.common || subject.images?.medium, 1000),
      score: Number(subject.rating?.score) || 0,
      ratingCount: Number(subject.rating?.total) || 0,
      rank: Number(subject.rank) || 0,
      author: infoboxText(infobox, ["作者", "原作", "漫畫", "作畫", "author"]),
      tags,
      infobox,
      url: "https://bgm.tv/subject/" + subjectId,
      fetchedAt: now
    };
    const serialized = JSON.stringify(metadata);
    if (serialized.length > 24000) return json({ error: "Bangumi 作品資料超過保存上限。" }, 413);

    const statements = [];
    for (const row of uniqueRows) {
      const bookId = await readerBookIdForFilename(row.name);
      statements.push(db.prepare(
        "INSERT INTO reader_comic_metadata (user_id,book_id,subject_id,metadata_json,source_url,fetched_at,updated_at) " +
        "VALUES (?,?,?,?,?,?,?) ON CONFLICT(user_id,book_id) DO UPDATE SET " +
        "subject_id=excluded.subject_id,metadata_json=excluded.metadata_json,source_url=excluded.source_url," +
        "fetched_at=excluded.fetched_at,updated_at=excluded.updated_at"
      ).bind(identity.userId, bookId, subjectId, serialized, metadata.url, now, now));
    }
    await db.batch(statements);
    return json({
      ok: true,
      subject: metadata,
      linkedBooks: uniqueRows.length,
      folderPath
    });
  } catch (error) {
    const message = clean(error?.message || error, 180);
    if (message.toLowerCase().includes("no such table: reader_comic_metadata")) {
      return json({ error: "漫畫資料表尚未建立，請先執行 migrations/0007_book_metadata_and_bangumi.sql。" }, 503);
    }
    return json({ error: "保存 Bangumi 作品資料失敗：" + message }, 503);
  }
}
