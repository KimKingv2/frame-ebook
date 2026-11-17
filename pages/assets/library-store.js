/* FRAME Reader cloud-only data client.
 * Persistent library state is stored in D1/R2 and original archives remain in Alist/OpenList.
 * The browser keeps only short-lived in-memory objects needed by the active page.
 */
const bookCache = new Map();


const LOCAL_DB_NAME = "frame-ebook-macos";
const LOCAL_DB_VERSION = 2;
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
      if (!db.objectStoreNames.contains("sync_meta")) db.createObjectStore("sync_meta", { keyPath: "key" });
    };
    request.onsuccess = () => {
      const db = request.result;
      migrateLegacyBookIds(db).then(() => resolve(db)).catch(error => {
        try { db.close(); } catch (_) {}
        reject(new Error("Mac 本機書籍識別遷移失敗，原始資料已保留：" + (error?.message || String(error))));
      });
    };
    request.onerror = () => reject(new Error("無法開啟 Mac 本機閱讀資料庫：" + (request.error?.message || "IndexedDB error")));
  });
}

async function filenameBookId(fileName) {
  let identity = String(fileName || "").trim();
  try { identity = identity.normalize("NFC"); } catch (_) {}
  if (!identity || identity.includes("/") || identity.includes("\\") || identity.includes("\0")) {
    throw new Error("書籍檔名無效，無法生成 Book ID。");
  }
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(identity));
  const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
  return "cloud:" + hash;
}

async function migrateLegacyBookIds(db) {
  const marker = await localTransaction(db, ["sync_meta"], "readonly", (tx, set) => {
    const request = tx.objectStore("sync_meta").get("legacyBookIdMigrationV1");
    request.onsuccess = () => set(request.result || null);
  });
  if (marker?.completedAt) return marker;

  const snapshot = await localTransaction(db, ["books", "states", "annotations", "events"], "readonly", (tx, set) => {
    const values = {};
    const names = ["books", "states", "annotations", "events"];
    let remaining = names.length;
    for (const name of names) {
      const request = tx.objectStore(name).getAll();
      request.onsuccess = () => {
        values[name] = request.result || [];
        remaining--;
        if (!remaining) set(values);
      };
    }
  });

  const byTarget = new Map();
  const targets = [];
  for (const book of snapshot.books || []) {
    const oldId = String(book.id || "");
    const fileName = String(book.fileName || book.cloudSource?.path?.split("/").pop() || "");
    if (!oldId || !fileName || !book.cloudSource || book.cloudSource.provider !== "webdav") continue;
    const nextId = await filenameBookId(fileName);
    if (oldId === nextId) continue;
    const item = { oldId, nextId, book };
    targets.push(item);
    if (!byTarget.has(nextId)) byTarget.set(nextId, []);
    byTarget.get(nextId).push(item);
  }

  const conflicted = new Set();
  for (const [targetId, group] of byTarget) {
    if (group.length > 1) group.forEach(item => conflicted.add(item.oldId));
    if ((snapshot.books || []).some(book => String(book.id || "") === targetId && !group.some(item => item.oldId === targetId))) {
      group.forEach(item => conflicted.add(item.oldId));
    }
  }

  const mapping = new Map();
  for (const item of targets) if (!conflicted.has(item.oldId)) mapping.set(item.oldId, item.nextId);
  const migratedBooks = [];
  for (const item of targets) {
    if (conflicted.has(item.oldId)) {
      migratedBooks.push({ ...item.book, idMigrationConflict: true });
    } else {
      migratedBooks.push({
        ...item.book,
        id: item.nextId,
        migratedFromBookId: item.oldId,
        cloudSource: { ...(item.book.cloudSource || {}), sourceId: item.book.cloudSource?.sourceId || "" }
      });
    }
  }

  const migratedStates = (snapshot.states || []).filter(item => mapping.has(String(item.id || "")))
    .map(item => ({ ...item, id: mapping.get(String(item.id)) }));
  const movedAnnotations = (snapshot.annotations || []).filter(item => mapping.has(String(item.bookId || "")))
    .map(item => {
      const bookId = mapping.get(String(item.bookId));
      return { ...item, bookId, key: bookId + "::" + String(item.id || item.key?.split("::").pop() || "") };
    });
  const movedEvents = (snapshot.events || []).filter(item => mapping.has(String(item.bookId || "")))
    .map(item => ({ ...item, bookId: mapping.get(String(item.bookId)) }));

  const report = {
    key: "legacyBookIdMigrationV1",
    completedAt: Date.now(),
    migrated: mapping.size,
    conflicts: conflicted.size,
    conflictBookIds: Array.from(conflicted).slice(0, 50)
  };

  await localTransaction(db, ["books", "states", "annotations", "events", "sync_meta"], "readwrite", tx => {
    const books = tx.objectStore("books");
    const states = tx.objectStore("states");
    const annotations = tx.objectStore("annotations");
    const events = tx.objectStore("events");
    for (const item of migratedBooks) {
      if (conflicted.has(String(item.migratedFromBookId || item.id))) books.put(item);
      else {
        books.put(item);
        books.delete(String(item.migratedFromBookId));
      }
    }
    for (const item of snapshot.states || []) {
      const nextId = mapping.get(String(item.id || ""));
      if (nextId) states.delete(String(item.id));
    }
    migratedStates.forEach(item => states.put(item));
    for (const item of snapshot.annotations || []) {
      if (mapping.has(String(item.bookId || ""))) annotations.delete(item.key);
    }
    movedAnnotations.forEach(item => annotations.put(item));
    movedEvents.forEach(item => events.put(item));
    tx.objectStore("sync_meta").put(report);
  });
  return report;
}

async function getBookIdMigrationReport() {
  if (!isLocalMacApp()) return null;
  const db = await openLocalDatabase();
  return localTransaction(db, ["sync_meta"], "readonly", (tx, set) => {
    const request = tx.objectStore("sync_meta").get("legacyBookIdMigrationV1");
    request.onsuccess = () => set(request.result || null);
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
  if (provider === "webdav" && (!filePath || filePath.includes("\0") ||
      pathParts.some(part => !part || part === "." || part === ".."))) {
    throw new Error("WebDAV 書籍路徑無效。");
  }
  return filenameBookId(fileName);
}

async function webDavSourceId(profile) {
  const rawUrl = String(profile?.baseUrl || profile?.base_url || "").trim();
  const username = String(profile?.username || "").trim().toLowerCase();
  if (!rawUrl || !username) throw new Error("WebDAV 來源缺少網址或帳號，無法建立跨設備來源識別碼。");
  let origin;
  try {
    const parsed = new URL(rawUrl);
    if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password) throw new Error("invalid");
    origin = parsed.origin.toLowerCase();
  } catch (_) {
    throw new Error("WebDAV 來源網址無效，無法建立跨設備來源識別碼。");
  }
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(origin + "\n" + username));
  const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
  return "webdav:" + hash;
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
  getBook, updateBook, listBooks, cloudBookId, webDavSourceId, getBookIdMigrationReport, addLocalBook, saveLocalBookCover, removeLocalBook,
  saveAnnotation, listAnnotations, deleteAnnotation, localDayKey,
  recordReadingEvent, getReadingEvents, getReadingSetting, setReadingSetting
};
