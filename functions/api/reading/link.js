import {
  json, getDatabase, requireAuth, isSameOrigin, getAccessIdentity
} from "../../_lib/common.js";
import {
  resolveReaderBook, migrateLegacyReaderBookIds, readerBookIdForFilename
} from "../../_lib/reader-data.js";

const ALIAS_SETTING = "system_book_aliases_v1";
const ID_PATTERN = /^cloud:[a-f0-9]{64}$/;

function fileNameFromPath(path) {
  return String(path || "").replace(/\\/g, "/").split("/").pop() || "";
}

function titleFromFileName(name) {
  return String(name || "").replace(/\\.(epub|cbz)$/i, "") || "未命名書籍";
}

function parseJson(value, fallback = {}) {
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : fallback;
  } catch (_) {
    return fallback;
  }
}

async function getContext(request, env) {
  const denied = await requireAuth(request, env);
  if (denied) return { error: denied };
  const db = getDatabase(env);
  if (!db || typeof db.prepare !== "function" || typeof db.batch !== "function") {
    return { error: json({ error: "FRAME_READER_DB 尚未正確綁定。" }, 503) };
  }
  let identity;
  try {
    identity = await getAccessIdentity(request, env);
  } catch (error) {
    return { error: json({ error: error?.message || "Cloudflare Access 身分驗證失敗。" }, error?.status || 503) };
  }
  return { db, userId: identity.userId };
}

async function readAliases(db, userId) {
  const row = await db.prepare(
    "SELECT value_json AS valueJson FROM reader_preferences WHERE user_id=? AND setting_key=?"
  ).bind(userId, ALIAS_SETTING).first();
  return parseJson(row?.valueJson, {});
}

async function getCurrentIds(db) {
  const result = await db.prepare(
    "SELECT name FROM cloud_catalog WHERE is_dir=0 AND provider IN ('vps','worker','mobile') " +
    "AND format IN ('EPUB','CBZ') LIMIT 50000"
  ).all();
  const ids = new Set();
  for (const row of result.results || []) {
    try { ids.add(await readerBookIdForFilename(row.name)); } catch (_) {}
  }
  return ids;
}

async function loadAnnotationGroups(db, userId) {
  try {
    const result = await db.prepare(
      "SELECT book_id AS bookId,MAX(book_path) AS path,COUNT(*) AS annotationCount " +
      "FROM reader_annotations WHERE user_id=? GROUP BY book_id"
    ).bind(userId).all();
    return result.results || [];
  } catch (error) {
    if (String(error?.message || error).toLowerCase().includes("no such table: reader_annotations")) return [];
    throw error;
  }
}

async function loadLinkableBooks(db, userId, targetBookId) {
  const [states, events, annotations, currentIds, aliases] = await Promise.all([
    db.prepare(
      "SELECT book_id AS bookId,provider,library,root_path AS rootPath,book_path AS path," +
      "state_json AS stateJson,updated_at AS updatedAt FROM reader_book_state WHERE user_id=?"
    ).bind(userId).all(),
    db.prepare(
      "SELECT book_id AS bookId,MAX(book_title) AS eventTitle,MAX(format) AS format," +
      "SUM(seconds) AS readingSeconds,MAX(ended_at) AS lastReadAt " +
      "FROM reader_reading_events WHERE user_id=? GROUP BY book_id"
    ).bind(userId).all(),
    loadAnnotationGroups(db, userId),
    getCurrentIds(db),
    readAliases(db, userId)
  ]);

  const items = new Map();
  const ensure = bookId => {
    if (!items.has(bookId)) items.set(bookId, {
      bookId, title: "", fileName: "", format: "", path: "",
      progress: 0, readingSeconds: 0, lastReadAt: 0, updatedAt: 0,
      annotationCount: 0, hasReadingState: false
    });
    return items.get(bookId);
  };

  for (const row of events.results || []) {
    const id = String(row.bookId || "");
    if (!ID_PATTERN.test(id)) continue;
    const item = ensure(id);
    item.eventTitle = String(row.eventTitle || "");
    item.readingSeconds = Number(row.readingSeconds) || 0;
    item.lastReadAt = Number(row.lastReadAt) || 0;
    if (!item.title && item.eventTitle) item.title = item.eventTitle;
    if (!item.format) item.format = String(row.format || "");
  }

  for (const row of states.results || []) {
    const id = String(row.bookId || "");
    if (!ID_PATTERN.test(id)) continue;
    const item = ensure(id);
    const name = fileNameFromPath(row.path);
    const state = parseJson(row.stateJson, {});
    const metadata = state.metadata || {};
    item.fileName = name;
    item.path = String(row.path || "");
    item.title = metadata.manualTitle && metadata.title
      ? String(metadata.title)
      : (String(metadata.title || "") || titleFromFileName(name));
    item.author = String(metadata.author || "");
    item.format = String(name.split(".").pop() || item.format).toUpperCase();
    item.progress = Math.max(0, Math.min(100, Number(state.progress?.percent) || 0));
    item.updatedAt = Number(row.updatedAt) || 0;
    item.lastOpenedAt = Number(state.lastOpenedAt) || 0;
    item.hasReadingState = true;
  }

  for (const row of annotations) {
    const id = String(row.bookId || "");
    if (!ID_PATTERN.test(id)) continue;
    const item = ensure(id);
    item.annotationCount = Number(row.annotationCount) || 0;
    if (!item.path) item.path = String(row.path || "");
    if (!item.fileName) item.fileName = fileNameFromPath(row.path);
    if (!item.title) item.title = titleFromFileName(item.fileName);
  }

  return [...items.values()]
    .filter(item => item.bookId !== targetBookId &&
      !currentIds.has(item.bookId) &&
      !Object.prototype.hasOwnProperty.call(aliases, item.bookId))
    .map(item => ({
      ...item,
      title: item.title || "未命名舊書籍",
      fileName: item.fileName || item.eventTitle || item.title,
      format: item.format || (item.fileName.toLowerCase().endsWith(".cbz") ? "CBZ" : "EPUB"),
      lastActivityAt: Math.max(item.lastOpenedAt || 0, item.lastReadAt || 0, item.updatedAt || 0)
    }))
    .sort((a, b) => b.lastActivityAt - a.lastActivityAt || a.title.localeCompare(b.title, "zh-Hant"))
    .slice(0, 200);
}

