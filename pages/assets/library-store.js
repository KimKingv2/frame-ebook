/* FRAME Reader cloud-only data client.
 * Persistent library state is stored in D1/R2 and original archives remain in Alist/OpenList.
 * The browser keeps only short-lived in-memory objects needed by the active page.
 */
const bookCache = new Map();


const LOCAL_DB_NAME = "frame-ebook-macos";
const LOCAL_DB_VERSION = 1;
function isLocalMacApp() {
  return typeof window !== "undefined" && window.FRAME_LOCAL_APP === true;
}
function openLocalDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(LOCAL_DB_NAME, LOCAL_DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("books")) db.createObjectStore("books", { keyPath: "id" });
      if (!db.objectStoreNames.contains("states")) db.createObjectStore("states", { keyPath: "id" });
      if (!db.objectStoreNames.contains("annotations")) db.createObjectStore("annotations", { keyPath: "key" });
      if (!db.objectStoreNames.contains("events")) db.createObjectStore("events", { keyPath: "id" });
      if (!db.objectStoreNames.contains("preferences")) db.createObjectStore("preferences", { keyPath: "key" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(new Error("無法開啟 Mac 本機閱讀資料庫：" + (request.error?.message || "IndexedDB error")));
  });
}
function localTransaction(db, stores, mode, execute) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(stores, mode);
    let result;
    let hasResult = false;
    const setResult = value => { result = value; hasResult = true; };
    transaction.oncomplete = () => resolve(hasResult ? result : undefined);
    transaction.onerror = () => reject(new Error("Mac 本機資料儲存失敗：" + (transaction.error?.message || "IndexedDB transaction error")));
    transaction.onabort = () => reject(new Error("Mac 本機資料交易已中止。"));
    try { execute(transaction, setResult); }
    catch (error) { try { transaction.abort(); } catch (_) {} reject(error); }
  });
}
function localApi(path, options = {}) {
  return openLocalDatabase().then(db => {
    const url = new URL(path, window.location.href);
    const method = String(options.method || "GET").toUpperCase();
    let body = {};
    try { body = options.body ? JSON.parse(options.body) : {}; } catch (_) {}
    const pathname = url.pathname;

    if (pathname === "/api/reading/bookshelf" && method === "GET") {
      return localTransaction(db, ["books"], "readonly", (tx, set) => {
        const request = tx.objectStore("books").getAll();
        request.onsuccess = () => {
          const items = (request.result || []).sort((a, b) =>
            (Number(b.lastOpenedAt) || 0) - (Number(a.lastOpenedAt) || 0));
          set({ items });
        };
      });
    }
    if (pathname === "/api/reading/state" && method === "GET") {
      const id = String(url.searchParams.get("book_id") || "");
      return localTransaction(db, ["states"], "readonly", (tx, set) => {
        const request = tx.objectStore("states").get(id);
        request.onsuccess = () => set({ state: request.result?.state || {} });
      });
    }
    if (pathname === "/api/reading/state" && method === "POST") {
      const id = String(body.book && body.book.id || "");
      if (!id) return Promise.reject(new Error("本機閱讀資料缺少書籍識別碼。"));
      return localTransaction(db, ["states", "books"], "readwrite", (tx, set) => {
        const states = tx.objectStore("states");
        const books = tx.objectStore("books");
        const stateRequest = states.get(id);
        const bookRequest = books.get(id);
        let stateReady = false;
        let bookReady = false;
        let previous = {};
        let book = null;
        const save = () => {
          if (!stateReady || !bookReady) return;
          const patch = body.state || {};
          const state = {
            ...previous, ...patch,
            progress: { ...(previous.progress || {}), ...(patch.progress || {}) },
            appearance: { ...(previous.appearance || {}), ...(patch.appearance || {}) },
            metadata: { ...(previous.metadata || {}), ...(patch.metadata || {}) }
          };
          states.put({ id, state });
          if (book) {
            books.put({
              ...book,
              ...(state.metadata || {}),
              progress: state.progress || book.progress,
              appearance: state.appearance || book.appearance,
              lastOpenedAt: Number(state.lastOpenedAt) || book.lastOpenedAt || 0
            });
          }
          set({ state });
        };
        stateRequest.onsuccess = () => { previous = stateRequest.result?.state || {}; stateReady = true; save(); };
        bookRequest.onsuccess = () => { book = bookRequest.result || null; bookReady = true; save(); };
      });
    }
    if (pathname === "/api/reading/annotations" && method === "GET") {
      const bookId = String(url.searchParams.get("book_id") || "");
      return localTransaction(db, ["annotations"], "readonly", (tx, set) => {
        const request = tx.objectStore("annotations").getAll();
        request.onsuccess = () => set({
          annotations: (request.result || []).filter(item => item.bookId === bookId)
            .map(({ key, ...annotation }) => annotation)
        });
      });
    }
    if (pathname === "/api/reading/annotations" && method === "POST") {
      const annotation = body.annotation || {};
      const bookId = String(body.book && body.book.id || annotation.bookId || "");
      if (!bookId || !annotation.id) return Promise.reject(new Error("本機標註缺少必要識別資訊。"));
      const next = { ...annotation, bookId, key: bookId + "::" + String(annotation.id) };
      return localTransaction(db, ["annotations"], "readwrite", (tx, set) => {
        tx.objectStore("annotations").put(next);
        const { key, ...saved } = next;
        set({ annotation: saved });
      });
    }
    if (pathname === "/api/reading/annotations" && method === "DELETE") {
      const bookId = String(body.book && body.book.id || "");
      const id = String(body.id || "");
      return localTransaction(db, ["annotations"], "readwrite", (tx, set) => {
        tx.objectStore("annotations").delete(bookId + "::" + id);
        set({ ok: true });
      });
    }
    if (pathname === "/api/reading/events" && method === "POST") {
      const incoming = Array.isArray(body.events) ? body.events : [];
      return localTransaction(db, ["events"], "readwrite", (tx, set) => {
        const events = tx.objectStore("events");
        let accepted = 0;
        let remaining = incoming.length;
        if (!remaining) { set({ accepted: 0 }); return; }
        incoming.forEach(event => {
          if (!event || !event.id) { remaining--; if (!remaining) set({ accepted }); return; }
          const request = events.get(String(event.id));
          request.onsuccess = () => {
            if (!request.result) { events.put(event); accepted++; }
            remaining--;
            if (!remaining) set({ accepted });
          };
          request.onerror = () => { remaining--; if (!remaining) set({ accepted }); };
        });
      });
    }
    if (pathname === "/api/reading/stats" && method === "GET") {
      const from = String(url.searchParams.get("from") || "");
      const to = String(url.searchParams.get("to") || "");
      return localTransaction(db, ["events"], "readonly", (tx, set) => {
        const request = tx.objectStore("events").getAll();
        request.onsuccess = () => set({
          events: (request.result || []).filter(item =>
            String(item.dayKey || "") >= from && String(item.dayKey || "") <= to)
        });
      });
    }
    if (pathname === "/api/reading/preferences" && method === "GET") {
      return localTransaction(db, ["preferences"], "readonly", (tx, set) => {
        const request = tx.objectStore("preferences").getAll();
        request.onsuccess = () => {
          const preferences = {};
          (request.result || []).forEach(item => { preferences[item.key] = item.value; });
          set({ preferences });
        };
      });
    }
    if (pathname === "/api/reading/preferences" && method === "POST") {
      const key = String(body.key || "");
      if (!key) return Promise.reject(new Error("本機偏好設定缺少欄位名稱。"));
      return localTransaction(db, ["preferences"], "readwrite", (tx, set) => {
        tx.objectStore("preferences").put({ key, value: body.value });
        set({ value: body.value });
      });
    }
    return Promise.reject(new Error("Mac 本機模式尚未實作這項資料操作：" + pathname));
  });
}

