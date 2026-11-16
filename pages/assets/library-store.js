/* FRAME Reader cloud-only data client.
 * Persistent library state is stored in D1/R2 and original archives remain in Alist/OpenList.
 * The browser keeps only short-lived in-memory objects needed by the active page.
 */
const bookCache = new Map();
let preferenceCache = null;
let preferencePromise = null;

async function readJson(response, fallback) {
  let data = {};
  try { data = await response.json(); } catch (_) {}
  if (!response.ok || data?.ok === false || data?.error) {
    throw new Error(String(data?.error || fallback || ("HTTP " + response.status)));
  }
  return data;
}

async function api(path, options = {}, fallback = "雲端資料讀取失敗。") {
  const response = await fetch(path, {
    credentials: "same-origin",
    cache: "no-store",
    ...options,
    headers: { ...(options.headers || {}) }
  });
  return readJson(response, fallback);
}

function normalizeDescriptor(book) {
  const source = book?.cloudSource || book?.source || book || {};
  const descriptor = {
    id: String(book?.id || source?.id || ""),
    provider: String(source?.provider || book?.provider || ""),
    library: String(source?.library || book?.library || book?.shelf || ""),
    rootPath: String(source?.rootPath || source?.root_path || book?.rootPath || ""),
    path: String(source?.path || source?.bookPath || book?.path || "")
  };
  if (!descriptor.id || !descriptor.provider || !descriptor.library || !descriptor.rootPath || !descriptor.path) {
    throw new Error("缺少有效的 Alist／OpenList 雲端書籍識別資訊。請返回書架重新開啟。");
  }
  return descriptor;
}

function descriptorQuery(book) {
  const d = normalizeDescriptor(book);
  return new URLSearchParams({
    book_id: d.id,
    provider: d.provider,
    library: d.library,
    root_path: d.rootPath,
    path: d.path
  });
}

function remember(book) {
  if (book?.id) bookCache.set(String(book.id), book);
  return book;
}

async function cloudBookId(scope, path) {
  const provider = String(scope?.provider || "");
  const library = String(scope?.library || "");
  const rootPath = String(scope?.rootPath || "").replace(/\\/g, "/").replace(/^\\/+|\\/+$/g, "");
  const filePath = String(path || "").replace(/\\/g, "/").replace(/^\\/+|\\/+$/g, "");
  if (!["vps", "worker", "mobile"].includes(provider) || !["books", "comics"].includes(library) || !rootPath || !filePath) {
    throw new Error("雲端書籍識別資訊無效。");
  }
  const identity = [provider, library, rootPath, filePath].join("\\n");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(identity));
  const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
  return "cloud:" + hash;
}

async function listBooks() {
  const data = await api("/api/reading/bookshelf", {}, "無法讀取雲端書架。");
  const items = Array.isArray(data.items) ? data.items : [];
  items.forEach(remember);
  return items;
}

async function getBook(bookOrId) {
  if (bookOrId && typeof bookOrId === "object") {
    const descriptor = normalizeDescriptor(bookOrId);
    const query = descriptorQuery(bookOrId);
    const data = await api("/api/reading/state?" + query.toString(), {}, "無法讀取這本書的雲端閱讀資料。");
    const base = bookCache.get(descriptor.id) || {
      id: descriptor.id,
      sourceType: "cloud",
      provider: descriptor.provider,
      library: descriptor.library,
      rootPath: descriptor.rootPath,
      path: descriptor.path,
      fileName: descriptor.path.split("/").pop(),
      title: descriptor.path.split("/").pop()?.replace(/\\.(epub|cbz)$/i, "") || "未命名書籍",
      author: "",
      format: descriptor.path.toLowerCase().endsWith(".cbz") ? "CBZ" : "EPUB",
      shelf: descriptor.library,
      size: 0,
      progress: { percent: 0, label: "尚未閱讀", cfi: "", index: null },
      cloudSource: {
        provider: descriptor.provider,
        library: descriptor.library,
        rootPath: descriptor.rootPath,
        path: descriptor.path
      }
    };
    const remote = data.state || {};
    const metadata = remote.metadata || {};
    return remember({
      ...base,
      ...metadata,
      id: descriptor.id,
      sourceType: "cloud",
      progress: remote.progress || base.progress,
      appearance: remote.appearance || {},
      lastOpenedAt: Number(remote.lastOpenedAt) || 0,
      manualTitle: !!metadata.manualTitle,
      manualAuthor: !!metadata.manualAuthor,
      cloudSource: {
        provider: descriptor.provider,
        library: descriptor.library,
        rootPath: descriptor.rootPath,
        path: descriptor.path
      }
    });
  }
  return bookCache.get(String(bookOrId || "")) || null;
}

