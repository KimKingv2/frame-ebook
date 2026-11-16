import {
  json, getDatabase, requireAuth, normalizePath, isWithinRoot, sha256Hex, getAccessIdentity
} from "./common.js";

export const READER_PROVIDERS = new Set(["vps", "worker", "mobile"]);
export const READER_LIBRARIES = new Set(["books", "comics"]);

export async function resolveReaderBook(db, raw) {
  const provider = String(raw && raw.provider || "");
  const library = String(raw && raw.library || "");
  const rootPath = normalizePath(raw && (raw.rootPath || raw.root_path));
  const path = normalizePath(raw && (raw.path || raw.bookPath));
  const bookId = String(raw && (raw.id || raw.bookId || raw.book_id) || "");

  if (!READER_PROVIDERS.has(provider) || !READER_LIBRARIES.has(library) ||
      !rootPath || !path || path === "/" || !isWithinRoot(path, rootPath) ||
      !/^cloud:[a-f0-9]{64}$/.test(bookId)) {
    return { error: json({ error: "雲端書籍識別資訊無效。" }, 400) };
  }

  const stripLeadingSlash = value => value.replace(/^\/+/, "");
  const identity = [provider, library, stripLeadingSlash(rootPath), stripLeadingSlash(path)].join("\\n");
  const expectedId = "cloud:" + await sha256Hex(identity);
  if (expectedId !== bookId) return { error: json({ error: "雲端書籍識別碼不相符。" }, 400) };

  const indexed = await db.prepare(
    "SELECT format FROM cloud_catalog WHERE provider=? AND library=? AND root_path=? AND path=? AND is_dir=0"
  ).bind(provider, library, rootPath, path).first();
  if (!indexed) return { error: json({ error: "這本書不在目前的 Alist／OpenList 書庫索引中。請先掃描書庫。" }, 404) };

  const format = String(indexed.format || "").toUpperCase();
  const validFormat = library === "books" ? format === "EPUB" : format === "EPUB" || format === "CBZ";
  if (!validFormat) return { error: json({ error: "這個檔案格式不屬於目前的書庫。" }, 415) };
  return { provider, library, rootPath, path, bookId, format };
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
    return { db, userId: identity.userId, book };
  } catch (error) {
    return { error: json({ error: "驗證雲端書籍失敗：" + String(error?.message || error).slice(0, 180) }, 503) };
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