async function readJson(response, fallback) {
  let data = {};
  try { data = await response.json(); } catch (_) {}
  if (!response.ok || data?.ok === false || data?.error) {
    throw new Error(String(data?.error || fallback || ("HTTP " + response.status)));
  }
  return data;
}

async function api(path, options = {}, fallback = "雲端資料讀取失敗。") {
  if (isLocalMacApp()) return localApi(path, options);
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
    path: String(source?.path || source?.bookPath || book?.path || ""),
    profileId: String(source?.profileId || source?.profile_id || book?.profileId || "")
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
    path: d.path,
    profile_id: d.profileId
  });
}

function remember(book) {
  if (book?.id) bookCache.set(String(book.id), book);
  return book;
}

async function cloudBookId(scope, path) {
  const provider = String(scope?.provider || "");
  const library = String(scope?.library || "");
  const filePath = String(path || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
  const pathParts = filePath.split("/");
  const fileName = pathParts[pathParts.length - 1] || "";
  if (!["vps", "worker", "mobile", "local", "webdav"].includes(provider) ||
      !["books", "comics"].includes(library) || !fileName.trim()) {
    throw new Error("雲端書籍識別資訊無效。");
  }

  let identity;
  if (provider === "webdav") {
    const profileId = String(scope?.profileId || "").trim();
    // WebDAV paths normally contain "/" separators. Validate path segments
    // rather than rejecting slashes in the combined source/path identity.
    const invalidPath = !filePath || filePath.includes("\0") ||
      pathParts.some(part => !part || part === "." || part === "..");
    const invalidProfileId = !profileId ||
      profileId.includes("/") || profileId.includes("\\") ||
      profileId.includes("\0") || profileId.includes("\n") || profileId.includes("\r");
    if (invalidPath || invalidProfileId) {
      throw new Error("書籍檔名或 WebDAV 來源資訊無效，無法生成 Book ID。");
    }
    identity = profileId + "\n" + filePath;
  } else {
    identity = fileName.trim();
    if (!identity || identity.includes("/") || identity.includes("\\") || identity.includes("\0")) {
      throw new Error("書籍檔名無效，無法生成 Book ID。");
    }
  }

  try { identity = identity.normalize("NFC"); } catch (_) {}
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
async function addLocalBook(book) {
  if (!isLocalMacApp()) throw new Error("只能在 FRAME Ebook Mac 版加入本機書架。");
  if (!book || !book.id || !book.cloudSource) throw new Error("書籍資料不完整，無法加入本機書架。");
  const db = await openLocalDatabase();
  await localTransaction(db, ["books"], "readwrite", (tx, set) => {
    tx.objectStore("books").put(book);
    set(book);
  });
  return remember(book);
}

async function saveLocalBookCover(id, blob) {
  if (!isLocalMacApp()) return false;
  const key = String(id || "");
  if (!key || !(blob instanceof Blob) || !blob.size || blob.size > 2 * 1024 * 1024) {
    throw new Error("封面縮圖資料無效或超過 2 MiB。");
  }
  const db = await openLocalDatabase();
  await localTransaction(db, ["books"], "readwrite", (tx, set) => {
    const objectStore = tx.objectStore("books");
    const request = objectStore.get(key);
    request.onsuccess = () => {
      const book = request.result;
      if (!book) { set(false); return; }
      const updated = {
        ...book,
        coverBlob: blob,
        coverMime: blob.type || "image/webp",
        coverUpdatedAt: Date.now()
      };
      objectStore.put(updated);
      remember(updated);
      set(true);
    };
  });
  return true;
}

async function removeLocalBook(id) {
  if (!isLocalMacApp()) throw new Error("只能在 FRAME Ebook Mac 版管理本機書架。");
  const key = String(id || "");
  const db = await openLocalDatabase();
  await localTransaction(db, ["books", "states", "annotations"], "readwrite", (tx, set) => {
    tx.objectStore("books").delete(key);
    tx.objectStore("states").delete(key);
    const annotations = tx.objectStore("annotations");
    const request = annotations.getAll();
    request.onsuccess = () => (request.result || []).forEach(item => {
      if (item.bookId === key) annotations.delete(item.key);
    });
    set(true);
  });
  bookCache.delete(key);
  return true;
}


async function getBook(bookOrId) {
  if (bookOrId && typeof bookOrId === "object") {
    const descriptor = normalizeDescriptor(bookOrId);
    const query = descriptorQuery(bookOrId);
    const data = await api("/api/reading/state?" + query.toString(), {}, "無法讀取這本書的雲端閱讀資料。");
    const localBooks = isLocalMacApp()
      ? await api("/api/reading/bookshelf", {}, "無法讀取本機書架。")
      : { items: [] };
    const localBook = (localBooks.items || []).find(item => String(item.id) === descriptor.id);
    const base = bookCache.get(descriptor.id) || localBook || {
      id: descriptor.id,
      sourceType: "cloud",
      provider: descriptor.provider,
      library: descriptor.library,
      rootPath: descriptor.rootPath,
      path: descriptor.path,
      fileName: descriptor.path.split("/").pop(),
      title: descriptor.path.split("/").pop()?.replace(/\.(epub|cbz)$/i, "") || "未命名書籍",
      author: "",
      format: descriptor.path.toLowerCase().endsWith(".cbz") ? "CBZ" : "EPUB",
      shelf: descriptor.library,
      size: 0,
      progress: { percent: 0, label: "尚未閱讀", cfi: "", index: null },
      cloudSource: {
        provider: descriptor.provider,
        library: descriptor.library,
        rootPath: descriptor.rootPath,
        path: descriptor.path,
        profileId: descriptor.profileId
      }
    };
    const remote = data.state || {};
    const metadata = remote.metadata || {};
    return remember({
      ...base,
      ...metadata,
      title: metadata.manualTitle && metadata.title ? metadata.title :
        (base.title || metadata.title || "未命名書籍"),
      author: metadata.manualAuthor && metadata.author ? metadata.author :
        (base.author || metadata.author || ""),
      id: descriptor.id,
      sourceType: "cloud",
      progress: remote.progress || base.progress,
      appearance: remote.appearance || {},
      lastOpenedAt: Number(remote.lastOpenedAt) || Number(base.lastOpenedAt) || 0,
      manualTitle: !!metadata.manualTitle,
      manualAuthor: !!metadata.manualAuthor,
      cloudSource: {
        provider: descriptor.provider,
        library: descriptor.library,
        rootPath: descriptor.rootPath,
        path: descriptor.path,
        profileId: descriptor.profileId
      }
    });
  }
  const key = String(bookOrId || "");
  const cached = bookCache.get(key);
  if (cached) return cached;
  if (isLocalMacApp()) {
    const localBooks = await api("/api/reading/bookshelf", {}, "無法讀取本機書架。");
    const localBook = (localBooks.items || []).find(item => String(item.id) === key);
    return localBook ? remember(localBook) : null;
  }
  return null;
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


export {
  getBook, updateBook, listBooks, cloudBookId, addLocalBook, saveLocalBookCover, removeLocalBook,
  saveAnnotation, listAnnotations, deleteAnnotation, localDayKey,
  recordReadingEvent, getReadingEvents, getReadingSetting, setReadingSetting
};