async function updateBook(id, patch = {}) {
  const book = await getBook(String(id));
  if (!book) throw new Error("找不到這本雲端書籍，請返回書架重新載入。");
  const payload = {};
  if (patch.progress) payload.progress = { ...(book.progress || {}), ...patch.progress };
  if (patch.appearance) payload.appearance = { ...(book.appearance || {}), ...patch.appearance };
  if (patch.lastOpenedAt != null) payload.lastOpenedAt = Number(patch.lastOpenedAt) || Date.now();
  const metadataKeys = ["title", "author", "shelf", "manualTitle", "manualAuthor", "language", "pageCount"];
  if (metadataKeys.some(key => Object.prototype.hasOwnProperty.call(patch, key))) {
    payload.metadata = {};
    metadataKeys.forEach(key => {
      if (Object.prototype.hasOwnProperty.call(patch, key)) payload.metadata[key] = patch[key];
      else if (Object.prototype.hasOwnProperty.call(book, key)) payload.metadata[key] = book[key];
    });
  }
  const descriptor = normalizeDescriptor(book);
  const result = await api("/api/reading/state", {
    method: "POST",
    keepalive: true,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      book: descriptor,
      state: payload
    })
  }, "雲端閱讀資料保存失敗。");
  const remote = result.state || {};
  const updated = {
    ...book,
    ...(remote.metadata || {}),
    progress: remote.progress || book.progress,
    appearance: remote.appearance || book.appearance || {},
    lastOpenedAt: Number(remote.lastOpenedAt) || book.lastOpenedAt || 0
  };
  return remember(updated);
}

async function saveAnnotation(annotation) {
  const book = await getBook(String(annotation?.bookId || ""));
  if (!book) throw new Error("找不到這本雲端書籍，無法保存標註。");
  const record = {
    id: String(annotation.id || (crypto.randomUUID ? crypto.randomUUID() : "ann-" + Date.now())),
    bookId: book.id,
    type: ["highlight", "note", "bookmark"].includes(annotation.type) ? annotation.type : "note",
    cfi: String(annotation.cfi || "").slice(0, 4000),
    quote: String(annotation.quote || "").slice(0, 12000),
    text: String(annotation.text || "").slice(0, 20000),
    color: String(annotation.color || "yellow").slice(0, 32),
    createdAt: Number(annotation.createdAt) || Date.now()
  };
  const data = await api("/api/reading/annotations", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ book: normalizeDescriptor(book), annotation: record })
  }, "雲端標註保存失敗。");
  return data.annotation;
}

async function listAnnotations(bookId) {
  const book = await getBook(String(bookId || ""));
  if (!book) throw new Error("找不到這本雲端書籍，無法讀取標註。");
  const query = descriptorQuery(book);
  const data = await api("/api/reading/annotations?" + query.toString(), {}, "雲端標註讀取失敗。");
  return Array.isArray(data.annotations) ? data.annotations : [];
}

async function deleteAnnotation(id, bookId) {
  const book = await getBook(String(bookId || ""));
  if (!book) throw new Error("找不到這本雲端書籍，無法刪除標註。");
  await api("/api/reading/annotations", {
    method: "DELETE",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ book: normalizeDescriptor(book), id: String(id || "") })
  }, "雲端標註刪除失敗。");
  return true;
}

function localDayKey(timestamp) {
  const date = new Date(Number(timestamp) || Date.now());
  return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, "0"), String(date.getDate()).padStart(2, "0")].join("-");
}

async function recordReadingEvent(event) {
  if (!event || !event.id || !event.dayKey || !String(event.bookId || "").startsWith("cloud:")) return false;
  const result = await api("/api/reading/events", {
    method: "POST",
    keepalive: true,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ events: [event] })
  }, "雲端閱讀紀錄保存失敗。");
  return Number(result.accepted || 0) > 0;
}

async function getReadingEvents(fromDay, toDay) {
  const query = new URLSearchParams({
    from: String(fromDay),
    to: String(toDay),
    include_events: "1"
  });
  const data = await api("/api/reading/stats?" + query.toString(), {}, "讀取雲端閱讀紀錄失敗。");
  return Array.isArray(data.events) ? data.events : [];
}

async function getReadingSetting(key, fallback = null) {
  if (!preferenceCache) {
    if (!preferencePromise) {
      preferencePromise = api("/api/reading/preferences", {}, "讀取雲端偏好設定失敗。")
        .then(data => { preferenceCache = data.preferences || {}; return preferenceCache; })
        .finally(() => { preferencePromise = null; });
    }
    await preferencePromise;
  }
  return Object.prototype.hasOwnProperty.call(preferenceCache, key) ? preferenceCache[key] : fallback;
}

async function setReadingSetting(key, value) {
  const data = await api("/api/reading/preferences", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ key, value })
  }, "保存雲端偏好設定失敗。");
  preferenceCache = { ...(preferenceCache || {}), [key]: data.value };
  return data.value;
}

function importBookFile() {
  return Promise.reject(new Error("已停用本機匯入。請先在「連接與掃描」選擇 Alist／OpenList 來源並掃描索引。"));
}
function deleteBook() {
  return Promise.reject(new Error("雲端書籍請在 Alist／OpenList 管理原始檔案，書架會在下次掃描後自動更新。"));
}
function getPendingReadingEvents() { return Promise.resolve([]); }
function markReadingEventsSynced() { return Promise.resolve(0); }
function openDatabase() { return Promise.reject(new Error("FRAME Reader 已改為雲端資料模式，不再使用瀏覽器 IndexedDB。")); }

export {
  openDatabase, importBookFile, getBook, updateBook, deleteBook, listBooks,
  cloudBookId, saveAnnotation, listAnnotations, deleteAnnotation, localDayKey,
  recordReadingEvent, getReadingEvents, getPendingReadingEvents,
  markReadingEventsSynced, getReadingSetting, setReadingSetting
};