export async function onRequestGet({ request, env }) {
  const context = await getContext(request, env);
  if (context.error) return context.error;
  const url = new URL(request.url);
  try {
    const descriptor = {
      id: url.searchParams.get("book_id"),
      provider: url.searchParams.get("provider"),
      library: url.searchParams.get("library"),
      rootPath: url.searchParams.get("root_path"),
      path: url.searchParams.get("path")
    };
    const currentBook = await resolveReaderBook(context.db, descriptor);
    if (currentBook.error) return currentBook.error;
    await migrateLegacyReaderBookIds(context.db, context.userId);
    const candidates = await loadLinkableBooks(context.db, context.userId, currentBook.bookId);
    return json({ ok: true, target: {
      bookId: currentBook.bookId, fileName: currentBook.fileName, title: titleFromFileName(currentBook.fileName)
    }, candidates, count: candidates.length });
  } catch (error) {
    return json({ error: "讀取可關聯的舊書籍資料失敗：" + String(error?.message || error).slice(0, 180) }, 503);
  }
}

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源關聯書籍資料。" }, 403);
  const context = await getContext(request, env);
  if (context.error) return context.error;
  let body;
  try { body = await request.json(); } catch (_) { return json({ error: "關聯資料格式無效。" }, 400); }

  const oldBookId = String(body?.oldBookId || "");
  if (!ID_PATTERN.test(oldBookId)) return json({ error: "舊書籍識別碼無效。" }, 400);

  try {
    const target = await resolveReaderBook(context.db, body?.book);
    if (target.error) return target.error;
    const newBookId = target.bookId;
    if (oldBookId === newBookId) return json({ error: "新舊書籍已經是同一個身份，無需關聯。" }, 400);

    await migrateLegacyReaderBookIds(context.db, context.userId);
    const [currentIds, aliases, oldState, newState, eventRow] = await Promise.all([
      getCurrentIds(context.db),
      readAliases(context.db, context.userId),
      context.db.prepare(
        "SELECT state_json AS stateJson,created_at AS createdAt,updated_at AS updatedAt " +
        "FROM reader_book_state WHERE user_id=? AND book_id=?"
      ).bind(context.userId, oldBookId).first(),
      context.db.prepare(
        "SELECT state_json AS stateJson,created_at AS createdAt,updated_at AS updatedAt " +
        "FROM reader_book_state WHERE user_id=? AND book_id=?"
      ).bind(context.userId, newBookId).first(),
      context.db.prepare(
        "SELECT COUNT(*) AS total FROM reader_reading_events WHERE user_id=? AND book_id=?"
      ).bind(context.userId, oldBookId).first()
    ]);

    if (currentIds.has(oldBookId)) {
      return json({ error: "這筆舊資料對應的檔名目前仍存在於書庫索引中。為避免合併兩本不同的書，系統不允許關聯。" }, 409);
    }
    if (Object.prototype.hasOwnProperty.call(aliases, oldBookId)) {
      return json({ error: "這筆舊資料已經關聯過，請重新整理書架。" }, 409);
    }
    if (Object.prototype.hasOwnProperty.call(aliases, newBookId)) {
      return json({ error: "目前書籍已經是另一筆關聯的舊身份，請先處理該關聯。" }, 409);
    }

    let annotationCount = 0;
    let annotationTableAvailable = true;
    try {
      const annotationResult = await context.db.prepare(
        "SELECT COUNT(*) AS total FROM reader_annotations WHERE user_id=? AND book_id=?"
      ).bind(context.userId, oldBookId).first();
      annotationCount = Number(annotationResult?.total) || 0;
    } catch (error) {
      if (String(error?.message || error).toLowerCase().includes("no such table: reader_annotations")) {
        annotationTableAvailable = false;
      } else throw error;
    }

    const eventCount = Number(eventRow?.total) || 0;
    if (!oldState && !eventCount && !annotationCount) {
      return json({ error: "找不到這筆舊書籍的閱讀進度、閱讀紀錄或標註資料。" }, 404);
    }

    const statements = [];
    if (oldState) {
      const previous = parseJson(oldState.stateJson, {});
      const current = parseJson(newState?.stateJson, {});
      const oldUpdated = Number(oldState.updatedAt) || 0;
      const currentUpdated = Number(newState?.updatedAt) || 0;
      const newerProgress = oldUpdated > currentUpdated ? previous.progress : current.progress;
      const oldMetadata = previous.metadata || {};
      const currentMetadata = current.metadata || {};
      const mergedMetadata = { ...oldMetadata, ...currentMetadata };
      for (const key of ["title", "author"]) {
        const manualKey = key === "title" ? "manualTitle" : "manualAuthor";
        if (!currentMetadata[manualKey] && oldMetadata[manualKey] && oldMetadata[key]) {
          mergedMetadata[key] = oldMetadata[key];
          mergedMetadata[manualKey] = true;
        }
      }
      const merged = {
        ...previous,
        ...current,
        ...(previous.appearance || current.appearance
          ? { appearance: { ...(previous.appearance || {}), ...(current.appearance || {}) } } : {}),
        ...(previous.metadata || current.metadata ? { metadata: mergedMetadata } : {}),
        ...(newerProgress ? { progress: newerProgress } : {}),
        lastOpenedAt: Math.max(Number(previous.lastOpenedAt) || 0, Number(current.lastOpenedAt) || 0)
      };
      statements.push(context.db.prepare(
        "INSERT INTO reader_book_state " +
        "(user_id,book_id,provider,library,root_path,book_path,state_json,created_at,updated_at) " +
        "VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(user_id,book_id) DO UPDATE SET " +
        "provider=excluded.provider,library=excluded.library,root_path=excluded.root_path,book_path=excluded.book_path," +
        "state_json=excluded.state_json,created_at=MIN(reader_book_state.created_at,excluded.created_at)," +
        "updated_at=MAX(reader_book_state.updated_at,excluded.updated_at)"
      ).bind(
        context.userId, newBookId, target.provider, target.library, target.rootPath, target.path,
        JSON.stringify(merged), Math.min(Number(oldState.createdAt) || Date.now(), Number(newState?.createdAt) || Date.now()),
        Math.max(oldUpdated, currentUpdated, Date.now())
      ));
      statements.push(context.db.prepare(
        "DELETE FROM reader_book_state WHERE user_id=? AND book_id=?"
      ).bind(context.userId, oldBookId));
    }

    if (annotationTableAvailable && annotationCount > 0) {
      statements.push(context.db.prepare(
        "INSERT OR IGNORE INTO reader_annotations " +
        "(user_id,book_id,annotation_id,provider,library,root_path,book_path,type,cfi,quote,note_text,color,created_at,updated_at) " +
        "SELECT user_id,?,annotation_id,?, ?, ?, ?,type,cfi,quote,note_text,color,created_at,updated_at " +
        "FROM reader_annotations WHERE user_id=? AND book_id=?"
      ).bind(newBookId, target.provider, target.library, target.rootPath, target.path, context.userId, oldBookId));
      statements.push(context.db.prepare(
        "DELETE FROM reader_annotations WHERE user_id=? AND book_id=?"
      ).bind(context.userId, oldBookId));
    }

    statements.push(context.db.prepare(
      "UPDATE reader_reading_events SET book_id=?,book_title=? WHERE user_id=? AND book_id=?"
    ).bind(newBookId, titleFromFileName(target.fileName), context.userId, oldBookId));

    const nextAliases = { ...aliases };
    for (const [aliasId, destination] of Object.entries(nextAliases)) {
      if (destination === oldBookId) nextAliases[aliasId] = newBookId;
    }
    nextAliases[oldBookId] = newBookId;
    const aliasesJson = JSON.stringify(nextAliases);
    if (aliasesJson.length > 90000) return json({ error: "書籍關聯紀錄已達保存上限，請先整理既有關聯。" }, 413);
    statements.push(context.db.prepare(
      "INSERT INTO reader_preferences (user_id,setting_key,value_json,updated_at) VALUES (?,?,?,?) " +
      "ON CONFLICT(user_id,setting_key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at"
    ).bind(context.userId, ALIAS_SETTING, aliasesJson, Date.now()));

    const results = await context.db.batch(statements);
    return json({
      ok: true,
      oldBookId, newBookId,
      moved: {
        readingState: oldState ? 1 : 0,
        annotations: annotationTableAvailable ? annotationCount : 0,
        readingEvents: eventCount
      },
      note: annotationTableAvailable ? "" : "目前 D1 尚未建立標註資料表，因此只合併了可用的閱讀資料。"
    });
  } catch (error) {
    return json({ error: "關聯舊書籍資料失敗：" + String(error?.message || error).slice(0, 180) }, 503);
  }
}
