import {
  json, getDatabase, requireAuth, normalizePath, isWithinRoot, sha256Hex, getAccessIdentity
} from "./common.js";

export const READER_PROVIDERS = new Set(["vps", "worker", "mobile"]);
export const READER_LIBRARIES = new Set(["books", "comics"]);
const IDENTITY_MIGRATION_KEY = "system_book_identity_filename_v1";

function stripLeadingSlash(value) {
  return String(value || "").replace(/^\/+/, "");
}

export function normalizeBookFileName(value) {
  let name = String(value == null ? "" : value).trim();
  try { name = name.normalize("NFC"); } catch (_) {}
  return name;
}

export async function readerBookIdForFilename(value) {
  const name = normalizeBookFileName(value);
  if (!name || name.includes("/") || name.includes("\\") || name.includes("\0")) {
    throw new Error("書籍檔名無效，無法生成 Book ID。");
  }
  return "cloud:" + await sha256Hex(name);
}

async function legacyPathBookId(provider, library, rootPath, path) {
  const identity = [
    String(provider || ""),
    String(library || ""),
    stripLeadingSlash(rootPath),
    stripLeadingSlash(path)
  ].join("\\n");
  return "cloud:" + await sha256Hex(identity);
}

function fileNameFromPath(path) {
  return normalizeBookFileName(String(path || "").replace(/\\/g, "/").split("/").pop());
}

async function addLegacyIdentity(mapping, descriptor) {
  const provider = String(descriptor && descriptor.provider || "");
  const library = String(descriptor && descriptor.library || "");
  const rootPath = normalizePath(descriptor && descriptor.rootPath);
  const path = normalizePath(descriptor && descriptor.path);
  const fileName = normalizeBookFileName(descriptor && descriptor.name || fileNameFromPath(path));
  if (!READER_PROVIDERS.has(provider) || !READER_LIBRARIES.has(library) ||
      !rootPath || !path || path === "/" || !fileName ||
      !/\.(epub|cbz)$/i.test(fileName)) return;
  const oldId = await legacyPathBookId(provider, library, rootPath, path);
  const newId = await readerBookIdForFilename(fileName);
  if (oldId === newId) return;
  const existing = mapping.get(oldId);
  if (existing && existing !== newId) {
    mapping.delete(oldId);
    return;
  }
  if (!mapping.has(oldId)) mapping.set(oldId, newId);
}

/**
 * One-time, per-Access-user migration from path-derived IDs to filename-derived IDs.
 * Progress, annotations and reading events keep their existing contents.
 */
export async function migrateLegacyReaderBookIds(db, userId) {
  const marker = await db.prepare(
    "SELECT value_json AS valueJson FROM reader_preferences WHERE user_id=? AND setting_key=?"
  ).bind(userId, IDENTITY_MIGRATION_KEY).first();
  if (marker && marker.valueJson === '"done"') return false;

  const [catalogResult, stateResult] = await Promise.all([
    db.prepare(
      "SELECT provider,library,root_path AS rootPath,path,name FROM cloud_catalog " +
      "WHERE is_dir=0 AND provider IN ('vps','worker','mobile') " +
      "AND format IN ('EPUB','CBZ') LIMIT 50000"
    ).all(),
    db.prepare(
      "SELECT book_id AS bookId,provider,library,root_path AS rootPath,book_path AS path," +
      "state_json AS stateJson,created_at AS createdAt,updated_at AS updatedAt " +
      "FROM reader_book_state WHERE user_id=?"
    ).bind(userId).all()
  ]);

  // Annotation support is optional in some older Production D1 databases.
  // A missing table must not prevent the cloud bookshelf from loading.
  let annotationRows = [];
  try {
    const annotationResult = await db.prepare(
      "SELECT DISTINCT book_id AS bookId,provider,library,root_path AS rootPath,book_path AS path " +
      "FROM reader_annotations WHERE user_id=?"
    ).bind(userId).all();
    annotationRows = annotationResult.results || [];
  } catch (error) {
    const message = String(error?.message || error);
    if (!/no such table:\\s*reader_annotations/i.test(message)) throw error;
  }

  const mapping = new Map();
  for (const row of catalogResult.results || []) await addLegacyIdentity(mapping, row);
  for (const row of stateResult.results || []) await addLegacyIdentity(mapping, row);
  for (const row of annotationRows) await addLegacyIdentity(mapping, row);

  const statements = [];
  const legacyStates = (stateResult.results || [])
    .filter(row => mapping.has(String(row.bookId)))
    .sort((a, b) => (Number(a.updatedAt) || 0) - (Number(b.updatedAt) || 0));

  for (const row of legacyStates) {
    const nextId = mapping.get(String(row.bookId));
    if (!nextId) continue;
    statements.push(db.prepare(
      "INSERT INTO reader_book_state " +
      "(user_id,book_id,provider,library,root_path,book_path,state_json,created_at,updated_at) " +
      "VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(user_id,book_id) DO UPDATE SET " +
      "provider=CASE WHEN excluded.updated_at>=reader_book_state.updated_at THEN excluded.provider ELSE reader_book_state.provider END," +
      "library=CASE WHEN excluded.updated_at>=reader_book_state.updated_at THEN excluded.library ELSE reader_book_state.library END," +
      "root_path=CASE WHEN excluded.updated_at>=reader_book_state.updated_at THEN excluded.root_path ELSE reader_book_state.root_path END," +
      "book_path=CASE WHEN excluded.updated_at>=reader_book_state.updated_at THEN excluded.book_path ELSE reader_book_state.book_path END," +
      "state_json=CASE WHEN excluded.updated_at>=reader_book_state.updated_at THEN excluded.state_json ELSE reader_book_state.state_json END," +
      "created_at=MIN(reader_book_state.created_at,excluded.created_at)," +
      "updated_at=MAX(reader_book_state.updated_at,excluded.updated_at)"
    ).bind(
      userId, nextId, row.provider, row.library, row.rootPath, row.path,
      row.stateJson || "{}", Number(row.createdAt) || Date.now(), Number(row.updatedAt) || 0
    ));
    statements.push(db.prepare(
      "DELETE FROM reader_book_state WHERE user_id=? AND book_id=?"
    ).bind(userId, row.bookId));
  }

  const legacyAnnotationIds = [...new Set(annotationRows
    .map(row => String(row.bookId))
    .filter(bookId => mapping.has(bookId)))];
  for (const oldId of legacyAnnotationIds) {
    const nextId = mapping.get(oldId);
    statements.push(db.prepare(
      "INSERT OR IGNORE INTO reader_annotations " +
      "(user_id,book_id,annotation_id,provider,library,root_path,book_path,type,cfi,quote,note_text,color,created_at,updated_at) " +
      "SELECT user_id,?,annotation_id,provider,library,root_path,book_path,type,cfi,quote,note_text,color,created_at,updated_at " +
      "FROM reader_annotations WHERE user_id=? AND book_id=?"
    ).bind(nextId, userId, oldId));
    statements.push(db.prepare(
      "DELETE FROM reader_annotations WHERE user_id=? AND book_id=?"
    ).bind(userId, oldId));
  }

  for (const [oldId, nextId] of mapping) {
    statements.push(db.prepare(
      "UPDATE reader_reading_events SET book_id=? WHERE user_id=? AND book_id=?"
    ).bind(nextId, userId, oldId));
  }

  statements.push(db.prepare(
    "INSERT INTO reader_preferences (user_id,setting_key,value_json,updated_at) VALUES (?,?,?,?) " +
    "ON CONFLICT(user_id,setting_key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at"
  ).bind(userId, IDENTITY_MIGRATION_KEY, '"done"', Date.now()));

  for (let index = 0; index < statements.length; index += 80) {
    await db.batch(statements.slice(index, index + 80));
  }
  return true;
}

export async function resolveReaderBook(db, raw) {
  const provider = String(raw && raw.provider || "");
  const library = String(raw && raw.library || "");
  const rootPath = normalizePath(raw && (raw.rootPath || raw.root_path));
  const path = normalizePath(raw && (raw.path || raw.bookPath));
  const suppliedBookId = String(raw && (raw.id || raw.bookId || raw.book_id) || "");

  if (!READER_PROVIDERS.has(provider) || !READER_LIBRARIES.has(library) ||
      !rootPath || !path || path === "/" || !isWithinRoot(path, rootPath) ||
      !/^cloud:[a-f0-9]{64}$/.test(suppliedBookId)) {
    return { error: json({ error: "雲端書籍識別資訊無效。" }, 400) };
  }

  const indexed = await db.prepare(
    "SELECT name,format FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND path=? AND is_dir=0"
  ).bind(provider, library, rootPath, path).first();
  if (!indexed) return { error: json({ error: "這本書不在目前的 Alist／OpenList 書庫索引中。請先掃描書庫。" }, 404) };

  const format = String(indexed.format || "").toUpperCase();
  const validFormat = library === "books" ? format === "EPUB" : format === "EPUB" || format === "CBZ";
  if (!validFormat) return { error: json({ error: "這個檔案格式不屬於目前的書庫。" }, 415) };

  const expectedId = await readerBookIdForFilename(indexed.name);
  const legacyId = await legacyPathBookId(provider, library, rootPath, path);
  if (suppliedBookId !== expectedId && suppliedBookId !== legacyId) {
    return { error: json({ error: "雲端書籍識別碼不相符。" }, 400) };
  }
  return {
    provider, library, rootPath, path, bookId: expectedId,
    fileName: normalizeBookFileName(indexed.name), format
  };
}

export async function getReaderContext(request, env, rawBook) {
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
    return { error: json({ error: error?.message || "Cloudflare Access 身分驗證失敗。", }, error?.status || 503) };
  }
  try {
    const book = await resolveReaderBook(db, rawBook);
    if (book.error) return book;
    await migrateLegacyReaderBookIds(db, identity.userId);
    return { db, userId: identity.userId, book };
  } catch (error) {
    return { error: json({ error: "驗證或遷移雲端書籍資料失敗：" + String(error?.message || error).slice(0, 180) }, 503) };
  }
}

export function requestBookDescriptor(url) {
  return {
    id: url.searchParams.get("book_id") || url.searchParams.get("book"),
    provider: url.searchParams.get("provider"),
    library: url.searchParams.get("library"),
    rootPath: url.searchParams.get("root_path"),
    path: url.searchParams.get("path")
  };
}
